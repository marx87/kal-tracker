from __future__ import annotations

import argparse
import logging
import os
import signal
import sys
import threading

from .claude_analyzer import ClaudeAnalyzer
from .codex_analyzer import CodexAnalyzer
from .keychain import MacOSKeychainPassword
from .supabase_gateway import (
    SupabaseAuth,
    SupabaseConfigurationError,
    SupabaseMealGateway,
)
from .transport import UrllibTransport
from .worker import CycleOutcome, MealWorker, RetryPolicy


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="kal-meal-worker",
        description=(
            "Worker privato Supabase -> CLI AI (Claude o Codex) "
            "per le foto dei pasti."
        ),
    )
    subcommands = parser.add_subparsers(dest="command", required=True)
    serve = subcommands.add_parser("serve", help="Avvia il poll loop a job singolo")
    serve.add_argument(
        "--supabase-url",
        default=os.environ.get("KAL_SUPABASE_URL"),
    )
    serve.add_argument(
        "--publishable-key",
        default=os.environ.get("KAL_SUPABASE_PUBLISHABLE_KEY"),
    )
    serve.add_argument(
        "--worker-email",
        default=os.environ.get("KAL_MEAL_WORKER_EMAIL"),
    )
    serve.add_argument(
        "--keychain-service",
        default=os.environ.get(
            "KAL_MEAL_WORKER_KEYCHAIN_SERVICE",
            "com.kaltracker.meal-worker.supabase",
        ),
    )
    serve.add_argument(
        "--keychain-account",
        default=os.environ.get("KAL_MEAL_WORKER_KEYCHAIN_ACCOUNT"),
    )
    serve.add_argument(
        "--provider",
        choices=("claude", "codex"),
        default=os.environ.get("KAL_MEAL_ANALYZER_PROVIDER", "claude"),
    )
    serve.add_argument(
        "--claude-executable",
        default=os.environ.get("KAL_CLAUDE_EXECUTABLE", "claude"),
    )
    serve.add_argument(
        "--codex-executable",
        default=os.environ.get("KAL_CODEX_EXECUTABLE", "codex"),
    )
    serve.add_argument("--poll-seconds", type=float, default=5)
    serve.add_argument("--lease-seconds", type=int, default=180)
    serve.add_argument("--heartbeat-seconds", type=float)
    serve.add_argument("--request-timeout", type=float, default=30)
    serve.add_argument("--claude-timeout", type=int, default=120)
    serve.add_argument("--codex-timeout", type=int, default=120)
    serve.add_argument("--operation-attempts", type=int, default=3)
    serve.add_argument("--once", action="store_true")
    serve.add_argument(
        "--log-level",
        choices=("DEBUG", "INFO", "WARNING", "ERROR"),
        default="INFO",
    )
    return parser


def create_analyzer(arguments: argparse.Namespace) -> ClaudeAnalyzer | CodexAnalyzer:
    provider = (arguments.provider or "").strip().lower()
    if provider == "claude":
        return ClaudeAnalyzer(
            executable=(arguments.claude_executable,),
            timeout_seconds=arguments.claude_timeout,
        )
    if provider == "codex":
        return CodexAnalyzer(
            executable=(arguments.codex_executable,),
            timeout_seconds=arguments.codex_timeout,
        )
    raise ValueError(f"Provider analisi non supportato: {arguments.provider}")


def _required(parser: argparse.ArgumentParser, value: str | None, name: str) -> str:
    if value is None or not value.strip():
        parser.error(
            f"{name} mancante: passarlo come opzione o variabile KAL_* documentata"
        )
    return value.strip()


def _install_signal_handlers(stop: threading.Event) -> None:
    def request_stop(signum: int, frame: object) -> None:
        del signum, frame
        stop.set()

    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    arguments = parser.parse_args(argv)
    if arguments.command != "serve":
        parser.error("Comando non supportato")

    logging.basicConfig(
        level=getattr(logging, arguments.log_level),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )

    base_url = _required(parser, arguments.supabase_url, "URL Supabase")
    publishable_key = _required(
        parser, arguments.publishable_key, "publishable key Supabase"
    )
    worker_email = _required(parser, arguments.worker_email, "email worker")
    keychain_account = arguments.keychain_account or worker_email

    try:
        transport = UrllibTransport()
        password = MacOSKeychainPassword(
            service=arguments.keychain_service,
            account=keychain_account,
        )
        auth = SupabaseAuth(
            base_url=base_url,
            publishable_key=publishable_key,
            email=worker_email,
            password_provider=password,
            transport=transport,
            request_timeout=arguments.request_timeout,
        )
        gateway = SupabaseMealGateway(
            auth=auth,
            transport=transport,
            request_timeout=arguments.request_timeout,
        )
        analyzer = create_analyzer(arguments)
        worker = MealWorker(
            gateway=gateway,
            analyzer=analyzer,
            lease_seconds=arguments.lease_seconds,
            heartbeat_interval_seconds=arguments.heartbeat_seconds,
            poll_interval_seconds=arguments.poll_seconds,
            retry_policy=RetryPolicy(
                maximum_attempts=arguments.operation_attempts,
            ),
        )
    except (SupabaseConfigurationError, ValueError) as error:
        print(f"Configurazione worker non valida: {error}", file=sys.stderr)
        return 2

    if arguments.once:
        try:
            outcome = worker.run_once()
        except Exception:
            logging.getLogger("kal_meal_worker").error(
                "Esecuzione singola non riuscita"
            )
            return 1
        logging.getLogger("kal_meal_worker").info(
            "Esecuzione singola terminata: %s", outcome.value
        )
        return 1 if outcome is CycleOutcome.FAILED else 0

    stop = threading.Event()
    _install_signal_handlers(stop)
    worker.serve(stop_event=stop)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
