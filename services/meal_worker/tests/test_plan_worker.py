import threading
import unittest

from kal_meal_worker.plan_analyzer import ClaudePlannerError
from kal_meal_worker.plan_contract import WeeklyPlanResult
from kal_meal_worker.plan_worker import PlanWorker
from kal_meal_worker.supabase_gateway import ClaimedPlanJob
from kal_meal_worker.transport import NetworkError
from kal_meal_worker.worker import AlternatingWorker, CycleOutcome, RetryPolicy
from test_plan_contract import plan_payload, request_payload


JOB_ID = "11111111-1111-4111-8111-111111111111"


def make_job(request=None):
    return ClaimedPlanJob(
        job_id=JOB_ID,
        owner_id="22222222-2222-4222-8222-222222222222",
        profile_id="33333333-3333-4333-8333-333333333333",
        request=request if request is not None else request_payload(),
        attempt_count=1,
        row_version=2,
        lease_expires_at="2026-08-04T12:00:00+00:00",
    )


class FakePlanGateway:
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


class SuccessfulPlanner:
    def __init__(self):
        self.request = None

    def plan(self, request):
        self.request = request
        return WeeklyPlanResult.from_json(plan_payload(), request=request)


def uuid_factory():
    counter = 0

    def next_uuid():
        nonlocal counter
        counter += 1
        return f"00000000-0000-4000-8000-{counter:012d}"

    return next_uuid


def build_worker(gateway, planner, **changes):
    options = {
        "gateway": gateway,
        "planner": planner,
        "uuid_factory": uuid_factory(),
        "sleep": lambda seconds: None,
    }
    options.update(changes)
    return PlanWorker(**options)


class PlanWorkerTest(unittest.TestCase):
    def test_successful_lifecycle(self) -> None:
        gateway = FakePlanGateway(make_job())
        planner = SuccessfulPlanner()

        outcome = build_worker(gateway, planner).run_once()

        self.assertIs(outcome, CycleOutcome.COMPLETED)
        self.assertEqual(len(gateway.heartbeats), 1)
        self.assertEqual(len(gateway.completes), 1)
        self.assertEqual(gateway.failures, [])
        self.assertEqual(planner.request.days, 2)
        self.assertEqual(planner.request.meals, ("pranzo", "cena"))
        self.assertEqual(len(gateway.completes[0][2].slots), 4)

    def test_empty_poll_is_idle(self) -> None:
        gateway = FakePlanGateway(None)

        outcome = build_worker(gateway, SuccessfulPlanner()).run_once()

        self.assertIs(outcome, CycleOutcome.IDLE)
        self.assertEqual(gateway.heartbeats, [])

    def test_malformed_request_fails_without_calling_the_planner(self) -> None:
        gateway = FakePlanGateway(make_job(request={"schema": 1, "days": 99}))

        class PlannerMustNotRun:
            def plan(self, request):
                raise AssertionError("Il pianificatore non doveva partire")

        outcome = build_worker(gateway, PlannerMustNotRun()).run_once()

        self.assertIs(outcome, CycleOutcome.FAILED)
        self.assertEqual(gateway.heartbeats, [])
        self.assertEqual(gateway.failures[0][2:], ("PLAN_BAD_REQUEST", False))

    def test_planner_failure_keeps_the_stable_error_code(self) -> None:
        gateway = FakePlanGateway(make_job())

        class FailingPlanner:
            def plan(self, request):
                raise ClaudePlannerError(
                    "dettaglio privato che non deve finire nella RPC",
                    error_code="PLAN_UNKNOWN_RECIPE",
                )

        outcome = build_worker(gateway, FailingPlanner()).run_once()

        self.assertIs(outcome, CycleOutcome.FAILED)
        self.assertEqual(gateway.failures[0][2:], ("PLAN_UNKNOWN_RECIPE", True))
        self.assertEqual(gateway.completes, [])

    def test_unexpected_planner_error_is_generic_and_retryable(self) -> None:
        gateway = FakePlanGateway(make_job())

        class BrokenPlanner:
            def plan(self, request):
                raise RuntimeError("segreto interno")

        outcome = build_worker(gateway, BrokenPlanner()).run_once()

        self.assertIs(outcome, CycleOutcome.FAILED)
        self.assertEqual(gateway.failures[0][2:], ("PLANNER_INTERNAL", True))

    def test_heartbeat_runs_while_the_planner_is_busy(self) -> None:
        gateway = FakePlanGateway(make_job())

        class SlowPlanner:
            def plan(self, request):
                if not gateway.heartbeat_event.wait(1):
                    raise AssertionError("Heartbeat periodico non osservato")
                return WeeklyPlanResult.from_json(plan_payload(), request=request)

        worker = build_worker(
            gateway,
            SlowPlanner(),
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
        gateway = FakePlanGateway(make_job())
        gateway.complete_results = [NetworkError("risposta persa"), None]
        worker = build_worker(
            gateway,
            SuccessfulPlanner(),
            retry_policy=RetryPolicy(
                maximum_attempts=2,
                initial_delay_seconds=0,
                maximum_delay_seconds=0,
            ),
        )

        self.assertIs(worker.run_once(), CycleOutcome.COMPLETED)
        self.assertEqual(len(gateway.completes), 2)
        self.assertEqual(gateway.completes[0][1], gateway.completes[1][1])


class ScriptedWorker:
    def __init__(self, name, outcomes):
        self.name = name
        self.outcomes = list(outcomes)
        self.calls = 0

    def run_once(self):
        self.calls += 1
        outcome = self.outcomes.pop(0) if self.outcomes else CycleOutcome.IDLE
        if isinstance(outcome, BaseException):
            raise outcome
        return outcome


class AlternatingWorkerTest(unittest.TestCase):
    def test_busy_queues_take_turns(self) -> None:
        photos = ScriptedWorker("foto", [CycleOutcome.COMPLETED] * 4)
        plans = ScriptedWorker("piano", [CycleOutcome.COMPLETED] * 4)
        worker = AlternatingWorker(workers=[photos, plans])

        outcomes = [worker.run_once() for _ in range(4)]

        self.assertEqual(outcomes, [CycleOutcome.COMPLETED] * 4)
        self.assertEqual(photos.calls, 2)
        self.assertEqual(plans.calls, 2)

    def test_an_idle_queue_lets_the_other_work_in_the_same_cycle(self) -> None:
        photos = ScriptedWorker("foto", [CycleOutcome.IDLE, CycleOutcome.IDLE])
        plans = ScriptedWorker("piano", [CycleOutcome.COMPLETED] * 2)
        worker = AlternatingWorker(workers=[photos, plans])

        self.assertIs(worker.run_once(), CycleOutcome.COMPLETED)
        self.assertEqual(photos.calls, 1)
        self.assertEqual(plans.calls, 1)

    def test_all_idle_is_a_single_idle_cycle(self) -> None:
        photos = ScriptedWorker("foto", [])
        plans = ScriptedWorker("piano", [])
        worker = AlternatingWorker(workers=[photos, plans])

        self.assertIs(worker.run_once(), CycleOutcome.IDLE)
        self.assertEqual(photos.calls, 1)
        self.assertEqual(plans.calls, 1)

    def test_a_failing_queue_does_not_starve_the_other(self) -> None:
        photos = ScriptedWorker("foto", [NetworkError("giu"), NetworkError("giu")])
        plans = ScriptedWorker("piano", [CycleOutcome.COMPLETED])
        worker = AlternatingWorker(workers=[photos, plans])

        with self.assertRaises(NetworkError):
            worker.run_once()
        self.assertIs(worker.run_once(), CycleOutcome.COMPLETED)
        self.assertEqual(photos.calls, 1)
        self.assertEqual(plans.calls, 1)

    def test_serve_stops_on_the_stop_event(self) -> None:
        photos = ScriptedWorker("foto", [CycleOutcome.COMPLETED])
        plans = ScriptedWorker("piano", [CycleOutcome.COMPLETED])
        worker = AlternatingWorker(workers=[photos, plans], poll_interval_seconds=0)

        worker.serve(stop_event=threading.Event(), maximum_cycles=2)

        self.assertEqual(photos.calls, 1)
        self.assertEqual(plans.calls, 1)

    def test_requires_at_least_one_queue(self) -> None:
        with self.assertRaises(ValueError):
            AlternatingWorker(workers=[])


if __name__ == "__main__":
    unittest.main()
