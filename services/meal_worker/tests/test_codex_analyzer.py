import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

from kal_meal_worker.codex_analyzer import CodexAnalyzer, CodexAnalyzerError
from test_contract import valid_payload


class CodexAnalyzerTest(unittest.TestCase):
    def test_invokes_ephemeral_read_only_codex_and_hides_api_keys(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            image = Path(temp) / "meal.jpg"
            image.write_bytes(b"not-a-real-jpeg-but-enough-for-the-boundary-test")
            observed = {}

            def runner(command, **kwargs):
                observed["command"] = command
                observed["environment"] = kwargs["env"]
                output = Path(command[command.index("--output-last-message") + 1])
                output.write_text(json.dumps(valid_payload()), encoding="utf-8")
                return subprocess.CompletedProcess(command, 0, "", "")

            old_api_key = os.environ.get("OPENAI_API_KEY")
            old_supabase_url = os.environ.get("KAL_SUPABASE_URL")
            os.environ["OPENAI_API_KEY"] = "must-not-be-forwarded"
            os.environ["KAL_SUPABASE_URL"] = "https://private.example.test"
            try:
                result = CodexAnalyzer(runner=runner).analyze(image)
            finally:
                if old_api_key is None:
                    os.environ.pop("OPENAI_API_KEY", None)
                else:
                    os.environ["OPENAI_API_KEY"] = old_api_key
                if old_supabase_url is None:
                    os.environ.pop("KAL_SUPABASE_URL", None)
                else:
                    os.environ["KAL_SUPABASE_URL"] = old_supabase_url

            command = observed["command"]
            self.assertIn("--ephemeral", command)
            self.assertIn("--ignore-user-config", command)
            self.assertEqual(command[command.index("--sandbox") + 1], "read-only")
            self.assertNotIn("OPENAI_API_KEY", observed["environment"])
            self.assertNotIn("KAL_SUPABASE_URL", observed["environment"])
            self.assertEqual(result.foods[0].name, "Riso basmati cotto")

    def test_prompt_asks_per100g_and_bans_total_calories(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            image = Path(temp) / "meal.jpg"
            image.write_bytes(b"jpg")
            observed = {}

            def runner(command, **kwargs):
                observed["command"] = command
                output = Path(command[command.index("--output-last-message") + 1])
                output.write_text(json.dumps(valid_payload()), encoding="utf-8")
                return subprocess.CompletedProcess(command, 0, "", "")

            CodexAnalyzer(runner=runner).analyze(image)

            prompt = observed["command"][-1]
            self.assertIn("PER 100 GRAMMI", prompt)
            self.assertIn("NON fornire MAI le calorie totali", prompt)
            self.assertIn("i totali li calcola sempre l'app", prompt)

    def test_rejects_unsupported_file_before_starting_codex(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            image = Path(temp) / "meal.gif"
            image.write_bytes(b"gif")

            with self.assertRaises(CodexAnalyzerError):
                CodexAnalyzer().analyze(image)

    def test_does_not_expose_model_output_when_contract_is_invalid(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            image = Path(temp) / "meal.png"
            image.write_bytes(b"png")

            def runner(command, **kwargs):
                output = Path(command[command.index("--output-last-message") + 1])
                output.write_text('{"unexpected":"secret-looking-value"}')
                return subprocess.CompletedProcess(command, 0, "", "")

            with self.assertRaisesRegex(
                CodexAnalyzerError, "Risultato Codex non valido"
            ):
                CodexAnalyzer(runner=runner).analyze(image)


if __name__ == "__main__":
    unittest.main()
