"""Worker della coda del piano settimanale.

Gemello di ``MealWorker`` e non un suo ramo condizionale: qui non c'e' nessuna
immagine da scaricare o verificare, la richiesta arriva gia' dentro il job e i
codici errore sono un'altra famiglia. Condividono soltanto il ciclo di vita
(claim, lease, heartbeat, esito, backoff), che vive in ``BaseJobWorker``.
"""

from __future__ import annotations

import logging
import random
import time
import uuid
from collections.abc import Callable, Mapping
from typing import Protocol

from .analyzer_errors import AnalyzerError
from .plan_contract import PlanContractError, PlanRequest, WeeklyPlanResult
from .supabase_gateway import ClaimedPlanJob
from .worker import (
    BaseJobWorker,
    CycleOutcome,
    JobGateway,
    RetryPolicy,
    WorkerCycleError,
)


_LOGGER = logging.getLogger("kal_meal_worker")


class Planner(Protocol):
    def plan(self, request: PlanRequest) -> WeeklyPlanResult: ...


class PlanGateway(JobGateway, Protocol):
    def claim(
        self, mutation_id: str, lease_seconds: int
    ) -> ClaimedPlanJob | None: ...

    def complete(
        self, job_id: str, mutation_id: str, result: WeeklyPlanResult
    ) -> Mapping[str, object]: ...


class PlanWorker(BaseJobWorker[ClaimedPlanJob]):
    heartbeat_thread_name = "kal-plan-heartbeat"

    def __init__(
        self,
        *,
        gateway: PlanGateway,
        planner: Planner,
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
        self._plan_gateway = gateway
        self._planner = planner

    def _process_job(self, job: ClaimedPlanJob) -> CycleOutcome:
        _LOGGER.info(
            "Job piano %s acquisito (tentativo %s)", job.job_id, job.attempt_count
        )
        try:
            request = PlanRequest.from_json(job.request)
        except PlanContractError as error:
            # La richiesta l'ha scritta l'app: ritentarla darebbe lo stesso
            # esito, quindi il job si chiude subito come non ritentabile.
            self._report_failure(job.job_id, error.error_code, retryable=False)
            return CycleOutcome.FAILED

        self._send_initial_heartbeat(job.job_id)
        heartbeat = self._start_heartbeat(job.job_id)
        planning_error: BaseException | None = None
        result: WeeklyPlanResult | None = None
        try:
            result = self._planner.plan(request)
        except Exception as error:
            planning_error = error
        finally:
            heartbeat.stop()

        if heartbeat.error is not None:
            raise WorkerCycleError("LEASE_HEARTBEAT_FAILED") from heartbeat.error
        if planning_error is not None:
            code, retryable = _planning_failure(planning_error)
            self._report_failure(job.job_id, code, retryable)
            return CycleOutcome.FAILED
        if result is None:
            raise WorkerCycleError("PLANNER_EMPTY_RESULT")

        complete_mutation = self._uuid_factory()
        try:
            self._retry(
                lambda: self._plan_gateway.complete(
                    job.job_id,
                    complete_mutation,
                    result,
                )
            )
        except Exception as error:
            raise WorkerCycleError("COMPLETE_RPC_FAILED") from error

        _LOGGER.info("Job piano %s completato; attende revisione", job.job_id)
        return CycleOutcome.COMPLETED


def _planning_failure(error: BaseException) -> tuple[str, bool]:
    if isinstance(error, AnalyzerError):
        return error.error_code, error.retryable
    if isinstance(error, PlanContractError):
        return error.error_code, False
    return "PLANNER_INTERNAL", True
