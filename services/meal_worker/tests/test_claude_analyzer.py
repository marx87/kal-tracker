import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

from kal_meal_worker.claude_analyzer import ClaudeAnalyzer, ClaudeAnalyzerError
from test_contract import valid_payload


def wrapper_stdout(result_value, *, is_error=False, structured=None) -> str:
    document = {
        "type": "result",
        "subtype": "success",
        "is_error": is_error,
        "result": result_value,
    }
    if structured is not None:
        document["structured_output"] = structured
    return json.dumps(document)


def make_runner(stdout: str, returncode: int = 0, observed: dict | None = None):
    def runner(command, **kwargs):
        if observed is not None:
            observed["command"] = command
            observed["environment"] = kwargs["env"]
        return subprocess.CompletedProcess(command, returncode, stdout, "")

    return runner


class ClaudeAnalyzerTest(unittest.TestCase):
    def test_invokes_print_mode_read_only_and_hides_api_keys(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            image = Path(temp) / "meal.jpg"
            image.write_bytes(b"not-a-real-jpeg-but-enough-for-the-boundary-test")
            observed = {}
            runner = make_runner(
                wrapper_stdout(
                    json.dumps(valid_payload()), structured=valid_payload()
                ),
                observed=observed,
            )

            old_api_key = os.environ.get("ANTHROPIC_API_KEY")
            old_supabase_url = os.environ.get("KAL_SUPABASE_URL")
            os.environ["ANTHROPIC_API_KEY"] = "must-not-be-forwarded"
            os.environ["KAL_SUPABASE_URL"] = "https://private.example.test"
            try:
                result = ClaudeAnalyzer(runner=runner).analyze(image)
            finally:
                if old_api_key is None:
                    os.environ.pop("ANTHROPIC_API_KEY", None)
                else:
                    os.environ["ANTHROPIC_API_KEY"] = old_api_key
                if old_supabase_url is None:
                    os.environ.pop("KAL_SUPABASE_URL", None)
                else:
                    os.environ["KAL_SUPABASE_URL"] = old_supabase_url

            command = observed["command"]
            self.assertIn("--print", command)
            self.assertIn("--no-session-persistence", command)
            self.assertIn("--safe-mode", command)
            self.assertIn("--strict-mcp-config", command)
            self.assertEqual(
                command[command.index("--output-format") + 1], "json"
            )
            self.assertEqual(command[command.index("--tools") + 1], "Read")
            self.assertEqual(
                command[command.index("--allowed-tools") + 1], "Read"
            )
            schema = json.loads(command[command.index("--json-schema") + 1])
            self.assertIn("foods", schema["properties"])
            self.assertNotIn("ANTHROPIC_API_KEY", observed["environment"])
            self.assertNotIn("KAL_SUPABASE_URL", observed["environment"])
            self.assertEqual(result.foods[0].name, "Riso basmati cotto")

    def test_accepts_wrapper_with_result_string(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            image = Path(temp) / "meal.png"
            image.write_bytes(b"png")
            runner = make_runner(wrapper_stdout(json.dumps(valid_payload())))

            result = ClaudeAnalyzer(runner=runner).analyze(image)

            self.assertEqual(result.foods[0].name, "Riso basmati cotto")

    def test_accepts_wrapper_with_markdown_fence(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            image = Path(temp) / "meal.png"
            image.write_bytes(b"png")
            fenced = f"```json\n{json.dumps(valid_payload())}\n```"
            runner = make_runner(wrapper_stdout(fenced))

            result = ClaudeAnalyzer(runner=runner).analyze(image)

            self.assertEqual(result.foods[0].suggested_grams, 160)

    def test_accepts_pure_payload_without_wrapper(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            image = Path(temp) / "meal.webp"
            image.write_bytes(b"webp")
            runner = make_runner(json.dumps(valid_payload()))

            result = ClaudeAnalyzer(runner=runner).analyze(image)

            self.assertEqual(result.foods[0].name, "Riso basmati cotto")

    def test_rejects_malformed_json(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            image = Path(temp) / "meal.png"
            image.write_bytes(b"png")
            runner = make_runner("questo non e JSON {{{")

            with self.assertRaisesRegex(
                ClaudeAnalyzerError, "Risultato Claude non valido"
            ) as context:
                ClaudeAnalyzer(runner=runner).analyze(image)
            self.assertEqual(
                context.exception.error_code, "CLAUDE_INVALID_RESULT"
            )

    def test_does_not_expose_model_output_when_contract_is_invalid(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            image = Path(temp) / "meal.png"
            image.write_bytes(b"png")
            runner = make_runner(
                wrapper_stdout('{"unexpected":"secret-looking-value"}')
            )

            with self.assertRaisesRegex(
                ClaudeAnalyzerError, "Risultato Claude non valido"
            ) as context:
                ClaudeAnalyzer(runner=runner).analyze(image)
            self.assertNotIn("secret-looking-value", str(context.exception))

    def test_timeout_is_reported_with_stable_code(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            image = Path(temp) / "meal.jpg"
            image.write_bytes(b"jpg")

            def runner(command, **kwargs):
                raise subprocess.TimeoutExpired(command, kwargs["timeout"])

            with self.assertRaises(ClaudeAnalyzerError) as context:
                ClaudeAnalyzer(runner=runner).analyze(image)
            self.assertEqual(context.exception.error_code, "CLAUDE_TIMEOUT")

    def test_missing_cli_is_reported_with_stable_code(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            image = Path(temp) / "meal.jpg"
            image.write_bytes(b"jpg")

            def runner(command, **kwargs):
                raise FileNotFoundError("claude")

            with self.assertRaises(ClaudeAnalyzerError) as context:
                ClaudeAnalyzer(runner=runner).analyze(image)
            self.assertEqual(context.exception.error_code, "CLAUDE_UNAVAILABLE")

    def test_wrapper_error_flag_is_reported(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            image = Path(temp) / "meal.png"
            image.write_bytes(b"png")
            runner = make_runner(wrapper_stdout("qualsiasi", is_error=True))

            with self.assertRaises(ClaudeAnalyzerError) as context:
                ClaudeAnalyzer(runner=runner).analyze(image)
            self.assertEqual(
                context.exception.error_code, "CLAUDE_REPORTED_ERROR"
            )

    def test_nonzero_exit_is_reported(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            image = Path(temp) / "meal.png"
            image.write_bytes(b"png")
            runner = make_runner("", returncode=3)

            with self.assertRaises(ClaudeAnalyzerError) as context:
                ClaudeAnalyzer(runner=runner).analyze(image)
            self.assertEqual(
                context.exception.error_code, "CLAUDE_PROCESS_FAILED"
            )

    def test_rejects_unsupported_file_before_starting_claude(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            image = Path(temp) / "meal.gif"
            image.write_bytes(b"gif")
            observed = {}
            runner = make_runner("", observed=observed)

            with self.assertRaises(ClaudeAnalyzerError) as context:
                ClaudeAnalyzer(runner=runner).analyze(image)
            self.assertEqual(
                context.exception.error_code, "IMAGE_FORMAT_UNSUPPORTED"
            )
            self.assertFalse(context.exception.retryable)
            self.assertNotIn("command", observed)


if __name__ == "__main__":
    unittest.main()
