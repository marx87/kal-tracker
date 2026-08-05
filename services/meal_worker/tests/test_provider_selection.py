import os
import unittest

from kal_meal_worker import service_cli
from kal_meal_worker.claude_analyzer import ClaudeAnalyzer
from kal_meal_worker.codex_analyzer import CodexAnalyzer
from kal_meal_worker.plan_analyzer import ClaudePlanner
from kal_meal_worker.plan_worker import PlanWorker
from kal_meal_worker.supabase_gateway import SupabaseAuth
from kal_meal_worker.worker import AlternatingWorker, MealWorker


class OfflineTransport:
    """Costruire i gateway non deve fare nessuna richiesta."""

    def request(self, method, url, **kwargs):
        raise AssertionError(f"richiesta HTTP inattesa: {method} {url}")


class ProviderSelectionTest(unittest.TestCase):
    def setUp(self) -> None:
        self._old_provider = os.environ.pop("KAL_MEAL_ANALYZER_PROVIDER", None)

    def tearDown(self) -> None:
        if self._old_provider is None:
            os.environ.pop("KAL_MEAL_ANALYZER_PROVIDER", None)
        else:
            os.environ["KAL_MEAL_ANALYZER_PROVIDER"] = self._old_provider

    @staticmethod
    def _parse(*extra: str):
        return service_cli.build_parser().parse_args(["serve", *extra])

    def test_default_provider_is_claude(self) -> None:
        analyzer = service_cli.create_analyzer(self._parse())

        self.assertIsInstance(analyzer, ClaudeAnalyzer)

    def test_codex_stays_available_via_flag(self) -> None:
        analyzer = service_cli.create_analyzer(
            self._parse("--provider", "codex")
        )

        self.assertIsInstance(analyzer, CodexAnalyzer)

    def test_environment_variable_switches_provider(self) -> None:
        os.environ["KAL_MEAL_ANALYZER_PROVIDER"] = "codex"

        analyzer = service_cli.create_analyzer(self._parse())

        self.assertIsInstance(analyzer, CodexAnalyzer)

    def test_unknown_provider_is_rejected(self) -> None:
        arguments = self._parse()
        arguments.provider = "gpt"

        with self.assertRaises(ValueError):
            service_cli.create_analyzer(arguments)


class ScopeSelectionTest(unittest.TestCase):
    _ENVIRONMENT_KEYS = ("KAL_MEAL_ANALYZER_PROVIDER", "KAL_MEAL_WORKER_SCOPE")

    def setUp(self) -> None:
        self._saved = {key: os.environ.pop(key, None) for key in self._ENVIRONMENT_KEYS}

    def tearDown(self) -> None:
        for key, value in self._saved.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value

    @staticmethod
    def _parse(*extra: str):
        return service_cli.build_parser().parse_args(["serve", *extra])

    def _worker(self, *extra: str):
        arguments = self._parse(*extra)
        transport = OfflineTransport()
        auth = SupabaseAuth(
            base_url="https://project.supabase.co",
            publishable_key="sb_publishable_example",
            email="worker@example.test",
            password_provider=lambda: "password",
            transport=transport,
        )
        return service_cli.build_worker(arguments, auth=auth, transport=transport)

    def test_default_scope_serves_both_queues(self) -> None:
        self.assertEqual(self._parse().scope, "all")
        self.assertIsInstance(self._worker(), AlternatingWorker)

    def test_single_scopes_build_a_single_worker(self) -> None:
        self.assertIsInstance(
            self._worker("--scope", "meal_analysis"), MealWorker
        )
        self.assertIsInstance(
            self._worker("--scope", "meal_planning"), PlanWorker
        )

    def test_environment_variable_switches_scope(self) -> None:
        os.environ["KAL_MEAL_WORKER_SCOPE"] = "meal_analysis"

        self.assertEqual(self._parse().scope, "meal_analysis")

    def test_planner_is_claude_only(self) -> None:
        self.assertIsInstance(
            service_cli.create_planner(self._parse()), ClaudePlanner
        )

        with self.assertRaisesRegex(ValueError, "solo con il provider claude"):
            service_cli.create_planner(self._parse("--provider", "codex"))

    def test_codex_cannot_serve_the_plan_queue(self) -> None:
        with self.assertRaises(ValueError):
            self._worker("--provider", "codex")

        self.assertIsInstance(
            self._worker("--provider", "codex", "--scope", "meal_analysis"),
            MealWorker,
        )

    def test_plan_timeout_may_exceed_the_lease(self) -> None:
        # Durante la composizione l'heartbeat rinnova il lease ogni lease/3
        # secondi: un piano lungo non lo perde, quindi il tetto del timeout
        # non deve piu' essere strozzato dalla durata di un singolo lease.
        self.assertIsInstance(
            self._worker("--lease-seconds", "180", "--plan-timeout", "600"),
            AlternatingWorker,
        )

    def test_unknown_scope_is_rejected(self) -> None:
        arguments = self._parse()
        arguments.scope = "tutto"
        transport = OfflineTransport()
        auth = SupabaseAuth(
            base_url="https://project.supabase.co",
            publishable_key="sb_publishable_example",
            email="worker@example.test",
            password_provider=lambda: "password",
            transport=transport,
        )

        with self.assertRaises(ValueError):
            service_cli.build_worker(arguments, auth=auth, transport=transport)


if __name__ == "__main__":
    unittest.main()
