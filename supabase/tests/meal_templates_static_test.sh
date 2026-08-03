#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
migration="$repo_root/supabase/migrations/202608030004_meal_templates.sql"

fail() {
  echo "meal-templates schema static check: $1" >&2
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
require_pattern 'create table kal_tracker\.meal_templates' \
  'meal_templates table'
require_pattern 'create table kal_tracker\.meal_template_items' \
  'meal_template_items table'
require_pattern 'alter table kal_tracker\.recipes[[:space:]]+add column tags text' \
  'recipes tags column'
require_pattern 'tags is null.*?char_length\(tags\) <= 240.*?tags = lower\(tags\)' \
  'lowercase 240-character tag constraint'

require_pattern 'constraint meal_templates_profile_fk[[:space:]]+foreign key \(owner_id, profile_id\)[[:space:]]+references kal_tracker\.profiles\(owner_id, id\)[[:space:]]+on delete cascade' \
  'owner-scoped profile foreign key'
require_pattern 'constraint meal_template_items_template_fk[[:space:]]+foreign key \(owner_id, template_id\)[[:space:]]+references kal_tracker\.meal_templates\(owner_id, id\)[[:space:]]+on delete cascade' \
  'owner-scoped template foreign key'

require_pattern 'create table kal_tracker\.meal_templates.*?last_mutation_id uuid not null.*?row_version bigint not null default 1 check \(row_version > 0\).*?deleted_at timestamptz' \
  'sync bookkeeping columns on meal_templates'
require_pattern 'create table kal_tracker\.meal_template_items.*?last_mutation_id uuid not null.*?row_version bigint not null default 1 check \(row_version > 0\).*?deleted_at timestamptz' \
  'sync bookkeeping columns on meal_template_items'

require_pattern "meal_type in \\('breakfast', 'lunch', 'dinner', 'snack', 'other'\\)" \
  'meal_type domain check'
require_pattern 'position integer not null check \(position >= 0\)' \
  'non-negative position check'
require_pattern 'quantity_g numeric\(12,3\) not null check \(quantity_g > 0\)' \
  'positive quantity check'
require_pattern 'constraint meal_template_items_nutrients_non_negative check' \
  'non-negative nutrient snapshot check'

require_pattern 'create index meal_templates_updated_idx[[:space:]]+on kal_tracker\.meal_templates\(owner_id, profile_id, updated_at desc\)[[:space:]]+where deleted_at is null' \
  'template lookup index'
require_pattern 'create unique index meal_template_items_position_idx[[:space:]]+on kal_tracker\.meal_template_items\(owner_id, template_id, position\)[[:space:]]+where deleted_at is null' \
  'unique live (template_id, position) index'

require_pattern 'do \$triggers\$.*?'\''meal_templates'\'',.*?'\''meal_template_items'\''.*?kal_tracker\.prepare_write\(\).*?kal_tracker\.record_sync_change\(\)' \
  'sync triggers on both tables'

require_pattern 'do \$policies\$.*?'\''meal_templates'\'',.*?'\''meal_template_items'\''.*?enable row level security' \
  'row level security on both tables'
require_pattern 'for select to authenticated .*?using \(owner_id = \(select auth\.uid\(\)\)\)' \
  'owner-only select policy'
require_pattern 'for insert to authenticated .*?with check \(owner_id = \(select auth\.uid\(\)\)\)' \
  'owner-only insert policy'
require_pattern 'for update to authenticated .*?using \(owner_id = \(select auth\.uid\(\)\)\) .*?with check \(owner_id = \(select auth\.uid\(\)\)\)' \
  'owner-only update policy'

require_pattern 'grant select, insert, update[[:space:]]+on kal_tracker\.meal_templates,[[:space:]]+kal_tracker\.meal_template_items[[:space:]]+to authenticated' \
  'minimal authenticated grant'
require_pattern 'grant all on[[:space:]]+kal_tracker\.meal_templates,[[:space:]]+kal_tracker\.meal_template_items[[:space:]]+to service_role' \
  'service_role maintenance grant'
require_pattern "notify pgrst, 'reload schema'" 'PostgREST schema reload'

if has_pattern 'grant[^;]*to[[:space:]]+(anon|public)' insensitive; then
  fail 'a grant to anon or public'
fi

if has_pattern \
  'grant[[:space:]]+(all|delete|truncate|references|trigger)[^;]*to[[:space:]]+authenticated' \
  insensitive; then
  fail 'an over-broad grant to authenticated'
fi

if has_pattern 'for delete to' insensitive; then
  fail 'a delete policy: rows are removed with tombstones'
fi

if has_pattern 'disable row level security' insensitive; then
  fail 'a row-level-security downgrade'
fi

if has_pattern 'drop policy' insensitive; then
  fail 'a policy removal in a schema-only migration'
fi

if has_pattern 'security definer' insensitive; then
  fail 'a SECURITY DEFINER object in a schema-only migration'
fi

if has_pattern 'alter default privileges' insensitive; then
  fail 'a default-privilege change'
fi

echo 'meal-templates schema static check: ok'
