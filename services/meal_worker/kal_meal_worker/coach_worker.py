"""Worker della coda del coach.

Gemello di ``PlanWorker``: anche qui la richiesta arriva gia' dentro il job,
non c'e' niente da scaricare e il ciclo di vita (claim, lease, heartbeat,
esito, backoff) e' quello di ``BaseJobWorker``. Cambiano il lavoro vero — si
scrive un commento invece di comporre una settimana — e la famiglia dei codici
errore, che resta separata perche' l'app li mostra a Marco cosi' come sono.
"""

from __future__ import annotations

import logging
import random
import time
import uuid
from collections.abc import Callable, Mapping
from typing import Protocol

from .analyzer_errors import AnalyzerError
from .coach_contract import CoachContractError, CoachNarrativeResult, CoachRequest
from .supabase_gateway import ClaimedCoachJob
from .worker import (
    BaseJobWorker,
    CycleOutcome,
    JobGateway,
    RetryPolicy,
    WorkerCycleError,
)


_LOGGER = logging.getLogger("kal_meal_worker")


class Commentator(Protocol):
    def comment(self, request: CoachRequest) -> CoachNarrativeResult: ...


class CoachGateway(JobGateway, Protocol):
    def claim(
        self, mutation_id: str, lease_seconds: int
    ) -> ClaimedCoachJob | None: ...

    def complete(
        self, job_id: str, mutation_id: str, result: CoachNarrativeResult
    ) -> Mapping[str, object]: ...


class CoachWorker(BaseJobWorker[ClaimedCoachJob]):
    heartbeat_thread_name = "kal-coach-heartbeat"

    def __init__(
        self,
        *,
        gateway: CoachGateway,
        commentator: Commentator,
        lease_seconds: int = 180,
        heartbeat_interval_seconds: float | None = None,
        poll_interval_seconds: float = 5,
        retry_policy: RetryPolicy = RetryPolicy(),
        sleep: Callable[[float], object] = time.sleep,
        random_value: Callable[[], float] = random.random,
        uuid_factory: Callable[[], str] = lambda: str(uuid.uuid4()),
    ) -> None:
        super().__init__(
            gateway=gateway,
            lease_seconds=lease_seconds,
            heartbeat_interval_seconds=heartbeat_interval_seconds,
            poll_interval_seconds=poll_interval_seconds,
            retry_policy=retry_policy,
            sleep=sleep,
            random_value=random_value,
            uuid_factory=uuid_factory,
        )
        self._coach_gateway = gateway
        self._commentator = commentator

    def _process_job(self, job: ClaimedCoachJob) -> CycleOutcome:
        _LOGGER.info(
            "Job coach %s acquisito (tentativo %s)", job.job_id, job.attempt_count
        )
        try:
            request = CoachRequest.from_json(job.request)
        except CoachContractError as error:
            # La richiesta l'ha scritta l'app: ritentarla darebbe lo stesso
            # esito, quindi il job si chiude subito come non ritentabile.
            self._report_failure(job.job_id, error.error_code, retryable=False)
            return CycleOutcome.FAILED

        self._send_initial_heartbeat(job.job_id)
        heartbeat = self._start_heartbeat(job.job_id)
        writing_error: BaseException | None = None
        result: CoachNarrativeResult | None = None
        try:
            result = self._commentator.comment(request)
        except Exception as error:
            writing_error = error
        finally:
            heartbeat.stop()

        if heartbeat.error is not None:
            raise WorkerCycleError("LEASE_HEARTBEAT_FAILED") from heartbeat.error
        if writing_error is not None:
            code, retryable = _writing_failure(writing_error)
            self._report_failure(job.job_id, code, retryable)
            return CycleOutcome.FAILED
        if result is None:
            raise WorkerCycleError("COACH_EMPTY_RESULT")

        complete_mutation = self._uuid_factory()
        try:
            self._retry(
                lambda: self._coach_gateway.complete(
                    job.job_id,
                    complete_mutation,
                    result,
                )
            )
        except Exception as error:
            raise WorkerCycleError("COMPLETE_RPC_FAILED") from error

        _LOGGER.info("Job coach %s completato; attende revisione", job.job_id)
        return CycleOutcome.COMPLETED


def _writing_failure(error: BaseException) -> tuple[str, bool]:
    if isinstance(error, AnalyzerError):
        return error.error_code, error.retryable
    if isinstance(error, CoachContractError):
        return error.error_code, False
    return "COACH_INTERNAL", True
