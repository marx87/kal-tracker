import unittest

from kal_meal_worker.contract import (
    _ATWATER_WARNING,
    AnalysisResult,
    ContractError,
)


def valid_payload() -> dict:
    return {
        "foods": [
            {
                "name": "Riso basmati cotto",
                "alternatives": ["Riso jasmine cotto"],
                "minimumGrams": 130,
                "suggestedGrams": 160,
                "maximumGrams": 200,
                "confidence": 0.82,
                "preparation": "boiled",
                "per100g": {
                    "energyKcal": 130,
                    "proteinG": 2.7,
                    "carbsG": 28,
                    "fatG": 0.3,
                },
                "hiddenIngredients": ["olio"],
                "uncertainty": "La profondita del piatto non e visibile.",
            }
        ],
        "questions": ["Hai aggiunto olio?"],
        "overallConfidence": 0.8,
        "notes": "Confermare sempre i grammi.",
    }


class AnalysisResultTest(unittest.TestCase):
    def test_accepts_valid_result(self) -> None:
        result = AnalysisResult.from_json(valid_payload())

        self.assertEqual(result.foods[0].name, "Riso basmati cotto")
        self.assertEqual(result.foods[0].suggested_grams, 160)
        self.assertEqual(result.to_json(), valid_payload())

    def test_rejects_invalid_portion_order(self) -> None:
        payload = valid_payload()
        payload["foods"][0]["minimumGrams"] = 250

        with self.assertRaises(ContractError):
            AnalysisResult.from_json(payload)

    def test_rejects_calorie_fields(self) -> None:
        payload = valid_payload()
        payload["foods"][0]["calories"] = 400

        with self.assertRaises(ContractError):
            AnalysisResult.from_json(payload)

    def test_rejects_missing_per100g(self) -> None:
        # Il worker nuovo esige sempre per100g: l'opzionalita e solo lato
        # app, per i risultati storici salvati prima di questa versione.
        payload = valid_payload()
        del payload["foods"][0]["per100g"]

        with self.assertRaises(ContractError):
            AnalysisResult.from_json(payload)

    def test_rejects_per100g_that_is_not_an_object(self) -> None:
        payload = valid_payload()
        payload["foods"][0]["per100g"] = 130

        with self.assertRaises(ContractError):
            AnalysisResult.from_json(payload)

    def test_rejects_per100g_with_unexpected_fields(self) -> None:
        payload = valid_payload()
        payload["foods"][0]["per100g"]["fiberG"] = 1.5

        with self.assertRaises(ContractError):
            AnalysisResult.from_json(payload)

    def test_rejects_per100g_out_of_range(self) -> None:
        violations = [
            ("energyKcal", 901),
            ("energyKcal", -1),
            ("proteinG", 100.1),
            ("carbsG", -0.1),
            ("fatG", 101),
        ]
        for field, bad_value in violations:
            with self.subTest(field=field, value=bad_value):
                payload = valid_payload()
                payload["foods"][0]["per100g"][field] = bad_value

                with self.assertRaises(ContractError):
                    AnalysisResult.from_json(payload)

    def test_rounds_per100g_to_one_decimal(self) -> None:
        payload = valid_payload()
        payload["foods"][0]["per100g"]["energyKcal"] = 129.9678
        payload["foods"][0]["per100g"]["proteinG"] = 2.66

        result = AnalysisResult.from_json(payload)

        self.assertEqual(result.foods[0].per100g.energy_kcal, 130.0)
        self.assertEqual(result.foods[0].per100g.protein_g, 2.7)

    def test_flags_atwater_mismatch_in_uncertainty_without_rejecting(
        self,
    ) -> None:
        payload = valid_payload()
        # 4*2.7 + 4*28 + 9*0.3 = 125.5 kcal: 700 se ne discosta oltre il 40%.
        payload["foods"][0]["per100g"]["energyKcal"] = 700

        result = AnalysisResult.from_json(payload)

        self.assertIn(_ATWATER_WARNING, result.foods[0].uncertainty)
        self.assertIn(
            "La profondita del piatto non e visibile.",
            result.foods[0].uncertainty,
        )

    def test_flags_positive_energy_with_zero_macros(self) -> None:
        payload = valid_payload()
        payload["foods"][0]["per100g"] = {
            "energyKcal": 50,
            "proteinG": 0,
            "carbsG": 0,
            "fatG": 0,
        }

        result = AnalysisResult.from_json(payload)

        self.assertIn(_ATWATER_WARNING, result.foods[0].uncertainty)

    def test_does_not_flag_coherent_atwater_energy(self) -> None:
        result = AnalysisResult.from_json(valid_payload())

        self.assertNotIn(_ATWATER_WARNING, result.foods[0].uncertainty)

    def test_atwater_warning_keeps_uncertainty_within_limit(self) -> None:
        payload = valid_payload()
        payload["foods"][0]["per100g"]["energyKcal"] = 700
        payload["foods"][0]["uncertainty"] = "x" * 300

        result = AnalysisResult.from_json(payload)

        self.assertLessEqual(len(result.foods[0].uncertainty), 300)
        self.assertIn(_ATWATER_WARNING, result.foods[0].uncertainty)


if __name__ == "__main__":
    unittest.main()
