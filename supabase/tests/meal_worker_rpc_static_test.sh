#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
migration="$repo_root/supabase/migrations/202608020003_meal_worker_rpc.sql"

fail() {
  echo "meal-worker RPC static check: $1" >&2
  exit 1
}

require_pattern() {
  local pattern="$1"
  local description="$2"
  rg --quiet --multiline --multiline-dotall "$pattern" "$migration" \
    || fail "missing $description"
}

[[ -f "$migration" ]] || fail "migration file"

require_pattern '^begin;.*commit;[[:space:]]*$' 'transaction boundary'
require_pattern 'create table kal_tracker\.automation_bindings' \
  'private binding table'
require_pattern 'create table kal_tracker\.automation_rpc_mutations' \
  'private idempotency ledger'
require_pattern 'alter table kal_tracker\.automation_bindings enable row level security' \
  'binding-table RLS'
require_pattern 'revoke all privileges on kal_tracker\.automation_bindings[[:space:]]+from public, anon, authenticated' \
  'binding-table privilege revocation'
require_pattern 'revoke insert, update on kal_tracker\.meal_analysis_jobs[[:space:]]+from authenticated' \
  'direct job-mutation revocation'
require_pattern 'drop policy meal_analysis_jobs_update_own' \
  'owner update-policy removal'
require_pattern 'grant insert \([[:space:]]+id,.*?last_mutation_id[[:space:]]+\) on kal_tracker\.meal_analysis_jobs[[:space:]]+to authenticated' \
  'column-limited job enqueue grant'
require_pattern 'create policy meal_analysis_jobs_enqueue_own.*?status = '\''queued'\''.*?claimed_by is null.*?analysis_result is null' \
  'strict queued-job insert policy'
require_pattern 'for update of j skip locked' 'atomic SKIP LOCKED claim'
require_pattern "scope = 'meal_analysis'" 'scope checks'
require_pattern 'lease_expires_at <= v_now' 'expired-lease reclaim'
require_pattern 'claimed_by is distinct from v_actor_id' \
  'lease ownership checks'
require_pattern 'pg_advisory_xact_lock' 'idempotent retry serialization'
require_pattern 'request_payload is distinct from v_request' \
  'mutation request replay validation'
require_pattern "set status = 'needs_review'" 'review-before-confirmation state'
require_pattern 'create policy kal_tracker_meal_photos_select_leased_worker' \
  'lease-limited Storage policy'

for function_name in \
  claim_meal_analysis_job \
  heartbeat_meal_analysis_job \
  complete_meal_analysis_job \
  fail_meal_analysis_job \
  worker_can_read_meal_photo
do
  require_pattern "create or replace function kal_tracker\\.${function_name}\\(.*?security definer.*?set search_path = ''" \
    "hardened ${function_name} function"
done

require_pattern 'grant execute on function.*to authenticated;' \
  'authenticated-only RPC grants'

if rg --quiet --ignore-case --multiline --multiline-dotall \
  'grant[[:space:][:print:]]*to[[:space:]]+(anon|public|service_role)' \
  "$migration"; then
  fail 'an RPC/table grant to anon, public, or service_role'
fi

if rg --quiet --ignore-case 'service_role' "$migration"; then
  fail 'service_role reference in worker migration'
fi

echo 'meal-worker RPC static check: ok'
