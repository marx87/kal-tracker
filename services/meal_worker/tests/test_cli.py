"""L'entrypoint manuale: una foto oppure un rapporto del coach, mai entrambi."""

import io
import json
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock

from kal_meal_worker import cli
from kal_meal_worker.coach_analyzer import ClaudeCoachError
from kal_meal_worker.coach_contract import CoachNarrativeResult
from test_coach_contract import narrative_payload, request_payload


class FakeCoach:
    """Sostituisce la CLI Claude: i test non avviano nessun processo."""

    def __init__(self, result=None, error=None):
        self.result = result
        self.error = error
        self.requests = []

    def __call__(self, **kwargs):
        self.options = kwargs
        return self

    def comment(self, request):
        self.requests.append(request)
        if self.error is not None:
            raise self.error
        return self.result


class CliArgumentsTest(unittest.TestCase):
    def test_a_photo_and_a_report_together_are_refused(self) -> None:
        with self.assertRaises(SystemExit), redirect_stderr(io.StringIO()):
            cli.main(["pasto.jpg", "--coach-request", "rapporto.json"])

    def test_nothing_at_all_is_refused(self) -> None:
        with self.assertRaises(SystemExit), redirect_stderr(io.StringIO()):
            cli.main([])


class CoachCliTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.report = Path(self.tmp.name) / "rapporto.json"

    def _write(self, payload) -> str:
        self.report.write_text(
            json.dumps(payload, ensure_ascii=False), encoding="utf-8"
        )
        return str(self.report)

    def test_prints_the_same_payload_the_worker_would_send(self) -> None:
        coach = FakeCoach(
            result=CoachNarrativeResult.from_json(narrative_payload())
        )
        output = io.StringIO()

        with mock.patch.object(cli, "ClaudeCoach", coach):
            with redirect_stdout(output):
                code = cli.main(["--coach-request", self._write(request_payload())])

        self.assertEqual(code, 0)
        payload = json.loads(output.getvalue())
        self.assertEqual(sorted(payload), ["headline", "paragraphs"])
        self.assertTrue(
            all(isinstance(item, str) for item in payload["paragraphs"])
        )
        self.assertEqual(coach.requests[0].workouts_done, 3)

    def test_says_out_loud_how_many_paragraphs_were_dropped(self) -> None:
        payload = narrative_payload()
        payload["paragraphs"][0] = "Sei sceso di 700 g."
        coach = FakeCoach(result=CoachNarrativeResult.from_json(payload))
        errors = io.StringIO()

        with mock.patch.object(cli, "ClaudeCoach", coach):
            with redirect_stdout(io.StringIO()), redirect_stderr(errors):
                code = cli.main(["--coach-request", self._write(request_payload())])

        self.assertEqual(code, 0)
        self.assertIn("scartati", errors.getvalue())

    def test_a_malformed_report_never_starts_the_cli(self) -> None:
        def must_not_run(**kwargs):
            raise AssertionError("la CLI non doveva partire")

        errors = io.StringIO()
        with mock.patch.object(cli, "ClaudeCoach", must_not_run):
            with redirect_stderr(errors):
                code = cli.main(
                    ["--coach-request", self._write({"week_start": "ieri"})]
                )

        self.assertEqual(code, 2)
        self.assertIn("COACH_BAD_REQUEST", errors.getvalue())

    def test_a_missing_file_is_reported_not_raised(self) -> None:
        errors = io.StringIO()
        with redirect_stderr(errors):
            code = cli.main(["--coach-request", str(self.report)])

        self.assertEqual(code, 2)
        self.assertIn("non leggibile", errors.getvalue())

    def test_a_model_error_keeps_its_stable_code(self) -> None:
        coach = FakeCoach(
            error=ClaudeCoachError("privato", error_code="COACH_EMPTY_NARRATIVE")
        )
        errors = io.StringIO()

        with mock.patch.object(cli, "ClaudeCoach", coach):
            with redirect_stderr(errors):
                code = cli.main(["--coach-request", self._write(request_payload())])

        self.assertEqual(code, 2)
        self.assertIn("COACH_EMPTY_NARRATIVE", errors.getvalue())

    def test_the_preview_uses_the_same_ceiling_as_the_service(self) -> None:
        """Un'anteprima che scade prima del worker non misura niente.

        Il default era 120 s, cioe' meno del budget che il servizio concede a
        una settimana da tre temi in su: la prova a mano non riproduceva le
        condizioni vere ed e' proprio per quello che esiste.
        """
        coach = FakeCoach(
            result=CoachNarrativeResult.from_json(narrative_payload())
        )

        with mock.patch.object(cli, "ClaudeCoach", coach):
            with redirect_stdout(io.StringIO()):
                cli.main(["--coach-request", self._write(request_payload())])

        self.assertEqual(coach.options["timeout_seconds"], 300)

    def test_a_ceiling_below_the_floor_is_refused_before_starting(self) -> None:
        def must_not_run(**kwargs):
            raise AssertionError("la CLI non doveva partire")

        errors = io.StringIO()
        with mock.patch.object(cli, "ClaudeCoach", must_not_run):
            with redirect_stderr(errors):
                code = cli.main(
                    [
                        "--timeout",
                        "45",
                        "--coach-request",
                        self._write(request_payload()),
                    ]
                )

        self.assertEqual(code, 2)
        self.assertIn("90", errors.getvalue())

    def test_codex_cannot_write_the_comment(self) -> None:
        errors = io.StringIO()
        with redirect_stderr(errors):
            code = cli.main(
                [
                    "--provider",
                    "codex",
                    "--coach-request",
                    self._write(request_payload()),
                ]
            )

        self.assertEqual(code, 2)
        self.assertIn("claude", errors.getvalue())


if __name__ == "__main__":
    unittest.main()
