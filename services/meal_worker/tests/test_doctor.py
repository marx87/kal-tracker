import json
import os
import subprocess
import unittest

from kal_meal_worker import doctor, service_cli
from kal_meal_worker.doctor import CheckStatus
from kal_meal_worker.keychain import KeychainError
from kal_meal_worker.supabase_gateway import (
    SupabaseAuth,
    SupabaseMealGateway,
    SupabasePlanGateway,
)
from kal_meal_worker.transport import HttpResponse, HttpStatusError, NetworkError


_BASE_URL = "https://example.supabase.co"
_TOKEN_RESPONSE = HttpResponse(
    200,
    {},
    json.dumps(
        {
            "access_token": "worker-token",
            "refresh_token": "refresh-token",
            "expires_in": 3600,
        }
    ).encode("utf-8"),
)
_BUCKET_METADATA = {
    "id": "kal-tracker-meal-photos",
    "name": "kal-tracker-meal-photos",
    "public": False,
    "file_size_limit": 10485760,
    "allowed_mime_types": ["image/jpeg", "image/png", "image/webp"],
}


class ScriptedTransport:
    """Trasporto offline: restituisce o solleva i passi programmati in ordine."""

    def __init__(self, steps):
        self._steps = list(steps)
        self.calls = []

    def request(self, method, url, *, headers, body, timeout, max_response_bytes):
        del body, timeout, max_response_bytes
        self.calls.append((method, url, dict(headers)))
        if not self._steps:
            raise AssertionError(f"richiesta HTTP non programmata: {method} {url}")
        step = self._steps.pop(0)
        if isinstance(step, Exception):
            raise step
        return step


def _auth(transport, password_provider=lambda: "password"):
    return SupabaseAuth(
        base_url=_BASE_URL,
        publishable_key="publishable-key",
        email="worker@example.test",
        password_provider=password_provider,
        transport=transport,
    )


def _bucket_response(**overrides):
    payload = dict(_BUCKET_METADATA)
    payload.update(overrides)
    return HttpResponse(200, {}, json.dumps(payload).encode("utf-8"))


class KeychainCheckTest(unittest.TestCase):
    def test_present_password_is_ok_and_never_shown(self) -> None:
        result = doctor.check_keychain(
            lambda: "super-secret-password",
            service="com.kaltracker.meal-worker.supabase",
            account="worker@example.test",
        )

        self.assertIs(result.status, CheckStatus.OK)
        self.assertIn("com.kaltracker.meal-worker.supabase", result.detail)
        self.assertNotIn("super-secret-password", result.detail)

    def test_missing_password_fails_with_location(self) -> None:
        def provider() -> str:
            raise KeychainError("Password worker non trovata nel Portachiavi")

        result = doctor.check_keychain(
            provider,
            service="service",
            account="account",
        )

        self.assertIs(result.status, CheckStatus.FAILED)
        self.assertIn("non trovata", result.detail)
        self.assertIn("service", result.detail)


class AnalyzerCliCheckTest(unittest.TestCase):
    def test_claude_ok_uses_auth_status_and_filtered_environment(self) -> None:
        observed = {}
        os.environ["ANTHROPIC_API_KEY"] = "secret-api-key"
        self.addCleanup(os.environ.pop, "ANTHROPIC_API_KEY", None)

        def runner(command, **kwargs):
            observed["command"] = command
            observed["env"] = kwargs["env"]
            return subprocess.CompletedProcess(command, 0, "ok", "")

        result = doctor.check_analyzer_cli(
            provider="claude",
            executable="/opt/homebrew/bin/claude",
            runner=runner,
        )

        self.assertIs(result.status, CheckStatus.OK)
        self.assertEqual(
            observed["command"],
            ["/opt/homebrew/bin/claude", "auth", "status"],
        )
        self.assertNotIn("ANTHROPIC_API_KEY", observed["env"])
        self.assertEqual(observed["env"]["NO_COLOR"], "1")

    def test_codex_uses_login_status(self) -> None:
        observed = {}

        def runner(command, **kwargs):
            del kwargs
            observed["command"] = command
            return subprocess.CompletedProcess(command, 0, "ok", "")

        result = doctor.check_analyzer_cli(
            provider="codex",
            executable="codex",
            runner=runner,
        )

        self.assertIs(result.status, CheckStatus.OK)
        self.assertEqual(observed["command"], ["codex", "login", "status"])

    def test_missing_executable_fails(self) -> None:
        def runner(command, **kwargs):
            del command, kwargs
            raise FileNotFoundError()

        result = doctor.check_analyzer_cli(
            provider="claude",
            executable="/missing/claude",
            runner=runner,
        )

        self.assertIs(result.status, CheckStatus.FAILED)
        self.assertIn("/missing/claude", result.detail)

    def test_logged_out_cli_fails_with_hint(self) -> None:
        def runner(command, **kwargs):
            del kwargs
            return subprocess.CompletedProcess(command, 1, "", "not logged in")

        result = doctor.check_analyzer_cli(
            provider="claude",
            executable="claude",
            runner=runner,
        )

        self.assertIs(result.status, CheckStatus.FAILED)
        self.assertIn("claude auth status", result.detail)

    def test_hung_cli_fails_on_timeout(self) -> None:
        def runner(command, **kwargs):
            del kwargs
            raise subprocess.TimeoutExpired(cmd=command, timeout=30)

        result = doctor.check_analyzer_cli(
            provider="claude",
            executable="claude",
            runner=runner,
        )

        self.assertIs(result.status, CheckStatus.FAILED)
        self.assertIn("30", result.detail)

    def test_unknown_provider_fails(self) -> None:
        result = doctor.check_analyzer_cli(provider="gpt", executable="gpt")

        self.assertIs(result.status, CheckStatus.FAILED)


class SupabaseHealthCheckTest(unittest.TestCase):
    def test_health_endpoint_reachable(self) -> None:
        transport = ScriptedTransport([HttpResponse(200, {}, b"{}")])

        result = doctor.check_supabase_health(
            transport=transport,
            base_url=_BASE_URL,
            publishable_key="publishable-key",
        )

        self.assertIs(result.status, CheckStatus.OK)
        method, url, headers = transport.calls[0]
        self.assertEqual(method, "GET")
        self.assertEqual(url, f"{_BASE_URL}/auth/v1/health")
        self.assertEqual(headers["apikey"], "publishable-key")

    def test_network_error_fails(self) -> None:
        transport = ScriptedTransport([NetworkError("giu")])

        result = doctor.check_supabase_health(
            transport=transport,
            base_url=_BASE_URL,
            publishable_key="publishable-key",
        )

        self.assertIs(result.status, CheckStatus.FAILED)
        self.assertIn("non raggiungibile", result.detail)

    def test_http_error_fails_with_status(self) -> None:
        transport = ScriptedTransport([HttpStatusError(503)])

        result = doctor.check_supabase_health(
            transport=transport,
            base_url=_BASE_URL,
            publishable_key="publishable-key",
        )

        self.assertIs(result.status, CheckStatus.FAILED)
        self.assertIn("503", result.detail)


class WorkerLoginCheckTest(unittest.TestCase):
    def test_login_obtains_session(self) -> None:
        transport = ScriptedTransport([_TOKEN_RESPONSE])

        result = doctor.check_worker_login(_auth(transport))

        self.assertIs(result.status, CheckStatus.OK)
        self.assertNotIn("worker-token", result.detail)

    def test_rejected_credentials_fail(self) -> None:
        transport = ScriptedTransport([HttpStatusError(400, "invalid_grant")])

        result = doctor.check_worker_login(_auth(transport))

        self.assertIs(result.status, CheckStatus.FAILED)
        self.assertIn("rifiutate", result.detail)

    def test_missing_keychain_password_fails(self) -> None:
        def provider() -> str:
            raise KeychainError("Portachiavi macOS non disponibile")

        transport = ScriptedTransport([])

        result = doctor.check_worker_login(_auth(transport, provider))

        self.assertIs(result.status, CheckStatus.FAILED)
        self.assertIn("Portachiavi", result.detail)


class WorkerRpcCheckTest(unittest.TestCase):
    def _gateway(self, transport):
        auth = _auth(transport)
        return SupabaseMealGateway(auth=auth, transport=transport)

    def test_probe_job_not_found_means_rpc_exposed(self) -> None:
        transport = ScriptedTransport(
            [_TOKEN_RESPONSE, HttpStatusError(400, "P0002")]
        )

        result = doctor.check_worker_rpc(self._gateway(transport))

        self.assertIs(result.status, CheckStatus.OK)
        method, url, headers = transport.calls[1]
        self.assertEqual(method, "POST")
        self.assertIn("/rest/v1/rpc/heartbeat_meal_analysis_job", url)
        self.assertEqual(headers["Accept-Profile"], "kal_tracker")

    def test_permission_denied_fails(self) -> None:
        transport = ScriptedTransport(
            [_TOKEN_RESPONSE, HttpStatusError(403, "42501")]
        )

        result = doctor.check_worker_rpc(self._gateway(transport))

        self.assertIs(result.status, CheckStatus.FAILED)
        self.assertIn("42501", result.detail)

    def test_missing_schema_fails(self) -> None:
        transport = ScriptedTransport(
            [_TOKEN_RESPONSE, HttpStatusError(404, "PGRST202")]
        )

        result = doctor.check_worker_rpc(self._gateway(transport))

        self.assertIs(result.status, CheckStatus.FAILED)
        self.assertIn("kal_tracker", result.detail)


class PlanRpcCheckTest(unittest.TestCase):
    def _gateway(self, transport):
        auth = _auth(transport)
        return SupabasePlanGateway(auth=auth, transport=transport)

    def test_probe_job_not_found_means_plan_rpc_exposed(self) -> None:
        transport = ScriptedTransport(
            [_TOKEN_RESPONSE, HttpStatusError(400, "P0002")]
        )

        result = doctor.check_plan_rpc(self._gateway(transport))

        self.assertIs(result.status, CheckStatus.OK)
        method, url, headers = transport.calls[1]
        self.assertEqual(method, "POST")
        self.assertIn("/rest/v1/rpc/heartbeat_weekly_plan_job", url)
        self.assertEqual(headers["Accept-Profile"], "kal_tracker")

    def test_missing_migration_fails_with_hint(self) -> None:
        transport = ScriptedTransport(
            [_TOKEN_RESPONSE, HttpStatusError(404, "PGRST202")]
        )

        result = doctor.check_plan_rpc(self._gateway(transport))

        self.assertIs(result.status, CheckStatus.FAILED)
        self.assertIn("202608040005_weekly_plan_jobs.sql", result.detail)

    def test_permission_denied_fails(self) -> None:
        transport = ScriptedTransport(
            [_TOKEN_RESPONSE, HttpStatusError(403, "42501")]
        )

        result = doctor.check_plan_rpc(self._gateway(transport))

        self.assertIs(result.status, CheckStatus.FAILED)
        self.assertIn("42501", result.detail)


class PhotoBucketCheckTest(unittest.TestCase):
    def test_metadata_matching_schema_is_ok(self) -> None:
        transport = ScriptedTransport([_TOKEN_RESPONSE, _bucket_response()])

        result = doctor.check_photo_bucket(
            transport=transport,
            auth=_auth(transport),
        )

        self.assertIs(result.status, CheckStatus.OK)
        method, url, headers = transport.calls[1]
        self.assertEqual(method, "GET")
        self.assertEqual(
            url,
            f"{_BASE_URL}/storage/v1/bucket/kal-tracker-meal-photos",
        )
        self.assertEqual(headers["Authorization"], "Bearer worker-token")

    def test_public_bucket_fails(self) -> None:
        transport = ScriptedTransport(
            [_TOKEN_RESPONSE, _bucket_response(public=True)]
        )

        result = doctor.check_photo_bucket(
            transport=transport,
            auth=_auth(transport),
        )

        self.assertIs(result.status, CheckStatus.FAILED)
        self.assertIn("privato", result.detail)

    def test_wrong_size_limit_fails(self) -> None:
        transport = ScriptedTransport(
            [_TOKEN_RESPONSE, _bucket_response(file_size_limit=None)]
        )

        result = doctor.check_photo_bucket(
            transport=transport,
            auth=_auth(transport),
        )

        self.assertIs(result.status, CheckStatus.FAILED)
        self.assertIn("10485760", result.detail)

    def test_reserved_metadata_falls_back_to_denied_probe(self) -> None:
        transport = ScriptedTransport(
            [
                _TOKEN_RESPONSE,
                HttpStatusError(404, "not_found"),
                HttpStatusError(400, "not_found"),
            ]
        )

        result = doctor.check_photo_bucket(
            transport=transport,
            auth=_auth(transport),
        )

        self.assertIs(result.status, CheckStatus.OK)
        self.assertIn("negato", result.detail)
        probe_url = transport.calls[2][1]
        self.assertIn(
            "/storage/v1/object/authenticated/kal-tracker-meal-photos/",
            probe_url,
        )

    def test_readable_probe_object_fails(self) -> None:
        transport = ScriptedTransport(
            [
                _TOKEN_RESPONSE,
                HttpStatusError(403, None),
                HttpResponse(200, {}, b"binary"),
            ]
        )

        result = doctor.check_photo_bucket(
            transport=transport,
            auth=_auth(transport),
        )

        self.assertIs(result.status, CheckStatus.FAILED)
        self.assertIn("policy", result.detail)

    def test_unreachable_storage_fails(self) -> None:
        transport = ScriptedTransport([_TOKEN_RESPONSE, NetworkError("giu")])

        result = doctor.check_photo_bucket(
            transport=transport,
            auth=_auth(transport),
        )

        self.assertIs(result.status, CheckStatus.FAILED)


class RunDoctorTest(unittest.TestCase):
    @staticmethod
    def _ok_runner(command, **kwargs):
        del kwargs
        return subprocess.CompletedProcess(command, 0, "ok", "")

    def test_all_checks_pass(self) -> None:
        transport = ScriptedTransport(
            [
                HttpResponse(200, {}, b"{}"),
                _TOKEN_RESPONSE,
                HttpStatusError(400, "P0002"),
                HttpStatusError(400, "P0002"),
                _bucket_response(),
            ]
        )
        auth = _auth(transport)
        gateway = SupabaseMealGateway(auth=auth, transport=transport)
        plan_gateway = SupabasePlanGateway(auth=auth, transport=transport)
        lines = []

        exit_code = doctor.run_doctor(
            provider="claude",
            analyzer_executable="claude",
            keychain_service="com.kaltracker.meal-worker.supabase",
            keychain_account="worker@example.test",
            password_provider=lambda: "password",
            auth=auth,
            gateway=gateway,
            plan_gateway=plan_gateway,
            transport=transport,
            runner=self._ok_runner,
            emit=lines.append,
        )

        self.assertEqual(exit_code, 0)
        report = "\n".join(lines)
        self.assertIn("Esito: 7/7 controlli superati", report)
        self.assertIn("RPC piano settimanale", report)
        self.assertNotIn("ERRORE", report)
        self.assertNotIn("password", report.replace("password del worker", ""))

    def test_keychain_failure_skips_dependent_checks(self) -> None:
        def provider() -> str:
            raise KeychainError("Password worker non trovata nel Portachiavi")

        transport = ScriptedTransport([HttpResponse(200, {}, b"{}")])
        auth = _auth(transport, provider)
        gateway = SupabaseMealGateway(auth=auth, transport=transport)
        plan_gateway = SupabasePlanGateway(auth=auth, transport=transport)
        lines = []

        exit_code = doctor.run_doctor(
            provider="claude",
            analyzer_executable="claude",
            keychain_service="service",
            keychain_account="account",
            password_provider=provider,
            auth=auth,
            gateway=gateway,
            plan_gateway=plan_gateway,
            transport=transport,
            runner=self._ok_runner,
            emit=lines.append,
        )

        self.assertEqual(exit_code, 1)
        report = "\n".join(lines)
        self.assertIn("[ERRORE ] Portachiavi", report)
        self.assertIn("[SALTATO] Login worker", report)
        self.assertIn("[SALTATO] RPC kal_tracker", report)
        self.assertIn("[SALTATO] RPC piano settimanale", report)
        self.assertIn("[SALTATO] Bucket kal-tracker-meal-photos", report)

    def test_logged_out_cli_fails_overall_run(self) -> None:
        def runner(command, **kwargs):
            del kwargs
            return subprocess.CompletedProcess(command, 1, "", "")

        transport = ScriptedTransport(
            [
                HttpResponse(200, {}, b"{}"),
                _TOKEN_RESPONSE,
                HttpStatusError(400, "P0002"),
                HttpStatusError(400, "P0002"),
                _bucket_response(),
            ]
        )
        auth = _auth(transport)
        gateway = SupabaseMealGateway(auth=auth, transport=transport)
        plan_gateway = SupabasePlanGateway(auth=auth, transport=transport)
        lines = []

        exit_code = doctor.run_doctor(
            provider="claude",
            analyzer_executable="claude",
            keychain_service="service",
            keychain_account="account",
            password_provider=lambda: "password",
            auth=auth,
            gateway=gateway,
            plan_gateway=plan_gateway,
            transport=transport,
            runner=runner,
            emit=lines.append,
        )

        self.assertEqual(exit_code, 1)
        self.assertIn("[ERRORE ] CLI claude", "\n".join(lines))


class CredentialSelectionTest(unittest.TestCase):
    _ENVIRONMENT_KEYS = (
        "KAL_MEAL_WORKER_KEYCHAIN_SERVICE",
        "KAL_MEAL_WORKER_KEYCHAIN_ACCOUNT",
        "KAL_MEAL_WORKER_EMAIL",
        "KAL_MEAL_ANALYZER_PROVIDER",
    )

    def setUp(self) -> None:
        self._saved = {}
        for key in self._ENVIRONMENT_KEYS:
            self._saved[key] = os.environ.pop(key, None)

    def tearDown(self) -> None:
        for key, value in self._saved.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value

    @staticmethod
    def _parse(*extra: str):
        return service_cli.build_parser().parse_args(["doctor", *extra])

    def test_account_defaults_to_worker_email(self) -> None:
        arguments = self._parse("--worker-email", "worker@example.test")

        self.assertEqual(
            service_cli.resolve_keychain_account(arguments),
            "worker@example.test",
        )

    def test_explicit_account_wins_over_email(self) -> None:
        arguments = self._parse(
            "--worker-email",
            "worker@example.test",
            "--keychain-account",
            "altro-account",
        )

        self.assertEqual(
            service_cli.resolve_keychain_account(arguments),
            "altro-account",
        )

    def test_environment_account_wins_over_email(self) -> None:
        os.environ["KAL_MEAL_WORKER_KEYCHAIN_ACCOUNT"] = "account-da-env"

        arguments = self._parse("--worker-email", "worker@example.test")

        self.assertEqual(
            service_cli.resolve_keychain_account(arguments),
            "account-da-env",
        )

    def test_default_keychain_service_matches_keychain_reader(self) -> None:
        arguments = self._parse()

        self.assertEqual(
            arguments.keychain_service,
            "com.kaltracker.meal-worker.supabase",
        )

    def test_environment_keychain_service_is_honored(self) -> None:
        os.environ["KAL_MEAL_WORKER_KEYCHAIN_SERVICE"] = "servizio-di-test"

        arguments = self._parse()

        self.assertEqual(arguments.keychain_service, "servizio-di-test")

    def test_doctor_shares_provider_and_executables_with_serve(self) -> None:
        arguments = self._parse()

        self.assertEqual(arguments.provider, "claude")
        self.assertEqual(
            service_cli.resolve_analyzer_executable(arguments),
            arguments.claude_executable,
        )

    def test_unknown_provider_executable_is_rejected(self) -> None:
        arguments = self._parse()
        arguments.provider = "gpt"

        with self.assertRaises(ValueError):
            service_cli.resolve_analyzer_executable(arguments)


if __name__ == "__main__":
    unittest.main()
