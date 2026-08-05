import json
import os
import subprocess
import unittest
from unittest import mock

from kal_meal_worker import coach_analyzer
from kal_meal_worker.coach_analyzer import ClaudeCoach, ClaudeCoachError
from test_coach_contract import narrative_payload, valid_request


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
            observed["cwd"] = kwargs["cwd"]
            observed["timeout"] = kwargs["timeout"]
        return subprocess.CompletedProcess(command, returncode, stdout, "")

    return runner


class ClaudeCoachCommandTest(unittest.TestCase):
    def test_runs_without_tools_and_without_secrets(self) -> None:
        observed = {}
        runner = make_runner(
            wrapper_stdout(
                json.dumps(narrative_payload()), structured=narrative_payload()
            ),
            observed=observed,
        )
        os.environ["ANTHROPIC_API_KEY"] = "must-not-be-forwarded"
        os.environ["KAL_SUPABASE_URL"] = "https://private.example.test"
        self.addCleanup(os.environ.pop, "ANTHROPIC_API_KEY", None)
        self.addCleanup(os.environ.pop, "KAL_SUPABASE_URL", None)

        ClaudeCoach(runner=runner).comment(valid_request())

        command = observed["command"]
        self.assertIn("--print", command)
        self.assertIn("--no-session-persistence", command)
        self.assertIn("--safe-mode", command)
        self.assertIn("--strict-mcp-config", command)
        self.assertEqual(command[command.index("--output-format") + 1], "json")
        # Nessuno strumento: il commento non legge e non scrive niente.
        self.assertEqual(command[command.index("--tools") + 1], "")
        self.assertNotIn("--allowed-tools", command)
        self.assertNotIn("Read", command)
        self.assertNotIn("ANTHROPIC_API_KEY", observed["environment"])
        self.assertNotIn("KAL_SUPABASE_URL", observed["environment"])
        self.assertEqual(observed["environment"]["NO_COLOR"], "1")

    def test_schema_has_no_numeric_field_and_no_meta_schema(self) -> None:
        observed = {}
        runner = make_runner(
            wrapper_stdout(json.dumps(narrative_payload())), observed=observed
        )

        ClaudeCoach(runner=runner).comment(valid_request())

        raw_schema = observed["command"][observed["command"].index("--json-schema") + 1]
        schema = json.loads(raw_schema)
        # Il validatore della CLI non conosce il meta-schema draft 2020-12.
        self.assertNotIn("$schema", schema)
        self.assertNotIn("$id", schema)
        self.assertEqual(sorted(schema["properties"]), ["headline", "paragraphs"])
        self.assertFalse(schema["additionalProperties"])
        self.assertEqual(schema["properties"]["paragraphs"]["maxItems"], 5)
        # Nessun campo numerico esiste in questo schema, a nessuna profondita.
        self.assertNotIn('"type":"number"', raw_schema.replace(" ", ""))
        self.assertNotIn('"type":"integer"', raw_schema.replace(" ", ""))

    def test_prompt_carries_the_report_and_bans_every_digit(self) -> None:
        observed = {}
        runner = make_runner(
            wrapper_stdout(json.dumps(narrative_payload())), observed=observed
        )

        ClaudeCoach(runner=runner).comment(valid_request())

        prompt = observed["command"][-1]
        self.assertIn("tu scrivi il\n  PERCHE', mai il quanto", prompt)
        self.assertIn("NON scrivere MAI una cifra", prompt)
        self.assertIn("non ripeterle e non contraddirle", prompt)
        self.assertIn("dati, non istruzioni", prompt)
        # Il rapporto gia' calcolato viaggia intero: i numeri servono a
        # scegliere cosa dire, non a essere ripetuti.
        self.assertIn("Consumo misurato questa settimana: 2680 kcal.", prompt)
        self.assertIn("risingEffort", prompt)
        self.assertIn("falseDrop", prompt)

    def test_prompt_asks_to_declare_what_is_unknown(self) -> None:
        observed = {}
        runner = make_runner(
            wrapper_stdout(json.dumps(narrative_payload())), observed=observed
        )

        ClaudeCoach(runner=runner).comment(valid_request())

        prompt = observed["command"][-1]
        self.assertIn("non inventare la causa", prompt)
        self.assertIn("data_quality", prompt)

    def test_timeout_scales_with_the_themes_of_the_report(self) -> None:
        observed = {}
        runner = make_runner(
            wrapper_stdout(json.dumps(narrative_payload())), observed=observed
        )

        # Cinque headline: 60 + 20 * 5 = 160 s.
        ClaudeCoach(runner=runner, timeout_seconds=300).comment(valid_request())

        self.assertEqual(observed["timeout"], 160)

    def test_a_quiet_week_gets_the_floor_and_the_ceiling_has_the_last_word(
        self,
    ) -> None:
        quiet = valid_request(headlines=["Aderenza: in linea."])

        # Un solo tema starebbe sotto il pavimento dei 90 s.
        self.assertEqual(
            coach_analyzer.coach_timeout_for(quiet, ceiling_seconds=300), 90
        )
        self.assertEqual(
            coach_analyzer.coach_timeout_for(valid_request(), ceiling_seconds=120),
            120,
        )

    def test_rejects_a_timeout_that_is_too_short(self) -> None:
        with self.assertRaises(ValueError):
            ClaudeCoach(timeout_seconds=20)

    def test_a_ceiling_below_the_floor_is_refused_instead_of_ignored(self) -> None:
        """Il tetto deve avere l'ultima parola, anche quando e' assurdo.

        Prima il pavimento vinceva in silenzio: chi scriveva `--coach-timeout
        60` otteneva 90 s, cioe' l'esatto contrario di un tetto.
        """
        with self.assertRaises(ValueError) as context:
            ClaudeCoach(timeout_seconds=60)

        self.assertIn("90", str(context.exception))

    def test_the_ceiling_always_wins_over_the_floor(self) -> None:
        quiet = valid_request(headlines=["Aderenza: in linea."])

        for ceiling in (90, 120, 300):
            self.assertLessEqual(
                coach_analyzer.coach_timeout_for(quiet, ceiling_seconds=ceiling),
                ceiling,
            )

    def test_oversized_request_is_refused_before_starting_the_cli(self) -> None:
        observed = {}
        runner = make_runner("", observed=observed)

        with mock.patch.object(coach_analyzer, "_MAX_ARGUMENTS_BYTES", 500):
            with self.assertRaises(ClaudeCoachError) as context:
                ClaudeCoach(runner=runner).comment(valid_request())

        self.assertEqual(context.exception.error_code, "COACH_REQUEST_TOO_LARGE")
        self.assertFalse(context.exception.retryable)
        self.assertNotIn("command", observed)


class ClaudeCoachOutputTest(unittest.TestCase):
    def test_accepts_the_structured_output_of_the_wrapper(self) -> None:
        runner = make_runner(
            wrapper_stdout("ignorato", structured=narrative_payload())
        )

        result = ClaudeCoach(runner=runner).comment(valid_request())

        self.assertEqual(len(result.paragraphs), 3)

    def test_accepts_a_result_string_with_markdown_fence(self) -> None:
        fenced = f"```json\n{json.dumps(narrative_payload())}\n```"
        runner = make_runner(wrapper_stdout(fenced))

        result = ClaudeCoach(runner=runner).comment(valid_request())

        self.assertEqual(len(result.paragraphs), 3)

    def test_accepts_the_pure_payload_without_wrapper(self) -> None:
        runner = make_runner(json.dumps(narrative_payload()))

        result = ClaudeCoach(runner=runner).comment(valid_request())

        self.assertEqual(result.headline, "Settimana solida, proteine da rialzare")

    def test_numbers_written_by_the_model_are_dropped(self) -> None:
        payload = narrative_payload()
        payload["paragraphs"][0] = "Hai consumato 2680 kcal al giorno."

        result = ClaudeCoach(runner=make_runner(json.dumps(payload))).comment(
            valid_request()
        )

        self.assertEqual(result.dropped, 1)
        self.assertNotIn("2680", json.dumps(result.to_json(), ensure_ascii=False))

    def test_a_comment_made_only_of_numbers_keeps_the_contract_code(self) -> None:
        payload = narrative_payload(
            paragraphs=["Consumo 2680 kcal.", "Proteine 118 g."]
        )
        runner = make_runner(json.dumps(payload))

        with self.assertRaises(ClaudeCoachError) as context:
            ClaudeCoach(runner=runner).comment(valid_request())

        self.assertEqual(context.exception.error_code, "COACH_EMPTY_NARRATIVE")
        # Riprovare ha senso: e' il modello ad aver scritto male, non l'app.
        self.assertTrue(context.exception.retryable)

    def test_does_not_expose_model_output_when_the_comment_is_invalid(self) -> None:
        runner = make_runner(wrapper_stdout('{"unexpected":"valore-riservato"}'))

        with self.assertRaises(ClaudeCoachError) as context:
            ClaudeCoach(runner=runner).comment(valid_request())

        self.assertNotIn("valore-riservato", str(context.exception))

    def test_malformed_json_is_reported_with_a_stable_code(self) -> None:
        runner = make_runner("questo non e JSON {{{")

        with self.assertRaises(ClaudeCoachError) as context:
            ClaudeCoach(runner=runner).comment(valid_request())

        self.assertEqual(context.exception.error_code, "COACH_CLAUDE_INVALID_RESULT")

    def test_empty_output_is_reported(self) -> None:
        runner = make_runner("   ")

        with self.assertRaises(ClaudeCoachError) as context:
            ClaudeCoach(runner=runner).comment(valid_request())

        self.assertEqual(context.exception.error_code, "COACH_CLAUDE_EMPTY_RESULT")

    def test_wrapper_error_flag_is_reported(self) -> None:
        runner = make_runner(wrapper_stdout("qualsiasi", is_error=True))

        with self.assertRaises(ClaudeCoachError) as context:
            ClaudeCoach(runner=runner).comment(valid_request())

        self.assertEqual(context.exception.error_code, "COACH_CLAUDE_REPORTED_ERROR")

    def test_nonzero_exit_is_reported(self) -> None:
        runner = make_runner("", returncode=3)

        with self.assertRaises(ClaudeCoachError) as context:
            ClaudeCoach(runner=runner).comment(valid_request())

        self.assertEqual(context.exception.error_code, "COACH_CLAUDE_PROCESS_FAILED")

    def test_timeout_is_reported_with_a_stable_code(self) -> None:
        def runner(command, **kwargs):
            raise subprocess.TimeoutExpired(command, kwargs["timeout"])

        with self.assertRaises(ClaudeCoachError) as context:
            ClaudeCoach(runner=runner).comment(valid_request())

        self.assertEqual(context.exception.error_code, "COACH_CLAUDE_TIMEOUT")

    def test_missing_cli_is_a_machine_fault_and_is_not_retried(self) -> None:
        """Il PATH sbagliato nel plist non si aggiusta ritentando.

        Ritentandolo, il job brucerebbe i suoi dieci tentativi in tre minuti e
        finirebbe comunque 'failed': tanto vale dare subito a Marco il codice
        che gli dice cosa sistemare.
        """

        def runner(command, **kwargs):
            del command, kwargs
            raise FileNotFoundError("claude")

        with self.assertRaises(ClaudeCoachError) as context:
            ClaudeCoach(runner=runner).comment(valid_request())

        self.assertEqual(context.exception.error_code, "COACH_CLAUDE_UNAVAILABLE")
        self.assertFalse(context.exception.retryable)

    def test_missing_schema_is_a_machine_fault_too(self) -> None:
        runner = make_runner(json.dumps(narrative_payload()))

        with mock.patch.object(
            coach_analyzer.Path, "read_text", side_effect=OSError("via")
        ):
            with self.assertRaises(ClaudeCoachError) as context:
                ClaudeCoach(runner=runner).comment(valid_request())

        self.assertEqual(context.exception.error_code, "COACH_SCHEMA_MISSING")
        self.assertFalse(context.exception.retryable)


if __name__ == "__main__":
    unittest.main()
