from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

from .analyzer_errors import AnalyzerError
from .claude_analyzer import ClaudeAnalyzer
from .codex_analyzer import CodexAnalyzer


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Analizza una foto pasto con la CLI AI di Marco.",
    )
    parser.add_argument("image", type=Path, help="Foto JPEG, PNG o WebP")
    parser.add_argument(
        "--provider",
        choices=("claude", "codex"),
        default=os.environ.get("KAL_MEAL_ANALYZER_PROVIDER", "claude"),
    )
    parser.add_argument(
        "--output",
        type=Path,
        help="File JSON di destinazione; altrimenti usa stdout",
    )
    parser.add_argument("--timeout", type=int, default=120)
    return parser


def main(argv: list[str] | None = None) -> int:
    arguments = build_parser().parse_args(argv)
    if arguments.provider == "codex":
        analyzer: ClaudeAnalyzer | CodexAnalyzer = CodexAnalyzer(
            timeout_seconds=arguments.timeout
        )
    else:
        analyzer = ClaudeAnalyzer(timeout_seconds=arguments.timeout)
    try:
        result = analyzer.analyze(arguments.image)
    except AnalyzerError as error:
        print(str(error), file=sys.stderr)
        return 2

    payload = json.dumps(
        result.to_json(), ensure_ascii=False, indent=2, sort_keys=True
    )
    if arguments.output is None:
        print(payload)
    else:
        destination = arguments.output.expanduser().resolve()
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(f"{payload}\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
