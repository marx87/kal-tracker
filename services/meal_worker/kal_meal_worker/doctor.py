from __future__ import annotations

import os
import subprocess
import uuid
from collections.abc import Callable
from dataclasses import dataclass
from enum import Enum

from .keychain import KeychainError
from .supabase_gateway import (
    SupabaseAuth,
    SupabaseMealGateway,
    SupabasePlanGateway,
    SupabaseProtocolError,
)
from .transport import (
    HttpResponse,
    HttpStatusError,
    HttpTransport,
    TransportError,
)


_PHOTO_BUCKET = "kal-tracker-meal-photos"
_EXPECTED_BUCKET_SIZE_LIMIT = 10 * 1024 * 1024
_EXPECTED_BUCKET_MIME_TYPES = ("image/jpeg", "image/png", "image/webp")
_MAX_DIAGNOSTIC_RESPONSE_BYTES = 64 * 1024

# Stessa filosofia degli analyzer: la CLI di verifica non riceve API key,
# token o variabili KAL_*.
_ALLOWED_ENVIRONMENT_KEYS = {
    "CLAUDE_CONFIG_DIR",
    "CODEX_CA_CERTIFICATE",
    "CODEX_HOME",
    "HOME",
    "LANG",
    "LC_ALL",
    "LC_CTYPE",
    "LOGNAME",
    "PATH",
    "SHELL",
    "SSL_CERT_DIR",
    "SSL_CERT_FILE",
    "TERM",
    "TMPDIR",
    "USER",
}

_AUTH_STATUS_ARGUMENTS = {
    "claude": ("auth", "status"),
    "codex": ("login", "status"),
}


Runner = Callable[..., subprocess.CompletedProcess[str]]


class CheckStatus(Enum):
    OK = "OK"
    FAILED = "ERRORE"
    SKIPPED = "SALTATO"


@dataclass(frozen=True)
class CheckResult:
    name: str
    status: CheckStatus
    detail: str

    @property
    def passed(self) -> bool:
        return self.status is CheckStatus.OK


def check_keychain(
    password_provider: Callable[[], str],
    *,
    service: str,
    account: str,
) -> CheckResult:
    """Verifica che la password del worker sia leggibile dal Portachiavi."""
    name = "Portachiavi"
    location = f"servizio {service}, account {account}"
    try:
        password_provider()
    except KeychainError as error:
        return CheckResult(name, CheckStatus.FAILED, f"{error} ({location})")
    return CheckResult(
        name,
        CheckStatus.OK,
        f"password del worker presente ({location})",
    )


def check_analyzer_cli(
    *,
    provider: str,
    executable: str,
    runner: Runner = subprocess.run,
    timeout_seconds: float = 30,
) -> CheckResult:
    """Verifica presenza e login della CLI AI, senza inoltrare segreti."""
    name = f"CLI {provider}"
    status_arguments = _AUTH_STATUS_ARGUMENTS.get(provider)
    if status_arguments is None:
        return CheckResult(
            name,
            CheckStatus.FAILED,
            f"provider non supportato: {provider}",
        )

    environment = {
        key: value
        for key, value in os.environ.items()
        if key in _ALLOWED_ENVIRONMENT_KEYS
    }
    environment["NO_COLOR"] = "1"

    command = [executable, *status_arguments]
    try:
        completed = runner(
            command,
            env=environment,
            capture_output=True,
            text=True,
            timeout=timeout_seconds,
            check=False,
        )
    except FileNotFoundError:
        return CheckResult(
            name,
            CheckStatus.FAILED,
            f"eseguibile non trovato: {executable}",
        )
    except subprocess.TimeoutExpired:
        return CheckResult(
            name,
            CheckStatus.FAILED,
            f"nessuna risposta entro {int(timeout_seconds)} secondi",
        )
    except OSError:
        return CheckResult(
            name,
            CheckStatus.FAILED,
            f"eseguibile non avviabile: {executable}",
        )

    if completed.returncode != 0:
        return CheckResult(
            name,
            CheckStatus.FAILED,
            "eseguibile presente ma senza login attivo: autenticare con "
            f"`{executable} {' '.join(status_arguments)}`",
        )
    return CheckResult(name, CheckStatus.OK, "eseguibile presente e login attivo")


def check_supabase_health(
    *,
    transport: HttpTransport,
    base_url: str,
    publishable_key: str,
    request_timeout: float = 30,
) -> CheckResult:
    """Verifica la raggiungibilita del progetto Supabase senza credenziali."""
    name = "Supabase"
    try:
        response = transport.request(
            "GET",
            f"{base_url}/auth/v1/health",
            headers={"apikey": publishable_key, "Accept": "application/json"},
            body=None,
            timeout=request_timeout,
            max_response_bytes=_MAX_DIAGNOSTIC_RESPONSE_BYTES,
        )
    except HttpStatusError as error:
        return CheckResult(
            name,
            CheckStatus.FAILED,
            f"l'endpoint Auth ha risposto HTTP {error.status}",
        )
    except TransportError:
        return CheckResult(
            name,
            CheckStatus.FAILED,
            "progetto non raggiungibile (rete assente o URL errato)",
        )
    if response.status != 200:
        return CheckResult(
            name,
            CheckStatus.FAILED,
            f"risposta inattesa HTTP {response.status} da /auth/v1/health",
        )
    return CheckResult(name, CheckStatus.OK, "endpoint /auth/v1/health raggiungibile")


def check_worker_login(auth: SupabaseAuth) -> CheckResult:
    """Verifica il login dell'utente worker con la password del Portachiavi."""
    name = "Login worker"
    try:
        auth.access_token()
    except KeychainError as error:
        return CheckResult(name, CheckStatus.FAILED, str(error))
    except HttpStatusError as error:
        if error.status in {400, 401}:
            return CheckResult(
                name,
                CheckStatus.FAILED,
                "credenziali rifiutate da Supabase Auth: la password nel "
                "Portachiavi non corrisponde all'utente worker",
            )
        return CheckResult(
            name,
            CheckStatus.FAILED,
            f"Supabase Auth ha risposto HTTP {error.status}",
        )
    except TransportError:
        return CheckResult(name, CheckStatus.FAILED, "Supabase Auth non raggiungibile")
    except SupabaseProtocolError as error:
        return CheckResult(name, CheckStatus.FAILED, str(error))
    return CheckResult(name, CheckStatus.OK, "sessione Auth del worker ottenuta")


def check_worker_rpc(gateway: SupabaseMealGateway) -> CheckResult:
    """Verifica schema esposto e RPC worker con un heartbeat su job inesistente.

    Il job di prova e un UUID casuale: la RPC lo rifiuta (P0002) senza toccare
    dati ne ledger. Il binding attivo si dimostra davvero solo con un claim
    reale (`serve --once`), che qui evitiamo per non rubare job in coda.
    """
    return _probe_heartbeat_rpc(
        gateway,
        name="RPC kal_tracker",
        missing_hint=(
            "schema kal_tracker non esposto o RPC heartbeat assente: "
            "verificare Exposed schemas e la migrazione 003"
        ),
    )


def check_plan_rpc(gateway: SupabasePlanGateway) -> CheckResult:
    """Come `check_worker_rpc`, ma sulle RPC della coda del piano.

    Anche qui il binding non viene provato: `heartbeat_weekly_plan_job` scarta
    il job inesistente (P0002) prima ancora di guardare `automation_bindings`,
    quindi un'installazione con il solo scope foto NON diventa rossa. La prova
    vera del binding `meal_planning` resta `serve --scope meal_planning --once`.
    """
    return _probe_heartbeat_rpc(
        gateway,
        name="RPC piano settimanale",
        missing_hint=(
            "RPC del piano assenti: applicare la migrazione "
            "202608040005_weekly_plan_jobs.sql e ricaricare lo schema"
        ),
    )


def _probe_heartbeat_rpc(
    gateway: SupabaseMealGateway | SupabasePlanGateway,
    *,
    name: str,
    missing_hint: str,
) -> CheckResult:
    try:
        gateway.heartbeat(str(uuid.uuid4()), str(uuid.uuid4()), 60)
    except HttpStatusError as error:
        if error.error_code == "P0002":
            return CheckResult(
                name,
                CheckStatus.OK,
                "RPC worker esposte: il job di prova inesistente e stato "
                "rifiutato come atteso",
            )
        if error.error_code == "42501" or error.status == 403:
            return CheckResult(
                name,
                CheckStatus.FAILED,
                "richiesta rifiutata (42501): token worker non valido o "
                "permessi RPC mancanti",
            )
        if error.status == 404:
            return CheckResult(name, CheckStatus.FAILED, missing_hint)
        return CheckResult(
            name,
            CheckStatus.FAILED,
            f"risposta inattesa HTTP {error.status} dalle RPC",
        )
    except TransportError:
        return CheckResult(name, CheckStatus.FAILED, "PostgREST non raggiungibile")
    except SupabaseProtocolError:
        return CheckResult(name, CheckStatus.FAILED, "risposta RPC fuori contratto")
    return CheckResult(
        name,
        CheckStatus.FAILED,
        "il job di prova casuale risulta esistente: risposta inattesa",
    )


def check_photo_bucket(
    *,
    transport: HttpTransport,
    auth: SupabaseAuth,
    request_timeout: float = 30,
) -> CheckResult:
    """Verifica lo schema del bucket foto, con fallback su oggetto di prova."""
    name = f"Bucket {_PHOTO_BUCKET}"
    try:
        response = _authorized_get(
            transport=transport,
            auth=auth,
            url=f"{auth.base_url}/storage/v1/bucket/{_PHOTO_BUCKET}",
            request_timeout=request_timeout,
        )
    except HttpStatusError as error:
        if error.status in {400, 403, 404, 406}:
            # I metadati del bucket sono riservati per il worker (RLS su
            # storage.buckets): si ripiega su una richiesta oggetto che deve
            # essere negata dalle policy.
            return _probe_bucket_object(
                transport=transport,
                auth=auth,
                request_timeout=request_timeout,
            )
        return CheckResult(
            name,
            CheckStatus.FAILED,
            f"Storage ha risposto HTTP {error.status} sui metadati bucket",
        )
    except TransportError:
        return CheckResult(name, CheckStatus.FAILED, "Storage non raggiungibile")
    return _validate_bucket_metadata(response)


def run_doctor(
    *,
    provider: str,
    analyzer_executable: str,
    keychain_service: str,
    keychain_account: str,
    password_provider: Callable[[], str],
    auth: SupabaseAuth,
    gateway: SupabaseMealGateway,
    plan_gateway: SupabasePlanGateway,
    transport: HttpTransport,
    request_timeout: float = 30,
    cli_timeout_seconds: float = 30,
    runner: Runner = subprocess.run,
    emit: Callable[[str], None] = print,
) -> int:
    """Esegue tutti i controlli e stampa un esito leggibile per riga."""
    results: list[CheckResult] = []

    keychain_result = check_keychain(
        password_provider,
        service=keychain_service,
        account=keychain_account,
    )
    results.append(keychain_result)

    results.append(
        check_analyzer_cli(
            provider=provider,
            executable=analyzer_executable,
            runner=runner,
            timeout_seconds=cli_timeout_seconds,
        )
    )

    health_result = check_supabase_health(
        transport=transport,
        base_url=auth.base_url,
        publishable_key=auth.publishable_key,
        request_timeout=request_timeout,
    )
    results.append(health_result)

    if keychain_result.passed and health_result.passed:
        login_result = check_worker_login(auth)
    else:
        login_result = CheckResult(
            "Login worker",
            CheckStatus.SKIPPED,
            "richiede Portachiavi leggibile e Supabase raggiungibile",
        )
    results.append(login_result)

    if login_result.passed:
        results.append(check_worker_rpc(gateway))
        results.append(check_plan_rpc(plan_gateway))
        results.append(
            check_photo_bucket(
                transport=transport,
                auth=auth,
                request_timeout=request_timeout,
            )
        )
    else:
        reason = "richiede il login del worker"
        results.append(CheckResult("RPC kal_tracker", CheckStatus.SKIPPED, reason))
        results.append(
            CheckResult("RPC piano settimanale", CheckStatus.SKIPPED, reason)
        )
        results.append(
            CheckResult(f"Bucket {_PHOTO_BUCKET}", CheckStatus.SKIPPED, reason)
        )

    emit(f"Diagnostica meal worker (provider {provider})")
    for result in results:
        emit(f"[{result.status.value:<7}] {result.name}: {result.detail}")
    passed = sum(1 for result in results if result.passed)
    emit(f"Esito: {passed}/{len(results)} controlli superati")
    if passed != len(results):
        emit(
            "Suggerimento: la procedura completa e in "
            "docs/MEAL_WORKER_PROTOCOL.md; la prova finale del binding e "
            "`kal-meal-worker serve --once`"
        )
        return 1
    return 0


def _authorized_get(
    *,
    transport: HttpTransport,
    auth: SupabaseAuth,
    url: str,
    request_timeout: float,
) -> HttpResponse:
    token = auth.access_token()
    return transport.request(
        "GET",
        url,
        headers={
            "apikey": auth.publishable_key,
            "Authorization": f"Bearer {token}",
            "Accept": "application/json",
        },
        body=None,
        timeout=request_timeout,
        max_response_bytes=_MAX_DIAGNOSTIC_RESPONSE_BYTES,
    )


def _validate_bucket_metadata(response: HttpResponse) -> CheckResult:
    name = f"Bucket {_PHOTO_BUCKET}"
    try:
        value = response.json()
    except TransportError:
        return CheckResult(
            name,
            CheckStatus.FAILED,
            "metadati bucket non decodificabili",
        )
    if not isinstance(value, dict):
        return CheckResult(name, CheckStatus.FAILED, "metadati bucket non validi")

    problems: list[str] = []
    if value.get("public") is not False:
        problems.append("il bucket deve restare privato (public=false)")
    if value.get("file_size_limit") != _EXPECTED_BUCKET_SIZE_LIMIT:
        problems.append(
            f"limite dimensione diverso da {_EXPECTED_BUCKET_SIZE_LIMIT}"
        )
    mime_types = value.get("allowed_mime_types")
    if not isinstance(mime_types, list) or sorted(
        entry for entry in mime_types if isinstance(entry, str)
    ) != sorted(_EXPECTED_BUCKET_MIME_TYPES):
        problems.append("MIME ammessi diversi da JPEG/PNG/WebP")
    if problems:
        return CheckResult(name, CheckStatus.FAILED, "; ".join(problems))
    return CheckResult(
        name,
        CheckStatus.OK,
        "bucket privato con limite dimensione e MIME attesi",
    )


def _probe_bucket_object(
    *,
    transport: HttpTransport,
    auth: SupabaseAuth,
    request_timeout: float,
) -> CheckResult:
    name = f"Bucket {_PHOTO_BUCKET}"
    probe_path = f"{uuid.uuid4()}/{uuid.uuid4()}/doctor-probe.jpg"
    try:
        _authorized_get(
            transport=transport,
            auth=auth,
            url=(
                f"{auth.base_url}/storage/v1/object/authenticated/"
                f"{_PHOTO_BUCKET}/{probe_path}"
            ),
            request_timeout=request_timeout,
        )
    except HttpStatusError as error:
        if error.status in {400, 403, 404}:
            return CheckResult(
                name,
                CheckStatus.OK,
                "Storage attivo sul bucket: metadati riservati al worker e "
                "oggetto di prova negato come atteso",
            )
        return CheckResult(
            name,
            CheckStatus.FAILED,
            f"Storage ha risposto HTTP {error.status} sull'oggetto di prova",
        )
    except TransportError:
        return CheckResult(name, CheckStatus.FAILED, "Storage non raggiungibile")
    return CheckResult(
        name,
        CheckStatus.FAILED,
        "l'oggetto di prova risulta leggibile: policy Storage da verificare",
    )
