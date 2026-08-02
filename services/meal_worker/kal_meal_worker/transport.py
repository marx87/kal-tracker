from __future__ import annotations

import json
import socket
import urllib.error
import urllib.request
from collections.abc import Mapping
from dataclasses import dataclass
from typing import Protocol


class TransportError(RuntimeError):
    """Errore di trasporto che non contiene payload o credenziali."""


class NetworkError(TransportError):
    """La richiesta non ha ricevuto una risposta HTTP utilizzabile."""


class ResponseTooLargeError(TransportError):
    """Il server ha superato il limite locale della risposta."""


class HttpStatusError(TransportError):
    def __init__(self, status: int, error_code: str | None = None) -> None:
        self.status = status
        self.error_code = error_code
        detail = f"HTTP {status}"
        if error_code:
            detail = f"{detail} ({error_code})"
        super().__init__(detail)

    @property
    def retryable(self) -> bool:
        return self.status in {408, 425, 429} or 500 <= self.status <= 599


@dataclass(frozen=True)
class HttpResponse:
    status: int
    headers: Mapping[str, str]
    body: bytes

    def json(self) -> object:
        try:
            return json.loads(self.body.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise TransportError("Risposta JSON non valida") from error


class HttpTransport(Protocol):
    def request(
        self,
        method: str,
        url: str,
        *,
        headers: Mapping[str, str],
        body: bytes | None,
        timeout: float,
        max_response_bytes: int,
    ) -> HttpResponse: ...


class _NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args: object, **kwargs: object) -> None:
        return None


def _read_limited(response: object, limit: int) -> bytes:
    if limit <= 0:
        raise ValueError("Il limite della risposta deve essere positivo")
    reader = getattr(response, "read")
    chunks: list[bytes] = []
    total = 0
    while True:
        chunk = reader(min(64 * 1024, limit + 1 - total))
        if not chunk:
            return b"".join(chunks)
        if not isinstance(chunk, bytes):
            raise TransportError("Risposta HTTP binaria non valida")
        chunks.append(chunk)
        total += len(chunk)
        if total > limit:
            raise ResponseTooLargeError("Risposta HTTP troppo grande")


def _safe_error_code(body: bytes) -> str | None:
    try:
        value = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return None
    if not isinstance(value, dict):
        return None
    for key in ("error_code", "code", "error"):
        candidate = value.get(key)
        if (
            isinstance(candidate, str)
            and 0 < len(candidate) <= 80
            and all(
                character.isalnum() or character in "._-" for character in candidate
            )
        ):
            return candidate
    return None


class UrllibTransport:
    """Trasporto standard library; i redirect sono rifiutati per non inoltrare token."""

    def __init__(self, opener: urllib.request.OpenerDirector | None = None) -> None:
        self._opener = opener or urllib.request.build_opener(_NoRedirectHandler())

    def request(
        self,
        method: str,
        url: str,
        *,
        headers: Mapping[str, str],
        body: bytes | None,
        timeout: float,
        max_response_bytes: int,
    ) -> HttpResponse:
        request = urllib.request.Request(
            url,
            data=body,
            headers=dict(headers),
            method=method,
        )
        try:
            with self._opener.open(request, timeout=timeout) as response:
                payload = _read_limited(response, max_response_bytes)
                normalized_headers = {
                    key.lower(): value for key, value in response.headers.items()
                }
                return HttpResponse(response.status, normalized_headers, payload)
        except urllib.error.HTTPError as error:
            try:
                payload = _read_limited(error, min(max_response_bytes, 64 * 1024))
            except ResponseTooLargeError:
                payload = b""
            raise HttpStatusError(error.code, _safe_error_code(payload)) from None
        except (urllib.error.URLError, TimeoutError, socket.timeout, OSError) as error:
            raise NetworkError("Richiesta HTTP non riuscita") from error


def is_retryable_transport_error(error: BaseException) -> bool:
    return isinstance(error, NetworkError) or (
        isinstance(error, HttpStatusError) and error.retryable
    )
