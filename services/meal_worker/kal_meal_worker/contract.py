from __future__ import annotations

from dataclasses import dataclass
from typing import Any


class ContractError(ValueError):
    """Il risultato del modello non rispetta il contratto dell'app."""


_PREPARATIONS = {
    "raw",
    "cooked",
    "grilled",
    "baked",
    "fried",
    "boiled",
    "mixed",
    "unknown",
}


def _required_string(value: Any, field: str, *, max_length: int) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ContractError(f"{field} deve essere una stringa non vuota")
    normalized = value.strip()
    if len(normalized) > max_length:
        raise ContractError(f"{field} supera {max_length} caratteri")
    return normalized


def _string_list(
    value: Any,
    field: str,
    *,
    max_items: int,
    max_length: int = 120,
) -> tuple[str, ...]:
    if not isinstance(value, list) or len(value) > max_items:
        raise ContractError(f"{field} deve contenere al massimo {max_items} voci")
    return tuple(
        _required_string(item, f"{field}[{index}]", max_length=max_length)
        for index, item in enumerate(value)
    )


def _number(value: Any, field: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ContractError(f"{field} deve essere numerico")
    result = float(value)
    if result != result or result in (float("inf"), float("-inf")):
        raise ContractError(f"{field} deve essere finito")
    return result


def _per100g_number(value: Any, field: str, *, maximum: float) -> float:
    result = _number(value, field)
    if not 0 <= result <= maximum:
        raise ContractError(f"{field} deve essere tra 0 e {maximum:g}")
    # Il contratto chiede al massimo una cifra decimale: lo schema non usa
    # multipleOf (il confronto in virgola mobile dei validatori rifiuterebbe
    # valori legittimi come 36.5), quindi qui si normalizza senza rifiutare.
    return round(result, 1)


# Coerenza Atwater lasca: se energyKcal si discosta oltre il 40% da
# 4P + 4C + 9F la voce viene segnalata nel campo uncertainty, mai rifiutata.
_ATWATER_TOLERANCE = 0.40
_ATWATER_WARNING = (
    "Energia per 100 g poco coerente con i macronutrienti dichiarati."
)
_UNCERTAINTY_MAX_LENGTH = 300


def _append_atwater_warning(uncertainty: str) -> str:
    if _ATWATER_WARNING in uncertainty:
        return uncertainty
    combined = f"{uncertainty} {_ATWATER_WARNING}".strip()
    if len(combined) > _UNCERTAINTY_MAX_LENGTH:
        keep = _UNCERTAINTY_MAX_LENGTH - len(_ATWATER_WARNING) - 1
        combined = f"{uncertainty[:keep].rstrip()} {_ATWATER_WARNING}"
    return combined


@dataclass(frozen=True)
class Per100g:
    """Valori nutrizionali stimati per 100 g, come su un'etichetta.

    Il worker nuovo esige sempre questo oggetto nel risultato del modello.
    L'opzionalita esiste solo lato app, per i risultati storici salvati
    prima di questa versione: li l'app mostra per-100 g vuoti da compilare
    in revisione, come per un inserimento manuale. I totali del piatto non
    passano mai da qui: li calcola sempre l'app da per-100 g e grammi.
    """

    energy_kcal: float
    protein_g: float
    carbs_g: float
    fat_g: float

    @classmethod
    def from_json(cls, value: Any) -> "Per100g":
        if not isinstance(value, dict):
            raise ContractError("per100g deve essere un oggetto")
        if set(value) != {"energyKcal", "proteinG", "carbsG", "fatG"}:
            raise ContractError("Campi per100g mancanti o inattesi")
        return cls(
            energy_kcal=_per100g_number(
                value["energyKcal"], "per100g.energyKcal", maximum=900
            ),
            protein_g=_per100g_number(
                value["proteinG"], "per100g.proteinG", maximum=100
            ),
            carbs_g=_per100g_number(
                value["carbsG"], "per100g.carbsG", maximum=100
            ),
            fat_g=_per100g_number(value["fatG"], "per100g.fatG", maximum=100),
        )

    def atwater_energy_kcal(self) -> float:
        return 4 * self.protein_g + 4 * self.carbs_g + 9 * self.fat_g

    def is_atwater_consistent(self) -> bool:
        reference = self.atwater_energy_kcal()
        if reference <= 0:
            return self.energy_kcal == 0
        deviation = abs(self.energy_kcal - reference)
        return deviation <= _ATWATER_TOLERANCE * reference

    def to_json(self) -> dict[str, Any]:
        return {
            "energyKcal": self.energy_kcal,
            "proteinG": self.protein_g,
            "carbsG": self.carbs_g,
            "fatG": self.fat_g,
        }


@dataclass(frozen=True)
class FoodSuggestion:
    name: str
    alternatives: tuple[str, ...]
    minimum_grams: float
    suggested_grams: float
    maximum_grams: float
    confidence: float
    preparation: str
    per100g: Per100g
    hidden_ingredients: tuple[str, ...]
    uncertainty: str

    @classmethod
    def from_json(cls, value: Any) -> "FoodSuggestion":
        if not isinstance(value, dict):
            raise ContractError("Ogni alimento deve essere un oggetto")

        expected = {
            "name",
            "alternatives",
            "minimumGrams",
            "suggestedGrams",
            "maximumGrams",
            "confidence",
            "preparation",
            "per100g",
            "hiddenIngredients",
            "uncertainty",
        }
        if set(value) != expected:
            raise ContractError("Campi alimento mancanti o inattesi")

        minimum = _number(value["minimumGrams"], "minimumGrams")
        suggested = _number(value["suggestedGrams"], "suggestedGrams")
        maximum = _number(value["maximumGrams"], "maximumGrams")
        if not (0 < minimum <= suggested <= maximum <= 3000):
            raise ContractError("La fascia dei grammi non e valida")

        confidence = _number(value["confidence"], "confidence")
        if not 0 <= confidence <= 1:
            raise ContractError("confidence deve essere tra 0 e 1")

        preparation = _required_string(
            value["preparation"], "preparation", max_length=20
        )
        if preparation not in _PREPARATIONS:
            raise ContractError("preparation non riconosciuta")

        per100g = Per100g.from_json(value["per100g"])

        uncertainty = value["uncertainty"]
        if (
            not isinstance(uncertainty, str)
            or len(uncertainty) > _UNCERTAINTY_MAX_LENGTH
        ):
            raise ContractError("uncertainty non valida")
        normalized_uncertainty = uncertainty.strip()
        if not per100g.is_atwater_consistent():
            normalized_uncertainty = _append_atwater_warning(
                normalized_uncertainty
            )

        return cls(
            name=_required_string(value["name"], "name", max_length=120),
            alternatives=_string_list(
                value["alternatives"], "alternatives", max_items=3
            ),
            minimum_grams=minimum,
            suggested_grams=suggested,
            maximum_grams=maximum,
            confidence=confidence,
            preparation=preparation,
            per100g=per100g,
            hidden_ingredients=_string_list(
                value["hiddenIngredients"],
                "hiddenIngredients",
                max_items=6,
            ),
            uncertainty=normalized_uncertainty,
        )


@dataclass(frozen=True)
class AnalysisResult:
    foods: tuple[FoodSuggestion, ...]
    questions: tuple[str, ...]
    overall_confidence: float
    notes: str

    @classmethod
    def from_json(cls, value: Any) -> "AnalysisResult":
        if not isinstance(value, dict):
            raise ContractError("Il risultato deve essere un oggetto JSON")
        if set(value) != {"foods", "questions", "overallConfidence", "notes"}:
            raise ContractError("Campi del risultato mancanti o inattesi")

        raw_foods = value["foods"]
        if not isinstance(raw_foods, list) or not 1 <= len(raw_foods) <= 12:
            raise ContractError("foods deve contenere da 1 a 12 elementi")

        overall_confidence = _number(
            value["overallConfidence"], "overallConfidence"
        )
        if not 0 <= overall_confidence <= 1:
            raise ContractError("overallConfidence deve essere tra 0 e 1")

        notes = value["notes"]
        if not isinstance(notes, str) or len(notes) > 500:
            raise ContractError("notes non valide")

        return cls(
            foods=tuple(FoodSuggestion.from_json(item) for item in raw_foods),
            questions=_string_list(
                value["questions"], "questions", max_items=5, max_length=240
            ),
            overall_confidence=overall_confidence,
            notes=notes.strip(),
        )

    def to_json(self) -> dict[str, Any]:
        return {
            "foods": [
                {
                    "name": food.name,
                    "alternatives": list(food.alternatives),
                    "minimumGrams": food.minimum_grams,
                    "suggestedGrams": food.suggested_grams,
                    "maximumGrams": food.maximum_grams,
                    "confidence": food.confidence,
                    "preparation": food.preparation,
                    "per100g": food.per100g.to_json(),
                    "hiddenIngredients": list(food.hidden_ingredients),
                    "uncertainty": food.uncertainty,
                }
                for food in self.foods
            ],
            "questions": list(self.questions),
            "overallConfidence": self.overall_confidence,
            "notes": self.notes,
        }
