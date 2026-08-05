from __future__ import annotations

import base64
import json
import re
import threading
import time
from collections.abc import Callable, Mapping
from dataclasses import dataclass
from datetime import datetime
from typing import Any
from urllib.parse import quote, urlsplit
from uuid import UUID

from .coach_contract import CoachNarrativeResult
from .contract import AnalysisResult
from .plan_contract import WeeklyPlanResult
from .transport import (
    HttpResponse,
    HttpStatusError,
    HttpTransport,
    TransportError,
)


_PHOTO_BUCKET = "kal-tracker-meal-photos"
_MAX_PHOTO_BYTES = 10 * 1024 * 1024
_MAX_JSON_BYTES = 1024 * 1024
_MIME_TYPES = {"image/jpeg", "image/png", "image/webp"}
_MEAL_TYPES = {"breakfast", "lunch", "dinner", "snack", "other"}
_SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")


class SupabaseConfigurationError(ValueError):
    """La configurazione locale non rispetta il profilo least-privilege."""


class SupabaseProtocolError(RuntimeError):
    """Supabase ha restituito un payload diverso dal contratto atteso."""


@dataclass(frozen=True)
class AuthSession:
    access_token: str
    refresh_token: str | None
    expires_at: float


@dataclass(frozen=True)
class ClaimedJob:
    job_id: str
    owner_id: str
    profile_id: str
    storage_bucket: str
    storage_object: str
    image_sha256: str
    image_size_bytes: int
    image_mime_type: str
    requested_meal_type: str | None
    user_note: str | None
    attempt_count: int
    row_version: int
    lease_expires_at: str

    @classmethod
    def from_json(cls, value: object) -> ClaimedJob | None:
        if not isinstance(value, dict):
            raise SupabaseProtocolError("Risposta claim non valida")
        if value == {"claimed": False}:
            return None

        expected = {
            "claimed",
            "job_id",
            "owner_id",
            "profile_id",
            "storage_bucket",
            "storage_object",
            "image_sha256",
            "image_size_bytes",
            "image_mime_type",
            "requested_meal_type",
            "user_note",
            "attempt_count",
            "row_version",
            "lease_expires_at",
        }
        if set(value) != expected or value.get("claimed") is not True:
            raise SupabaseProtocolError("Campi claim mancanti o inattesi")

        job_id = _uuid_string(value["job_id"], "job_id")
        owner_id = _uuid_string(value["owner_id"], "owner_id")
        profile_id = _uuid_string(value["profile_id"], "profile_id")
        bucket = _required_string(value["storage_bucket"], "storage_bucket", 80)
        if bucket != _PHOTO_BUCKET:
            raise SupabaseProtocolError("Bucket foto inatteso")

        storage_object = _required_string(
            value["storage_object"], "storage_object", 1024
        )
        _validate_storage_object(storage_object, owner_id, job_id)

        image_sha256 = _required_string(value["image_sha256"], "image_sha256", 64)
        if not _SHA256_PATTERN.fullmatch(image_sha256):
            raise SupabaseProtocolError("Hash foto non valido")

        image_size = _integer(value["image_size_bytes"], "image_size_bytes")
        if not 1 <= image_size <= _MAX_PHOTO_BYTES:
            raise SupabaseProtocolError("Dimensione foto non valida")

        image_mime = _required_string(
            value["image_mime_type"], "image_mime_type", 40
        )
        if image_mime not in _MIME_TYPES:
            raise SupabaseProtocolError("MIME foto non valido")

        meal_type = value["requested_meal_type"]
        if meal_type is not None and meal_type not in _MEAL_TYPES:
            raise SupabaseProtocolError("Tipo pasto non valido")
        note = value["user_note"]
        if note is not None and (not isinstance(note, str) or len(note) > 500):
            raise SupabaseProtocolError("Nota pasto non valida")

        attempt_count = _integer(value["attempt_count"], "attempt_count")
        row_version = _integer(value["row_version"], "row_version")
        if not 1 <= attempt_count <= 10 or row_version <= 0:
            raise SupabaseProtocolError("Versione o tentativo claim non valido")

        lease = _lease_timestamp(value["lease_expires_at"])

        return cls(
            job_id=job_id,
            owner_id=owner_id,
            profile_id=profile_id,
            storage_bucket=bucket,
            storage_object=storage_object,
            image_sha256=image_sha256,
            image_size_bytes=image_size,
            image_mime_type=image_mime,
            requested_meal_type=meal_type,
            user_note=note,
            attempt_count=attempt_count,
            row_version=row_version,
            lease_expires_at=lease,
        )


def _request_job_fields(
    value: object, *, request_label: str
) -> dict[str, object] | None:
    """Campi del claim delle code che portano la richiesta dentro il job.

    Piano settimanale e coach hanno la stessa identica risposta di claim: otto
    chiavi, nessuna delle quali riguarda le foto. Le due code restano classi
    diverse (i loro job non sono intercambiabili e i messaggi d'errore devono
    dire di quale coda si parla), ma la lettura difensiva e' una sola: due
    copie della stessa validazione divergerebbero al primo campo aggiunto.
    """
    if not isinstance(value, dict):
        raise SupabaseProtocolError("Risposta claim non valida")
    if value == {"claimed": False}:
        return None

    expected = {
        "claimed",
        "job_id",
        "owner_id",
        "profile_id",
        "request",
        "attempt_count",
        "row_version",
        "lease_expires_at",
    }
    if set(value) != expected or value.get("claimed") is not True:
        raise SupabaseProtocolError("Campi claim mancanti o inattesi")

    request = value["request"]
    if not isinstance(request, dict):
        raise SupabaseProtocolError(f"Richiesta {request_label} non valida")

    attempt_count = _integer(value["attempt_count"], "attempt_count")
    row_version = _integer(value["row_version"], "row_version")
    if not 1 <= attempt_count <= 10 or row_version <= 0:
        raise SupabaseProtocolError("Versione o tentativo claim non valido")

    return {
        "job_id": _uuid_string(value["job_id"], "job_id"),
        "owner_id": _uuid_string(value["owner_id"], "owner_id"),
        "profile_id": _uuid_string(value["profile_id"], "profile_id"),
        "request": request,
        "attempt_count": attempt_count,
        "row_version": row_version,
        "lease_expires_at": _lease_timestamp(value["lease_expires_at"]),
    }


@dataclass(frozen=True)
class ClaimedPlanJob:
    """Job della coda del piano settimanale.

    Le chiavi ammesse sono 8 e nessuna riguarda le foto: la RPC del piano ha
    una risposta sua, proprio per non far crescere quella delle foto (un campo
    in piu' li' romperebbe subito ``ClaimedJob.from_json``).
    """

    job_id: str
    owner_id: str
    profile_id: str
    request: Mapping[str, object]
    attempt_count: int
    row_version: int
    lease_expires_at: str

    @classmethod
    def from_json(cls, value: object) -> "ClaimedPlanJob | None":
        fields = _request_job_fields(value, request_label="del piano")
        if fields is None:
            return None
        return cls(**fields)  # type: ignore[arg-type]


@dataclass(frozen=True)
class ClaimedCoachJob:
    """Job della coda del coach.

    Stessa forma del piano, contenuto opposto: qui ``request`` non e' un
    catalogo da cui scegliere ma il rapporto gia' calcolato dall'app, e dal
    Mac tornera' solo testo.
    """

    job_id: str
    owner_id: str
    profile_id: str
    request: Mapping[str, object]
    attempt_count: int
    row_version: int
    lease_expires_at: str

    @classmethod
    def from_json(cls, value: object) -> "ClaimedCoachJob | None":
        fields = _request_job_fields(value, request_label="del coach")
        if fields is None:
            return None
        return cls(**fields)  # type: ignore[arg-type]


@dataclass(frozen=True)
class DownloadedPhoto:
    body: bytes
    content_type: str | None


def _required_string(value: object, field: str, maximum: int) -> str:
    if not isinstance(value, str) or not value or len(value) > maximum:
        raise SupabaseProtocolError(f"{field} non valido")
    return value


def _uuid_string(value: object, field: str) -> str:
    raw = _required_string(value, field, 36)
    try:
        return str(UUID(raw))
    except ValueError as error:
        raise SupabaseProtocolError(f"{field} non e un UUID") from error


def _integer(value: object, field: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise SupabaseProtocolError(f"{field} non e intero")
    return value


def _lease_timestamp(value: object) -> str:
    lease = _required_string(value, "lease_expires_at", 64)
    try:
        parsed = datetime.fromisoformat(lease.replace("Z", "+00:00"))
    except ValueError as error:
        raise SupabaseProtocolError("Scadenza lease non valida") from error
    if parsed.tzinfo is None:
        raise SupabaseProtocolError("Scadenza lease senza fuso orario")
    return lease


def _validated_error_code(error_code: str) -> str:
    if (
        not error_code
        or len(error_code) > 80
        or not all(
            character.isalnum() or character == "_" for character in error_code
        )
    ):
        raise ValueError("Codice errore worker non valido")
    return error_code


def _validate_storage_object(storage_object: str, owner_id: str, job_id: str) -> None:
    contains_control = any(ord(character) < 32 for character in storage_object)
    if "\\" in storage_object or contains_control:
        raise SupabaseProtocolError("Percorso Storage non valido")
    components = storage_object.split("/")
    if (
        len(components) < 3
        or components[0] != owner_id
        or components[1] != job_id
        or any(component in {"", ".", ".."} for component in components)
    ):
        raise SupabaseProtocolError("Percorso Storage fuori dal job")


def _json_body(value: Mapping[str, object]) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")


def _validated_base_url(value: str) -> str:
    candidate = value.strip().rstrip("/")
    parsed = urlsplit(candidate)
    local_host = parsed.hostname in {"localhost", "127.0.0.1", "::1"}
    if (
        not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
        or parsed.path not in {"", "/"}
        or (parsed.scheme != "https" and not (parsed.scheme == "http" and local_host))
    ):
        raise SupabaseConfigurationError(
            "URL Supabase non valida: usare HTTPS (HTTP solo localhost)"
        )
    return candidate


def _jwt_role(key: str) -> str | None:
    parts = key.split(".")
    if len(parts) != 3:
        return None
    try:
        raw = parts[1] + "=" * (-len(parts[1]) % 4)
        payload = json.loads(base64.urlsafe_b64decode(raw).decode("utf-8"))
    except (ValueError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise SupabaseConfigurationError("JWT Supabase non valido") from error
    if not isinstance(payload, dict):
        raise SupabaseConfigurationError("JWT Supabase non valido")
    role = payload.get("role")
    return role if isinstance(role, str) else None


def validate_publishable_key(value: str) -> str:
    key = value.strip()
    if not key:
        raise SupabaseConfigurationError("Publishable key Supabase mancante")
    if key.startswith("sb_secret_"):
        raise SupabaseConfigurationError("Una secret/service_role key non e ammessa")
    role = _jwt_role(key)
    if role in {"service_role", "supabase_admin"}:
        raise SupabaseConfigurationError("Una service_role key non e ammessa")
    return key


class SupabaseAuth:
    def __init__(
        self,
        *,
        base_url: str,
        publishable_key: str,
        email: str,
        password_provider: Callable[[], str],
        transport: HttpTransport,
        request_timeout: float = 30,
        clock: Callable[[], float] = time.time,
    ) -> None:
        if not email or "\x00" in email or len(email) > 320:
            raise SupabaseConfigurationError("Email worker non valida")
        self._base_url = _validated_base_url(base_url)
        self._publishable_key = validate_publishable_key(publishable_key)
        self._email = email
        self._password_provider = password_provider
        self._transport = transport
        self._request_timeout = request_timeout
        self._clock = clock
        self._session: AuthSession | None = None
        self._lock = threading.RLock()

    @property
    def publishable_key(self) -> str:
        return self._publishable_key

    @property
    def base_url(self) -> str:
        return self._base_url

    def access_token(self, *, force_refresh: bool = False) -> str:
        with self._lock:
            now = self._clock()
            if (
                not force_refresh
                and self._session is not None
                and self._session.expires_at - 30 > now
            ):
                return self._session.access_token

            if self._session is not None and self._session.refresh_token:
                try:
                    self._session = self._refresh(self._session.refresh_token)
                    return self._session.access_token
                except HttpStatusError as error:
                    if error.status not in {400, 401}:
                        raise

            password = self._password_provider()
            self._session = self._sign_in(password)
            return self._session.access_token

    def _sign_in(self, password: str) -> AuthSession:
        return self._auth_request(
            "password",
            {"email": self._email, "password": password},
        )

    def _refresh(self, refresh_token: str) -> AuthSession:
        return self._auth_request(
            "refresh_token",
            {"refresh_token": refresh_token},
        )

    def _auth_request(
        self, grant_type: str, payload: Mapping[str, object]
    ) -> AuthSession:
        response = self._transport.request(
            "POST",
            f"{self._base_url}/auth/v1/token?grant_type={grant_type}",
            headers={
                "apikey": self._publishable_key,
                "Content-Type": "application/json",
                "Accept": "application/json",
                "X-Client-Info": "kal-meal-worker/0.2",
            },
            body=_json_body(payload),
            timeout=self._request_timeout,
            max_response_bytes=256 * 1024,
        )
        return self._parse_session(response.json())

    def _parse_session(self, value: object) -> AuthSession:
        if not isinstance(value, dict):
            raise SupabaseProtocolError("Sessione Auth non valida")
        access = value.get("access_token")
        refresh = value.get("refresh_token")
        if not isinstance(access, str) or not access or len(access) > 32768:
            raise SupabaseProtocolError("Access token Auth non valido")
        if refresh is not None and (
            not isinstance(refresh, str) or not refresh or len(refresh) > 32768
        ):
            raise SupabaseProtocolError("Refresh token Auth non valido")

        expires_at = value.get("expires_at")
        if isinstance(expires_at, bool) or not isinstance(expires_at, (int, float)):
            expires_in = value.get("expires_in")
            if isinstance(expires_in, bool) or not isinstance(expires_in, (int, float)):
                raise SupabaseProtocolError("Scadenza Auth non valida")
            expires_at = self._clock() + float(expires_in)
        if float(expires_at) <= self._clock():
            raise SupabaseProtocolError("Sessione Auth gia scaduta")
        return AuthSession(access, refresh, float(expires_at))


class _SupabaseRpcClient:
    """Chiamate RPC autenticate come utente worker, e nient'altro.

    Le due code (foto e piano) condividono soltanto questo: sessione, header
    di schema e gestione del 401. Ogni coda ha poi le sue RPC, con i loro
    campi attesi e i loro stati ammessi.
    """

    def __init__(
        self,
        *,
        auth: SupabaseAuth,
        transport: HttpTransport,
        request_timeout: float = 30,
    ) -> None:
        self._auth = auth
        self._transport = transport
        self._request_timeout = request_timeout

    def _rpc(
        self, function_name: str, payload: Mapping[str, object]
    ) -> Mapping[str, object]:
        response = self._authorized_request(
            "POST",
            f"{self._auth.base_url}/rest/v1/rpc/{quote(function_name, safe='')}",
            headers={
                "Accept": "application/json",
                "Accept-Profile": "kal_tracker",
                "Content-Profile": "kal_tracker",
                "Content-Type": "application/json",
            },
            body=_json_body(payload),
            max_response_bytes=_MAX_JSON_BYTES,
        )
        value: Any = response.json()
        if not isinstance(value, dict):
            raise SupabaseProtocolError("Risposta RPC non valida")
        return value

    def _authorized_request(
        self,
        method: str,
        url: str,
        *,
        headers: Mapping[str, str],
        body: bytes | None,
        max_response_bytes: int,
    ) -> HttpResponse:
        token = self._auth.access_token()
        try:
            return self._request_with_token(
                method,
                url,
                headers=headers,
                body=body,
                token=token,
                max_response_bytes=max_response_bytes,
            )
        except HttpStatusError as error:
            if error.status != 401:
                raise
        token = self._auth.access_token(force_refresh=True)
        return self._request_with_token(
            method,
            url,
            headers=headers,
            body=body,
            token=token,
            max_response_bytes=max_response_bytes,
        )

    def _request_with_token(
        self,
        method: str,
        url: str,
        *,
        headers: Mapping[str, str],
        body: bytes | None,
        token: str,
        max_response_bytes: int,
    ) -> HttpResponse:
        authorized_headers = {
            **headers,
            "apikey": self._auth.publishable_key,
            "Authorization": f"Bearer {token}",
            "X-Client-Info": "kal-meal-worker/0.2",
        }
        return self._transport.request(
            method,
            url,
            headers=authorized_headers,
            body=body,
            timeout=self._request_timeout,
            max_response_bytes=max_response_bytes,
        )


class SupabaseMealGateway(_SupabaseRpcClient):
    """Accesso esclusivo alle RPC worker e all'oggetto Storage assegnato."""

    def claim(self, mutation_id: str, lease_seconds: int) -> ClaimedJob | None:
        value = self._rpc(
            "claim_meal_analysis_job",
            {
                "p_mutation_id": _uuid_string(mutation_id, "mutation_id"),
                "p_lease_seconds": lease_seconds,
            },
        )
        return ClaimedJob.from_json(value)

    def heartbeat(
        self, job_id: str, mutation_id: str, lease_seconds: int
    ) -> Mapping[str, object]:
        normalized_job_id = _uuid_string(job_id, "job_id")
        value = self._rpc(
            "heartbeat_meal_analysis_job",
            {
                "p_job_id": normalized_job_id,
                "p_mutation_id": _uuid_string(mutation_id, "mutation_id"),
                "p_lease_seconds": lease_seconds,
            },
        )
        _validate_rpc_result(
            value,
            expected_fields={"job_id", "status", "row_version", "lease_expires_at"},
            job_id=normalized_job_id,
            allowed_statuses={"processing"},
        )
        return value

    def complete(
        self, job_id: str, mutation_id: str, result: AnalysisResult
    ) -> Mapping[str, object]:
        normalized_job_id = _uuid_string(job_id, "job_id")
        value = self._rpc(
            "complete_meal_analysis_job",
            {
                "p_job_id": normalized_job_id,
                "p_mutation_id": _uuid_string(mutation_id, "mutation_id"),
                "p_analysis_result": result.to_json(),
            },
        )
        _validate_rpc_result(
            value,
            expected_fields={"job_id", "status", "row_version", "completed_at"},
            job_id=normalized_job_id,
            allowed_statuses={"needs_review"},
        )
        return value

    def fail(
        self,
        job_id: str,
        mutation_id: str,
        error_code: str,
        retryable: bool,
    ) -> Mapping[str, object]:
        normalized_job_id = _uuid_string(job_id, "job_id")
        value = self._rpc(
            "fail_meal_analysis_job",
            {
                "p_job_id": normalized_job_id,
                "p_mutation_id": _uuid_string(mutation_id, "mutation_id"),
                "p_error_code": _validated_error_code(error_code),
                "p_retryable": retryable,
            },
        )
        _validate_rpc_result(
            value,
            expected_fields={
                "job_id",
                "status",
                "retryable",
                "attempt_count",
                "row_version",
                "completed_at",
            },
            job_id=normalized_job_id,
            allowed_statuses={"queued", "failed"},
        )
        if not isinstance(value["retryable"], bool):
            raise SupabaseProtocolError("Flag retry RPC non valido")
        return value

    def download_photo(self, job: ClaimedJob) -> DownloadedPhoto:
        encoded_path = "/".join(
            quote(component, safe="") for component in job.storage_object.split("/")
        )
        encoded_bucket = quote(job.storage_bucket, safe="")
        response = self._authorized_request(
            "GET",
            f"{self._auth.base_url}/storage/v1/object/authenticated/"
            f"{encoded_bucket}/{encoded_path}",
            headers={"Accept": job.image_mime_type},
            body=None,
            max_response_bytes=_MAX_PHOTO_BYTES,
        )
        content_type = response.headers.get("content-type")
        if content_type:
            content_type = content_type.split(";", 1)[0].strip().lower()
        return DownloadedPhoto(response.body, content_type)


class SupabasePlanGateway(_SupabaseRpcClient):
    """Le sole quattro RPC della coda del piano settimanale.

    Nessuno Storage e nessun accesso diretto a ``weekly_plan_jobs``: come per
    le foto, il worker non e' il proprietario e le policy lo escludono.
    """

    def claim(self, mutation_id: str, lease_seconds: int) -> ClaimedPlanJob | None:
        value = self._rpc(
            "claim_weekly_plan_job",
            {
                "p_mutation_id": _uuid_string(mutation_id, "mutation_id"),
                "p_lease_seconds": lease_seconds,
            },
        )
        return ClaimedPlanJob.from_json(value)

    def heartbeat(
        self, job_id: str, mutation_id: str, lease_seconds: int
    ) -> Mapping[str, object]:
        normalized_job_id = _uuid_string(job_id, "job_id")
        value = self._rpc(
            "heartbeat_weekly_plan_job",
            {
                "p_job_id": normalized_job_id,
                "p_mutation_id": _uuid_string(mutation_id, "mutation_id"),
                "p_lease_seconds": lease_seconds,
            },
        )
        _validate_rpc_result(
            value,
            expected_fields={"job_id", "status", "row_version", "lease_expires_at"},
            job_id=normalized_job_id,
            allowed_statuses={"processing"},
        )
        return value

    def complete(
        self, job_id: str, mutation_id: str, result: WeeklyPlanResult
    ) -> Mapping[str, object]:
        normalized_job_id = _uuid_string(job_id, "job_id")
        value = self._rpc(
            "complete_weekly_plan_job",
            {
                "p_job_id": normalized_job_id,
                "p_mutation_id": _uuid_string(mutation_id, "mutation_id"),
                # Forma canonica: solo scelte, mai numeri nutrizionali.
                "p_result": result.to_json(),
            },
        )
        _validate_rpc_result(
            value,
            expected_fields={"job_id", "status", "row_version", "completed_at"},
            job_id=normalized_job_id,
            allowed_statuses={"needs_review"},
        )
        return value

    def fail(
        self,
        job_id: str,
        mutation_id: str,
        error_code: str,
        retryable: bool,
    ) -> Mapping[str, object]:
        normalized_job_id = _uuid_string(job_id, "job_id")
        value = self._rpc(
            "fail_weekly_plan_job",
            {
                "p_job_id": normalized_job_id,
                "p_mutation_id": _uuid_string(mutation_id, "mutation_id"),
                "p_error_code": _validated_error_code(error_code),
                "p_retryable": retryable,
            },
        )
        _validate_rpc_result(
            value,
            expected_fields={
                "job_id",
                "status",
                "retryable",
                "attempt_count",
                "row_version",
                "completed_at",
            },
            job_id=normalized_job_id,
            allowed_statuses={"queued", "failed"},
        )
        if not isinstance(value["retryable"], bool):
            raise SupabaseProtocolError("Flag retry RPC non valido")
        return value


class SupabaseCoachGateway(_SupabaseRpcClient):
    """Le quattro RPC della coda del coach, piu' la sonda del binding.

    Come per il piano: nessuno Storage, nessun accesso diretto a
    ``coach_jobs``, nessuna ``service_role``. L'unica cosa che questo gateway
    puo' scrivere e' un oggetto di sole stringhe, e la sua forma canonica la
    decide ``CoachNarrativeResult.to_json()``.
    """

    def binding_active(self) -> bool:
        """Dice se questo worker ha un binding 'coaching' attivo.

        E' l'unica chiamata di questo gateway che non tocca la coda: serve al
        doctor, che prima provava il binding con un claim vero e cosi' facendo
        consumava un tentativo del job di Marco (e al decimo lo chiudeva).
        """
        value = self._rpc("coaching_binding_active", {})
        active = value.get("active")
        if set(value) != {"active"} or not isinstance(active, bool):
            raise SupabaseProtocolError("Risposta binding non valida")
        return active

    def claim(self, mutation_id: str, lease_seconds: int) -> ClaimedCoachJob | None:
        value = self._rpc(
            "claim_coach_job",
            {
                "p_mutation_id": _uuid_string(mutation_id, "mutation_id"),
                "p_lease_seconds": lease_seconds,
            },
        )
        return ClaimedCoachJob.from_json(value)

    def heartbeat(
        self, job_id: str, mutation_id: str, lease_seconds: int
    ) -> Mapping[str, object]:
        normalized_job_id = _uuid_string(job_id, "job_id")
        value = self._rpc(
            "heartbeat_coach_job",
            {
                "p_job_id": normalized_job_id,
                "p_mutation_id": _uuid_string(mutation_id, "mutation_id"),
                "p_lease_seconds": lease_seconds,
            },
        )
        _validate_rpc_result(
            value,
            expected_fields={"job_id", "status", "row_version", "lease_expires_at"},
            job_id=normalized_job_id,
            allowed_statuses={"processing"},
        )
        return value

    def complete(
        self, job_id: str, mutation_id: str, result: CoachNarrativeResult
    ) -> Mapping[str, object]:
        normalized_job_id = _uuid_string(job_id, "job_id")
        value = self._rpc(
            "complete_coach_job",
            {
                "p_job_id": normalized_job_id,
                "p_mutation_id": _uuid_string(mutation_id, "mutation_id"),
                # `to_json()` verifica da se' che sia solo testo: se non lo
                # fosse solleverebbe qui, prima della richiesta, invece di
                # farsi rifiutare dalla CHECK di Postgres.
                "p_result": result.to_json(),
            },
        )
        _validate_rpc_result(
            value,
            expected_fields={"job_id", "status", "row_version", "completed_at"},
            job_id=normalized_job_id,
            allowed_statuses={"needs_review"},
        )
        return value

    def fail(
        self,
        job_id: str,
        mutation_id: str,
        error_code: str,
        retryable: bool,
    ) -> Mapping[str, object]:
        normalized_job_id = _uuid_string(job_id, "job_id")
        value = self._rpc(
            "fail_coach_job",
            {
                "p_job_id": normalized_job_id,
                "p_mutation_id": _uuid_string(mutation_id, "mutation_id"),
                "p_error_code": _validated_error_code(error_code),
                "p_retryable": retryable,
            },
        )
        _validate_rpc_result(
            value,
            expected_fields={
                "job_id",
                "status",
                "retryable",
                "attempt_count",
                "row_version",
                "completed_at",
            },
            job_id=normalized_job_id,
            allowed_statuses={"queued", "failed"},
        )
        if not isinstance(value["retryable"], bool):
            raise SupabaseProtocolError("Flag retry RPC non valido")
        return value


def safe_remote_error_code(error: BaseException) -> str:
    if isinstance(error, HttpStatusError):
        return f"SUPABASE_HTTP_{error.status}"
    if isinstance(error, TransportError):
        return "SUPABASE_TRANSPORT"
    if isinstance(error, SupabaseProtocolError):
        return "SUPABASE_PROTOCOL"
    return "SUPABASE_UNKNOWN"


def _validate_rpc_result(
    value: Mapping[str, object],
    *,
    expected_fields: set[str],
    job_id: str,
    allowed_statuses: set[str],
) -> None:
    if set(value) != expected_fields:
        raise SupabaseProtocolError("Campi risposta RPC mancanti o inattesi")
    if value.get("job_id") != job_id or value.get("status") not in allowed_statuses:
        raise SupabaseProtocolError("Stato risposta RPC non valido")
    if _integer(value.get("row_version"), "row_version") <= 0:
        raise SupabaseProtocolError("Versione risposta RPC non valida")
