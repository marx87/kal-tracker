from __future__ import annotations

import argparse
import logging
import os
import signal
import sys
import threading

from .claude_analyzer import ClaudeAnalyzer
from .codex_analyzer import CodexAnalyzer
from .doctor import run_doctor
from .keychain import MacOSKeychainPassword
from .plan_analyzer import ClaudePlanner
from .plan_worker import PlanWorker
from .supabase_gateway import (
    SupabaseAuth,
    SupabaseConfigurationError,
    SupabaseMealGateway,
    SupabasePlanGateway,
)
from .transport import HttpTransport, UrllibTransport
from .worker import AlternatingWorker, CycleOutcome, MealWorker, RetryPolicy


MEAL_ANALYSIS_SCOPE = "meal_analysis"
MEAL_PLANNING_SCOPE = "meal_planning"
ALL_SCOPES = "all"


def _add_connection_arguments(subparser: argparse.ArgumentParser) -> None:
    subparser.add_argument(
        "--supabase-url",
        default=os.environ.get("KAL_SUPABASE_URL"),
    )
    subparser.add_argument(
        "--publishable-key",
        default=os.environ.get("KAL_SUPABASE_PUBLISHABLE_KEY"),
    )
    subparser.add_argument(
        "--worker-email",
        default=os.environ.get("KAL_MEAL_WORKER_EMAIL"),
    )
    subparser.add_argument(
        "--keychain-service",
        default=os.environ.get(
            "KAL_MEAL_WORKER_KEYCHAIN_SERVICE",
            "com.kaltracker.meal-worker.supabase",
        ),
    )
    subparser.add_argument(
        "--keychain-account",
        default=os.environ.get("KAL_MEAL_WORKER_KEYCHAIN_ACCOUNT"),
    )
    subparser.add_argument(
        "--provider",
        choices=("claude", "codex"),
        default=os.environ.get("KAL_MEAL_ANALYZER_PROVIDER", "claude"),
    )
    subparser.add_argument(
        "--claude-executable",
        default=os.environ.get("KAL_CLAUDE_EXECUTABLE", "claude"),
    )
    subparser.add_argument(
        "--codex-executable",
        default=os.environ.get("KAL_CODEX_EXECUTABLE", "codex"),
    )
    subparser.add_argument("--request-timeout", type=float, default=30)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="kal-meal-worker",
        description=(
            "Worker privato Supabase -> CLI AI (Claude o Codex) per le foto "
            "dei pasti e per il piano settimanale."
        ),
    )
    subcommands = parser.add_subparsers(dest="command", required=True)

    serve = subcommands.add_parser("serve", help="Avvia il poll loop a job singolo")
    _add_connection_arguments(serve)
    serve.add_argument(
        "--scope",
        choices=(MEAL_ANALYSIS_SCOPE, MEAL_PLANNING_SCOPE, ALL_SCOPES),
        default=os.environ.get("KAL_MEAL_WORKER_SCOPE", ALL_SCOPES),
        help=(
            "Code servite: foto, piano settimanale o entrambe a turno "
            "(un solo processo, una sola lavorazione alla volta)"
        ),
    )
    serve.add_argument("--poll-seconds", type=float, default=5)
    serve.add_argument("--lease-seconds", type=int, default=180)
    serve.add_argument("--heartbeat-seconds", type=float)
    serve.add_argument("--claude-timeout", type=int, default=120)
    serve.add_argument("--codex-timeout", type=int, default=120)
    serve.add_argument(
        "--plan-timeout",
        type=int,
        default=170,
        help=(
            "Timeout della CLI per un piano: piu' generoso dell'analisi foto "
            "e mai oltre --lease-seconds"
        ),
    )
    serve.add_argument("--operation-attempts", type=int, default=3)
    serve.add_argument("--once", action="store_true")
    serve.add_argument(
        "--log-level",
        choices=("DEBUG", "INFO", "WARNING", "ERROR"),
        default="INFO",
    )

    doctor = subcommands.add_parser(
        "doctor",
        help=(
            "Verifica Portachiavi, CLI AI, raggiungibilita Supabase, RPC "
            "delle due code e bucket foto"
        ),
    )
    _add_connection_arguments(doctor)
    doctor.add_argument("--cli-timeout", type=float, default=30)

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


def create_planner(arguments: argparse.Namespace) -> ClaudePlanner:
    """Il piano lo genera solo Claude: e' la decisione della fase 10."""
    provider = (arguments.provider or "").strip().lower()
    if provider != "claude":
        raise ValueError(
            "Il piano settimanale si genera solo con il provider claude: "
            f"con {arguments.provider} usa --scope {MEAL_ANALYSIS_SCOPE}"
        )
    return ClaudePlanner(
        executable=(arguments.claude_executable,),
        timeout_seconds=arguments.plan_timeout,
    )


def resolve_keychain_account(arguments: argparse.Namespace) -> str:
    """L'account Portachiavi esplicito vince, altrimenti l'email del worker."""
    account = (arguments.keychain_account or "").strip()
    if account:
        return account
    return (arguments.worker_email or "").strip()


def resolve_analyzer_executable(arguments: argparse.Namespace) -> str:
    provider = (arguments.provider or "").strip().lower()
    if provider == "claude":
        return arguments.claude_executable
    if provider == "codex":
        return arguments.codex_executable
    raise ValueError(f"Provider analisi non supportato: {arguments.provider}")


def _required(parser: argparse.ArgumentParser, value: str | None, name: str) -> str:
    if value is None or not value.strip():
        parser.error(
            f"{name} mancante: passarlo come opzione o variabile KAL_* documentata"
        )
    return value.strip()


def build_worker(
    arguments: argparse.Namespace,
    *,
    auth: SupabaseAuth,
    transport: HttpTransport,
) -> MealWorker | PlanWorker | AlternatingWorker:
    """Un solo processo serve una o entrambe le code, secondo --scope."""
    scope = (arguments.scope or "").strip().lower()
    if scope not in {MEAL_ANALYSIS_SCOPE, MEAL_PLANNING_SCOPE, ALL_SCOPES}:
        raise ValueError(f"Ambito non supportato: {arguments.scope}")

    retry_policy = RetryPolicy(maximum_attempts=arguments.operation_attempts)
    workers: list[MealWorker | PlanWorker] = []

    if scope in {MEAL_ANALYSIS_SCOPE, ALL_SCOPES}:
        workers.append(
            MealWorker(
                gateway=SupabaseMealGateway(
                    auth=auth,
                    transport=transport,
                    request_timeout=arguments.request_timeout,
                ),
                analyzer=create_analyzer(arguments),
                lease_seconds=arguments.lease_seconds,
                heartbeat_interval_seconds=arguments.heartbeat_seconds,
                poll_interval_seconds=arguments.poll_seconds,
                retry_policy=retry_policy,
            )
        )

    if scope in {MEAL_PLANNING_SCOPE, ALL_SCOPES}:
        if arguments.plan_timeout > arguments.lease_seconds:
            raise ValueError(
                "--plan-timeout deve stare entro --lease-seconds "
                f"({arguments.plan_timeout} > {arguments.lease_seconds})"
            )
        workers.append(
            PlanWorker(
                gateway=SupabasePlanGateway(
                    auth=auth,
                    transport=transport,
                    request_timeout=arguments.request_timeout,
                ),
                planner=create_planner(arguments),
                lease_seconds=arguments.lease_seconds,
                heartbeat_interval_seconds=arguments.heartbeat_seconds,
                poll_interval_seconds=arguments.poll_seconds,
                retry_policy=retry_policy,
            )
        )

    if len(workers) == 1:
        return workers[0]
    return AlternatingWorker(
        workers=workers,
        poll_interval_seconds=arguments.poll_seconds,
        retry_policy=retry_policy,
    )


def _install_signal_handlers(stop: threading.Event) -> None:
    def request_stop(signum: int, frame: object) -> None:
        del signum, frame
        stop.set()

    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)


def _run_serve(
    parser: argparse.ArgumentParser, arguments: argparse.Namespace
) -> int:
    logging.basicConfig(
        level=getattr(logging, arguments.log_level),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )

    base_url = _required(parser, arguments.supabase_url, "URL Supabase")
    publishable_key = _required(
        parser, arguments.publishable_key, "publishable key Supabase"
    )
    worker_email = _required(parser, arguments.worker_email, "email worker")
    keychain_account = resolve_keychain_account(arguments)

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
        worker = build_worker(arguments, auth=auth, transport=transport)
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


def _run_doctor(
    parser: argparse.ArgumentParser, arguments: argparse.Namespace
) -> int:
    base_url = _required(parser, arguments.supabase_url, "URL Supabase")
    publishable_key = _required(
        parser, arguments.publishable_key, "publishable key Supabase"
    )
    worker_email = _required(parser, arguments.worker_email, "email worker")
    keychain_account = resolve_keychain_account(arguments)

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
        plan_gateway = SupabasePlanGateway(
            auth=auth,
            transport=transport,
            request_timeout=arguments.request_timeout,
        )
        analyzer_executable = resolve_analyzer_executable(arguments)
    except (SupabaseConfigurationError, ValueError) as error:
        print(f"Configurazione worker non valida: {error}", file=sys.stderr)
        return 2

    return run_doctor(
        provider=(arguments.provider or "").strip().lower(),
        analyzer_executable=analyzer_executable,
        keychain_service=arguments.keychain_service,
        keychain_account=keychain_account,
        password_provider=password,
        auth=auth,
        gateway=gateway,
        plan_gateway=plan_gateway,
        transport=transport,
        request_timeout=arguments.request_timeout,
        cli_timeout_seconds=arguments.cli_timeout,
    )


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    arguments = parser.parse_args(argv)
    if arguments.command == "serve":
        return _run_serve(parser, arguments)
    if arguments.command == "doctor":
        return _run_doctor(parser, arguments)
    parser.error("Comando non supportato")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
