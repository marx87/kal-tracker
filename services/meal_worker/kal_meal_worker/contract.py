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


@dataclass(frozen=True)
class FoodSuggestion:
    name: str
    alternatives: tuple[str, ...]
    minimum_grams: float
    suggested_grams: float
    maximum_grams: float
    confidence: float
    preparation: str
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

        uncertainty = value["uncertainty"]
        if not isinstance(uncertainty, str) or len(uncertainty) > 300:
            raise ContractError("uncertainty non valida")

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
            hidden_ingredients=_string_list(
                value["hiddenIngredients"],
                "hiddenIngredients",
                max_items=6,
            ),
            uncertainty=uncertainty.strip(),
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
                    "hiddenIngredients": list(food.hidden_ingredients),
                    "uncertainty": food.uncertainty,
                }
                for food in self.foods
            ],
            "questions": list(self.questions),
            "overallConfidence": self.overall_confidence,
            "notes": self.notes,
        }
