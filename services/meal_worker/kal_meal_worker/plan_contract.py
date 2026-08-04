"""Contratto del piano settimanale: richiesta dall'app, piano dal modello.

Due regole non negoziabili sono incise qui, una volta sola:

* l'AI **sceglie, non inventa**: puo' indicare solo `recipeId` presenti nel
  catalogo arrivato con la richiesta. Un id sconosciuto rende invalido tutto
  il piano (nessun piano a meta'), con codice ``PLAN_UNKNOWN_RECIPE``;
* l'AI **non dichiara mai** calorie o macronutrienti: qui non esiste alcun
  campo nutrizionale e qualunque chiave in piu' viene IGNORATA (mai letta,
  mai rimandata all'app). I numeri li calcola sempre l'app dalle ricette vere.
  Non basta pero' la struttura: ``why`` e ``notes`` sono testo libero, e una
  riga come «circa 600 kcal» affiancherebbe al valore calcolato dall'app un
  numero DICHIARATO dal modello. Per questo il testo libero non puo'
  contenere cifre: se ne ha, sparisce (vedi ``_free_text``).

A differenza di ``contract.py`` (foto), che pretende l'insieme ESATTO delle
chiavi, questo contratto e' tollerante sulle chiavi in piu' e rigidissimo sui
valori: un modello che aggiunge ``kcal`` a uno slot non deve far fallire un
piano per il resto corretto, ma quel numero non deve nemmeno sopravvivere.

La validazione e' pura: nessuna rete, nessun file, nessun processo figlio.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from datetime import date, timedelta
from typing import Any


class PlanContractError(ValueError):
    """Richiesta o piano fuori contratto.

    ``error_code`` e' stabile e arriva fino a ``fail_weekly_plan_job``: e'
    l'unica cosa che l'app vede quando un piano viene rifiutato, quindi non
    deve mai contenere testo prodotto dal modello.
    """

    def __init__(self, message: str, *, error_code: str) -> None:
        self.error_code = error_code
        super().__init__(message)


SCHEMA_VERSION = 1
MAXIMUM_DAYS = 14
MAXIMUM_RECIPES = 400
MAXIMUM_REQUEST_NOTES = 500
MAXIMUM_PLAN_NOTES = 400
MAXIMUM_WHY = 200
MINIMUM_SERVINGS = 0.5
MAXIMUM_SERVINGS = 4.0

# Ordine del contratto: e' anche l'ordine degli slot dentro un giorno.
MEALS: tuple[str, ...] = ("colazione", "pranzo", "cena", "spuntino")

_MEAL_ORDER = {meal: index for index, meal in enumerate(MEALS)}
_DATE_PATTERN = re.compile(r"^(\d{4})-(\d{2})-(\d{2})$")
_DIGIT = re.compile(r"\d")
_MAXIMUM_RECIPE_ID = 64
_MAXIMUM_RECIPE_NAME = 160
_MAXIMUM_TAGS = 8
_MAXIMUM_TAG_LENGTH = 24
_MAXIMUM_PREP_MINUTES = 10080

# Codici errore stabili.
BAD_REQUEST = "PLAN_BAD_REQUEST"
BAD_RESULT = "PLAN_BAD_RESULT"
UNKNOWN_RECIPE = "PLAN_UNKNOWN_RECIPE"
BAD_SERVINGS = "PLAN_BAD_SERVINGS"
BAD_DATES = "PLAN_BAD_DATES"
BAD_MEAL = "PLAN_BAD_MEAL"
DUPLICATE_SLOT = "PLAN_DUPLICATE_SLOT"


def _fail(message: str, error_code: str) -> PlanContractError:
    return PlanContractError(message, error_code=error_code)


def _mapping(value: Any, field: str, error_code: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise _fail(f"{field} deve essere un oggetto JSON", error_code)
    return value


def _sequence(value: Any, field: str, error_code: str) -> list[Any]:
    if not isinstance(value, list):
        raise _fail(f"{field} deve essere una lista", error_code)
    return value


def _text(value: Any, field: str, *, maximum: int, error_code: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise _fail(f"{field} deve essere una stringa non vuota", error_code)
    normalized = value.strip()
    if len(normalized) > maximum:
        raise _fail(f"{field} supera {maximum} caratteri", error_code)
    return normalized


def _optional_text(
    value: Any, field: str, *, maximum: int, error_code: str
) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str):
        raise _fail(f"{field} deve essere una stringa", error_code)
    normalized = value.strip()
    if not normalized:
        return None
    if len(normalized) > maximum:
        raise _fail(f"{field} supera {maximum} caratteri", error_code)
    return normalized


def _free_text(value: Any, field: str, *, maximum: int, error_code: str) -> str | None:
    """Testo libero del modello: ammesso, ma senza cifre.

    E' l'altra meta' della regola «l'AI non dichiara mai calorie o macro»:
    lo schema non ha campi numerici, ma ``why`` e ``notes`` sono prosa e una
    cifra li trasformerebbe in una dichiarazione nutrizionale accanto al
    numero vero calcolato dall'app.

    Come per le chiavi in piu', un piano buono non fallisce per una frase:
    il testo con cifre SPARISCE (torna ``None``), non arriva mai all'app.
    """
    text = _optional_text(value, field, maximum=maximum, error_code=error_code)
    if text is None or _DIGIT.search(text) is not None:
        return None
    return text


def _number(value: Any, field: str, error_code: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise _fail(f"{field} deve essere numerico", error_code)
    result = float(value)
    if result != result or result in (float("inf"), float("-inf")):
        raise _fail(f"{field} deve essere finito", error_code)
    return result


def _non_negative(value: Any, field: str, error_code: str) -> float:
    result = _number(value, field, error_code)
    if result < 0:
        raise _fail(f"{field} non puo essere negativo", error_code)
    return result


def _whole(value: Any, field: str, *, maximum: int, error_code: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise _fail(f"{field} deve essere un intero", error_code)
    if not 0 <= value <= maximum:
        raise _fail(f"{field} deve stare fra 0 e {maximum}", error_code)
    return value


def parse_plan_date(value: Any, field: str, *, error_code: str) -> date:
    """Data di calendario ISO stretta: ``AAAA-MM-GG`` e nient'altro.

    ``date.fromisoformat`` accetterebbe anche forme compatte e con orario:
    qui la data e' una chiave, quindi una sola forma e' ammessa.
    """
    if not isinstance(value, str):
        raise _fail(f"{field} deve essere una data ISO", error_code)
    match = _DATE_PATTERN.fullmatch(value.strip())
    if match is None:
        raise _fail(f"{field} non e una data AAAA-MM-GG", error_code)
    try:
        return date(int(match[1]), int(match[2]), int(match[3]))
    except ValueError as error:
        raise _fail(f"{field} non e una data esistente", error_code) from error


def format_plan_date(value: date) -> str:
    return value.isoformat()


def _servings(value: Any) -> float:
    """Porzioni ammesse: da mezza a quattro, a passi di mezza porzione."""
    servings = _number(value, "servings", BAD_SERVINGS)
    if not MINIMUM_SERVINGS <= servings <= MAXIMUM_SERVINGS:
        raise _fail(
            f"servings deve stare fra {MINIMUM_SERVINGS} e {MAXIMUM_SERVINGS}",
            BAD_SERVINGS,
        )
    halves = servings * 2
    if abs(halves - round(halves)) > 1e-9:
        raise _fail("servings va a passi di mezza porzione", BAD_SERVINGS)
    return round(halves) / 2


@dataclass(frozen=True)
class PlanTargets:
    """Obiettivi giornalieri di Marco: contesto per il modello, mai output."""

    calories: float
    protein: float
    carbs: float
    fat: float

    @classmethod
    def from_json(cls, value: Any) -> "PlanTargets":
        payload = _mapping(value, "targets", BAD_REQUEST)
        return cls(
            calories=_non_negative(
                payload.get("calories"), "targets.calories", BAD_REQUEST
            ),
            protein=_non_negative(
                payload.get("protein"), "targets.protein", BAD_REQUEST
            ),
            carbs=_non_negative(
                payload.get("carbs"), "targets.carbs", BAD_REQUEST
            ),
            fat=_non_negative(payload.get("fat"), "targets.fat", BAD_REQUEST),
        )

    def to_json(self) -> dict[str, Any]:
        return {
            "calories": self.calories,
            "protein": self.protein,
            "carbs": self.carbs,
            "fat": self.fat,
        }


@dataclass(frozen=True)
class PlanRecipeOption:
    """Una ricetta REALE del ricettario: l'unica scelta ammessa per il modello."""

    id: str
    name: str
    tags: tuple[str, ...]
    prep_minutes: int
    serving_kcal: float
    serving_protein: float
    serving_carbs: float
    serving_fat: float

    @classmethod
    def from_json(cls, value: Any, *, index: int) -> "PlanRecipeOption":
        payload = _mapping(value, f"recipes[{index}]", BAD_REQUEST)
        raw_tags = payload.get("tags")
        if raw_tags is None:
            tags: tuple[str, ...] = ()
        else:
            entries = _sequence(raw_tags, f"recipes[{index}].tags", BAD_REQUEST)
            if len(entries) > _MAXIMUM_TAGS:
                raise _fail(
                    f"recipes[{index}].tags supera {_MAXIMUM_TAGS} voci",
                    BAD_REQUEST,
                )
            tags = tuple(
                _text(
                    entry,
                    f"recipes[{index}].tags[{position}]",
                    maximum=_MAXIMUM_TAG_LENGTH,
                    error_code=BAD_REQUEST,
                )
                for position, entry in enumerate(entries)
            )
        return cls(
            id=_text(
                payload.get("id"),
                f"recipes[{index}].id",
                maximum=_MAXIMUM_RECIPE_ID,
                error_code=BAD_REQUEST,
            ),
            name=_text(
                payload.get("name"),
                f"recipes[{index}].name",
                maximum=_MAXIMUM_RECIPE_NAME,
                error_code=BAD_REQUEST,
            ),
            tags=tags,
            prep_minutes=_whole(
                payload.get("prepMinutes", 0),
                f"recipes[{index}].prepMinutes",
                maximum=_MAXIMUM_PREP_MINUTES,
                error_code=BAD_REQUEST,
            ),
            serving_kcal=_non_negative(
                payload.get("servingKcal"),
                f"recipes[{index}].servingKcal",
                BAD_REQUEST,
            ),
            serving_protein=_non_negative(
                payload.get("servingProtein"),
                f"recipes[{index}].servingProtein",
                BAD_REQUEST,
            ),
            serving_carbs=_non_negative(
                payload.get("servingCarbs"),
                f"recipes[{index}].servingCarbs",
                BAD_REQUEST,
            ),
            serving_fat=_non_negative(
                payload.get("servingFat"),
                f"recipes[{index}].servingFat",
                BAD_REQUEST,
            ),
        )

    def to_json(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "name": self.name,
            "tags": list(self.tags),
            "prepMinutes": self.prep_minutes,
            "servingKcal": self.serving_kcal,
            "servingProtein": self.serving_protein,
            "servingCarbs": self.serving_carbs,
            "servingFat": self.serving_fat,
        }


@dataclass(frozen=True)
class PlanRequest:
    """La richiesta che l'app ha messo nel job.

    E' anche il CONTRATTO con cui si valida il risultato: giorni ammessi,
    pasti ammessi, ricette ammesse.
    """

    start_date: date
    days: int
    meals: tuple[str, ...]
    targets: PlanTargets
    notes: str
    recipes: tuple[PlanRecipeOption, ...]

    @classmethod
    def from_json(cls, value: Any) -> "PlanRequest":
        payload = _mapping(value, "request", BAD_REQUEST)

        schema = payload.get("schema")
        if schema is not None and schema != SCHEMA_VERSION:
            raise _fail(
                f"Schema della richiesta non supportato: {schema!r}",
                BAD_REQUEST,
            )

        days = _whole(
            payload.get("days"),
            "days",
            maximum=MAXIMUM_DAYS,
            error_code=BAD_REQUEST,
        )
        if days < 1:
            raise _fail("Il piano copre da 1 a 14 giorni", BAD_REQUEST)

        raw_meals = _sequence(payload.get("meals"), "meals", BAD_REQUEST)
        selected: list[str] = []
        for position, raw_meal in enumerate(raw_meals):
            meal = _text(
                raw_meal, f"meals[{position}]", maximum=20, error_code=BAD_REQUEST
            ).lower()
            if meal not in _MEAL_ORDER:
                raise _fail(f"Pasto non riconosciuto: {meal!r}", BAD_REQUEST)
            if meal not in selected:
                selected.append(meal)
        if not selected:
            raise _fail("Serve almeno un pasto da pianificare", BAD_REQUEST)
        meals = tuple(sorted(selected, key=_MEAL_ORDER.__getitem__))

        raw_recipes = _sequence(payload.get("recipes"), "recipes", BAD_REQUEST)
        if not raw_recipes:
            raise _fail(
                "Serve almeno una ricetta nel catalogo della richiesta",
                BAD_REQUEST,
            )
        if len(raw_recipes) > MAXIMUM_RECIPES:
            raise _fail("Troppe ricette nella richiesta", BAD_REQUEST)
        recipes = tuple(
            PlanRecipeOption.from_json(entry, index=index)
            for index, entry in enumerate(raw_recipes)
        )
        if len({recipe.id for recipe in recipes}) != len(recipes):
            raise _fail("Il catalogo contiene ricette duplicate", BAD_REQUEST)

        notes = payload.get("notes")
        if notes is None:
            notes = ""
        if not isinstance(notes, str):
            raise _fail("notes deve essere una stringa", BAD_REQUEST)
        notes = notes.strip()
        if len(notes) > MAXIMUM_REQUEST_NOTES:
            raise _fail("Le note della richiesta sono troppo lunghe", BAD_REQUEST)

        return cls(
            start_date=parse_plan_date(
                payload.get("startDate"), "startDate", error_code=BAD_REQUEST
            ),
            days=days,
            meals=meals,
            targets=PlanTargets.from_json(payload.get("targets")),
            notes=notes,
            recipes=recipes,
        )

    @property
    def dates(self) -> tuple[date, ...]:
        return tuple(
            self.start_date + timedelta(days=offset) for offset in range(self.days)
        )

    @property
    def recipe_ids(self) -> frozenset[str]:
        return frozenset(recipe.id for recipe in self.recipes)

    @property
    def recipe_names_by_id(self) -> dict[str, str]:
        return {recipe.id: recipe.name for recipe in self.recipes}

    def to_json(self) -> dict[str, Any]:
        return {
            "schema": SCHEMA_VERSION,
            "days": self.days,
            "startDate": format_plan_date(self.start_date),
            "meals": list(self.meals),
            "targets": self.targets.to_json(),
            "notes": self.notes,
            "recipes": [recipe.to_json() for recipe in self.recipes],
        }


@dataclass(frozen=True)
class PlanSlot:
    """Una scelta: ricetta, porzioni, motivazione. Nessun numero nutrizionale."""

    date: date
    meal: str
    recipe_id: str
    servings: float
    why: str | None

    def to_json(self) -> dict[str, Any]:
        payload: dict[str, Any] = {
            "meal": self.meal,
            "recipeId": self.recipe_id,
            "servings": self.servings,
        }
        if self.why is not None:
            payload["why"] = self.why
        return payload


@dataclass(frozen=True)
class WeeklyPlanResult:
    """Il piano validato contro la richiesta, in forma canonica."""

    dates: tuple[date, ...]
    slots: tuple[PlanSlot, ...]
    notes: str

    @classmethod
    def from_json(cls, value: Any, *, request: PlanRequest) -> "WeeklyPlanResult":
        payload = _mapping(value, "Il piano", BAD_RESULT)

        schema = payload.get("schema")
        if schema is not None and schema != SCHEMA_VERSION:
            raise _fail(f"Schema del piano non supportato: {schema!r}", BAD_RESULT)

        raw_days = _sequence(payload.get("days"), "days", BAD_RESULT)
        if len(raw_days) != request.days:
            raise _fail(
                f"Il piano deve avere {request.days} giorni, non {len(raw_days)}",
                BAD_DATES,
            )

        allowed_meals = set(request.meals)
        recipe_names = request.recipe_names_by_id
        missing = {format_plan_date(day) for day in request.dates}
        slots: list[PlanSlot] = []

        for index, raw_day in enumerate(raw_days):
            day = _mapping(raw_day, f"days[{index}]", BAD_RESULT)
            day_date = parse_plan_date(
                day.get("date"), f"days[{index}].date", error_code=BAD_DATES
            )
            key = format_plan_date(day_date)
            if key not in missing:
                # Giorno fuori dal periodo, oppure ripetuto due volte.
                raise _fail(f"Il giorno {key} non fa parte del piano", BAD_DATES)
            missing.discard(key)

            raw_slots = _sequence(day.get("slots"), f"days[{index}].slots", BAD_RESULT)
            if len(raw_slots) > len(allowed_meals):
                raise _fail(f"Troppi pasti nel giorno {key}", DUPLICATE_SLOT)

            used: set[str] = set()
            for position, raw_slot in enumerate(raw_slots):
                slot = _mapping(
                    raw_slot, f"days[{index}].slots[{position}]", BAD_RESULT
                )
                meal = _text(
                    slot.get("meal"),
                    f"days[{index}].slots[{position}].meal",
                    maximum=20,
                    error_code=BAD_MEAL,
                ).lower()
                if meal not in allowed_meals:
                    raise _fail(
                        f"Il pasto {meal!r} non e tra quelli richiesti", BAD_MEAL
                    )
                if meal in used:
                    raise _fail(
                        f"Il giorno {key} ha due volte il pasto {meal}",
                        DUPLICATE_SLOT,
                    )
                used.add(meal)

                recipe_id = _text(
                    slot.get("recipeId"),
                    f"days[{index}].slots[{position}].recipeId",
                    maximum=_MAXIMUM_RECIPE_ID,
                    error_code=UNKNOWN_RECIPE,
                )
                if recipe_id not in recipe_names:
                    # L'AI sceglie, non inventa: niente piano a meta'.
                    raise _fail(
                        f"La ricetta {recipe_id} non e nel catalogo inviato",
                        UNKNOWN_RECIPE,
                    )

                slots.append(
                    PlanSlot(
                        date=day_date,
                        meal=meal,
                        recipe_id=recipe_id,
                        servings=_servings(slot.get("servings")),
                        why=_free_text(
                            slot.get("why"),
                            f"days[{index}].slots[{position}].why",
                            maximum=MAXIMUM_WHY,
                            error_code=BAD_RESULT,
                        ),
                    )
                )

        if missing:
            raise _fail(
                "Mancano dei giorni nel piano: " + ", ".join(sorted(missing)),
                BAD_DATES,
            )

        notes = (
            _free_text(
                payload.get("notes"),
                "notes",
                maximum=MAXIMUM_PLAN_NOTES,
                error_code=BAD_RESULT,
            )
            or ""
        )

        slots.sort(key=lambda slot: (slot.date, _MEAL_ORDER[slot.meal]))
        return cls(dates=request.dates, slots=tuple(slots), notes=notes)

    def slots_for(self, day: date) -> tuple[PlanSlot, ...]:
        return tuple(slot for slot in self.slots if slot.date == day)

    def to_json(self) -> dict[str, Any]:
        """Forma canonica: solo scelte, un giorno per ogni data richiesta.

        Ogni chiave in piu' letta dal modello (comprese eventuali calorie) e'
        gia' sparita qui: l'app riceve solo cosa mangiare e quanto.
        """
        return {
            "schema": SCHEMA_VERSION,
            "days": [
                {
                    "date": format_plan_date(day),
                    "slots": [slot.to_json() for slot in self.slots_for(day)],
                }
                for day in self.dates
            ],
            "notes": self.notes,
        }
