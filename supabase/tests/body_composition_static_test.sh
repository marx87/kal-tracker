#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
migration="$repo_root/supabase/migrations/202608050006_body_composition.sql"

fail() {
  echo "body-composition schema static check: $1" >&2
  exit 1
}

has_pattern() {
  local pattern="$1"
  local case_mode="${2:-sensitive}"

  if command -v rg >/dev/null 2>&1; then
    local rg_args=(--quiet --multiline --multiline-dotall)
    [[ "$case_mode" == 'insensitive' ]] && rg_args+=(--ignore-case)
    rg "${rg_args[@]}" "$pattern" "$migration"
    return
  fi

  if [[ "$case_mode" == 'insensitive' ]]; then
    LC_ALL=C perl -0777 -e \
      '$pattern = shift; $content = <>; exit($content =~ /$pattern/is ? 0 : 1)' \
      "$pattern" "$migration"
  else
    LC_ALL=C perl -0777 -e \
      '$pattern = shift; $content = <>; exit($content =~ /$pattern/s ? 0 : 1)' \
      "$pattern" "$migration"
  fi
}

require_pattern() {
  local pattern="$1"
  local description="$2"
  has_pattern "$pattern" || fail "missing $description"
}

refute_pattern() {
  local pattern="$1"
  local description="$2"
  if has_pattern "$pattern" insensitive; then
    fail "$description"
  fi
}

[[ -f "$migration" ]] || fail "migration file"

require_pattern '^begin;.*commit;[[:space:]]*$' 'transaction boundary'

# La misura grezza e la versione della formula sono il cuore del disegno:
# senza di loro lo storico non si puo ricalcolare cambiando formula.
require_pattern 'add column if not exists impedance_ohm numeric' \
  'raw impedance column'
require_pattern 'add column if not exists formula_version text' \
  'formula version column'
require_pattern 'add column if not exists has_impedance boolean not null default false' \
  'impedance flag with a safe default for existing rows'

# Percentuali derivate, tutte con il proprio intervallo.
for column in body_fat_pct muscle_pct skeletal_muscle_pct bone_pct \
  protein_pct water_pct subcutaneous_fat_pct; do
  require_pattern "add column if not exists ${column} numeric" \
    "${column} column"
  require_pattern \
    "${column} is null or[[:space:]]+${column} between 0 and 100" \
    "${column} range check"
done

require_pattern 'visceral_fat_index is null or visceral_fat_index between 1 and 60' \
  'visceral fat range check'
require_pattern 'impedance_ohm > 0 and impedance_ohm <= 2000' \
  'impedance range check'

# Anagrafica del profilo: senza non si calcolano BMI, BMR ne le formule BIA.
require_pattern 'alter table kal_tracker\.profiles' 'profile anagraphics'
require_pattern 'height_cm is null or height_cm between 50 and 260' \
  'height range check'
require_pattern "sex is null or sex in \\('M', 'F'\\)" 'sex check'
require_pattern 'add column if not exists birth_date date' \
  'birth date stored as a date, not a timestamp'

# Le pesate della bilancia nascono ormai sul telefono: senza questa policy
# la sincronizzazione delle letture Bluetooth verrebbe rifiutata da RLS.
require_pattern "create policy body_measurements_insert_client.*?source in \\('kal_tracker'.*?'renpho_ble'" \
  'client-side sources allowed on insert'
require_pattern "create policy body_measurements_update_client.*?source in \\('kal_tracker'.*?'renpho_ble'" \
  'client-side sources allowed on update'
require_pattern 'notify pgrst' 'PostgREST schema reload'

# Cio che NON deve esistere: i valori derivabili si calcolano, non si salvano,
# e i giudizi proprietari della bilancia non entrano nel modello.
refute_pattern 'add column[^;]*\bbmi\b' 'a stored BMI column (it is weight / height^2)'
refute_pattern 'add column[^;]*fat_mass_kg' 'a stored fat mass column (it is weight x percentage)'
refute_pattern 'add column[^;]*metabolic_age' "a stored metabolic age (it is the BMR repainted)"
refute_pattern 'add column[^;]*(ideal|optimal)_weight' 'a stored ideal weight verdict'
refute_pattern 'add column[^;]*body_type' 'a stored body-type verdict'

if has_pattern 'security definer' insensitive; then
  fail 'a SECURITY DEFINER object in a schema-only migration'
fi

if has_pattern 'alter default privileges' insensitive; then
  fail 'a default-privilege change'
fi

if has_pattern 'drop column' insensitive; then
  fail 'a destructive column drop'
fi

echo 'body-composition schema static check: ok'
