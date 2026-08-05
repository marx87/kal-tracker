#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
migration="$repo_root/supabase/migrations/202608050007_workouts.sql"

# Le tredici tabelle di allenamento, nell'ordine in cui la migrazione le crea.
tables=(
  exercises
  routines
  routine_exercises
  routine_interval_segments
  routine_weekly_plan
  workouts
  workout_exercises
  workout_sets
  workout_pain_points
  workout_interval_segments
  workout_profile_stats
  workout_achievements
  body_measurement_values
)

fail() {
  echo "workouts schema static check: $1" >&2
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

# Estrae il corpo di una singola CREATE TABLE. Serve perché i controlli per
# tabella devono restare confinati a quella: un `unique (owner_id,
# last_mutation_id)` cercato sull'intero file passerebbe anche se appartenesse
# a un'altra delle tredici.
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

# Estrae il corpo di un blocco DO delimitato dal tag passato (triggers, policies).
do_block() {
  local tag="$1"
  BLOCK_TAG="$tag" LC_ALL=C perl -0777 -ne '
    my $tag = $ENV{BLOCK_TAG};
    print $1 if /do \$\Q$tag\E\$(.*?)\$\Q$tag\E\$;/s
  ' "$migration"
}

[[ -f "$migration" ]] || fail "migration file"

require_pattern '^begin;.*commit;[[:space:]]*$' 'transaction boundary'

# BLOCCANTE 1. La FK delle circonferenze punta a (owner_id, id) di
# body_measurements, che la 0002 non ha mai reso unica. Senza questa ALTER —
# e prima delle CREATE TABLE — la migrazione fallisce con 42830 e, stando
# tutto in un solo begin/commit, non viene applicato niente.
require_pattern \
  'alter table kal_tracker\.body_measurements[[:space:]]+add constraint body_measurements_owner_id_id_key unique \(owner_id, id\);.*create table kal_tracker\.body_measurement_values' \
  'the unique (owner_id, id) on body_measurements, before the table that references it'
require_in_table body_measurement_values \
  'references kal_tracker\.body_measurements\(owner_id, id\)' \
  'the foreign key to the parent measurement'

# Le colonne del protocollo di sincronizzazione: senza di loro prepare_write
# solleva 23502 e la riga non entra, oppure record_sync_change non produce
# nessuna voce nel ledger e la modifica non raggiunge il secondo dispositivo.
for table in "${tables[@]}"; do
  require_in_table "$table" '^  id uuid primary key,$' 'the surrogate id'
  require_in_table "$table" 'owner_id uuid not null default auth\.uid\(\)' \
    'the owner column'
  require_in_table "$table" 'last_mutation_id uuid not null' \
    'the mutation id'
  require_in_table "$table" 'row_version bigint not null default 1 check \(row_version > 0\)' \
    'the row version'
  require_in_table "$table" '^  deleted_at timestamptz,?$' 'the tombstone'
  require_in_table "$table" 'unique \(owner_id, last_mutation_id\)' \
    'the mutation uniqueness'
done

# Ogni FK composita ha bisogno del proprio unique (owner_id, id) sul padre.
for table in exercises routines workouts workout_exercises; do
  require_in_table "$table" 'unique \(owner_id, id\)' \
    'the unique pair the child foreign keys point at'
done

# L'import non deve poter raddoppiare lo storico al secondo lancio.
for table in exercises routines workouts; do
  require_in_table "$table" 'unique \(owner_id, source, external_id\)' \
    'the import-idempotency uniqueness'
done

# Trigger e RLS: la lista va tenuta allineata alle tredici tabelle, altrimenti
# una tabella resta senza ledger o senza isolamento fra utenti.
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
grep -q 'prepare_write' <<<"$triggers_block" || fail 'missing the prepare_write trigger'
grep -q 'record_sync_change' <<<"$triggers_block" \
  || fail 'missing the record_sync_change trigger'
require_pattern "using \\(owner_id = \\(select auth\\.uid\\(\\)\\)\\)" \
  'the owner check in the policies'

# Una sola sessione aperta per profilo: in Firestore era un documento puntatore
# da riconciliare a mano.
require_pattern \
  'create unique index workouts_one_active_idx[[:space:]]+on kal_tracker\.workouts\(owner_id, profile_id\)[[:space:]]+where deleted_at is null and ended_at is null;' \
  'the single-open-session index'

# L'unicità delle posizioni vale solo fra le righe vive: senza il filtro, la
# sostituzione in blocco dei figli sbatterebbe contro i propri tombstone.
for index in routine_exercises_position_idx workout_exercises_position_idx \
  workout_sets_position_idx routine_weekly_plan_day_idx \
  workout_interval_segments_index_idx workout_achievements_slug_idx \
  body_measurement_values_label_idx workout_profile_stats_profile_idx; do
  # [^;] confina il confronto alla singola CREATE INDEX: con un `.*` il filtro
  # dell'indice successivo farebbe passare un indice che il proprio l'ha perso.
  require_pattern "create unique index ${index}[^;]*where deleted_at is null" \
    "the partial unique index ${index}"
done

# L'id originale dell'esercizio è la chiave di raggruppamento del dominio
# (record personali, calorie): se diventasse nullabile, due esercizi cancellati
# diversi collasserebbero nella stessa voce.
for table in routine_exercises workout_exercises; do
  require_in_table "$table" 'exercise_ref_id uuid not null' \
    'the non-nullable original exercise id'
  require_in_table "$table" 'exercise_name_snapshot text not null' \
    'the frozen exercise name'
done
require_in_table workout_exercises 'tracking_mode text not null' \
  'the tracking mode effective in that session'

# I due marker dei blocchi a tempo restano indipendenti: comprimerli in una
# colonna sola manderebbe la ripresa del circuito sulla schermata sbagliata.
require_in_table workout_interval_segments 'completed_marker boolean not null' \
  'the completion marker'
require_in_table workout_interval_segments 'partial_marker boolean not null' \
  'the partial marker'
require_pattern 'workout_interval_segments_has_marker check \([[:space:]]*completed_marker or partial_marker' \
  'the check that rejects a marker-less segment'

# Il giorno dell'ultimo allenamento è una data di calendario, non un istante:
# un timestamptz verrebbe troncato al giorno UTC e spezzerebbe lo streak di
# Marco (mezzanotte di Roma è le 22:00 del giorno prima).
require_in_table workout_profile_stats '^  last_workout_day date,$' \
  'the calendar day of the last workout'
require_in_table workout_profile_stats 'gym_body_weight_kg numeric' \
  'the frozen Gym body weight'
require_in_table workout_profile_stats 'gym_exported_at timestamptz' \
  'the export instant that bounds the imported achievements'

require_pattern 'notify pgrst' 'PostgREST schema reload'
require_pattern 'comment on table kal_tracker\.external_workouts' \
  'the note that supersedes the old external workout bridge'

# Ciò che NON deve esistere.

# Volume, e1RM e record personali sono funzioni dei dati grezzi: salvarli
# creerebbe una seconda verità che invecchia da sola.
refute_pattern '[[:space:]]volume[[:space:]]+(numeric|integer|bigint|real|double)' \
  'a stored volume column (it is weight x reps)'
refute_pattern 'total_volume' 'a stored total volume column'
refute_pattern '[[:space:]]e1rm[[:space:]]' 'a stored one-rep-max estimate'
refute_pattern 'personal_record' 'a stored personal record (it is recomputed from the sets)'
refute_pattern '[[:space:]](duration_minutes|elapsed_seconds)[[:space:]]' \
  'a second duration alongside the raw counters'

# Il tetto di 24 ore sulla durata è una regola di LETTURA: come vincolo
# rifiuterebbe la chiusura della sessione reale rimasta aperta 536 ore.
refute_pattern 'final_duration_seconds[^,]*86400' \
  'a 24-hour cap on the session duration (the clamp belongs to the reader)'
refute_pattern 'accumulated_pause_seconds[^,]*86400' \
  'a 24-hour cap on the accumulated pause'

# total_kcal a tre decimali riscriverebbe sul telefono un valore che il
# modello dichiara immutabile.
refute_pattern 'total_kcal numeric\(10,3\)' \
  'a total_kcal too coarse for the real values (twelve decimals)'

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

echo 'workouts schema static check: ok'
