from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

from .analyzer_errors import AnalyzerError
from .claude_analyzer import ClaudeAnalyzer
from .coach_analyzer import COACH_MINIMUM_TIMEOUT_SECONDS, ClaudeCoach
from .coach_contract import CoachContractError, CoachRequest
from .codex_analyzer import CodexAnalyzer


# Il tetto di una foto e quello di un commento non sono la stessa cosa: la
# prima costa poche decine di secondi, il secondo si dimensiona sui temi del
# rapporto e il servizio gli concede fino a 300 s.
_PHOTO_DEFAULT_TIMEOUT = 120
_COACH_DEFAULT_TIMEOUT = 300


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Analizza una foto pasto, oppure scrive il commento del coach da "
            "un rapporto gia' calcolato, con la CLI AI di Marco."
        ),
    )
    # Facoltativo perche' con --coach-request non c'e' nessuna foto da leggere.
    parser.add_argument(
        "image", type=Path, nargs="?", help="Foto JPEG, PNG o WebP"
    )
    parser.add_argument(
        "--coach-request",
        type=Path,
        help=(
            "File JSON con la richiesta del coach (lo stesso `request` che "
            "l'app mette nel job): stampa il commento senza toccare Supabase"
        ),
    )
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
    parser.add_argument(
        "--timeout",
        type=int,
        help=(
            "Tetto in secondi: default 120 per una foto, 300 per "
            "--coach-request (lo stesso tetto del servizio, cosi' la prova a "
            "mano riproduce le condizioni vere)"
        ),
    )
    return parser


def _emit(payload: dict[str, object], destination: Path | None) -> None:
    text = json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True)
    if destination is None:
        print(text)
        return
    resolved = destination.expanduser().resolve()
    resolved.parent.mkdir(parents=True, exist_ok=True)
    resolved.write_text(f"{text}\n", encoding="utf-8")


def _run_coach(arguments: argparse.Namespace) -> int:
    """Scrive il commento di un rapporto letto da file.

    Serve a rileggere con i propri occhi cosa direbbe il Mac prima di far
    partire il servizio: stessa CLI effimera, stesso contratto, stessa
    ripulitura delle cifre del worker vero. Il provider e' obbligatoriamente
    Claude, come nel servizio.
    """
    if arguments.provider != "claude":
        print(
            "Il commento del coach si scrive solo con il provider claude",
            file=sys.stderr,
        )
        return 2

    source = arguments.coach_request.expanduser()
    try:
        document = json.loads(source.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        print(f"Rapporto non leggibile: {error}", file=sys.stderr)
        return 2

    try:
        request = CoachRequest.from_json(document)
    except CoachContractError as error:
        print(f"{error} ({error.error_code})", file=sys.stderr)
        return 2

    # Stesso tetto del servizio (`serve --coach-timeout`): un'anteprima che
    # scade prima del worker vero non direbbe quanto costa davvero scrivere un
    # commento, ed e' proprio per misurarlo che questo comando esiste.
    ceiling = _COACH_DEFAULT_TIMEOUT if arguments.timeout is None else arguments.timeout
    if ceiling < COACH_MINIMUM_TIMEOUT_SECONDS:
        print(
            f"--timeout per il coach deve essere almeno "
            f"{COACH_MINIMUM_TIMEOUT_SECONDS} secondi",
            file=sys.stderr,
        )
        return 2

    try:
        result = ClaudeCoach(timeout_seconds=ceiling).comment(request)
    except AnalyzerError as error:
        print(f"{error} ({error.error_code})", file=sys.stderr)
        return 2

    # Lo stesso payload che finirebbe in `complete_coach_job`, gia' verificato
    # come testo puro: cosi' quello che si legge qui e' esattamente quello che
    # riceverebbe il telefono.
    _emit(result.to_json(), arguments.output)
    if result.dropped:
        print(
            f"Capoversi scartati perche' contenevano cifre: {result.dropped}",
            file=sys.stderr,
        )
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    arguments = parser.parse_args(argv)

    if (arguments.image is None) == (arguments.coach_request is None):
        parser.error("indicare una foto oppure --coach-request, non entrambi")

    if arguments.coach_request is not None:
        return _run_coach(arguments)

    photo_timeout = (
        _PHOTO_DEFAULT_TIMEOUT if arguments.timeout is None else arguments.timeout
    )
    if arguments.provider == "codex":
        analyzer: ClaudeAnalyzer | CodexAnalyzer = CodexAnalyzer(
            timeout_seconds=photo_timeout
        )
    else:
        analyzer = ClaudeAnalyzer(timeout_seconds=photo_timeout)
    try:
        result = analyzer.analyze(arguments.image)
    except AnalyzerError as error:
        print(str(error), file=sys.stderr)
        return 2

    _emit(result.to_json(), arguments.output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
