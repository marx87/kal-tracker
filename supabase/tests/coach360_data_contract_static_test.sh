#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
migration="$repo_root/supabase/migrations/202608080012_coach360_data_contract.sql"

fail() {
  echo "coach360 data contract static check: $1" >&2
  exit 1
}

require() {
  local pattern="$1"
  local description="$2"
  rg --quiet --multiline --multiline-dotall "$pattern" "$migration" \
    || fail "missing $description"
}

[[ -f "$migration" ]] || fail 'migration file'
require '^begin;.*commit;[[:space:]]*$' 'transaction boundary'
require 'alter table kal_tracker\.daily_check_ins.*add column if not exists steps' \
  'steps on check-ins'
require 'daily_check_ins_not_blank check \(.*steps is not null.*walk_minutes is not null' \
  'expanded non-empty check-in constraint'

tables=(
  training_profiles
  training_limitations
  daily_health_summaries
  coach_feed_items
)
for table in "${tables[@]}"; do
  require "create table kal_tracker\\.${table}" "${table} table"
  require "create table kal_tracker\\.${table}.*owner_id uuid not null default auth\\.uid\\(\\).*last_mutation_id uuid not null.*row_version bigint not null.*deleted_at timestamptz" \
    "${table} sync columns"
  require "'${table}'" "${table} trigger/policy registration"
  require "kal_tracker\\.${table}" "${table} grants"
done

require 'daily_health_summaries_not_blank check' \
  'non-empty health summary constraint'
require "source text not null check \(source in \('deterministic', 'ai'\)\)" \
  'closed coach feed provenance'
require 'execute function kal_tracker\.prepare_write\(\)' 'prepare trigger'
require 'execute function kal_tracker\.record_sync_change\(\)' \
  'change-ledger trigger'
require 'enable row level security' 'row level security'
require 'using \(owner_id = \(select auth\.uid\(\)\)\)' 'owner policy'
require "notify pgrst, 'reload schema'" 'PostgREST reload'

if rg --quiet --ignore-case 'for delete to authenticated|drop table|drop column' "$migration"; then
  fail 'destructive operation or DELETE policy'
fi

echo 'coach360 data contract static check: ok'
