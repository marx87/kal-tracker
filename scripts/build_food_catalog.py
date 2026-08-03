#!/usr/bin/env python3
"""Costruisce l'asset del catalogo piatti a partire dai chunk JSON.

Uso:
    python3 scripts/build_food_catalog.py [CHUNK_DIR] [--out FILE] [--version N]

Senza argomenti legge i chunk sorgente versionati in
scripts/food_catalog_chunks/ e riscrive l'asset
apps/mobile/assets/catalog/catalogo_piatti_v1.json in modo deterministico.

Ogni chunk e' una lista JSON di voci con questa forma:
    {
      "name": "Pasta al pomodoro",
      "aliases": ["pasta al sugo", ...],
      "category": "Primi piatti",
      "kcalPer100g": 130,
      "proteinPer100g": 4.5,
      "carbsPer100g": 23,
      "fatPer100g": 2.5,
      "portionGrams": 350,
      "note": "valori da cotto e condito"   # opzionale
    }

Lo script valida ogni voce (campi, range, coerenza Atwater al 25% con
eccezione dichiarata per le bevande alcoliche), normalizza i valori a una
cifra decimale, scarta le voci invalide loggando il motivo, deduplica per
nome normalizzato (minuscole, senza accenti: vince la prima occorrenza),
assegna id stabili deterministici "cat-" + slug del nome e scrive l'asset
ordinato per categoria e nome con intestazione {"version": N, "items": [...]}.

Riusabile per le versioni successive del catalogo: basta puntare a nuovi
chunk e alzare --version.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import unicodedata
from pathlib import Path

# Ordine canonico delle categorie: decide l'ordine dei chip in app.
CATEGORIES = [
    "Primi piatti",
    "Carne e salumi",
    "Pesce e uova",
    "Pizza e street food",
    "Contorni e verdure",
    "Legumi, cereali e pane",
    "Latticini e formaggi",
    "Frutta e frutta secca",
    "Colazione, dolci e snack",
    "Piatti pronti, etnici e bevande",
]

ATWATER_TOLERANCE = 0.25
KCAL_PER_PROTEIN_GRAM = 4.0
KCAL_PER_CARBS_GRAM = 4.0
KCAL_PER_FAT_GRAM = 9.0

# Eccezione dichiarata al controllo Atwater: le bevande alcoliche portano
# calorie dall'alcol (7 kcal/g) che non compaiono nei macro. Vale solo per la
# categoria che contiene le bevande e solo se nome o nota dichiarano l'alcol.
ALCOHOL_PATTERN = re.compile(
    r"alcol|alcool|alcolic|vino|birra|spumante|prosecco|liquore|grappa|"
    r"distillat|cocktail|spritz|vermouth|rum\b|gin\b",
    re.IGNORECASE,
)

MAX_NAME_LENGTH = 160
MAX_KCAL_PER_100G = 900.0
MAX_MACRO_PER_100G = 100.0
MAX_PORTION_GRAMS = 1000.0

REQUIRED_NUMBERS = (
    "kcalPer100g",
    "proteinPer100g",
    "carbsPer100g",
    "fatPer100g",
    "portionGrams",
)


def normalize_text(value: str) -> str:
    """minuscole + accenti rimossi: chiave di deduplica e base dello slug."""
    decomposed = unicodedata.normalize("NFKD", value.strip().lower())
    return "".join(ch for ch in decomposed if not unicodedata.combining(ch))


def slugify(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", normalize_text(value)).strip("-")


def is_number(value: object) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def is_alcohol_exception(name: str, category: str, note: str) -> bool:
    if "bevande" not in category.lower():
        return False
    return bool(ALCOHOL_PATTERN.search(name) or ALCOHOL_PATTERN.search(note))


def validate(raw: dict, origin: str) -> tuple[dict | None, str | None, bool]:
    """Ritorna (voce normalizzata, motivo dello scarto, eccezione alcol)."""
    name = raw.get("name")
    if not isinstance(name, str) or not name.strip():
        return None, f"{origin}: nome mancante o vuoto", False
    name = name.strip()
    label = f"{origin} «{name}»"
    if len(name) > MAX_NAME_LENGTH:
        return None, f"{label}: nome oltre {MAX_NAME_LENGTH} caratteri", False

    category = raw.get("category")
    if not isinstance(category, str) or category.strip() not in CATEGORIES:
        return None, f"{label}: categoria sconosciuta {category!r}", False
    category = category.strip()

    for field in REQUIRED_NUMBERS:
        if not is_number(raw.get(field)):
            return None, f"{label}: campo {field} mancante o non numerico", False
        if raw[field] < 0:
            return None, f"{label}: campo {field} negativo ({raw[field]})", False

    kcal = round(float(raw["kcalPer100g"]), 1)
    protein = round(float(raw["proteinPer100g"]), 1)
    carbs = round(float(raw["carbsPer100g"]), 1)
    fat = round(float(raw["fatPer100g"]), 1)
    portion = round(float(raw["portionGrams"]), 1)

    if kcal > MAX_KCAL_PER_100G:
        return None, f"{label}: kcalPer100g fuori range ({kcal})", False
    for field_name, value in (
        ("proteinPer100g", protein),
        ("carbsPer100g", carbs),
        ("fatPer100g", fat),
    ):
        if value > MAX_MACRO_PER_100G:
            return None, f"{label}: {field_name} fuori range ({value})", False
    if not 0 < portion <= MAX_PORTION_GRAMS:
        return None, f"{label}: portionGrams fuori range ({portion})", False

    note = raw.get("note")
    if note is not None and not isinstance(note, str):
        return None, f"{label}: note non testuale", False
    note = (note or "").strip()

    aliases_raw = raw.get("aliases", [])
    if not isinstance(aliases_raw, list) or any(
        not isinstance(alias, str) for alias in aliases_raw
    ):
        return None, f"{label}: aliases non è una lista di stringhe", False
    aliases: list[str] = []
    seen_aliases = {normalize_text(name)}
    for alias in aliases_raw:
        alias = alias.strip()
        key = normalize_text(alias)
        if not alias or key in seen_aliases:
            continue
        seen_aliases.add(key)
        aliases.append(alias)

    # Controllo Atwater: le kcal dichiarate devono tornare con i macro.
    alcohol = is_alcohol_exception(name, category, note)
    estimated = (
        protein * KCAL_PER_PROTEIN_GRAM
        + carbs * KCAL_PER_CARBS_GRAM
        + fat * KCAL_PER_FAT_GRAM
    )
    if not alcohol:
        deviation = (
            abs(kcal - estimated) / estimated
            if estimated > 0
            else (0.0 if kcal == 0 else 1.0)
        )
        if deviation > ATWATER_TOLERANCE:
            return None, (
                f"{label}: Atwater fuori tolleranza "
                f"({kcal} kcal dichiarate vs {estimated:.0f} dai macro, "
                f"scarto {deviation:.0%})"
            ), False

    item = {
        "id": f"cat-{slugify(name)}",
        "name": name,
        "aliases": aliases,
        "category": category,
        "kcalPer100g": kcal,
        "proteinPer100g": protein,
        "carbsPer100g": carbs,
        "fatPer100g": fat,
        "portionGrams": portion,
    }
    if note:
        item["note"] = note
    return item, None, alcohol


def build(chunk_dir: Path, out_path: Path, version: int) -> int:
    chunk_paths = sorted(chunk_dir.glob("*.json"))
    if not chunk_paths:
        print(f"Nessun chunk *.json in {chunk_dir}", file=sys.stderr)
        return 1

    items: list[dict] = []
    seen_names: dict[str, str] = {}
    seen_ids: dict[str, str] = {}
    discarded: list[str] = []
    alcohol_exceptions: list[str] = []
    total = 0

    for chunk_path in chunk_paths:
        try:
            raw_items = json.loads(chunk_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            print(f"Chunk illeggibile {chunk_path.name}: {error}", file=sys.stderr)
            return 1
        if not isinstance(raw_items, list):
            print(f"Chunk {chunk_path.name}: atteso un array JSON", file=sys.stderr)
            return 1

        for position, raw in enumerate(raw_items, start=1):
            total += 1
            origin = f"{chunk_path.name}#{position}"
            if not isinstance(raw, dict):
                discarded.append(f"{origin}: voce non è un oggetto JSON")
                continue
            item, reason, alcohol = validate(raw, origin)
            if item is None:
                discarded.append(reason or f"{origin}: voce invalida")
                continue

            name_key = normalize_text(item["name"])
            if name_key in seen_names:
                discarded.append(
                    f"{origin} «{item['name']}»: duplicato di "
                    f"{seen_names[name_key]} (vince la prima)"
                )
                continue
            if item["id"] in seen_ids:
                discarded.append(
                    f"{origin} «{item['name']}»: slug id {item['id']} già usato "
                    f"da {seen_ids[item['id']]}"
                )
                continue
            seen_names[name_key] = f"{origin} «{item['name']}»"
            seen_ids[item["id"]] = f"{origin} «{item['name']}»"
            if alcohol:
                alcohol_exceptions.append(item["name"])
            items.append(item)

    items.sort(key=lambda item: (CATEGORIES.index(item["category"]), normalize_text(item["name"])))

    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(
        json.dumps({"version": version, "items": items}, ensure_ascii=False, indent=2)
        + "\n",
        encoding="utf-8",
    )

    print(f"Chunk letti: {len(chunk_paths)} ({total} voci)")
    print(f"Voci valide scritte: {len(items)} -> {out_path}")
    print(f"Eccezioni Atwater dichiarate (alcol): {len(alcohol_exceptions)}")
    for name in alcohol_exceptions:
        print(f"  ~ {name}")
    print(f"Voci scartate: {len(discarded)}")
    for reason in discarded:
        print(f"  - {reason}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "chunk_dir",
        type=Path,
        nargs="?",
        default=Path(__file__).resolve().parent / "food_catalog_chunks",
        help="cartella con i chunk *.json (default: scripts/food_catalog_chunks)",
    )
    parser.add_argument(
        "--out",
        type=Path,
        default=Path(__file__).resolve().parent.parent
        / "apps/mobile/assets/catalog/catalogo_piatti_v1.json",
        help="file asset di destinazione",
    )
    parser.add_argument(
        "--version", type=int, default=1, help="version scritta nell'intestazione"
    )
    args = parser.parse_args()
    return build(args.chunk_dir, args.out, args.version)


if __name__ == "__main__":
    sys.exit(main())
