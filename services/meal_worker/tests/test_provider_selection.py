import os
import unittest

from kal_meal_worker import service_cli
from kal_meal_worker.claude_analyzer import ClaudeAnalyzer
from kal_meal_worker.codex_analyzer import CodexAnalyzer


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


if __name__ == "__main__":
    unittest.main()
