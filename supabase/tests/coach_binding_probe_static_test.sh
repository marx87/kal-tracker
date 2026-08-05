#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
migration="$repo_root/supabase/migrations/202608050009_coach_binding_probe.sql"

fail() {
  echo "coach binding probe static check: $1" >&2
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
require_pattern 'create or replace function kal_tracker\.coaching_binding_active\(\)[[:space:]]+returns jsonb[[:space:]]+language sql[[:space:]]+stable[[:space:]]+security definer[[:space:]]+set search_path = '\'\''' \
  'hardened read-only probe'
require_pattern 'where b\.worker_user_id = auth\.uid\(\)' \
  'caller-scoped binding lookup'
require_pattern "and b\\.scope = 'coaching'" 'coaching scope filter'
require_pattern 'revoke all privileges on function[[:space:]]+kal_tracker\.coaching_binding_active\(\)[[:space:]]+from public, anon, authenticated' \
  'privilege revocation'
require_pattern 'grant execute on function[[:space:]]+kal_tracker\.coaching_binding_active\(\)[[:space:]]+to authenticated' \
  'authenticated-only grant'
require_pattern "notify pgrst, 'reload schema'" 'PostgREST schema reload'

# **Il punto di questa migrazione**: la diagnostica non scrive. Se qui
# comparisse una scrittura, il doctor tornerebbe a consumare i tentativi dei
# job veri di Marco.
if has_pattern '(insert|update|delete|truncate)[[:space:]]+' insensitive; then
  fail 'a write statement in a read-only probe'
fi

if has_pattern 'volatile' insensitive; then
  fail 'a volatile probe: the function must stay read-only'
fi

if has_pattern \
  'grant[[:space:][:print:]]*to[[:space:]]+(anon|public|service_role)' \
  insensitive; then
  fail 'a grant to anon, public, or service_role'
fi

if has_pattern 'service_role' insensitive; then
  fail 'service_role reference in worker migration'
fi

echo 'coach binding probe static check: ok'
