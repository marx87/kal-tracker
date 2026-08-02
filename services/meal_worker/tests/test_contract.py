import unittest

from kal_meal_worker.contract import AnalysisResult, ContractError


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


if __name__ == "__main__":
    unittest.main()
