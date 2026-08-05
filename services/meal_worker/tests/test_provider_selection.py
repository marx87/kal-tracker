import os
import unittest

from kal_meal_worker import service_cli
from kal_meal_worker.claude_analyzer import ClaudeAnalyzer
from kal_meal_worker.coach_analyzer import ClaudeCoach
from kal_meal_worker.coach_worker import CoachWorker
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

    def test_default_scope_serves_all_three_queues(self) -> None:
        self.assertEqual(self._parse().scope, "all")

        worker = self._worker()

        self.assertIsInstance(worker, AlternatingWorker)
        # Tre code a turno in un processo solo: una sola lavorazione alla
        # volta e una sola password nel Portachiavi.
        self.assertEqual(len(worker._workers), 3)

    def test_single_scopes_build_a_single_worker(self) -> None:
        self.assertIsInstance(
            self._worker("--scope", "meal_analysis"), MealWorker
        )
        self.assertIsInstance(
            self._worker("--scope", "meal_planning"), PlanWorker
        )
        self.assertIsInstance(self._worker("--scope", "coaching"), CoachWorker)

    def test_the_coach_scope_is_named_like_the_database_binding(self) -> None:
        # Non "coach": il valore deve combaciare con `automation_bindings.scope`,
        # altrimenti l'errore si presenta come un 42501 incomprensibile.
        self.assertEqual(service_cli.COACHING_SCOPE, "coaching")

    def test_commentator_is_claude_only(self) -> None:
        self.assertIsInstance(
            service_cli.create_commentator(self._parse()), ClaudeCoach
        )

        with self.assertRaisesRegex(ValueError, "solo con il provider claude"):
            service_cli.create_commentator(self._parse("--provider", "codex"))

    def test_environment_variable_switches_scope(self) -> None:
        os.environ["KAL_MEAL_WORKER_SCOPE"] = "meal_analysis"

        self.assertEqual(self._parse().scope, "meal_analysis")

    def test_planner_is_claude_only(self) -> None:
        self.assertIsInstance(
            service_cli.create_planner(self._parse()), ClaudePlanner
        )

        with self.assertRaisesRegex(ValueError, "solo con il provider claude"):
            service_cli.create_planner(self._parse("--provider", "codex"))

    def test_codex_cannot_serve_the_plan_or_coach_queues(self) -> None:
        with self.assertRaises(ValueError):
            self._worker("--provider", "codex")
        with self.assertRaises(ValueError):
            self._worker("--provider", "codex", "--scope", "coaching")

        self.assertIsInstance(
            self._worker("--provider", "codex", "--scope", "meal_analysis"),
            MealWorker,
        )

    def test_coach_timeout_may_exceed_the_lease(self) -> None:
        # Come per il piano: l'heartbeat rinnova il lease mentre il modello
        # scrive, quindi il tetto non e' strozzato da un singolo lease.
        self.assertIsInstance(
            self._worker(
                "--scope", "coaching", "--lease-seconds", "60", "--coach-timeout", "300"
            ),
            CoachWorker,
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
