"""Lettura difensiva di quello che stampa una CLI AI in `--output-format json`.

La CLI puo' restituire tre forme, tutte legittime e viste dal vivo:

1. il payload strutturato puro (riconoscibile dalla chiave attesa);
2. il wrapper della CLI con ``structured_output`` gia' decodificato;
3. il wrapper con ``result`` come stringa, a volte dentro una recinzione
   markdown.

Qui si normalizzano le tre forme e nient'altro: la validazione del contenuto
resta ai contratti (``contract.py`` per le foto, ``plan_contract.py`` per il
piano), che sono gli unici a sapere cosa e' ammesso.
"""

from __future__ import annotations

import json
from typing import Any


class CliOutputError(ValueError):
    """L'output della CLI non e' riconoscibile come risultato strutturato."""


class CliReportedError(RuntimeError):
    """La CLI ha segnalato un errore nel proprio wrapper (``is_error``)."""


def strip_markdown_fence(text: str) -> str:
    stripped = text.strip()
    if stripped.startswith("```") and stripped.endswith("```"):
        first_newline = stripped.find("\n")
        if first_newline != -1:
            return stripped[first_newline + 1 : -3].strip()
    return stripped


def extract_cli_payload(document: Any, *, payload_key: str) -> Any:
    """Estrae il payload del modello; ``payload_key`` riconosce quello puro."""
    if not isinstance(document, dict):
        raise CliOutputError("Il risultato deve essere un oggetto JSON")
    if payload_key in document:
        return document
    if not ("result" in document or "structured_output" in document):
        raise CliOutputError("Risultato della CLI non riconosciuto")
    if document.get("is_error") is True:
        raise CliReportedError("La CLI ha segnalato un errore")
    structured = document.get("structured_output")
    if isinstance(structured, dict):
        return structured
    result = document.get("result")
    if isinstance(result, dict):
        return result
    if isinstance(result, str):
        return json.loads(strip_markdown_fence(result))
    raise CliOutputError("Wrapper della CLI senza risultato utilizzabile")
