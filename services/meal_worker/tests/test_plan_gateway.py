import json
import unittest

from kal_meal_worker.plan_contract import WeeklyPlanResult
from kal_meal_worker.supabase_gateway import (
    ClaimedPlanJob,
    SupabaseAuth,
    SupabasePlanGateway,
    SupabaseProtocolError,
)
from test_plan_contract import RECIPE_UNO, plan_payload, request_payload, valid_request
from test_supabase_gateway import (
    JOB_ID,
    MUTATION_ID,
    OWNER_ID,
    PROFILE_ID,
    FakeTransport,
    json_response,
)


SECOND_MUTATION_ID = "55555555-5555-4555-8555-555555555555"


def claim_payload(**changes):
    payload = {
        "claimed": True,
        "job_id": JOB_ID,
        "owner_id": OWNER_ID,
        "profile_id": PROFILE_ID,
        "request": request_payload(),
        "attempt_count": 1,
        "row_version": 2,
        "lease_expires_at": "2026-08-04T12:00:00+00:00",
    }
    payload.update(changes)
    return payload


def build_gateway(transport):
    auth = SupabaseAuth(
        base_url="https://project.supabase.co",
        publishable_key="sb_publishable_example",
        email="worker@example.test",
        password_provider=lambda: "worker-password",
        transport=transport,
        clock=lambda: 1000.0,
    )
    return SupabasePlanGateway(auth=auth, transport=transport)


def session_response():
    return json_response(
        {
            "access_token": "access-one",
            "refresh_token": "refresh-one",
            "expires_at": 5000,
        }
    )


class ClaimedPlanJobTest(unittest.TestCase):
    def test_reads_the_eight_fields_of_the_claim(self) -> None:
        job = ClaimedPlanJob.from_json(claim_payload())

        self.assertEqual(job.job_id, JOB_ID)
        self.assertEqual(job.owner_id, OWNER_ID)
        self.assertEqual(job.profile_id, PROFILE_ID)
        self.assertEqual(job.request["days"], 2)
        self.assertEqual(job.attempt_count, 1)
        self.assertEqual(job.row_version, 2)

    def test_empty_poll_is_not_a_job(self) -> None:
        self.assertIsNone(ClaimedPlanJob.from_json({"claimed": False}))

    def test_rejects_photo_fields_and_any_other_extra(self) -> None:
        with self.assertRaisesRegex(SupabaseProtocolError, "inattesi"):
            ClaimedPlanJob.from_json(claim_payload(storage_object="foto.jpg"))

    def test_rejects_a_request_that_is_not_an_object(self) -> None:
        with self.assertRaisesRegex(SupabaseProtocolError, "Richiesta"):
            ClaimedPlanJob.from_json(claim_payload(request=[]))

    def test_rejects_a_lease_without_timezone(self) -> None:
        with self.assertRaisesRegex(SupabaseProtocolError, "fuso orario"):
            ClaimedPlanJob.from_json(
                claim_payload(lease_expires_at="2026-08-04T12:00:00")
            )


class SupabasePlanGatewayTest(unittest.TestCase):
    def test_claim_calls_the_plan_rpc_only(self) -> None:
        transport = FakeTransport(session_response(), json_response(claim_payload()))
        gateway = build_gateway(transport)

        job = gateway.claim(MUTATION_ID, 180)

        self.assertIsNotNone(job)
        rpc_request = transport.requests[1]
        self.assertTrue(rpc_request[1].endswith("/rpc/claim_weekly_plan_job"))
        self.assertEqual(rpc_request[2]["headers"]["Content-Profile"], "kal_tracker")
        self.assertEqual(
            json.loads(rpc_request[2]["body"]),
            {"p_lease_seconds": 180, "p_mutation_id": MUTATION_ID},
        )
        self.assertNotIn("weekly_plan_jobs?", rpc_request[1])

    def test_heartbeat_complete_and_fail_use_the_plan_rpcs(self) -> None:
        transport = FakeTransport(
            session_response(),
            json_response(
                {
                    "job_id": JOB_ID,
                    "status": "processing",
                    "row_version": 3,
                    "lease_expires_at": "2026-08-04T12:03:00+00:00",
                }
            ),
            json_response(
                {
                    "job_id": JOB_ID,
                    "status": "needs_review",
                    "row_version": 4,
                    "completed_at": "2026-08-04T12:01:00+00:00",
                }
            ),
            json_response(
                {
                    "job_id": JOB_ID,
                    "status": "queued",
                    "retryable": True,
                    "attempt_count": 2,
                    "row_version": 5,
                    "completed_at": None,
                }
            ),
        )
        gateway = build_gateway(transport)
        result = WeeklyPlanResult.from_json(plan_payload(), request=valid_request())

        gateway.heartbeat(JOB_ID, MUTATION_ID, 180)
        gateway.complete(JOB_ID, SECOND_MUTATION_ID, result)
        gateway.fail(
            JOB_ID,
            "66666666-6666-4666-8666-666666666666",
            "PLAN_UNKNOWN_RECIPE",
            True,
        )

        rpc_urls = [request[1] for request in transport.requests[1:]]
        self.assertTrue(rpc_urls[0].endswith("/rpc/heartbeat_weekly_plan_job"))
        self.assertTrue(rpc_urls[1].endswith("/rpc/complete_weekly_plan_job"))
        self.assertTrue(rpc_urls[2].endswith("/rpc/fail_weekly_plan_job"))

    def test_complete_sends_the_canonical_plan_without_nutrition(self) -> None:
        transport = FakeTransport(
            session_response(),
            json_response(
                {
                    "job_id": JOB_ID,
                    "status": "needs_review",
                    "row_version": 4,
                    "completed_at": "2026-08-04T12:01:00+00:00",
                }
            ),
        )
        gateway = build_gateway(transport)
        payload = plan_payload()
        payload["days"][0]["slots"][0]["kcal"] = 780
        result = WeeklyPlanResult.from_json(payload, request=valid_request())

        gateway.complete(JOB_ID, MUTATION_ID, result)

        body = json.loads(transport.requests[1][2]["body"])
        self.assertEqual(body["p_job_id"], JOB_ID)
        self.assertEqual(
            body["p_result"]["days"][0]["slots"][0],
            {
                "meal": "pranzo",
                "recipeId": RECIPE_UNO,
                "servings": 1.5,
                "why": "Piatto unico completo per il rientro in ufficio.",
            },
        )
        self.assertNotIn("kcal", transport.requests[1][2]["body"].decode("utf-8"))

    def test_rejects_a_status_outside_the_contract(self) -> None:
        transport = FakeTransport(
            session_response(),
            json_response(
                {
                    "job_id": JOB_ID,
                    "status": "confirmed",
                    "row_version": 4,
                    "completed_at": "2026-08-04T12:01:00+00:00",
                }
            ),
        )
        gateway = build_gateway(transport)
        result = WeeklyPlanResult.from_json(plan_payload(), request=valid_request())

        with self.assertRaisesRegex(SupabaseProtocolError, "Stato"):
            gateway.complete(JOB_ID, MUTATION_ID, result)

    def test_rejects_an_unsafe_error_code_before_any_request(self) -> None:
        transport = FakeTransport()
        gateway = build_gateway(transport)

        with self.assertRaises(ValueError):
            gateway.fail(JOB_ID, MUTATION_ID, "codice con spazi", True)

        self.assertEqual(transport.requests, [])


if __name__ == "__main__":
    unittest.main()
