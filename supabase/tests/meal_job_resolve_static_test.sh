#!/usr/bin/env bash
set -euo pipefail

# La RPC che chiude una proposta foto è l'unico punto in cui il proprietario
# tocca `meal_analysis_jobs`, e per questo va tenuta stretta: deve poter fare
# una cosa sola, su un job suo, e solo dal punto in cui ha senso farla.
#
# Il controllo è statico perché non c'è un Postgres nei test — è lo stesso
# patto delle altre migrazioni di questa cartella, e vale finché la RPC non
# viene provata contro un database vero.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
migration="$repo_root/supabase/migrations/202608060011_meal_job_resolve.sql"

fail() {
  echo "meal job resolve static check: $1" >&2
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

require() {
  local pattern="$1"
  local message="$2"
  local case_mode="${3:-sensitive}"
  has_pattern "$pattern" "$case_mode" || fail "$message"
}

[[ -f "$migration" ]] || fail 'migration file missing'

require 'security[[:space:]]+definer' \
  'the function must run as definer: the client has no update grant' \
  insensitive

require 'set[[:space:]]+search_path' \
  'a pinned search_path: a definer function without one is hijackable' \
  insensitive

require 'owner_id[[:space:]]*=[[:space:]]*v_owner' \
  'the ownership check: any job could be closed by anyone' \
  insensitive

require 'for[[:space:]]+update' \
  'the row lock: two devices can resolve the same job at once' \
  insensitive

require "v_status[[:space:]]*<>[[:space:]]*'needs_review'" \
  'the guard against resolving a job still queued or in flight' \
  insensitive

require 'grant[[:space:]]+execute[[:print:][:space:]]*to[[:space:]]+authenticated' \
  'the execute grant to authenticated' \
  insensitive

# --- e quello che NON deve esserci ---------------------------------------

if has_pattern \
  'grant[[:space:][:print:]]*to[[:space:]]+(anon|public|service_role)' \
  insensitive; then
  fail 'a grant to anon, public, or service_role'
fi

if has_pattern \
  'grant[[:space:]]+(all|update|delete|insert|truncate)[^;]*on[[:space:]]+kal_tracker\.meal_analysis_jobs' \
  insensitive; then
  fail 'a table grant: the owner closes a job through the RPC, never directly'
fi

if has_pattern 'analysis_result[[:space:]]*=' insensitive; then
  fail 'a write to analysis_result: only the worker produces it'
fi

if has_pattern 'claimed_by[[:space:]]*=' insensitive; then
  fail 'a write to claimed_by: that would be impersonating the worker'
fi

if has_pattern 'disable row level security' insensitive; then
  fail 'a row-level-security downgrade'
fi

echo 'meal job resolve static check: ok'
