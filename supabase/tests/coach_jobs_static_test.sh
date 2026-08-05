#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
migration="$repo_root/supabase/migrations/202608050008_coach_jobs.sql"

fail() {
  echo "coach queue static check: $1" >&2
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

[[ -f "$migration" ]] || fail "migration file"

require_pattern '^begin;.*commit;[[:space:]]*$' 'transaction boundary'
require_pattern 'create table kal_tracker\.coach_jobs' 'coach queue table'
require_pattern 'request jsonb not null check \([[:space:]]+jsonb_typeof\(request\) = '\''object'\''.*?octet_length\(request::text\) <= 524288' \
  'bounded request payload'
require_pattern 'constraint coach_jobs_profile_fk[[:space:]]+foreign key \(owner_id, profile_id\)[[:space:]]+references kal_tracker\.profiles\(owner_id, id\)[[:space:]]+on delete cascade' \
  'owner-scoped profile foreign key'
require_pattern 'constraint coach_jobs_lease_check' 'lease consistency check'
require_pattern 'constraint coach_jobs_timestamps_check' 'timestamp ordering check'
require_pattern 'last_mutation_id uuid not null.*?row_version bigint not null default 1 check \(row_version > 0\).*?deleted_at timestamptz' \
  'sync bookkeeping columns'
require_pattern 'do \$triggers\$.*?'\''coach_jobs'\''.*?kal_tracker\.prepare_write\(\).*?kal_tracker\.record_sync_change\(\)' \
  'sync triggers on the queue table'
require_pattern 'create index coach_jobs_queue_idx.*?where deleted_at is null and status in \('\''queued'\'', '\''claimed'\'', '\''processing'\''\)' \
  'partial queue index'

require_pattern 'alter table kal_tracker\.coach_jobs enable row level security' \
  'queue-table RLS'
require_pattern 'create policy coach_jobs_select_own' 'owner-only select policy'
require_pattern 'grant insert \([[:space:]]+id,[[:space:]]+owner_id,[[:space:]]+profile_id,[[:space:]]+request,[[:space:]]+last_mutation_id[[:space:]]+\) on kal_tracker\.coach_jobs[[:space:]]+to authenticated' \
  'column-limited job enqueue grant'
require_pattern 'create policy coach_jobs_enqueue_own.*?status = '\''queued'\''.*?claimed_by is null.*?attempt_count = 0.*?result is null' \
  'strict queued-job insert policy'

require_pattern 'alter table kal_tracker\.automation_bindings[[:space:]]+add constraint automation_bindings_scope_check[[:space:]]+check \(scope in \('\''meal_analysis'\'', '\''meal_planning'\'', '\''coaching'\''\)\)' \
  'automation scope extended to coaching'
require_pattern 'create table kal_tracker\.automation_coach_rpc_mutations' \
  'private idempotency ledger for the coach queue'
require_pattern 'job_id uuid not null references kal_tracker\.coach_jobs\(id\)[[:space:]]+on delete restrict' \
  'ledger foreign key on the coach queue'
require_pattern 'alter table kal_tracker\.automation_coach_rpc_mutations[[:space:]]+enable row level security' \
  'ledger RLS'
require_pattern 'revoke all privileges on kal_tracker\.automation_coach_rpc_mutations[[:space:]]+from public, anon, authenticated' \
  'ledger privilege revocation'

require_pattern 'for update of j skip locked' 'atomic SKIP LOCKED claim'
require_pattern "scope = 'coaching'" 'scope checks'
require_pattern 'lease_expires_at <= v_now' 'expired-lease reclaim'
require_pattern 'claimed_by is distinct from v_actor_id' 'lease ownership checks'
require_pattern 'pg_advisory_xact_lock' 'idempotent retry serialization'
require_pattern 'request_payload is distinct from v_request' \
  'mutation request replay validation'
require_pattern "raise exception 'coach job not found' using errcode = 'P0002'" \
  'missing-job error code'
require_pattern "set status = 'needs_review'" 'review-before-archive state'

# **Il cuore di questa coda**: dal Mac torna solo testo. Non e' un'intenzione
# scritta in un commento, e' un vincolo del database.
require_pattern 'create or replace function kal_tracker\.coach_result_is_text_only\([[:space:]]*p_result jsonb[[:space:]]*\)[[:space:]]+returns boolean[[:space:]]+language sql[[:space:]]+immutable[[:space:]]+strict[[:space:]]+set search_path = '\'\''' \
  'immutable text-only predicate'
require_pattern "jsonb_typeof\\(field\\.value\\) = 'string'" \
  'string check on top-level values'
require_pattern "jsonb_typeof\\(item\\.value\\) = 'string'" \
  'string check inside arrays'
require_pattern 'and kal_tracker\.coach_result_is_text_only\(result\)' \
  'text-only CHECK on the result column'
require_pattern 'if not kal_tracker\.coach_result_is_text_only\(p_result\) then' \
  'text-only refusal inside complete_coach_job'

for function_name in \
  claim_coach_job \
  heartbeat_coach_job \
  complete_coach_job \
  fail_coach_job
do
  require_pattern "create or replace function kal_tracker\\.${function_name}\\(.*?security definer.*?set search_path = ''" \
    "hardened ${function_name} function"
  require_pattern "revoke all privileges on function[[:space:]]+kal_tracker\\.${function_name}\\(" \
    "privilege revocation for ${function_name}"
done

require_pattern 'grant execute on function.*to authenticated;' \
  'authenticated-only RPC grants'
require_pattern "notify pgrst, 'reload schema'" 'PostgREST schema reload'

# Il coach non dichiara MAI un numero: nessuna colonna nutrizionale o di peso
# in questa coda. I numeri viaggiano dentro `request` — dall'app al Mac, mai
# al contrario — e li calcola il motore deterministico sul telefono.
if has_pattern \
  '(kcal|calorie|protein|carb|macro|weight|tdee|deficit)[a-z_]*[[:space:]]+(numeric|integer|real|double|bigint)' \
  insensitive; then
  fail 'a metric column in the coach queue: every number comes from the app'
fi

if has_pattern \
  'grant[[:space:][:print:]]*to[[:space:]]+(anon|public|service_role)' \
  insensitive; then
  fail 'an RPC/table grant to anon, public, or service_role'
fi

if has_pattern 'service_role' insensitive; then
  fail 'service_role reference in worker migration'
fi

if has_pattern \
  'grant[[:space:]]+(all|update|delete|truncate|references|trigger)[^;]*to[[:space:]]+authenticated' \
  insensitive; then
  fail 'an over-broad grant to authenticated: the client never updates a job'
fi

if has_pattern 'for delete to' insensitive; then
  fail 'a delete policy: rows are removed with tombstones'
fi

if has_pattern 'disable row level security' insensitive; then
  fail 'a row-level-security downgrade'
fi

echo 'coach queue static check: ok'
