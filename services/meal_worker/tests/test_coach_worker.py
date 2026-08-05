import threading
import unittest

from kal_meal_worker.coach_analyzer import ClaudeCoachError
from kal_meal_worker.coach_contract import CoachNarrativeResult
from kal_meal_worker.coach_worker import CoachWorker
from kal_meal_worker.supabase_gateway import ClaimedCoachJob
from kal_meal_worker.transport import NetworkError
from kal_meal_worker.worker import AlternatingWorker, CycleOutcome, RetryPolicy
from test_coach_contract import narrative_payload, request_payload


JOB_ID = "11111111-1111-4111-8111-111111111111"


def make_job(request=None):
    return ClaimedCoachJob(
        job_id=JOB_ID,
        owner_id="22222222-2222-4222-8222-222222222222",
        profile_id="33333333-3333-4333-8333-333333333333",
        request=request if request is not None else request_payload(),
        attempt_count=1,
        row_version=2,
        lease_expires_at="2026-08-05T12:00:00+00:00",
    )


class FakeCoachGateway:
    def __init__(self, job=None):
        self.claim_results = [job]
        self.claim_mutations = []
        self.heartbeats = []
        self.completes = []
        self.failures = []
        self.complete_results = []
        self.heartbeat_event = threading.Event()

    def claim(self, mutation_id, lease_seconds):
        self.claim_mutations.append((mutation_id, lease_seconds))
        result = self.claim_results.pop(0)
        if isinstance(result, BaseException):
            raise result
        return result

    def heartbeat(self, job_id, mutation_id, lease_seconds):
        self.heartbeats.append((job_id, mutation_id, lease_seconds))
        if len(self.heartbeats) >= 2:
            self.heartbeat_event.set()
        return {"status": "processing"}

    def complete(self, job_id, mutation_id, result):
        self.completes.append((job_id, mutation_id, result))
        if self.complete_results:
            outcome = self.complete_results.pop(0)
            if isinstance(outcome, BaseException):
                raise outcome
        return {"status": "needs_review"}

    def fail(self, job_id, mutation_id, error_code, retryable):
        self.failures.append((job_id, mutation_id, error_code, retryable))
        return {"status": "queued" if retryable else "failed"}


class SuccessfulCommentator:
    def __init__(self):
        self.request = None

    def comment(self, request):
        self.request = request
        return CoachNarrativeResult.from_json(narrative_payload())


def uuid_factory():
    counter = 0

    def next_uuid():
        nonlocal counter
        counter += 1
        return f"00000000-0000-4000-8000-{counter:012d}"

    return next_uuid


def build_worker(gateway, commentator, **changes):
    options = {
        "gateway": gateway,
        "commentator": commentator,
        "uuid_factory": uuid_factory(),
        "sleep": lambda seconds: None,
    }
    options.update(changes)
    return CoachWorker(**options)


class CoachWorkerTest(unittest.TestCase):
    def test_successful_lifecycle(self) -> None:
        gateway = FakeCoachGateway(make_job())
        commentator = SuccessfulCommentator()

        outcome = build_worker(gateway, commentator).run_once()

        self.assertIs(outcome, CycleOutcome.COMPLETED)
        self.assertEqual(len(gateway.heartbeats), 1)
        self.assertEqual(len(gateway.completes), 1)
        self.assertEqual(gateway.failures, [])
        self.assertEqual(commentator.request.workouts_done, 3)
        self.assertEqual(len(gateway.completes[0][2].paragraphs), 3)

    def test_the_completed_result_is_text_only(self) -> None:
        gateway = FakeCoachGateway(make_job())

        build_worker(gateway, SuccessfulCommentator()).run_once()

        payload = gateway.completes[0][2].to_json()
        for value in payload.values():
            with self.subTest(value=value):
                self.assertTrue(
                    isinstance(value, str)
                    or (
                        isinstance(value, list)
                        and all(isinstance(item, str) for item in value)
                    )
                )

    def test_empty_poll_is_idle(self) -> None:
        gateway = FakeCoachGateway(None)

        outcome = build_worker(gateway, SuccessfulCommentator()).run_once()

        self.assertIs(outcome, CycleOutcome.IDLE)
        self.assertEqual(gateway.heartbeats, [])

    def test_malformed_request_fails_without_calling_the_model(self) -> None:
        gateway = FakeCoachGateway(make_job(request={"week_start": "ieri"}))

        class CommentatorMustNotRun:
            def comment(self, request):
                raise AssertionError("Il coach non doveva partire")

        outcome = build_worker(gateway, CommentatorMustNotRun()).run_once()

        self.assertIs(outcome, CycleOutcome.FAILED)
        self.assertEqual(gateway.heartbeats, [])
        self.assertEqual(gateway.failures[0][2:], ("COACH_BAD_REQUEST", False))

    def test_a_comment_of_only_numbers_is_retried(self) -> None:
        # Il modello ha scritto solo cifre: e' colpa sua, non della richiesta,
        # quindi il job torna in coda.
        gateway = FakeCoachGateway(make_job())

        class NumericCommentator:
            def comment(self, request):
                raise ClaudeCoachError(
                    "dettaglio privato che non deve finire nella RPC",
                    error_code="COACH_EMPTY_NARRATIVE",
                )

        outcome = build_worker(gateway, NumericCommentator()).run_once()

        self.assertIs(outcome, CycleOutcome.FAILED)
        self.assertEqual(gateway.failures[0][2:], ("COACH_EMPTY_NARRATIVE", True))
        self.assertEqual(gateway.completes, [])

    def test_a_missing_cli_does_not_burn_the_ten_attempts_of_the_job(self) -> None:
        """Guasto della macchina: un tentativo solo, e un codice che si legge.

        Ritentarlo su una macchina con il PATH sbagliato vorrebbe dire dieci
        tentativi in tre minuti e la stessa fine, con in piu' tre minuti di
        attesa per Marco.
        """
        gateway = FakeCoachGateway(make_job())

        class UnavailableCommentator:
            def comment(self, request):
                raise ClaudeCoachError(
                    "Claude CLI non trovata",
                    error_code="COACH_CLAUDE_UNAVAILABLE",
                    retryable=False,
                )

        build_worker(gateway, UnavailableCommentator()).run_once()

        self.assertEqual(
            gateway.failures[0][2:], ("COACH_CLAUDE_UNAVAILABLE", False)
        )

    def test_unexpected_error_is_generic_and_retryable(self) -> None:
        gateway = FakeCoachGateway(make_job())

        class BrokenCommentator:
            def comment(self, request):
                raise RuntimeError("segreto interno")

        outcome = build_worker(gateway, BrokenCommentator()).run_once()

        self.assertIs(outcome, CycleOutcome.FAILED)
        self.assertEqual(gateway.failures[0][2:], ("COACH_INTERNAL", True))

    def test_heartbeat_runs_while_the_model_is_writing(self) -> None:
        gateway = FakeCoachGateway(make_job())

        class SlowCommentator:
            def comment(self, request):
                if not gateway.heartbeat_event.wait(1):
                    raise AssertionError("Heartbeat periodico non osservato")
                return CoachNarrativeResult.from_json(narrative_payload())

        worker = build_worker(
            gateway,
            SlowCommentator(),
            heartbeat_interval_seconds=0.01,
            retry_policy=RetryPolicy(
                maximum_attempts=2,
                initial_delay_seconds=0,
                maximum_delay_seconds=0,
            ),
        )

        self.assertIs(worker.run_once(), CycleOutcome.COMPLETED)
        self.assertGreaterEqual(len(gateway.heartbeats), 2)

    def test_complete_retry_reuses_the_mutation_uuid(self) -> None:
        gateway = FakeCoachGateway(make_job())
        gateway.complete_results = [NetworkError("risposta persa"), None]
        worker = build_worker(
            gateway,
            SuccessfulCommentator(),
            retry_policy=RetryPolicy(
                maximum_attempts=2,
                initial_delay_seconds=0,
                maximum_delay_seconds=0,
            ),
        )

        self.assertIs(worker.run_once(), CycleOutcome.COMPLETED)
        self.assertEqual(len(gateway.completes), 2)
        self.assertEqual(gateway.completes[0][1], gateway.completes[1][1])

    def test_one_job_at_a_time_across_the_three_queues(self) -> None:
        # Il coach entra nel turno insieme alle altre due: resta una sola
        # lavorazione alla volta, e nessuna coda affama le altre.
        gateway = FakeCoachGateway(make_job())
        coach = build_worker(gateway, SuccessfulCommentator())

        class IdleWorker:
            def __init__(self):
                self.calls = 0

            def run_once(self):
                self.calls += 1
                return CycleOutcome.IDLE

        photos = IdleWorker()
        plans = IdleWorker()
        worker = AlternatingWorker(workers=[photos, plans, coach])

        self.assertIs(worker.run_once(), CycleOutcome.COMPLETED)
        self.assertEqual((photos.calls, plans.calls), (1, 1))
        self.assertEqual(len(gateway.completes), 1)


if __name__ == "__main__":
    unittest.main()
