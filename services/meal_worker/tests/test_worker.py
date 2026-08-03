import hashlib
import threading
import unittest
from pathlib import Path

from kal_meal_worker.codex_analyzer import CodexAnalyzerError
from kal_meal_worker.contract import AnalysisResult
from kal_meal_worker.supabase_gateway import ClaimedJob, DownloadedPhoto
from kal_meal_worker.transport import NetworkError
from kal_meal_worker.worker import CycleOutcome, MealWorker, RetryPolicy
from test_contract import valid_payload


IMAGE = b"\xff\xd8\xffworker-test-image"


def make_job(*, sha256=None):
    return ClaimedJob(
        job_id="11111111-1111-4111-8111-111111111111",
        owner_id="22222222-2222-4222-8222-222222222222",
        profile_id="33333333-3333-4333-8333-333333333333",
        storage_bucket="kal-tracker-meal-photos",
        storage_object=(
            "22222222-2222-4222-8222-222222222222/"
            "11111111-1111-4111-8111-111111111111/photo.jpg"
        ),
        image_sha256=sha256 or hashlib.sha256(IMAGE).hexdigest(),
        image_size_bytes=len(IMAGE),
        image_mime_type="image/jpeg",
        requested_meal_type="dinner",
        user_note="Poco olio",
        attempt_count=1,
        row_version=2,
        lease_expires_at="2026-08-02T12:00:00+00:00",
    )


class FakeGateway:
    def __init__(self, job=None):
        self.claim_results = [job]
        self.claim_mutations = []
        self.heartbeats = []
        self.downloads = []
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

    def download_photo(self, job):
        self.downloads.append(job.job_id)
        return DownloadedPhoto(IMAGE, "image/jpeg")

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


class SuccessfulAnalyzer:
    def __init__(self):
        self.path = None
        self.context = None

    def analyze(self, image_path, *, requested_meal_type=None, user_note=None):
        self.path = Path(image_path)
        self.context = (requested_meal_type, user_note)
        self.assert_image = self.path.read_bytes()
        return AnalysisResult.from_json(valid_payload())


def uuid_factory():
    counter = 0

    def next_uuid():
        nonlocal counter
        counter += 1
        return f"00000000-0000-4000-8000-{counter:012d}"

    return next_uuid


class MealWorkerTest(unittest.TestCase):
    def test_successful_lifecycle_and_temporary_cleanup(self) -> None:
        gateway = FakeGateway(make_job())
        analyzer = SuccessfulAnalyzer()
        worker = MealWorker(
            gateway=gateway,
            analyzer=analyzer,
            uuid_factory=uuid_factory(),
            sleep=lambda seconds: None,
        )

        outcome = worker.run_once()

        self.assertIs(outcome, CycleOutcome.COMPLETED)
        self.assertEqual(gateway.downloads, [make_job().job_id])
        self.assertEqual(len(gateway.heartbeats), 1)
        self.assertEqual(len(gateway.completes), 1)
        self.assertEqual(gateway.failures, [])
        self.assertEqual(analyzer.context, ("dinner", "Poco olio"))
        self.assertEqual(analyzer.assert_image, IMAGE)
        self.assertFalse(analyzer.path.exists())

    def test_invalid_hash_is_failed_without_calling_analyzer(self) -> None:
        gateway = FakeGateway(make_job(sha256="0" * 64))

        class AnalyzerMustNotRun:
            def analyze(self, *args, **kwargs):
                raise AssertionError("L'analizzatore non doveva partire")

        worker = MealWorker(
            gateway=gateway,
            analyzer=AnalyzerMustNotRun(),
            uuid_factory=uuid_factory(),
            sleep=lambda seconds: None,
        )

        self.assertIs(worker.run_once(), CycleOutcome.FAILED)
        self.assertEqual(gateway.heartbeats, [])
        self.assertEqual(gateway.failures[0][2:], ("IMAGE_SHA256_MISMATCH", False))

    def test_codex_failure_is_reported_with_stable_code(self) -> None:
        gateway = FakeGateway(make_job())

        class FailedAnalyzer:
            def analyze(self, *args, **kwargs):
                raise CodexAnalyzerError(
                    "private detail must not become an RPC payload",
                    error_code="CODEX_TIMEOUT",
                )

        worker = MealWorker(
            gateway=gateway,
            analyzer=FailedAnalyzer(),
            uuid_factory=uuid_factory(),
            sleep=lambda seconds: None,
        )

        self.assertIs(worker.run_once(), CycleOutcome.FAILED)
        self.assertEqual(gateway.failures[0][2:], ("CODEX_TIMEOUT", True))

    def test_claim_retries_with_the_same_mutation_uuid(self) -> None:
        gateway = FakeGateway()
        gateway.claim_results = [NetworkError("first"), NetworkError("second"), None]
        delays = []
        worker = MealWorker(
            gateway=gateway,
            analyzer=SuccessfulAnalyzer(),
            uuid_factory=uuid_factory(),
            retry_policy=RetryPolicy(
                maximum_attempts=3,
                initial_delay_seconds=0.5,
                maximum_delay_seconds=2,
                jitter_ratio=0,
            ),
            sleep=delays.append,
        )

        self.assertIs(worker.run_once(), CycleOutcome.IDLE)
        self.assertEqual(delays, [0.5, 1.0])
        self.assertEqual(len({item[0] for item in gateway.claim_mutations}), 1)

    def test_complete_retry_reuses_mutation_uuid(self) -> None:
        gateway = FakeGateway(make_job())
        gateway.complete_results = [NetworkError("response lost"), None]
        worker = MealWorker(
            gateway=gateway,
            analyzer=SuccessfulAnalyzer(),
            uuid_factory=uuid_factory(),
            retry_policy=RetryPolicy(
                maximum_attempts=2,
                initial_delay_seconds=0,
                maximum_delay_seconds=0,
            ),
            sleep=lambda seconds: None,
        )

        self.assertIs(worker.run_once(), CycleOutcome.COMPLETED)
        self.assertEqual(len(gateway.completes), 2)
        self.assertEqual(gateway.completes[0][1], gateway.completes[1][1])

    def test_heartbeat_runs_while_analyzer_is_busy(self) -> None:
        gateway = FakeGateway(make_job())

        class WaitForHeartbeatAnalyzer:
            def analyze(self, *args, **kwargs):
                if not gateway.heartbeat_event.wait(1):
                    raise AssertionError("Heartbeat periodico non osservato")
                return AnalysisResult.from_json(valid_payload())

        worker = MealWorker(
            gateway=gateway,
            analyzer=WaitForHeartbeatAnalyzer(),
            uuid_factory=uuid_factory(),
            heartbeat_interval_seconds=0.01,
            retry_policy=RetryPolicy(
                maximum_attempts=2,
                initial_delay_seconds=0,
                maximum_delay_seconds=0,
            ),
            sleep=lambda seconds: None,
        )

        self.assertIs(worker.run_once(), CycleOutcome.COMPLETED)
        self.assertGreaterEqual(len(gateway.heartbeats), 2)


if __name__ == "__main__":
    unittest.main()
