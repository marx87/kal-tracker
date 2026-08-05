#!/usr/bin/env python3
"""Genera le fixture di test dell'importer a partire dai dati veri.

Perche esiste
-------------
I test dell'importer valgono solo se girano sulla forma reale dei dati: i
conteggi (308 esercizi, 29 sessioni, 628 serie), i riferimenti orfani, la
sessione rimasta aperta 536 ore e le schede con i blocchi a tempo non si
inventano con un campione finto, e un importer provato su dati inventati non
prova niente.

Ma `marx87/kal-tracker` e un repository PUBBLICO, e peso corporeo,
composizione, carichi sollevati e feedback di allenamento sono dati sanitari
di una persona identificabile. Non ci vanno.

Questo script tiene le due cose insieme: conserva **struttura, conteggi, date,
identificatori interni e ogni caso limite**, e sostituisce i **valori
personali**. Le fixture che ne escono sono quelle committate; i file veri
restano fuori dal repository.

Cosa viene sostituito
---------------------
- gli UID Firebase, con identificatori fittizi ma stabili;
- il peso corporeo e le circonferenze (misure e profilo);
- i carichi sollevati e le distanze delle serie;
- le note libere e le note di feedback.

Cosa NON viene toccato, perche i test ci si appoggiano
------------------------------------------------------
- date e orari (i test sul fuso di Roma verificano che il 4 agosto 22:34
  resti il 4 agosto);
- tutti gli id di documento e i riferimenti fra entita, compresi quelli
  orfani: sono uuid casuali, non dicono niente di nessuno;
- conteggi, ordinamenti, posizioni, catene di superserie;
- ripetizioni, durate, RPE, umore, XP: servono ai test e da soli non
  identificano nulla.

Uso
---
    python3 scripts/anonymize_gym_fixtures.py \\
        --export ~/Downloads/gym-tracker-export-20260805-1038.json \\
        --dump ~/Documents/KalTracker-Signing/gym-firestore-dump.json
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from typing import Any

DESTINAZIONE = Path("apps/mobile/test/features/gym_import/fixtures")

# Fattore applicato a pesi e carichi: cambia i valori mantenendone la scala,
# cosi i test sulle soglie (peso fra 20 e 500 kg) restano significativi.
FATTORE_PESO = 0.834
NOTA_SOSTITUTIVA = "Nota di prova"

CAMPI_PESO_CORPOREO = {"weightKg", "bodyWeightKg"}
CAMPI_CARICO = {"weightKg", "distanceM"}
CAMPI_NOTE = {"notes", "feedbackNotes", "note"}


def uid_fittizio(reale: str) -> str:
    """Identificatore stabile e senza legame con l'originale."""
    impronta = hashlib.sha256(f"coach360-fixture::{reale}".encode()).hexdigest()
    return f"utente-di-prova-{impronta[:20]}"


def scala(valore: Any) -> Any:
    if isinstance(valore, (int, float)) and not isinstance(valore, bool):
        return round(valore * FATTORE_PESO, 1)
    return valore


def pulisci(nodo: Any, dentro_serie: bool = False) -> Any:
    """Percorre l'albero sostituendo i soli valori personali."""
    if isinstance(nodo, list):
        return [pulisci(v, dentro_serie) for v in nodo]
    if not isinstance(nodo, dict):
        return nodo

    risultato: dict[str, Any] = {}
    for chiave, valore in nodo.items():
        if chiave in CAMPI_NOTE and isinstance(valore, str) and valore:
            risultato[chiave] = NOTA_SOSTITUTIVA
        elif chiave in CAMPI_PESO_CORPOREO or (dentro_serie and chiave in CAMPI_CARICO):
            risultato[chiave] = scala(valore)
        elif chiave == "custom" and isinstance(valore, dict):
            # Circonferenze a nastro: vita, braccio, coscia.
            risultato[chiave] = {k: scala(v) for k, v in valore.items()}
        elif chiave == "sets":
            risultato[chiave] = pulisci(valore, dentro_serie=True)
        else:
            risultato[chiave] = pulisci(valore, dentro_serie)
    return risultato


def sostituisci_uid(testo: str, mappa: dict[str, str]) -> str:
    for reale, fittizio in mappa.items():
        testo = testo.replace(reale, fittizio)
    return testo


def main() -> int:
    argomenti = argparse.ArgumentParser(description=__doc__)
    argomenti.add_argument("--export", required=True, type=Path)
    argomenti.add_argument("--dump", required=True, type=Path)
    argomenti.add_argument("--destinazione", type=Path, default=DESTINAZIONE)
    opzioni = argomenti.parse_args()

    opzioni.destinazione.mkdir(parents=True, exist_ok=True)

    dump = json.loads(opzioni.dump.read_text())
    mappa_uid = {
        utente["__id__"]: uid_fittizio(utente["__id__"])
        for utente in dump["dati"]["users"]
    }

    for nome, sorgente in (
        ("gym-tracker-export.json", opzioni.export),
        ("gym-firestore-dump.json", opzioni.dump),
    ):
        dati = pulisci(json.loads(sorgente.read_text()))
        # Gli UID compaiono anche dentro i percorsi dei documenti, quindi la
        # sostituzione si fa sul testo serializzato e non campo per campo.
        testo = sostituisci_uid(
            json.dumps(dati, ensure_ascii=False, indent=1), mappa_uid
        )
        (opzioni.destinazione / nome).write_text(testo)
        peso = (opzioni.destinazione / nome).stat().st_size / 1024
        print(f"{nome}: {peso:.0f} KB")

    print("\nUID sostituiti:")
    for reale, fittizio in mappa_uid.items():
        print(f"  {reale[:12]}… -> {fittizio}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
