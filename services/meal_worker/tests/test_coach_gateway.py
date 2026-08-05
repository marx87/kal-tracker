import json
import unittest

from kal_meal_worker.coach_contract import CoachNarrativeResult
from kal_meal_worker.supabase_gateway import (
    ClaimedCoachJob,
    SupabaseAuth,
    SupabaseCoachGateway,
    SupabaseProtocolError,
)
from test_coach_contract import narrative_payload, request_payload
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
        "lease_expires_at": "2026-08-05T12:00:00+00:00",
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
    return SupabaseCoachGateway(auth=auth, transport=transport)


def session_response():
    return json_response(
        {
            "access_token": "access-one",
            "refresh_token": "refresh-one",
            "expires_at": 5000,
        }
    )


class ClaimedCoachJobTest(unittest.TestCase):
    def test_reads_the_eight_fields_of_the_claim(self) -> None:
        job = ClaimedCoachJob.from_json(claim_payload())

        self.assertEqual(job.job_id, JOB_ID)
        self.assertEqual(job.owner_id, OWNER_ID)
        self.assertEqual(job.profile_id, PROFILE_ID)
        self.assertEqual(job.request["workouts_done"], 3)
        self.assertEqual(job.attempt_count, 1)
        self.assertEqual(job.row_version, 2)

    def test_empty_poll_is_not_a_job(self) -> None:
        self.assertIsNone(ClaimedCoachJob.from_json({"claimed": False}))

    def test_rejects_photo_fields_and_any_other_extra(self) -> None:
        with self.assertRaisesRegex(SupabaseProtocolError, "inattesi"):
            ClaimedCoachJob.from_json(claim_payload(storage_object="foto.jpg"))

    def test_rejects_a_request_that_is_not_an_object(self) -> None:
        with self.assertRaisesRegex(SupabaseProtocolError, "del coach"):
            ClaimedCoachJob.from_json(claim_payload(request=[]))

    def test_rejects_a_lease_without_timezone(self) -> None:
        with self.assertRaisesRegex(SupabaseProtocolError, "fuso orario"):
            ClaimedCoachJob.from_json(
                claim_payload(lease_expires_at="2026-08-05T12:00:00")
            )


class SupabaseCoachGatewayTest(unittest.TestCase):
    def test_claim_calls_the_coach_rpc_only(self) -> None:
        transport = FakeTransport(session_response(), json_response(claim_payload()))
        gateway = build_gateway(transport)

        job = gateway.claim(MUTATION_ID, 180)

        self.assertIsNotNone(job)
        rpc_request = transport.requests[1]
        self.assertTrue(rpc_request[1].endswith("/rpc/claim_coach_job"))
        self.assertEqual(rpc_request[2]["headers"]["Content-Profile"], "kal_tracker")
        self.assertEqual(
            json.loads(rpc_request[2]["body"]),
            {"p_lease_seconds": 180, "p_mutation_id": MUTATION_ID},
        )
        # Nessun accesso diretto alla tabella: il worker non e' il
        # proprietario e le policy lo escludono.
        self.assertNotIn("coach_jobs?", rpc_request[1])

    def test_heartbeat_complete_and_fail_use_the_coach_rpcs(self) -> None:
        transport = FakeTransport(
            session_response(),
            json_response(
                {
                    "job_id": JOB_ID,
                    "status": "processing",
                    "row_version": 3,
                    "lease_expires_at": "2026-08-05T12:03:00+00:00",
                }
            ),
            json_response(
                {
                    "job_id": JOB_ID,
                    "status": "needs_review",
                    "row_version": 4,
                    "completed_at": "2026-08-05T12:01:00+00:00",
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
        result = CoachNarrativeResult.from_json(narrative_payload())

        gateway.heartbeat(JOB_ID, MUTATION_ID, 180)
        gateway.complete(JOB_ID, SECOND_MUTATION_ID, result)
        gateway.fail(
            JOB_ID,
            "66666666-6666-4666-8666-666666666666",
            "COACH_EMPTY_NARRATIVE",
            True,
        )

        rpc_urls = [request[1] for request in transport.requests[1:]]
        self.assertTrue(rpc_urls[0].endswith("/rpc/heartbeat_coach_job"))
        self.assertTrue(rpc_urls[1].endswith("/rpc/complete_coach_job"))
        self.assertTrue(rpc_urls[2].endswith("/rpc/fail_coach_job"))

    def test_complete_sends_only_text_and_no_null_headline(self) -> None:
        transport = FakeTransport(
            session_response(),
            json_response(
                {
                    "job_id": JOB_ID,
                    "status": "needs_review",
                    "row_version": 4,
                    "completed_at": "2026-08-05T12:01:00+00:00",
                }
            ),
        )
        gateway = build_gateway(transport)
        payload = narrative_payload(headline="Titolo con 3 numeri")
        payload["paragraphs"][0] = "Hai chiuso la settimana a 2410 kcal."
        result = CoachNarrativeResult.from_json(payload)

        gateway.complete(JOB_ID, MUTATION_ID, result)

        body = json.loads(transport.requests[1][2]["body"])
        self.assertEqual(body["p_job_id"], JOB_ID)
        self.assertEqual(sorted(body["p_result"]), ["paragraphs"])
        self.assertEqual(len(body["p_result"]["paragraphs"]), 2)
        raw = transport.requests[1][2]["body"].decode("utf-8")
        self.assertNotIn("2410", raw)
        self.assertNotIn("headline", raw)

    def test_a_result_with_a_number_never_reaches_the_database(self) -> None:
        transport = FakeTransport()
        gateway = build_gateway(transport)
        result = CoachNarrativeResult.from_json(narrative_payload())
        object.__setattr__(result, "paragraphs", ("va bene", 2680))

        with self.assertRaises(Exception) as context:
            gateway.complete(JOB_ID, MUTATION_ID, result)

        self.assertEqual(context.exception.error_code, "COACH_RESULT_NOT_TEXT")
        self.assertEqual(transport.requests, [])

    def test_rejects_a_status_outside_the_contract(self) -> None:
        transport = FakeTransport(
            session_response(),
            json_response(
                {
                    "job_id": JOB_ID,
                    "status": "confirmed",
                    "row_version": 4,
                    "completed_at": "2026-08-05T12:01:00+00:00",
                }
            ),
        )
        gateway = build_gateway(transport)
        result = CoachNarrativeResult.from_json(narrative_payload())

        with self.assertRaisesRegex(SupabaseProtocolError, "Stato"):
            gateway.complete(JOB_ID, MUTATION_ID, result)

    def test_rejects_an_unsafe_error_code_before_any_request(self) -> None:
        transport = FakeTransport()
        gateway = build_gateway(transport)

        with self.assertRaises(ValueError):
            gateway.fail(JOB_ID, MUTATION_ID, "codice con spazi", True)

        self.assertEqual(transport.requests, [])

    def test_the_binding_probe_reads_and_does_not_touch_the_queue(self) -> None:
        """La sonda del doctor: una domanda, nessun job, nessuna mutazione."""
        transport = FakeTransport(
            session_response(), json_response({"active": True})
        )
        gateway = build_gateway(transport)

        self.assertTrue(gateway.binding_active())

        rpc_request = transport.requests[1]
        self.assertTrue(rpc_request[1].endswith("/rpc/coaching_binding_active"))
        # Nessun mutation_id: non c'e' niente da rendere idempotente.
        self.assertEqual(json.loads(rpc_request[2]["body"]), {})

    def test_the_binding_probe_reports_a_missing_binding(self) -> None:
        transport = FakeTransport(
            session_response(), json_response({"active": False})
        )

        self.assertFalse(build_gateway(transport).binding_active())

    def test_the_binding_probe_rejects_an_answer_out_of_contract(self) -> None:
        transport = FakeTransport(
            session_response(), json_response({"active": "si", "extra": 1})
        )

        with self.assertRaises(SupabaseProtocolError):
            build_gateway(transport).binding_active()


if __name__ == "__main__":
    unittest.main()
