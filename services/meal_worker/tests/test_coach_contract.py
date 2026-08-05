import json
import unittest
from datetime import date

from kal_meal_worker.coach_contract import (
    CoachContractError,
    CoachNarrativeResult,
    CoachRequest,
    ensure_text_only,
)


def request_payload(**changes):
    """La richiesta esatta che scrive `CoachMetrics.toRequestJson()` in Dart."""
    payload = {
        "week_start": "2026-07-27",
        "week_end": "2026-08-02",
        "tdee": {
            "kcal": 2680,
            "source": "misurato",
            "average_daily_kcal": 2410,
            "weight_change_kg": -0.42,
            "diary_days": 6,
            "weigh_in_days": 5,
        },
        "adherence": {
            "overall": "drifting",
            "lines": [
                {
                    "label": "Calorie",
                    "grade": "onTrack",
                    "planned": 2200.0,
                    "actual": 2410.0,
                    "unit": "kcal",
                    "days_counted": 6,
                    "days_missing": 1,
                },
                {
                    "label": "Proteine",
                    "grade": "off",
                    "planned": 170.0,
                    "actual": 118.0,
                    "unit": "g",
                    "days_counted": 6,
                    "days_missing": 1,
                },
                {
                    "label": "Allenamenti",
                    "grade": "unknown",
                    "planned": None,
                    "actual": None,
                    "unit": "",
                    "days_counted": 3,
                    "days_missing": 0,
                },
            ],
        },
        "recomposition": {
            "lean_trend": "holding",
            "lean_change_kg": 0.1,
            "fat_change_kg": -0.55,
            "is_recomposition": True,
        },
        "projection": {
            "state": "moving",
            "target_weight_kg": 87.4,
            "current_average_kg": 91.32,
            "observed_kg_per_week": -0.412,
            "projected_date": "2026-12-02",
            "planned_date": "2026-11-18",
            "weeks_late": 2,
        },
        "overtraining": {
            "level": "watch",
            "fired": ["risingEffort", "lowProtein"],
            "unknown": ["fallingBodyWater"],
        },
        "false_movement": {
            "kind": "falseDrop",
            "daily_change_kg": -0.7,
            "trend_change_kg": -0.05,
        },
        "workouts_done": 3,
        "data_quality": {"filled": 3, "total": 4},
        "headlines": [
            "Consumo misurato questa settimana: 2680 kcal.",
            "Aderenza: si scosta.",
            "Massa magra tenuta.",
            "A questo ritmo arrivi a 87,4 kg il 2 dicembre.",
            "Tieni d'occhio.",
        ],
    }
    payload.update(changes)
    return payload


def valid_request(**changes):
    return CoachRequest.from_json(request_payload(**changes))


def narrative_payload(**changes):
    payload = {
        "headline": "Settimana solida, proteine da rialzare",
        "paragraphs": [
            "Il consumo che vedi sopra ora e misurato sui tuoi dati e non "
            "piu stimato: le pesate e il diario di questa settimana bastano.",
            "Le proteine sono l'unica cosa lontana dal previsto, ed e quella "
            "che spiega lo sforzo percepito in salita.",
            "La settimana prossima tieni le calorie dove sono e sposta il "
            "grosso delle proteine nel pasto dopo l'allenamento.",
        ],
    }
    payload.update(changes)
    return payload


class CoachRequestTest(unittest.TestCase):
    def test_reads_the_report_written_by_the_app(self) -> None:
        request = valid_request()

        self.assertEqual(request.week_start, date(2026, 7, 27))
        self.assertEqual(request.week_end, date(2026, 8, 2))
        self.assertTrue(request.tdee.is_measured)
        self.assertEqual(request.tdee.kcal, 2680)
        # Nel prompt deve leggersi «2680», non «2680.0»: il secondo sembra una
        # precisione che il consumo misurato non ha.
        compact = json.dumps(request.to_json(), separators=(",", ":"))
        self.assertIn('"kcal":2680,', compact)
        self.assertEqual(request.adherence.overall, "drifting")
        self.assertEqual(len(request.adherence.lines), 3)
        self.assertEqual(request.overtraining.fired, ("risingEffort", "lowProtein"))
        self.assertEqual(request.workouts_done, 3)
        self.assertEqual(request.data_quality.filled, 3)
        self.assertEqual(len(request.headlines), 5)

    def test_a_missing_measure_stays_missing(self) -> None:
        # `null` non e' zero: e' «questa settimana non lo so», e il commento
        # deve poterlo dire invece di inventarlo.
        payload = request_payload()
        payload["tdee"]["average_daily_kcal"] = None
        payload["tdee"]["weight_change_kg"] = None
        payload["recomposition"]["lean_change_kg"] = None

        request = CoachRequest.from_json(payload)

        self.assertIsNone(request.tdee.average_daily_kcal)
        self.assertIsNone(request.tdee.weight_change_kg)
        self.assertIsNone(request.recomposition.lean_change_kg)

    def test_a_report_without_a_goal_has_no_projection(self) -> None:
        request = valid_request(projection=None)

        self.assertIsNone(request.projection)
        self.assertIsNone(request.to_json()["projection"])

    def test_being_early_is_a_negative_delay(self) -> None:
        payload = request_payload()
        payload["projection"]["weeks_late"] = -3

        request = CoachRequest.from_json(payload)

        self.assertEqual(request.projection.weeks_late, -3)

    def test_an_impossible_delay_is_treated_as_unknown_not_as_a_bad_request(
        self,
    ) -> None:
        """Una data obiettivo digitata col 2046 non deve spegnere il coach.

        `weeks_late` nasce dalla differenza fra la data promessa e quella
        proiettata: con l'anno sbagliato diventa mille settimane. Rifiutare la
        richiesta la renderebbe non ritentabile, e ogni commento successivo
        morirebbe allo stesso modo per un dettaglio di contorno.
        """
        for out_of_scale in (-1043, 1043):
            with self.subTest(weeks_late=out_of_scale):
                payload = request_payload()
                payload["projection"]["weeks_late"] = out_of_scale

                request = CoachRequest.from_json(payload)

                self.assertIsNone(request.projection.weeks_late)
                # Le due date restano: il rapporto vive lo stesso.
                self.assertIsNotNone(request.projection.planned_date)

    def test_a_delay_that_is_not_a_whole_number_is_still_a_bad_request(self) -> None:
        payload = request_payload()
        payload["projection"]["weeks_late"] = "due"

        with self.assertRaises(CoachContractError) as context:
            CoachRequest.from_json(payload)

        self.assertEqual(context.exception.error_code, "COACH_BAD_REQUEST")

    def test_headlines_may_contain_digits(self) -> None:
        # Sono i numeri dell'app: il divieto di cifre vale sul testo del
        # modello, non su quello che il modello legge.
        request = valid_request()

        self.assertIn("2680", request.headlines[0])
        self.assertIn("2680", json.dumps(request.to_json(), ensure_ascii=False))

    def test_canonical_form_drops_keys_the_app_did_not_promise(self) -> None:
        request = valid_request(inventato="qualcosa")

        self.assertNotIn("inventato", request.to_json())
        self.assertNotIn("inventato", json.dumps(request.to_json()))

    def test_rejects_a_request_that_is_not_an_object(self) -> None:
        with self.assertRaises(CoachContractError) as context:
            CoachRequest.from_json([])

        self.assertEqual(context.exception.error_code, "COACH_BAD_REQUEST")

    def test_rejects_a_week_that_ends_before_it_starts(self) -> None:
        with self.assertRaisesRegex(CoachContractError, "prima di iniziare"):
            valid_request(week_start="2026-08-02", week_end="2026-07-27")

    def test_rejects_a_date_that_is_not_a_day_label(self) -> None:
        with self.assertRaisesRegex(CoachContractError, "AAAA-MM-GG"):
            valid_request(week_end="2026-08-02T00:00:00Z")

    def test_rejects_an_unknown_tdee_source(self) -> None:
        payload = request_payload()
        payload["tdee"]["source"] = "indovinato"

        with self.assertRaisesRegex(CoachContractError, "Origine del consumo"):
            CoachRequest.from_json(payload)

    def test_rejects_a_measure_that_is_not_a_number(self) -> None:
        payload = request_payload()
        payload["tdee"]["kcal"] = "2680"

        with self.assertRaisesRegex(CoachContractError, "numerico"):
            CoachRequest.from_json(payload)

    def test_rejects_data_quality_that_counts_more_than_it_has(self) -> None:
        with self.assertRaisesRegex(CoachContractError, "supera"):
            valid_request(data_quality={"filled": 5, "total": 4})

    def test_rejects_an_unsupported_schema(self) -> None:
        with self.assertRaisesRegex(CoachContractError, "Schema"):
            valid_request(schema=2)

    def test_a_new_grade_in_the_app_does_not_break_the_report(self) -> None:
        # I nomi degli enum finiscono solo nel prompt: un grado nuovo non deve
        # trasformare un rapporto intero in un job fallito.
        payload = request_payload()
        payload["adherence"]["overall"] = "gradoNuovo"

        self.assertEqual(
            CoachRequest.from_json(payload).adherence.overall, "gradoNuovo"
        )

    def test_a_grade_that_is_not_a_name_is_still_refused(self) -> None:
        payload = request_payload()
        payload["adherence"]["overall"] = "grado con spazi"

        with self.assertRaisesRegex(CoachContractError, "non e un nome"):
            CoachRequest.from_json(payload)


class CoachNarrativeResultTest(unittest.TestCase):
    def test_reads_a_clean_comment(self) -> None:
        result = CoachNarrativeResult.from_json(narrative_payload())

        self.assertEqual(len(result.paragraphs), 3)
        self.assertEqual(result.headline, "Settimana solida, proteine da rialzare")
        self.assertEqual(result.dropped, 0)

    def test_a_paragraph_with_a_digit_disappears(self) -> None:
        payload = narrative_payload()
        payload["paragraphs"][1] = "Hai mangiato circa 600 kcal in meno al giorno."

        result = CoachNarrativeResult.from_json(payload)

        self.assertEqual(len(result.paragraphs), 2)
        self.assertEqual(result.dropped, 1)
        self.assertNotIn("600", json.dumps(result.to_json()))

    def test_a_headline_with_a_digit_disappears_without_losing_the_comment(
        self,
    ) -> None:
        result = CoachNarrativeResult.from_json(
            narrative_payload(headline="Settimana da 2410 kcal")
        )

        self.assertIsNone(result.headline)
        self.assertEqual(len(result.paragraphs), 3)
        # Il titolo assente si OMETTE: un null non e' una stringa e la CHECK
        # del database lo rifiuterebbe.
        self.assertNotIn("headline", result.to_json())

    def test_digits_in_any_alphabet_are_dropped(self) -> None:
        payload = narrative_payload()
        payload["paragraphs"][0] = "Sei sceso di ٢ chili questa settimana."

        self.assertEqual(CoachNarrativeResult.from_json(payload).dropped, 1)

    def test_numbers_that_are_not_decimal_digits_are_dropped_too(self) -> None:
        """«½ chilo» e' un numero del modello quanto «0,5 chili».

        Il filtro guardava solo le cifre decimali (Nd): frazioni e numerali
        passavano indenni anche dalla CHECK del database, che verifica il TIPO
        del campo e non il contenuto della prosa.
        """
        for numeral in ("½", "¾", "⅓", "Ⅶ", "①"):
            with self.subTest(numeral=numeral):
                payload = narrative_payload()
                payload["paragraphs"][0] = (
                    f"Hai perso {numeral} chilo piu' del previsto."
                )

                result = CoachNarrativeResult.from_json(payload)

                self.assertEqual(result.dropped, 1)
                self.assertNotIn(
                    numeral, json.dumps(result.to_json(), ensure_ascii=False)
                )

    def test_a_headline_with_a_fraction_is_dropped_without_losing_the_comment(
        self,
    ) -> None:
        payload = narrative_payload(headline="Settimana solida: ½ chilo in meno")

        result = CoachNarrativeResult.from_json(payload)

        self.assertIsNone(result.headline)
        self.assertEqual(len(result.paragraphs), 3)

    def test_only_the_first_five_paragraphs_survive(self) -> None:
        payload = narrative_payload(
            paragraphs=[f"Capoverso numero {name}." for name in "abcdefg"]
        )

        result = CoachNarrativeResult.from_json(payload)

        self.assertEqual(len(result.paragraphs), 5)
        self.assertEqual(result.dropped, 2)

    def test_an_overlong_paragraph_is_dropped(self) -> None:
        payload = narrative_payload()
        payload["paragraphs"][0] = "a" * 401

        self.assertEqual(CoachNarrativeResult.from_json(payload).dropped, 1)

    def test_a_comment_made_only_of_numbers_is_refused(self) -> None:
        payload = narrative_payload(
            paragraphs=[
                "Consumo: 2680 kcal.",
                "Proteine: 118 g contro 170 g.",
            ]
        )

        with self.assertRaises(CoachContractError) as context:
            CoachNarrativeResult.from_json(payload)

        self.assertEqual(context.exception.error_code, "COACH_EMPTY_NARRATIVE")

    def test_a_result_without_paragraphs_is_refused(self) -> None:
        with self.assertRaises(CoachContractError) as context:
            CoachNarrativeResult.from_json({"headline": "Solo un titolo"})

        self.assertEqual(context.exception.error_code, "COACH_BAD_RESULT")

    def test_the_payload_carries_only_text(self) -> None:
        payload = CoachNarrativeResult.from_json(narrative_payload()).to_json()

        self.assertEqual(sorted(payload), ["headline", "paragraphs"])
        self.assertIsInstance(payload["headline"], str)
        self.assertTrue(all(isinstance(item, str) for item in payload["paragraphs"]))
        # `dropped` serve al log del worker e non al database: sarebbe un
        # numero, e un numero nel risultato lo rifiuta la CHECK.
        self.assertNotIn("dropped", payload)


class TextOnlyGuardTest(unittest.TestCase):
    """Il gemello Python di `kal_tracker.coach_result_is_text_only`."""

    def test_strings_and_arrays_of_strings_pass(self) -> None:
        ensure_text_only({"headline": "Ciao", "paragraphs": ["uno", "due"]})

    def test_the_empty_cases_pass_exactly_like_in_sql(self) -> None:
        # In SQL `bool_and` su un insieme vuoto torna NULL e `is not false` lo
        # fa passare: oggetto senza campi e array vuoto sono validi.
        ensure_text_only({})
        ensure_text_only({"paragraphs": []})

    def test_a_number_is_refused_with_the_field_name(self) -> None:
        with self.assertRaises(CoachContractError) as context:
            ensure_text_only({"paragraphs": ["uno"], "kcal": 2680})

        self.assertEqual(context.exception.error_code, "COACH_RESULT_NOT_TEXT")
        self.assertIn("kcal", str(context.exception))

    def test_a_number_hidden_in_an_array_is_refused(self) -> None:
        with self.assertRaises(CoachContractError):
            ensure_text_only({"paragraphs": ["uno", 2]})

    def test_null_and_nested_objects_are_refused(self) -> None:
        with self.assertRaises(CoachContractError):
            ensure_text_only({"headline": None})
        with self.assertRaises(CoachContractError):
            ensure_text_only({"tdee": {"kcal": "2680"}})

    def test_a_boolean_is_not_text(self) -> None:
        with self.assertRaises(CoachContractError):
            ensure_text_only({"is_recomposition": True})

    def test_a_hand_built_result_cannot_smuggle_a_number(self) -> None:
        # `to_json` verifica da se': nessun chiamante puo' dimenticarsene.
        result = CoachNarrativeResult(paragraphs=("uno",), headline=None)
        object.__setattr__(result, "paragraphs", ("uno", 2))

        with self.assertRaises(CoachContractError) as context:
            result.to_json()

        self.assertEqual(context.exception.error_code, "COACH_RESULT_NOT_TEXT")


if __name__ == "__main__":
    unittest.main()
