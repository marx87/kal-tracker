#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
migration="$repo_root/supabase/migrations/202608060010_checkin_goals_impedance.sql"

# Le tre tabelle della v7, nell'ordine in cui la migrazione le crea.
tables=(
  daily_check_ins
  goals
  body_impedance_readings
)

fail() {
  echo "checkin/goals/impedance schema static check: $1" >&2
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

# Estrae il corpo di una singola CREATE TABLE: i controlli per tabella devono
# restare confinati a quella, altrimenti un vincolo cercato sull'intero file
# passerebbe anche se appartenesse a un'altra.
table_block() {
  local name="$1"
  TABLE_NAME="$name" LC_ALL=C perl -0777 -ne '
    my $name = $ENV{TABLE_NAME};
    print $1 if /^create table kal_tracker\.\Q$name\E \((.*?)^\);/ms
  ' "$migration"
}

require_in_table() {
  local name="$1"
  local pattern="$2"
  local description="$3"
  table_block "$name" | grep -qE "$pattern" \
    || fail "missing $description on kal_tracker.$name"
}

refute_in_table() {
  local name="$1"
  local pattern="$2"
  local description="$3"
  if table_block "$name" | grep -qiE "$pattern"; then
    fail "$description on kal_tracker.$name"
  fi
}

do_block() {
  local tag="$1"
  BLOCK_TAG="$tag" LC_ALL=C perl -0777 -ne '
    my $tag = $ENV{BLOCK_TAG};
    print $1 if /do \$\Q$tag\E\$(.*?)\$\Q$tag\E\$;/s
  ' "$migration"
}

[[ -f "$migration" ]] || fail "migration file"

require_pattern '^begin;.*commit;[[:space:]]*$' 'transaction boundary'

# Le colonne del protocollo di sincronizzazione: senza di loro prepare_write
# solleva 23502 e la riga non entra, oppure record_sync_change non produce
# nessuna voce nel ledger e la modifica non raggiunge il secondo dispositivo.
for table in "${tables[@]}"; do
  require_in_table "$table" '^  id uuid primary key,$' 'the surrogate id'
  require_in_table "$table" 'owner_id uuid not null default auth\.uid\(\)' \
    'the owner column'
  require_in_table "$table" 'last_mutation_id uuid not null' 'the mutation id'
  require_in_table "$table" 'row_version bigint not null default 1 check \(row_version > 0\)' \
    'the row version'
  require_in_table "$table" '^  deleted_at timestamptz,?$' 'the tombstone'
  require_in_table "$table" 'unique \(owner_id, last_mutation_id\)' \
    'the mutation uniqueness'
done

# BLOCCANTE. `body_measurements` e referenziata da body_measurement_values
# (0007) e ora dalle impedenze: si estende SOLO con add column, mai ricreandola.
require_pattern \
  'alter table kal_tracker\.body_measurements[[:space:]]+add column if not exists device_model text' \
  'the scale model added, not a rebuilt table'
require_pattern 'add column if not exists raw_payload text' \
  'the raw Bluetooth frame'
# La FK delle impedenze punta alla coppia (owner_id, id) resa unica dalla 0007.
require_in_table body_impedance_readings \
  'references kal_tracker\.body_measurements\(owner_id, id\)' \
  'the foreign key to the parent measurement'

# --- Check-in ---------------------------------------------------------------

# Il giorno e una data di calendario, non un istante: mezzanotte di Roma e le
# 22:00 del giorno prima in UTC, e il check-in del mattino deve cadere nello
# stesso giorno della pesata e del diario.
require_in_table daily_check_ins '^  day date not null,$' \
  'the calendar day of the check-in'
refute_in_table daily_check_ins 'day timestamptz' \
  'a timestamp instead of a calendar day'

# Una riga viva senza sonno ne energia farebbe contare come «compilato» un
# giorno vuoto; il tombstone invece e proprio una riga svuotata.
require_pattern 'daily_check_ins_not_blank check \([[:space:]]*deleted_at is not null' \
  'the check that rejects an empty live check-in'

# L'unicita e totale e non parziale: il client fa upsert su (profilo, giorno) e
# un giorno cancellato riprende la sua riga. Un filtro sulle righe vive
# lascerebbe nascere un secondo check-in per lo stesso giorno.
require_in_table daily_check_ins 'unique \(owner_id, profile_id, day\)' \
  'the one-row-per-day uniqueness'
refute_pattern \
  'create unique index[^;]*daily_check_ins\(owner_id, profile_id, day\)[^;]*where deleted_at is null' \
  'a partial day uniqueness that would let a second check-in in'

# Il peso NON si duplica qui: vive in body_measurements, e due tabelle con lo
# stesso numero diventano due numeri diversi il giorno in cui una sbaglia.
refute_in_table daily_check_ins '(weight|peso)' \
  'a duplicated body weight'
# Sonno ed energia sono lo stesso gesto: una tabella sola.
refute_pattern 'create table kal_tracker\.(sleep_logs|energy_logs|check_in_energy)' \
  'a second table for what is one gesture'

# --- Obiettivo --------------------------------------------------------------

require_in_table goals "target_level text not null check \(target_level in \(" \
  'the closed scale of definition levels'
require_in_table goals "phase text not null default 'approach'" \
  'the phase, with the approach as the starting one'
require_pattern 'goals_outcome_needs_closing check \([[:space:]]*outcome is null or closed_at is not null' \
  'the check that refuses an outcome without a closing date'

# Nessun indice unico sull'obiettivo aperto: due dispositivi offline che
# fissano un traguardo ciascuno resterebbero bloccati sulla sincronizzazione
# invece di far eleggere il piu recente al client.
refute_pattern 'create unique index[^;]*goals\(owner_id, profile_id\)[^;]*where[^;]*closed_at is null' \
  'a unique index on the open goal (the election belongs to the reader)'

# Deficit, data stimata, banda di mantenimento e TDEE sono funzioni di ritmo,
# peso e storico: salvarli creerebbe una seconda verita che invecchia da sola.
# Il TDEE, in piu, e una proprieta del corpo e sopravvive a ogni cambio di
# traguardo: appenderlo all'obiettivo lo farebbe ripartire da zero.
refute_in_table goals 'daily_deficit' 'a stored daily deficit'
refute_in_table goals 'estimated_date' 'a stored estimated date'
refute_in_table goals 'tdee' 'a TDEE hanging off the goal'
refute_in_table goals 'maintenance_(low|high|band)' 'a stored maintenance band'
# Il limite dello 0,7 % e una frazione del peso CORRENTE, che questa riga non
# conosce: come CHECK sarebbe sbagliato in un verso o nell'altro.
refute_in_table goals 'pace_kg_per_week[^,]*0\.007' \
  'the safety limit frozen into a CHECK'

# --- Impedenze --------------------------------------------------------------

# La frequenza resta nullabile: scrivere «50 kHz» perche e il valore tipico
# sarebbe salvare una supposizione accanto a una misura.
require_in_table body_impedance_readings '^  frequency_hz integer$' \
  'the optional frequency'
require_in_table body_impedance_readings 'ohm numeric\(7,2\) not null' \
  'the raw impedance'
# Le percentuali sono formula e vivono sulla pesata, non qui.
refute_in_table body_impedance_readings '(body_fat|muscle|water|bone)_pct' \
  'a derived percentage'

# Servono DUE indici: in Postgres, come in SQLite, due NULL non collidono mai.
require_pattern \
  'create unique index body_impedance_readings_declared_idx[^;]*where deleted_at is null and frequency_hz is not null;' \
  'the uniqueness of a declared frequency'
require_pattern \
  'create unique index body_impedance_readings_undeclared_idx[^;]*where deleted_at is null and frequency_hz is null;' \
  'the uniqueness of the undeclared-frequency reading'

# --- Trigger, RLS e permessi ------------------------------------------------

triggers_block="$(do_block triggers)"
policies_block="$(do_block policies)"
[[ -n "$triggers_block" ]] || fail 'missing the trigger DO block'
[[ -n "$policies_block" ]] || fail 'missing the policy DO block'
for table in "${tables[@]}"; do
  grep -qE "^    '${table}',?$" <<<"$triggers_block" \
    || fail "kal_tracker.$table is missing from the trigger list"
  grep -qE "^    '${table}',?$" <<<"$policies_block" \
    || fail "kal_tracker.$table is missing from the policy list"
  grep -qE "kal_tracker\.${table}\b" <<<"$(sed -n '/^grant select, insert, update/,/to authenticated;/p' "$migration")" \
    || fail "kal_tracker.$table is missing from the authenticated grant"
  grep -qE "kal_tracker\.${table}\b" <<<"$(sed -n '/^grant all on/,/to service_role;/p' "$migration")" \
    || fail "kal_tracker.$table is missing from the service_role grant"
done
grep -q 'enable row level security' <<<"$policies_block" \
  || fail 'missing row level security'
grep -q 'prepare_write' <<<"$triggers_block" \
  || fail 'missing the prepare_write trigger'
grep -q 'record_sync_change' <<<"$triggers_block" \
  || fail 'missing the record_sync_change trigger'
require_pattern "using \\(owner_id = \\(select auth\\.uid\\(\\)\\)\\)" \
  'the owner check in the policies'
# La cancellazione e sempre un tombstone, come per ogni altra tabella
# sincronizzata: una policy di DELETE porterebbe via la riga senza dirlo
# all'altro dispositivo.
refute_pattern 'for delete to authenticated' 'a DELETE policy'

require_pattern 'notify pgrst' 'PostgREST schema reload'

if has_pattern 'security definer' insensitive; then
  fail 'a SECURITY DEFINER object in a schema-only migration'
fi

if has_pattern 'alter default privileges' insensitive; then
  fail 'a default-privilege change'
fi

if has_pattern 'drop table' insensitive; then
  fail 'a destructive table drop'
fi

if has_pattern 'drop column' insensitive; then
  fail 'a destructive column drop'
fi

echo 'checkin/goals/impedance schema static check: ok'
