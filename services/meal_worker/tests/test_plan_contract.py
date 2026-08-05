import json
import unittest
from datetime import date

from kal_meal_worker.plan_contract import (
    PlanContractError,
    PlanRequest,
    WeeklyPlanResult,
)


RECIPE_UNO = "11111111-1111-4111-8111-aaaaaaaaaaaa"
RECIPE_DUE = "22222222-2222-4222-8222-bbbbbbbbbbbb"
RECIPE_TRE = "33333333-3333-4333-8333-cccccccccccc"


def recipes_payload():
    return [
        {
            "id": RECIPE_UNO,
            "name": "Bowl pollo e riso",
            "tags": ["pranzo", "proteico"],
            "prepMinutes": 25,
            "servingKcal": 520.0,
            "servingProtein": 38.0,
            "servingCarbs": 45.0,
            "servingFat": 18.0,
        },
        {
            "id": RECIPE_DUE,
            "name": "Vellutata di ceci",
            "tags": ["cena"],
            "prepMinutes": 30,
            "servingKcal": 410.0,
            "servingProtein": 19.0,
            "servingCarbs": 52.0,
            "servingFat": 12.0,
        },
        {
            "id": RECIPE_TRE,
            "name": "Frittata di zucchine",
            "tags": ["cena", "veloce"],
            "prepMinutes": 15,
            "servingKcal": 380.0,
            "servingProtein": 26.0,
            "servingCarbs": 8.0,
            "servingFat": 27.0,
        },
    ]


def request_payload(**changes):
    payload = {
        "schema": 1,
        "days": 2,
        "startDate": "2026-08-05",
        "meals": ["pranzo", "cena"],
        "targets": {
            "calories": 2400.0,
            "protein": 160.0,
            "carbs": 250.0,
            "fat": 80.0,
        },
        "notes": "Niente funghi",
        "recipes": recipes_payload(),
    }
    payload.update(changes)
    return payload


def valid_request(**changes):
    return PlanRequest.from_json(request_payload(**changes))


def plan_payload(**changes):
    payload = {
        "schema": 1,
        "days": [
            {
                "date": "2026-08-05",
                "slots": [
                    {
                        "meal": "pranzo",
                        "recipeId": RECIPE_UNO,
                        "servings": 1.5,
                        "why": "Piatto unico completo per il rientro in ufficio.",
                    },
                    {
                        "meal": "cena",
                        "recipeId": RECIPE_DUE,
                        "servings": 1,
                        "why": "Cena leggera dopo un pranzo abbondante.",
                    },
                ],
            },
            {
                "date": "2026-08-06",
                "slots": [
                    {
                        "meal": "pranzo",
                        "recipeId": RECIPE_TRE,
                        "servings": 2,
                        "why": "Alterna la fonte proteica rispetto a ieri.",
                    },
                    {
                        "meal": "cena",
                        "recipeId": RECIPE_UNO,
                        "servings": 1,
                        "why": "Chiude la giornata vicino agli obiettivi.",
                    },
                ],
            },
        ],
        "notes": "Settimana varia, senza funghi.",
    }
    payload.update(changes)
    return payload


class PlanRequestTest(unittest.TestCase):
    def test_reads_days_meals_and_catalogue(self) -> None:
        request = valid_request()

        self.assertEqual(request.start_date, date(2026, 8, 5))
        self.assertEqual(request.days, 2)
        self.assertEqual(request.meals, ("pranzo", "cena"))
        self.assertEqual(request.dates, (date(2026, 8, 5), date(2026, 8, 6)))
        self.assertEqual(
            request.recipe_ids, frozenset({RECIPE_UNO, RECIPE_DUE, RECIPE_TRE})
        )
        self.assertEqual(request.recipe_names_by_id[RECIPE_UNO], "Bowl pollo e riso")
        self.assertEqual(request.targets.calories, 2400.0)
        self.assertEqual(request.notes, "Niente funghi")

    def test_meals_are_deduplicated_and_ordered(self) -> None:
        request = valid_request(meals=["cena", "colazione", "cena"])

        self.assertEqual(request.meals, ("colazione", "cena"))

    def test_rejects_out_of_range_days(self) -> None:
        for days in (0, 15):
            with self.subTest(days=days):
                with self.assertRaises(PlanContractError) as context:
                    valid_request(days=days)
                self.assertEqual(context.exception.error_code, "PLAN_BAD_REQUEST")

    def test_rejects_unknown_schema_and_meal(self) -> None:
        with self.assertRaises(PlanContractError) as schema_error:
            valid_request(schema=2)
        self.assertEqual(schema_error.exception.error_code, "PLAN_BAD_REQUEST")

        with self.assertRaises(PlanContractError) as meal_error:
            valid_request(meals=["merenda"])
        self.assertEqual(meal_error.exception.error_code, "PLAN_BAD_REQUEST")

    def test_rejects_empty_and_duplicated_catalogue(self) -> None:
        with self.assertRaises(PlanContractError) as empty:
            valid_request(recipes=[])
        self.assertEqual(empty.exception.error_code, "PLAN_BAD_REQUEST")

        duplicated = recipes_payload()[:1] * 2
        with self.assertRaises(PlanContractError) as duplicate:
            valid_request(recipes=duplicated)
        self.assertIn("duplicate", str(duplicate.exception))

    def test_rejects_dates_that_are_not_calendar_days(self) -> None:
        for raw in ("20260805", "2026-8-5", "2026-02-30", "2026-08-05T10:00:00"):
            with self.subTest(raw=raw):
                with self.assertRaises(PlanContractError) as context:
                    valid_request(startDate=raw)
                self.assertEqual(context.exception.error_code, "PLAN_BAD_REQUEST")

    def test_round_trip_of_the_saved_request(self) -> None:
        request = valid_request()

        self.assertEqual(PlanRequest.from_json(request.to_json()), request)


class PlanWorkoutsTest(unittest.TestCase):
    """I giorni di allenamento: dati dell'app, mai scelte del modello."""

    def test_reads_workouts_in_order_and_survives_a_round_trip(self) -> None:
        request = valid_request(
            workouts=[
                {"date": "2026-08-06", "name": "Gambe", "proteinMeal": "cena"},
                {"date": "2026-08-05", "name": "Spinta", "proteinMeal": "cena"},
            ]
        )

        self.assertEqual(
            [(workout.date.isoformat(), workout.name) for workout in request.workouts],
            [("2026-08-05", "Spinta"), ("2026-08-06", "Gambe")],
        )
        self.assertEqual(
            request.workouts_by_date[date(2026, 8, 5)].protein_meal, "cena"
        )
        self.assertEqual(PlanRequest.from_json(request.to_json()), request)

    def test_a_request_without_workouts_stays_valid(self) -> None:
        # Le richieste salvate prima del piano unificato non hanno la chiave:
        # devono restare rileggibili senza bump di schema.
        request = valid_request()

        self.assertEqual(request.workouts, ())
        self.assertEqual(request.to_json()["workouts"], [])

    def test_a_workout_without_protein_meal_is_allowed(self) -> None:
        # Senza storico non si conosce l'ora dell'allenamento: il giorno
        # viaggia lo stesso, senza indicazione inventata.
        request = valid_request(
            workouts=[{"date": "2026-08-05", "name": "Spinta"}]
        )

        self.assertIsNone(request.workouts[0].protein_meal)
        self.assertNotIn("proteinMeal", request.to_json()["workouts"][0])

    def test_rejects_a_workout_outside_the_planned_days(self) -> None:
        with self.assertRaises(PlanContractError) as context:
            valid_request(
                workouts=[{"date": "2026-08-09", "name": "Gambe"}]
            )

        self.assertEqual(context.exception.error_code, "PLAN_BAD_REQUEST")

    def test_rejects_two_workouts_in_the_same_day(self) -> None:
        with self.assertRaises(PlanContractError) as context:
            valid_request(
                workouts=[
                    {"date": "2026-08-05", "name": "Spinta"},
                    {"date": "2026-08-05", "name": "Gambe"},
                ]
            )

        self.assertEqual(context.exception.error_code, "PLAN_BAD_REQUEST")

    def test_rejects_a_protein_meal_that_is_not_planned(self) -> None:
        # Il pasto dopo l'allenamento deve essere uno di quelli richiesti,
        # altrimenti il modello non potrebbe metterci niente.
        with self.assertRaises(PlanContractError) as context:
            valid_request(
                workouts=[
                    {
                        "date": "2026-08-05",
                        "name": "Spinta",
                        "proteinMeal": "colazione",
                    }
                ]
            )

        self.assertEqual(context.exception.error_code, "PLAN_BAD_REQUEST")

    def test_rejects_malformed_workouts(self) -> None:
        cases = {
            "non una lista": {"workouts": {"date": "2026-08-05"}},
            "senza nome": {"workouts": [{"date": "2026-08-05"}]},
            "data non ISO": {"workouts": [{"date": "05/08/2026", "name": "X"}]},
            "pasto inventato": {
                "workouts": [
                    {"date": "2026-08-05", "name": "X", "proteinMeal": "merenda"}
                ]
            },
        }
        for name, changes in cases.items():
            with self.subTest(name=name):
                with self.assertRaises(PlanContractError) as context:
                    valid_request(**changes)
                self.assertEqual(context.exception.error_code, "PLAN_BAD_REQUEST")


class WeeklyPlanResultTest(unittest.TestCase):
    def test_accepts_a_valid_plan_and_orders_the_slots(self) -> None:
        request = valid_request()

        result = WeeklyPlanResult.from_json(plan_payload(), request=request)

        self.assertEqual(len(result.slots), 4)
        self.assertEqual(
            [(slot.date.isoformat(), slot.meal) for slot in result.slots],
            [
                ("2026-08-05", "pranzo"),
                ("2026-08-05", "cena"),
                ("2026-08-06", "pranzo"),
                ("2026-08-06", "cena"),
            ],
        )
        self.assertEqual(result.slots[0].servings, 1.5)
        self.assertEqual(result.slots[1].servings, 1.0)
        self.assertEqual(result.notes, "Settimana varia, senza funghi.")

    def test_rejects_a_recipe_outside_the_catalogue(self) -> None:
        request = valid_request()
        payload = plan_payload()
        payload["days"][0]["slots"][0]["recipeId"] = "ricetta-inventata"

        with self.assertRaises(PlanContractError) as context:
            WeeklyPlanResult.from_json(payload, request=request)

        self.assertEqual(context.exception.error_code, "PLAN_UNKNOWN_RECIPE")

    def test_rejects_servings_outside_the_half_portion_scale(self) -> None:
        request = valid_request()
        for servings in (0, 0.25, 1.25, 4.5, "1", True, None):
            with self.subTest(servings=servings):
                payload = plan_payload()
                payload["days"][0]["slots"][0]["servings"] = servings
                with self.assertRaises(PlanContractError) as context:
                    WeeklyPlanResult.from_json(payload, request=request)
                self.assertEqual(context.exception.error_code, "PLAN_BAD_SERVINGS")

    def test_accepts_the_extremes_of_the_servings_scale(self) -> None:
        request = valid_request()
        payload = plan_payload()
        payload["days"][0]["slots"][0]["servings"] = 0.5
        payload["days"][0]["slots"][1]["servings"] = 4

        result = WeeklyPlanResult.from_json(payload, request=request)

        self.assertEqual(
            [slot.servings for slot in result.slots_for(date(2026, 8, 5))],
            [0.5, 4.0],
        )

    def test_rejects_wrong_days(self) -> None:
        request = valid_request()

        short = plan_payload()
        short["days"] = short["days"][:1]

        outside = plan_payload()
        outside["days"][1]["date"] = "2026-08-09"

        duplicated = plan_payload()
        duplicated["days"][1]["date"] = "2026-08-05"

        for name, payload in (
            ("giorno mancante", short),
            ("giorno estraneo", outside),
            ("giorno ripetuto", duplicated),
        ):
            with self.subTest(name=name):
                with self.assertRaises(PlanContractError) as context:
                    WeeklyPlanResult.from_json(payload, request=request)
                self.assertEqual(context.exception.error_code, "PLAN_BAD_DATES")

    def test_rejects_two_slots_for_the_same_meal(self) -> None:
        request = valid_request()
        payload = plan_payload()
        payload["days"][0]["slots"][1]["meal"] = "pranzo"

        with self.assertRaises(PlanContractError) as context:
            WeeklyPlanResult.from_json(payload, request=request)

        self.assertEqual(context.exception.error_code, "PLAN_DUPLICATE_SLOT")

    def test_rejects_a_meal_that_was_not_requested(self) -> None:
        request = valid_request()
        payload = plan_payload()
        payload["days"][0]["slots"][0]["meal"] = "colazione"

        with self.assertRaises(PlanContractError) as context:
            WeeklyPlanResult.from_json(payload, request=request)

        self.assertEqual(context.exception.error_code, "PLAN_BAD_MEAL")

    def test_calories_from_the_model_are_ignored_and_never_serialized(self) -> None:
        request = valid_request()
        payload = plan_payload()
        payload["totalCalories"] = 12345
        payload["days"][0]["dayKcal"] = 2400
        payload["days"][0]["slots"][0]["kcal"] = 780
        payload["days"][0]["slots"][0]["macros"] = {"protein": 57}

        result = WeeklyPlanResult.from_json(payload, request=request)
        serialized = json.dumps(result.to_json())

        self.assertEqual(len(result.slots), 4)
        self.assertNotIn("kcal", serialized)
        self.assertNotIn("macros", serialized)
        self.assertNotIn("12345", serialized)

    def test_free_text_with_digits_is_dropped(self) -> None:
        # Lo schema non ha campi numerici, ma "why" e "notes" sono prosa:
        # una cifra li' e' un numero DICHIARATO dal modello accanto a quello
        # calcolato dall'app. Il piano resta buono, la frase sparisce.
        request = valid_request()
        payload = plan_payload(notes="In media 2400 kcal al giorno.")
        payload["days"][0]["slots"][0]["why"] = "Circa 600 kcal, leggera per la sera"

        result = WeeklyPlanResult.from_json(payload, request=request)
        serialized = json.dumps(result.to_json())

        self.assertIsNone(result.slots[0].why)
        self.assertEqual(result.notes, "")
        self.assertNotIn("600", serialized)
        self.assertNotIn("2400", serialized)
        self.assertNotIn("kcal", serialized)
        # Il resto del piano non ne risente: 4 slot e le altre motivazioni.
        self.assertEqual(len(result.slots), 4)
        self.assertEqual(result.slots[1].why, "Cena leggera dopo un pranzo abbondante.")

    def test_canonical_form_covers_every_requested_day(self) -> None:
        request = valid_request()
        payload = plan_payload()
        payload["days"][1]["slots"] = []

        canonical = WeeklyPlanResult.from_json(payload, request=request).to_json()

        self.assertEqual(canonical["schema"], 1)
        self.assertEqual(
            [day["date"] for day in canonical["days"]],
            ["2026-08-05", "2026-08-06"],
        )
        self.assertEqual(canonical["days"][1]["slots"], [])
        self.assertEqual(
            canonical["days"][0]["slots"][0],
            {
                "meal": "pranzo",
                "recipeId": RECIPE_UNO,
                "servings": 1.5,
                "why": "Piatto unico completo per il rientro in ufficio.",
            },
        )

    def test_re_reading_the_canonical_form_is_stable(self) -> None:
        request = valid_request()
        first = WeeklyPlanResult.from_json(plan_payload(), request=request)

        second = WeeklyPlanResult.from_json(first.to_json(), request=request)

        self.assertEqual(first, second)

    def test_missing_or_empty_why_becomes_none(self) -> None:
        request = valid_request()
        payload = plan_payload()
        del payload["days"][0]["slots"][0]["why"]
        payload["days"][0]["slots"][1]["why"] = "   "

        result = WeeklyPlanResult.from_json(payload, request=request)

        self.assertIsNone(result.slots[0].why)
        self.assertIsNone(result.slots[1].why)
        self.assertNotIn("why", result.to_json()["days"][0]["slots"][0])

    def test_rejects_notes_and_why_that_are_too_long(self) -> None:
        request = valid_request()

        long_notes = plan_payload(notes="x" * 401)
        long_why = plan_payload()
        long_why["days"][0]["slots"][0]["why"] = "y" * 201

        for name, payload in (("notes", long_notes), ("why", long_why)):
            with self.subTest(name=name):
                with self.assertRaises(PlanContractError) as context:
                    WeeklyPlanResult.from_json(payload, request=request)
                self.assertEqual(context.exception.error_code, "PLAN_BAD_RESULT")

    def test_rejects_a_plan_that_is_not_an_object(self) -> None:
        request = valid_request()

        with self.assertRaises(PlanContractError) as context:
            WeeklyPlanResult.from_json([], request=request)

        self.assertEqual(context.exception.error_code, "PLAN_BAD_RESULT")


if __name__ == "__main__":
    unittest.main()
