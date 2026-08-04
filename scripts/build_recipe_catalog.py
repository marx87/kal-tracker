#!/usr/bin/env python3
"""Costruisce l'asset del ricettario fit a partire dai chunk JSON.

Uso:
    python3 scripts/build_recipe_catalog.py [CHUNK_DIR] [--out FILE] [--version N]

Senza argomenti legge i chunk sorgente versionati in
scripts/recipe_catalog_chunks/ e riscrive l'asset
apps/mobile/assets/catalog/ricettario_fit_v1.json in modo deterministico.

Ogni chunk e' una lista JSON di ricette con questa forma:
    {
      "name": "Straccetti di pollo al limone",
      "tags": ["cena", "proteico", "veloce"],
      "description": "...",
      "instructions": "1. ...\n2. ...",
      "servings": 2,
      "prepMinutes": 20,
      "ingredients": [
        {"name": "Petto di pollo", "grams": 400,
         "per100g": {"calories": 110, "protein": 23, "carbs": 0, "fat": 1.5}}
      ]
    }

Lo script valida ogni ricetta (campi, range, coerenza Atwater per ingrediente
al 25%, porzione sensata per tipo di pasto), normalizza i tag (minuscoli, dal
vocabolario ammesso), scarta le ricette invalide loggando il motivo, deduplica
per nome normalizzato (minuscole, senza accenti: vince la prima occorrenza),
assegna slug stabili deterministici dal nome e scrive l'asset ordinato per
pasto e nome con intestazione {"version": N, "recipes": [...]}.

Le calorie NON sono mai dichiarate a mano: per ogni ricetta lo script CALCOLA
i totali dagli ingredienti (per-100g x grammi / 100) e li scrive nel campo
"totals" come controllo incrociato: l'app li ricalcola con
RecipeNutritionCalculator e un test verifica che combacino.

ATTENZIONE: gli slug sono API permanenti — l'id della ricetta installata e' un
uuid v5 sullo slug. Rinominare uno slug in una versione futura crea un
doppione e ignora i tombstone: non farlo mai.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import unicodedata
from pathlib import Path

# Vocabolario controllato dei tag: decide anche quanti FilterChip mostra
# la schermata Ricette, quindi resta volutamente piccolo.
ALLOWED_TAGS = {
    "colazione",
    "pranzo",
    "cena",
    "spuntino",
    "dolce",
    "proteico",
    "veloce",
    "leggero",
    "comfort",
    "meal prep",
}

# Tag pasto in ordine canonico: decide l'ordine delle ricette nell'asset.
MEAL_TAGS = ["colazione", "pranzo", "cena", "spuntino", "dolce"]

# Porzione sensata (grammi a porzione) per tag pasto. Per le ricette con piu'
# tag pasto vale l'unione dei range (es. dolce+spuntino -> 60..400).
PORTION_RANGES = {
    "colazione": (60.0, 400.0),
    "pranzo": (150.0, 700.0),
    "cena": (150.0, 700.0),
    "spuntino": (60.0, 400.0),
    "dolce": (60.0, 400.0),
}

ATWATER_TOLERANCE = 0.25
KCAL_PER_PROTEIN_GRAM = 4.0
KCAL_PER_CARBS_GRAM = 4.0
KCAL_PER_FAT_GRAM = 9.0

MAX_NAME_LENGTH = 160
MAX_DESCRIPTION_LENGTH = 600
MAX_INSTRUCTIONS_LENGTH = 4000
MAX_TAGS = 8
MAX_TAG_LENGTH = 24
SERVINGS_RANGE = (1, 6)
PREP_MINUTES_RANGE = (5, 90)
INGREDIENTS_RANGE = (3, 10)
MAX_INGREDIENT_GRAMS = 2000.0
MAX_KCAL_PER_100G = 900.0
MAX_MACRO_PER_100G = 100.0
KCAL_PER_SERVING_RANGE = (80.0, 900.0)


def normalize_text(value: str) -> str:
    """minuscole + accenti rimossi: chiave di deduplica e base dello slug."""
    decomposed = unicodedata.normalize("NFKD", value.strip().lower())
    return "".join(ch for ch in decomposed if not unicodedata.combining(ch))


def slugify(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", normalize_text(value)).strip("-")


def is_number(value: object) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def is_int(value: object) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def normalize_tags(raw: object) -> tuple[list[str] | None, str | None]:
    """Minuscoli, spazi collassati, dedup con ordine; solo tag ammessi."""
    if not isinstance(raw, list) or not raw:
        return None, "tags mancanti o non lista"
    tags: list[str] = []
    for tag in raw:
        if not isinstance(tag, str):
            return None, f"tag non testuale {tag!r}"
        clean = re.sub(r"\s+", " ", tag.lower().strip())
        if not clean or clean in tags:
            continue
        if clean not in ALLOWED_TAGS:
            return None, f"tag fuori vocabolario {clean!r}"
        if len(clean) > MAX_TAG_LENGTH:
            return None, f"tag oltre {MAX_TAG_LENGTH} caratteri {clean!r}"
        tags.append(clean)
    if not tags:
        return None, "nessun tag valido"
    if len(tags) > MAX_TAGS:
        return None, f"piu' di {MAX_TAGS} tag"
    if not any(tag in PORTION_RANGES for tag in tags):
        return None, "manca il tag pasto (colazione/pranzo/cena/spuntino/dolce)"
    return tags, None


def validate_ingredient(raw: object) -> tuple[dict | None, str | None]:
    if not isinstance(raw, dict):
        return None, "ingrediente non e' un oggetto JSON"
    name = raw.get("name")
    if not isinstance(name, str) or not name.strip():
        return None, "ingrediente senza nome"
    name = name.strip()
    if len(name) > MAX_NAME_LENGTH:
        return None, f"nome ingrediente oltre {MAX_NAME_LENGTH} caratteri"

    grams = raw.get("grams")
    if not is_number(grams) or not 0 < grams <= MAX_INGREDIENT_GRAMS:
        return None, f"{name}: grams fuori range ({grams!r})"

    per100g = raw.get("per100g")
    if not isinstance(per100g, dict):
        return None, f"{name}: per100g mancante"
    values: dict[str, float] = {}
    for field in ("calories", "protein", "carbs", "fat"):
        value = per100g.get(field)
        if not is_number(value) or value < 0:
            return None, f"{name}: per100g.{field} mancante o negativo"
        values[field] = float(value)
    if values["calories"] > MAX_KCAL_PER_100G:
        return None, f"{name}: calories per 100 g fuori range ({values['calories']})"
    for field in ("protein", "carbs", "fat"):
        if values[field] > MAX_MACRO_PER_100G:
            return None, f"{name}: {field} per 100 g fuori range ({values[field]})"

    # Controllo Atwater per ingrediente: le kcal devono tornare con i macro.
    estimated = (
        values["protein"] * KCAL_PER_PROTEIN_GRAM
        + values["carbs"] * KCAL_PER_CARBS_GRAM
        + values["fat"] * KCAL_PER_FAT_GRAM
    )
    if values["calories"] > 0:
        deviation = abs(values["calories"] - estimated) / values["calories"]
        if deviation > ATWATER_TOLERANCE:
            return None, (
                f"{name}: Atwater fuori tolleranza ({values['calories']} kcal "
                f"dichiarate vs {estimated:.0f} dai macro, scarto {deviation:.0%})"
            )
    elif estimated > 5:
        return None, f"{name}: calories 0 ma macro presenti"

    return {
        "name": name,
        "grams": raw["grams"],
        "per100g": {
            "calories": per100g["calories"],
            "protein": per100g["protein"],
            "carbs": per100g["carbs"],
            "fat": per100g["fat"],
        },
    }, None


def portion_range(tags: list[str]) -> tuple[float, float]:
    ranges = [PORTION_RANGES[tag] for tag in tags if tag in PORTION_RANGES]
    return min(low for low, _ in ranges), max(high for _, high in ranges)


def validate(raw: dict, origin: str) -> tuple[dict | None, str | None]:
    """Ritorna (ricetta normalizzata con totali calcolati, motivo scarto)."""
    name = raw.get("name")
    if not isinstance(name, str) or not name.strip():
        return None, f"{origin}: nome mancante o vuoto"
    name = name.strip()
    label = f"{origin} «{name}»"
    if len(name) > MAX_NAME_LENGTH:
        return None, f"{label}: nome oltre {MAX_NAME_LENGTH} caratteri"

    tags, tag_error = normalize_tags(raw.get("tags"))
    if tags is None:
        return None, f"{label}: {tag_error}"

    description = raw.get("description")
    if not isinstance(description, str) or not description.strip():
        return None, f"{label}: descrizione mancante"
    description = description.strip()
    if len(description) > MAX_DESCRIPTION_LENGTH:
        return None, f"{label}: descrizione oltre {MAX_DESCRIPTION_LENGTH} caratteri"

    instructions = raw.get("instructions")
    if not isinstance(instructions, str) or not instructions.strip():
        return None, f"{label}: istruzioni mancanti"
    instructions = instructions.strip()
    if len(instructions) > MAX_INSTRUCTIONS_LENGTH:
        return None, f"{label}: istruzioni oltre {MAX_INSTRUCTIONS_LENGTH} caratteri"

    servings = raw.get("servings")
    if not is_int(servings) or not SERVINGS_RANGE[0] <= servings <= SERVINGS_RANGE[1]:
        return None, f"{label}: servings fuori range ({servings!r})"
    prep_minutes = raw.get("prepMinutes")
    if not is_int(prep_minutes) or not (
        PREP_MINUTES_RANGE[0] <= prep_minutes <= PREP_MINUTES_RANGE[1]
    ):
        return None, f"{label}: prepMinutes fuori range ({prep_minutes!r})"

    raw_ingredients = raw.get("ingredients")
    if not isinstance(raw_ingredients, list) or not (
        INGREDIENTS_RANGE[0] <= len(raw_ingredients) <= INGREDIENTS_RANGE[1]
    ):
        count = len(raw_ingredients) if isinstance(raw_ingredients, list) else "?"
        return None, f"{label}: numero ingredienti fuori range ({count})"

    ingredients: list[dict] = []
    totals = {"calories": 0.0, "protein": 0.0, "carbs": 0.0, "fat": 0.0}
    total_grams = 0.0
    for raw_ingredient in raw_ingredients:
        ingredient, reason = validate_ingredient(raw_ingredient)
        if ingredient is None:
            return None, f"{label}: {reason}"
        ingredients.append(ingredient)
        factor = float(ingredient["grams"]) / 100.0
        for field in totals:
            totals[field] += float(ingredient["per100g"][field]) * factor
        total_grams += float(ingredient["grams"])

    # Porzione sensata: grammi e calorie a porzione nei range del tipo pasto.
    per_serving_grams = total_grams / servings
    low, high = portion_range(tags)
    if not low <= per_serving_grams <= high:
        return None, (
            f"{label}: porzione {per_serving_grams:.0f} g fuori range "
            f"{low:.0f}..{high:.0f}"
        )
    per_serving_kcal = totals["calories"] / servings
    if not KCAL_PER_SERVING_RANGE[0] <= per_serving_kcal <= KCAL_PER_SERVING_RANGE[1]:
        return None, (
            f"{label}: {per_serving_kcal:.0f} kcal a porzione fuori range "
            f"{KCAL_PER_SERVING_RANGE[0]:.0f}..{KCAL_PER_SERVING_RANGE[1]:.0f}"
        )

    slug = slugify(name)
    if not slug:
        return None, f"{label}: slug vuoto"

    return {
        "slug": slug,
        "name": name,
        "tags": tags,
        "description": description,
        "instructions": instructions,
        "servings": servings,
        "prepMinutes": prep_minutes,
        "ingredients": ingredients,
        # Totali CALCOLATI dagli ingredienti: mai dichiarati a mano. L'app li
        # ricalcola con RecipeNutritionCalculator e deve trovarli identici.
        "totals": {field: round(value, 2) for field, value in totals.items()},
    }, None


def meal_order(tags: list[str]) -> int:
    return min(MEAL_TAGS.index(tag) for tag in tags if tag in MEAL_TAGS)


def build(chunk_dir: Path, out_path: Path, version: int) -> int:
    chunk_paths = sorted(chunk_dir.glob("*.json"))
    if not chunk_paths:
        print(f"Nessun chunk *.json in {chunk_dir}", file=sys.stderr)
        return 1

    recipes: list[dict] = []
    seen_names: dict[str, str] = {}
    seen_slugs: dict[str, str] = {}
    discarded: list[str] = []
    total = 0

    for chunk_path in chunk_paths:
        try:
            raw_recipes = json.loads(chunk_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            print(f"Chunk illeggibile {chunk_path.name}: {error}", file=sys.stderr)
            return 1
        if not isinstance(raw_recipes, list):
            print(f"Chunk {chunk_path.name}: atteso un array JSON", file=sys.stderr)
            return 1

        for position, raw in enumerate(raw_recipes, start=1):
            total += 1
            origin = f"{chunk_path.name}#{position}"
            if not isinstance(raw, dict):
                discarded.append(f"{origin}: ricetta non e' un oggetto JSON")
                continue
            recipe, reason = validate(raw, origin)
            if recipe is None:
                discarded.append(reason or f"{origin}: ricetta invalida")
                continue

            name_key = normalize_text(recipe["name"])
            if name_key in seen_names:
                discarded.append(
                    f"{origin} «{recipe['name']}»: duplicato di "
                    f"{seen_names[name_key]} (vince la prima)"
                )
                continue
            if recipe["slug"] in seen_slugs:
                discarded.append(
                    f"{origin} «{recipe['name']}»: slug {recipe['slug']} gia' "
                    f"usato da {seen_slugs[recipe['slug']]}"
                )
                continue
            seen_names[name_key] = f"{origin} «{recipe['name']}»"
            seen_slugs[recipe["slug"]] = f"{origin} «{recipe['name']}»"
            recipes.append(recipe)

    recipes.sort(
        key=lambda recipe: (meal_order(recipe["tags"]), normalize_text(recipe["name"]))
    )

    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(
        json.dumps(
            {"version": version, "recipes": recipes}, ensure_ascii=False, indent=2
        )
        + "\n",
        encoding="utf-8",
    )

    print(f"Chunk letti: {len(chunk_paths)} ({total} ricette)")
    print(f"Ricette valide scritte: {len(recipes)} -> {out_path}")
    print(f"Ricette scartate: {len(discarded)}")
    for reason in discarded:
        print(f"  - {reason}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "chunk_dir",
        type=Path,
        nargs="?",
        default=Path(__file__).resolve().parent / "recipe_catalog_chunks",
        help="cartella con i chunk *.json (default: scripts/recipe_catalog_chunks)",
    )
    parser.add_argument(
        "--out",
        type=Path,
        default=Path(__file__).resolve().parent.parent
        / "apps/mobile/assets/catalog/ricettario_fit_v1.json",
        help="file asset di destinazione",
    )
    parser.add_argument(
        "--version", type=int, default=1, help="version scritta nell'intestazione"
    )
    args = parser.parse_args()
    return build(args.chunk_dir, args.out, args.version)


if __name__ == "__main__":
    sys.exit(main())
