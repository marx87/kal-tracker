import base64
import json
import unittest

from kal_meal_worker.supabase_gateway import (
    ClaimedJob,
    SupabaseAuth,
    SupabaseConfigurationError,
    SupabaseMealGateway,
    SupabaseProtocolError,
    validate_publishable_key,
)
from kal_meal_worker.transport import HttpResponse, HttpStatusError
from kal_meal_worker.contract import AnalysisResult
from test_contract import valid_payload


JOB_ID = "11111111-1111-4111-8111-111111111111"
OWNER_ID = "22222222-2222-4222-8222-222222222222"
PROFILE_ID = "33333333-3333-4333-8333-333333333333"
MUTATION_ID = "44444444-4444-4444-8444-444444444444"


def claim_payload(**changes):
    payload = {
        "claimed": True,
        "job_id": JOB_ID,
        "owner_id": OWNER_ID,
        "profile_id": PROFILE_ID,
        "storage_bucket": "kal-tracker-meal-photos",
        "storage_object": f"{OWNER_ID}/{JOB_ID}/foto ü.jpg",
        "image_sha256": "a" * 64,
        "image_size_bytes": 123,
        "image_mime_type": "image/jpeg",
        "requested_meal_type": "lunch",
        "user_note": "Senza olio",
        "attempt_count": 1,
        "row_version": 2,
        "lease_expires_at": "2026-08-02T12:00:00+00:00",
    }
    payload.update(changes)
    return payload


def json_response(value, headers=None):
    return HttpResponse(
        200,
        headers or {"content-type": "application/json"},
        json.dumps(value).encode(),
    )


class FakeTransport:
    def __init__(self, *responses):
        self.responses = list(responses)
        self.requests = []

    def request(self, method, url, **kwargs):
        self.requests.append((method, url, kwargs))
        response = self.responses.pop(0)
        if isinstance(response, BaseException):
            raise response
        return response


def build_gateway(transport, *, clock=lambda: 1000.0, password_calls=None):
    password_calls = password_calls if password_calls is not None else []

    def password_provider():
        password_calls.append(True)
        return "worker-password"

    auth = SupabaseAuth(
        base_url="https://project.supabase.co",
        publishable_key="sb_publishable_example",
        email="worker@example.test",
        password_provider=password_provider,
        transport=transport,
        clock=clock,
    )
    return SupabaseMealGateway(auth=auth, transport=transport), password_calls


class SupabaseGatewayTest(unittest.TestCase):
    def test_claim_signs_in_and_calls_scoped_rpc(self) -> None:
        transport = FakeTransport(
            json_response(
                {
                    "access_token": "access-one",
                    "refresh_token": "refresh-one",
                    "expires_at": 5000,
                }
            ),
            json_response(claim_payload()),
        )
        gateway, password_calls = build_gateway(transport)

        job = gateway.claim(MUTATION_ID, 180)

        self.assertIsNotNone(job)
        self.assertEqual(job.job_id, JOB_ID)
        self.assertEqual(password_calls, [True])
        auth_request, rpc_request = transport.requests
        self.assertIn("grant_type=password", auth_request[1])
        self.assertEqual(auth_request[2]["headers"]["apikey"], "sb_publishable_example")
        self.assertNotIn("Authorization", auth_request[2]["headers"])
        self.assertTrue(rpc_request[1].endswith("/rpc/claim_meal_analysis_job"))
        self.assertEqual(
            rpc_request[2]["headers"]["Authorization"], "Bearer access-one"
        )
        self.assertEqual(rpc_request[2]["headers"]["Content-Profile"], "kal_tracker")
        self.assertEqual(
            json.loads(rpc_request[2]["body"]),
            {"p_lease_seconds": 180, "p_mutation_id": MUTATION_ID},
        )

    def test_401_refreshes_once_without_reading_password_again(self) -> None:
        transport = FakeTransport(
            json_response(
                {
                    "access_token": "access-one",
                    "refresh_token": "refresh-one",
                    "expires_at": 5000,
                }
            ),
            HttpStatusError(401),
            json_response(
                {
                    "access_token": "access-two",
                    "refresh_token": "refresh-two",
                    "expires_at": 5000,
                }
            ),
            json_response({"claimed": False}),
        )
        gateway, password_calls = build_gateway(transport)

        self.assertIsNone(gateway.claim(MUTATION_ID, 180))
        self.assertEqual(password_calls, [True])
        self.assertIn("grant_type=refresh_token", transport.requests[2][1])
        self.assertEqual(
            transport.requests[3][2]["headers"]["Authorization"],
            "Bearer access-two",
        )

    def test_expired_session_uses_refresh_token(self) -> None:
        now = [1000.0]
        transport = FakeTransport(
            json_response(
                {
                    "access_token": "access-one",
                    "refresh_token": "refresh-one",
                    "expires_at": 1200,
                }
            ),
            json_response({"claimed": False}),
            json_response(
                {
                    "access_token": "access-two",
                    "refresh_token": "refresh-two",
                    "expires_at": 5000,
                }
            ),
            json_response({"claimed": False}),
        )
        gateway, password_calls = build_gateway(transport, clock=lambda: now[0])

        gateway.claim(MUTATION_ID, 180)
        now[0] = 1190
        gateway.claim("55555555-5555-4555-8555-555555555555", 180)

        self.assertEqual(password_calls, [True])
        self.assertIn("grant_type=refresh_token", transport.requests[2][1])

    def test_download_uses_authenticated_private_storage_path(self) -> None:
        image = b"image-data"
        transport = FakeTransport(
            json_response(
                {
                    "access_token": "access",
                    "refresh_token": "refresh",
                    "expires_at": 5000,
                }
            ),
            HttpResponse(200, {"content-type": "image/jpeg; charset=binary"}, image),
        )
        gateway, _ = build_gateway(transport)
        job = ClaimedJob.from_json(claim_payload())

        photo = gateway.download_photo(job)

        self.assertEqual(photo.body, image)
        self.assertEqual(photo.content_type, "image/jpeg")
        request = transport.requests[1]
        self.assertIn("/storage/v1/object/authenticated/", request[1])
        self.assertIn("foto%20%C3%BC.jpg", request[1])
        self.assertEqual(request[2]["headers"]["Authorization"], "Bearer access")

    def test_heartbeat_complete_and_fail_use_only_worker_rpcs(self) -> None:
        transport = FakeTransport(
            json_response(
                {
                    "access_token": "access",
                    "refresh_token": "refresh",
                    "expires_at": 5000,
                }
            ),
            json_response(
                {
                    "job_id": JOB_ID,
                    "status": "processing",
                    "row_version": 3,
                    "lease_expires_at": "2026-08-02T12:03:00+00:00",
                }
            ),
            json_response(
                {
                    "job_id": JOB_ID,
                    "status": "needs_review",
                    "row_version": 4,
                    "completed_at": "2026-08-02T12:01:00+00:00",
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
        gateway, _ = build_gateway(transport)

        gateway.heartbeat(JOB_ID, MUTATION_ID, 180)
        gateway.complete(
            JOB_ID,
            "55555555-5555-4555-8555-555555555555",
            AnalysisResult.from_json(valid_payload()),
        )
        gateway.fail(
            JOB_ID,
            "66666666-6666-4666-8666-666666666666",
            "CODEX_TIMEOUT",
            True,
        )

        rpc_urls = [request[1] for request in transport.requests[1:]]
        self.assertTrue(rpc_urls[0].endswith("/rpc/heartbeat_meal_analysis_job"))
        self.assertTrue(rpc_urls[1].endswith("/rpc/complete_meal_analysis_job"))
        self.assertTrue(rpc_urls[2].endswith("/rpc/fail_meal_analysis_job"))
        self.assertNotIn("meal_analysis_jobs?", " ".join(rpc_urls))
        fail_body = json.loads(transport.requests[3][2]["body"])
        self.assertEqual(fail_body["p_error_code"], "CODEX_TIMEOUT")
        self.assertIs(fail_body["p_retryable"], True)

    def test_rejects_path_outside_claimed_owner_and_job(self) -> None:
        with self.assertRaisesRegex(SupabaseProtocolError, "fuori dal job"):
            ClaimedJob.from_json(claim_payload(storage_object="../other/photo.jpg"))

    def test_rejects_unexpected_claim_fields(self) -> None:
        with self.assertRaisesRegex(SupabaseProtocolError, "inattesi"):
            ClaimedJob.from_json(claim_payload(secret="unexpected"))

    def test_rejects_new_and_legacy_service_role_keys(self) -> None:
        payload = base64.urlsafe_b64encode(
            json.dumps({"role": "service_role"}).encode()
        ).decode().rstrip("=")
        legacy_service_role = f"header.{payload}.signature"

        for key in ("sb_secret_example", legacy_service_role):
            with self.subTest(key=key):
                with self.assertRaisesRegex(
                    SupabaseConfigurationError, "service_role"
                ):
                    validate_publishable_key(key)

    def test_rejects_plain_http_except_for_local_development(self) -> None:
        with self.assertRaisesRegex(SupabaseConfigurationError, "HTTPS"):
            SupabaseAuth(
                base_url="http://example.test",
                publishable_key="sb_publishable_example",
                email="worker@example.test",
                password_provider=lambda: "password",
                transport=FakeTransport(),
            )


if __name__ == "__main__":
    unittest.main()
