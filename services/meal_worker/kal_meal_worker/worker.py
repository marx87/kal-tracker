from __future__ import annotations

import logging
import random
import tempfile
import threading
import time
import uuid
from collections.abc import Callable, Mapping
from dataclasses import dataclass
from enum import Enum
from pathlib import Path
from typing import Protocol, TypeVar

from .codex_analyzer import CodexAnalyzerError
from .contract import AnalysisResult
from .image_file import ImageIntegrityError, verify_and_write_photo
from .supabase_gateway import (
    ClaimedJob,
    DownloadedPhoto,
    SupabaseProtocolError,
    safe_remote_error_code,
)
from .transport import (
    HttpStatusError,
    ResponseTooLargeError,
    is_retryable_transport_error,
)


_LOGGER = logging.getLogger("kal_meal_worker")
_T = TypeVar("_T")


class Analyzer(Protocol):
    def analyze(
        self,
        image_path: Path | str,
        *,
        requested_meal_type: str | None = None,
        user_note: str | None = None,
    ) -> AnalysisResult: ...


class MealGateway(Protocol):
    def claim(self, mutation_id: str, lease_seconds: int) -> ClaimedJob | None: ...

    def heartbeat(
        self, job_id: str, mutation_id: str, lease_seconds: int
    ) -> Mapping[str, object]: ...

    def download_photo(self, job: ClaimedJob) -> DownloadedPhoto: ...

    def complete(
        self, job_id: str, mutation_id: str, result: AnalysisResult
    ) -> Mapping[str, object]: ...

    def fail(
        self,
        job_id: str,
        mutation_id: str,
        error_code: str,
        retryable: bool,
    ) -> Mapping[str, object]: ...


class CycleOutcome(Enum):
    IDLE = "idle"
    COMPLETED = "completed"
    FAILED = "failed"


class WorkerCycleError(RuntimeError):
    def __init__(self, error_code: str) -> None:
        self.error_code = error_code
        super().__init__(error_code)


@dataclass(frozen=True)
class RetryPolicy:
    maximum_attempts: int = 3
    initial_delay_seconds: float = 1
    maximum_delay_seconds: float = 30
    multiplier: float = 2
    jitter_ratio: float = 0.2

    def __post_init__(self) -> None:
        if self.maximum_attempts < 1:
            raise ValueError("maximum_attempts deve essere positivo")
        if self.initial_delay_seconds < 0 or self.maximum_delay_seconds < 0:
            raise ValueError("I ritardi retry non possono essere negativi")
        if self.multiplier < 1:
            raise ValueError("Il moltiplicatore retry deve essere almeno 1")
        if not 0 <= self.jitter_ratio <= 1:
            raise ValueError("jitter_ratio deve essere tra 0 e 1")

    def delay(self, failed_attempt: int, random_value: float) -> float:
        exponent = min(failed_attempt - 1, 31)
        base = min(
            self.maximum_delay_seconds,
            self.initial_delay_seconds * self.multiplier**exponent,
        )
        jitter = base * self.jitter_ratio * (2 * random_value - 1)
        return max(0, min(self.maximum_delay_seconds, base + jitter))


def _run_with_retry(
    operation: Callable[[], _T],
    *,
    policy: RetryPolicy,
    sleep: Callable[[float], object],
    random_value: Callable[[], float],
) -> _T:
    for attempt in range(1, policy.maximum_attempts + 1):
        try:
            return operation()
        except Exception as error:
            if attempt >= policy.maximum_attempts or not is_retryable_transport_error(
                error
            ):
                raise
            sleep(policy.delay(attempt, random_value()))
    raise AssertionError("retry loop irraggiungibile")


class _HeartbeatStopped(Exception):
    pass


class LeaseHeartbeat:
    def __init__(
        self,
        *,
        gateway: MealGateway,
        job_id: str,
        lease_seconds: int,
        interval_seconds: float,
        retry_policy: RetryPolicy,
        uuid_factory: Callable[[], str],
        random_value: Callable[[], float],
    ) -> None:
        self._gateway = gateway
        self._job_id = job_id
        self._lease_seconds = lease_seconds
        self._interval_seconds = interval_seconds
        self._retry_policy = retry_policy
        self._uuid_factory = uuid_factory
        self._random_value = random_value
        self._stop = threading.Event()
        self._thread = threading.Thread(
            target=self._run,
            name="kal-meal-heartbeat",
            daemon=True,
        )
        self.error: BaseException | None = None

    def start(self) -> None:
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        self._thread.join()

    def _interruptible_sleep(self, seconds: float) -> None:
        if self._stop.wait(seconds):
            raise _HeartbeatStopped

    def _run(self) -> None:
        while not self._stop.wait(self._interval_seconds):
            mutation_id = self._uuid_factory()
            try:
                _run_with_retry(
                    lambda: self._gateway.heartbeat(
                        self._job_id,
                        mutation_id,
                        self._lease_seconds,
                    ),
                    policy=self._retry_policy,
                    sleep=self._interruptible_sleep,
                    random_value=self._random_value,
                )
            except _HeartbeatStopped:
                return
            except BaseException as error:
                self.error = error
                return


class MealWorker:
    def __init__(
        self,
        *,
        gateway: MealGateway,
        analyzer: Analyzer,
        lease_seconds: int = 180,
        heartbeat_interval_seconds: float | None = None,
        poll_interval_seconds: float = 5,
        retry_policy: RetryPolicy = RetryPolicy(),
        sleep: Callable[[float], object] = time.sleep,
        random_value: Callable[[], float] = random.random,
        uuid_factory: Callable[[], str] = lambda: str(uuid.uuid4()),
    ) -> None:
        if not 30 <= lease_seconds <= 900:
            raise ValueError("lease_seconds deve essere tra 30 e 900")
        heartbeat_interval = heartbeat_interval_seconds
        if heartbeat_interval is None:
            heartbeat_interval = min(60, max(10, lease_seconds / 3))
        if heartbeat_interval <= 0 or heartbeat_interval >= lease_seconds:
            raise ValueError("Intervallo heartbeat non valido")
        if poll_interval_seconds < 0:
            raise ValueError("Intervallo poll non valido")
        self._gateway = gateway
        self._analyzer = analyzer
        self._lease_seconds = lease_seconds
        self._heartbeat_interval_seconds = heartbeat_interval
        self._poll_interval_seconds = poll_interval_seconds
        self._retry_policy = retry_policy
        self._sleep = sleep
        self._random_value = random_value
        self._uuid_factory = uuid_factory

    def run_once(self) -> CycleOutcome:
        mutation_id = self._uuid_factory()
        job = self._retry(
            lambda: self._gateway.claim(mutation_id, self._lease_seconds)
        )
        if job is None:
            return CycleOutcome.IDLE
        return self._process_job(job)

    def serve(
        self,
        *,
        stop_event: threading.Event | None = None,
        maximum_cycles: int | None = None,
    ) -> None:
        stop = stop_event or threading.Event()
        cycles = 0
        consecutive_failures = 0
        while not stop.is_set():
            if maximum_cycles is not None and cycles >= maximum_cycles:
                return
            cycles += 1
            try:
                outcome = self.run_once()
            except KeyboardInterrupt:
                return
            except Exception as error:
                consecutive_failures += 1
                _LOGGER.warning("Ciclo worker fallito (%s)", _safe_cycle_code(error))
                delay = self._retry_policy.delay(
                    consecutive_failures, self._random_value()
                )
                if stop.wait(delay):
                    return
                continue

            if outcome is CycleOutcome.COMPLETED:
                consecutive_failures = 0
                continue
            if outcome is CycleOutcome.FAILED:
                consecutive_failures += 1
                delay = self._retry_policy.delay(
                    consecutive_failures, self._random_value()
                )
                if stop.wait(delay):
                    return
                continue

            consecutive_failures = 0
            if stop.wait(self._poll_interval_seconds):
                return

    def _process_job(self, job: ClaimedJob) -> CycleOutcome:
        _LOGGER.info("Job %s acquisito (tentativo %s)", job.job_id, job.attempt_count)
        with tempfile.TemporaryDirectory(prefix="kal-meal-job-") as temporary:
            directory = Path(temporary)
            try:
                photo = self._retry(lambda: self._gateway.download_photo(job))
            except Exception as error:
                if isinstance(error, HttpStatusError) and error.status in {401, 403}:
                    raise WorkerCycleError("LEASE_OR_AUTH_REJECTED") from error
                code, retryable = _download_failure(error)
                self._report_failure(job, code, retryable)
                return CycleOutcome.FAILED

            try:
                image = verify_and_write_photo(photo, job, directory)
            except ImageIntegrityError as error:
                self._report_failure(job, error.error_code, retryable=False)
                return CycleOutcome.FAILED

            heartbeat_mutation = self._uuid_factory()
            try:
                self._retry(
                    lambda: self._gateway.heartbeat(
                        job.job_id,
                        heartbeat_mutation,
                        self._lease_seconds,
                    )
                )
            except Exception as error:
                raise WorkerCycleError("INITIAL_HEARTBEAT_FAILED") from error

            heartbeat = LeaseHeartbeat(
                gateway=self._gateway,
                job_id=job.job_id,
                lease_seconds=self._lease_seconds,
                interval_seconds=self._heartbeat_interval_seconds,
                retry_policy=self._retry_policy,
                uuid_factory=self._uuid_factory,
                random_value=self._random_value,
            )
            heartbeat.start()
            analysis_error: BaseException | None = None
            result: AnalysisResult | None = None
            try:
                result = self._analyzer.analyze(
                    image,
                    requested_meal_type=job.requested_meal_type,
                    user_note=job.user_note,
                )
            except Exception as error:
                analysis_error = error
            finally:
                heartbeat.stop()

            if heartbeat.error is not None:
                raise WorkerCycleError("LEASE_HEARTBEAT_FAILED") from heartbeat.error
            if analysis_error is not None:
                code, retryable = _analysis_failure(analysis_error)
                self._report_failure(job, code, retryable)
                return CycleOutcome.FAILED
            if result is None:
                raise WorkerCycleError("ANALYZER_EMPTY_RESULT")

            complete_mutation = self._uuid_factory()
            try:
                self._retry(
                    lambda: self._gateway.complete(
                        job.job_id,
                        complete_mutation,
                        result,
                    )
                )
            except Exception as error:
                raise WorkerCycleError("COMPLETE_RPC_FAILED") from error

        _LOGGER.info("Job %s completato; attende revisione", job.job_id)
        return CycleOutcome.COMPLETED

    def _report_failure(
        self, job: ClaimedJob, error_code: str, retryable: bool
    ) -> None:
        mutation_id = self._uuid_factory()
        try:
            self._retry(
                lambda: self._gateway.fail(
                    job.job_id,
                    mutation_id,
                    error_code,
                    retryable,
                )
            )
        except Exception as error:
            raise WorkerCycleError("FAIL_RPC_FAILED") from error
        _LOGGER.warning("Job %s non riuscito (%s)", job.job_id, error_code)

    def _retry(self, operation: Callable[[], _T]) -> _T:
        return _run_with_retry(
            operation,
            policy=self._retry_policy,
            sleep=self._sleep,
            random_value=self._random_value,
        )


def _download_failure(error: BaseException) -> tuple[str, bool]:
    if isinstance(error, ResponseTooLargeError):
        return "IMAGE_RESPONSE_TOO_LARGE", False
    if isinstance(error, HttpStatusError):
        if error.status == 404:
            return "IMAGE_NOT_FOUND", False
        if error.status in {400, 413, 415}:
            return "IMAGE_DOWNLOAD_REJECTED", False
    if is_retryable_transport_error(error):
        return "IMAGE_DOWNLOAD_TRANSIENT", True
    if isinstance(error, SupabaseProtocolError):
        return "IMAGE_DOWNLOAD_PROTOCOL", False
    return "IMAGE_DOWNLOAD_FAILED", True


def _analysis_failure(error: BaseException) -> tuple[str, bool]:
    if isinstance(error, CodexAnalyzerError):
        return error.error_code, error.retryable
    return "ANALYZER_INTERNAL", True


def _safe_cycle_code(error: BaseException) -> str:
    if isinstance(error, WorkerCycleError):
        return error.error_code
    return safe_remote_error_code(error)
