#!/usr/bin/env python3
"""Dump integrale di Firestore per Gym Tracker, prima di spegnere Firebase.

Perche esiste
-------------
L'export dell'app (`gym-tracker-export-*.json`) NON contiene tutto: mancano le
prescrizioni per esercizio delle schede e gli `intervalSegments`, cioe i
blocchi a tempo dei circuiti HIIT. L'esportatore dell'app semplicemente non li
scrive. Questo script prende i documenti grezzi, senza passare dai modelli
dell'app, quindi porta via *qualunque* campo esista sul server, compresi
quelli che nessun modello Dart legge piu.

E l'ultima occasione utile: dopo lo spegnimento di Firebase (traguardo M5.8)
quei dati non esistono piu da nessuna parte.

Come ottenere le credenziali
----------------------------
Console Firebase -> progetto `gym-tracker-89afb` -> Impostazioni progetto ->
Account di servizio -> «Genera nuova chiave privata». Scarica il JSON e
tienilo FUORI dal repository (per esempio in ~/Documents/KalTracker-Signing/).

E una credenziale con pieni poteri sul progetto: non va committata, non va
inviata via email e conviene revocarla dalla stessa pagina quando il dump e
finito.

Uso
---
    python3 scripts/dump_gym_firestore.py \\
        --credenziali ~/Documents/KalTracker-Signing/gym-tracker-admin.json \\
        --destinazione ~/Documents/KalTracker-Signing/gym-firestore-dump.json

Opzioni utili:
    --uid UID        scarica un solo utente invece di tutti
    --progetto ID    se diverso da gym-tracker-89afb

Dipendenze: solo `cryptography` (gia presente) e la libreria standard.
"""

from __future__ import annotations

import argparse
import base64
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

PROGETTO_PREDEFINITO = "gym-tracker-89afb"
SCOPE = "https://www.googleapis.com/auth/datastore"
TOKEN_URL = "https://oauth2.googleapis.com/token"
FIRESTORE = "https://firestore.googleapis.com/v1"


# --------------------------------------------------------------------------
# Autenticazione
# --------------------------------------------------------------------------


def _b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def access_token(credenziali: Path) -> str:
    """Scambia la chiave della service account con un access token OAuth2."""
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import padding

    conto = json.loads(credenziali.read_text())
    for chiave in ("client_email", "private_key"):
        if chiave not in conto:
            raise SystemExit(
                f"{credenziali}: manca «{chiave}». "
                "Serve la chiave privata di un ACCOUNT DI SERVIZIO, non il "
                "google-services.json dell'app."
            )

    adesso = int(time.time())
    intestazione = {"alg": "RS256", "typ": "JWT"}
    corpo = {
        "iss": conto["client_email"],
        "scope": SCOPE,
        "aud": TOKEN_URL,
        "iat": adesso,
        "exp": adesso + 3600,
    }
    da_firmare = ".".join(
        _b64url(json.dumps(parte, separators=(",", ":")).encode())
        for parte in (intestazione, corpo)
    ).encode("ascii")

    chiave_privata = serialization.load_pem_private_key(
        conto["private_key"].encode(), password=None
    )
    firma = chiave_privata.sign(da_firmare, padding.PKCS1v15(), hashes.SHA256())
    asserzione = f"{da_firmare.decode('ascii')}.{_b64url(firma)}"

    richiesta = urllib.request.Request(
        TOKEN_URL,
        data=urllib.parse.urlencode(
            {
                "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
                "assertion": asserzione,
            }
        ).encode(),
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    with urllib.request.urlopen(richiesta, timeout=30) as risposta:
        return json.load(risposta)["access_token"]


# --------------------------------------------------------------------------
# Conversione dei valori Firestore
# --------------------------------------------------------------------------


def valore(campo: dict[str, Any]) -> Any:
    """Traduce un valore tipizzato di Firestore in JSON normale.

    Gli interi arrivano come stringhe e i timestamp come ISO-8601: si
    conservano cosi come sono, senza reinterpretarli, perche lo scopo del dump
    e la fedelta al server e non la comodita di chi legge.
    """
    if "nullValue" in campo:
        return None
    if "booleanValue" in campo:
        return campo["booleanValue"]
    if "integerValue" in campo:
        return int(campo["integerValue"])
    if "doubleValue" in campo:
        return campo["doubleValue"]
    if "stringValue" in campo:
        return campo["stringValue"]
    if "timestampValue" in campo:
        return campo["timestampValue"]
    if "bytesValue" in campo:
        return {"__bytes__": campo["bytesValue"]}
    if "referenceValue" in campo:
        return {"__ref__": campo["referenceValue"]}
    if "geoPointValue" in campo:
        return {"__geo__": campo["geoPointValue"]}
    if "arrayValue" in campo:
        return [valore(v) for v in campo["arrayValue"].get("values", [])]
    if "mapValue" in campo:
        return {
            k: valore(v) for k, v in campo["mapValue"].get("fields", {}).items()
        }
    return {"__sconosciuto__": campo}


# --------------------------------------------------------------------------
# Lettura da Firestore
# --------------------------------------------------------------------------


class Firestore:
    def __init__(self, progetto: str, token: str) -> None:
        self.base = f"{FIRESTORE}/projects/{progetto}/databases/(default)/documents"
        self.token = token
        self.documenti_letti = 0

    def _chiama(self, url: str, corpo: dict | None = None) -> dict:
        dati = json.dumps(corpo).encode() if corpo is not None else None
        richiesta = urllib.request.Request(
            url,
            data=dati,
            headers={
                "Authorization": f"Bearer {self.token}",
                "Content-Type": "application/json",
            },
            method="POST" if dati is not None else "GET",
        )
        try:
            with urllib.request.urlopen(richiesta, timeout=60) as risposta:
                return json.load(risposta)
        except urllib.error.HTTPError as errore:
            dettaglio = errore.read().decode("utf-8", "replace")[:500]
            raise SystemExit(
                f"Firestore ha risposto {errore.code} su {url}\n{dettaglio}"
            ) from errore

    def collezioni(self, percorso: str = "") -> list[str]:
        url = f"{self.base}{percorso}:listCollectionIds"
        nomi: list[str] = []
        pagina: str | None = None
        while True:
            corpo: dict[str, Any] = {"pageSize": 300}
            if pagina:
                corpo["pageToken"] = pagina
            risposta = self._chiama(url, corpo)
            nomi.extend(risposta.get("collectionIds", []))
            pagina = risposta.get("nextPageToken")
            if not pagina:
                return nomi

    def documenti(self, percorso_collezione: str) -> list[dict[str, Any]]:
        raccolti: list[dict[str, Any]] = []
        pagina: str | None = None
        while True:
            query = {"pageSize": "300"}
            if pagina:
                query["pageToken"] = pagina
            url = f"{self.base}{percorso_collezione}?{urllib.parse.urlencode(query)}"
            risposta = self._chiama(url)
            for documento in risposta.get("documents", []):
                nome = documento["name"].split("/documents", 1)[1]
                raccolti.append(
                    {
                        "__id__": nome.rsplit("/", 1)[-1],
                        "__percorso__": nome,
                        "__creato__": documento.get("createTime"),
                        "__aggiornato__": documento.get("updateTime"),
                        **{
                            k: valore(v)
                            for k, v in documento.get("fields", {}).items()
                        },
                    }
                )
                self.documenti_letti += 1
            pagina = risposta.get("nextPageToken")
            if not pagina:
                return raccolti

    def albero(self, percorso: str = "", profondita: int = 0) -> dict[str, Any]:
        """Scende ricorsivamente in ogni sottocollezione trovata."""
        risultato: dict[str, Any] = {}
        for collezione in self.collezioni(percorso):
            percorso_collezione = f"{percorso}/{collezione}"
            print(
                f"{'  ' * profondita}- {percorso_collezione}",
                file=sys.stderr,
                flush=True,
            )
            documenti = self.documenti(percorso_collezione)
            for documento in documenti:
                figli = self.albero(documento["__percorso__"], profondita + 1)
                if figli:
                    documento["__sottocollezioni__"] = figli
            risultato[collezione] = documenti
        return risultato


# --------------------------------------------------------------------------


def main() -> int:
    argomenti = argparse.ArgumentParser(
        description="Dump integrale di Firestore per Gym Tracker."
    )
    argomenti.add_argument("--credenziali", required=True, type=Path)
    argomenti.add_argument("--destinazione", required=True, type=Path)
    argomenti.add_argument("--progetto", default=PROGETTO_PREDEFINITO)
    argomenti.add_argument(
        "--uid",
        help="Scarica un solo utente. Senza, scarica tutto il database.",
    )
    opzioni = argomenti.parse_args()

    if not opzioni.credenziali.is_file():
        raise SystemExit(f"Credenziali non trovate: {opzioni.credenziali}")

    print(f"Progetto: {opzioni.progetto}", file=sys.stderr)
    cliente = Firestore(opzioni.progetto, access_token(opzioni.credenziali))

    if opzioni.uid:
        radice = f"/users/{opzioni.uid}"
        dati = {"users": [{"__id__": opzioni.uid, "__percorso__": radice}]}
        dati["users"][0]["__sottocollezioni__"] = cliente.albero(radice)
    else:
        dati = cliente.albero()

    documento = {
        "progetto": opzioni.progetto,
        "generato": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "strumento": "dump_gym_firestore.py",
        "nota": (
            "Documenti grezzi da Firestore, non filtrati dai modelli dell'app: "
            "contengono anche i campi che l'export dell'app non scrive "
            "(prescrizioni per esercizio, intervalSegments)."
        ),
        "documenti": cliente.documenti_letti,
        "dati": dati,
    }

    opzioni.destinazione.parent.mkdir(parents=True, exist_ok=True)
    opzioni.destinazione.write_text(
        json.dumps(documento, ensure_ascii=False, indent=1)
    )

    peso = opzioni.destinazione.stat().st_size / 1024
    print(
        f"\nFatto: {cliente.documenti_letti} documenti, "
        f"{peso:.0f} KB in {opzioni.destinazione}",
        file=sys.stderr,
    )
    print(
        "Ricorda di revocare la chiave della service account dalla console "
        "Firebase quando non serve piu.",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
