begin;

-- Remote counterpart of the local Drift tables meal_templates and
-- meal_template_items. A template is a reusable meal ("pranzo tipo"): applying
-- it creates ordinary meals and meal_items, so the template itself never owns
-- diary history. Items carry the same nutrient snapshots as recipe_items,
-- which keeps the deterministic calculation identical on both sides.
create table kal_tracker.meal_templates (
  id uuid primary key,
  owner_id uuid not null default auth.uid(),
  profile_id uuid not null,
  name text not null check (btrim(name) <> '' and char_length(name) <= 80),
  meal_type text not null
    check (meal_type in ('breakfast', 'lunch', 'dinner', 'snack', 'other')),
  last_mutation_id uuid not null,
  row_version bigint not null default 1 check (row_version > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  constraint meal_templates_profile_fk
    foreign key (owner_id, profile_id)
    references kal_tracker.profiles(owner_id, id)
    on delete cascade,
  unique (owner_id, id),
  unique (owner_id, last_mutation_id)
);

create table kal_tracker.meal_template_items (
  id uuid primary key,
  owner_id uuid not null default auth.uid(),
  template_id uuid not null,
  position integer not null check (position >= 0),
  quantity_g numeric(12,3) not null check (quantity_g > 0),
  food_name_snapshot text not null check (
    btrim(food_name_snapshot) <> ''
    and char_length(food_name_snapshot) <= 160
  ),
  energy_kcal_per_100g numeric(10,3) not null,
  protein_g_per_100g numeric(10,3) not null,
  carbohydrate_g_per_100g numeric(10,3) not null,
  fat_g_per_100g numeric(10,3) not null,
  fiber_g_per_100g numeric(10,3) not null default 0,
  last_mutation_id uuid not null,
  row_version bigint not null default 1 check (row_version > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  constraint meal_template_items_template_fk
    foreign key (owner_id, template_id)
    references kal_tracker.meal_templates(owner_id, id)
    on delete cascade,
  constraint meal_template_items_nutrients_non_negative check (
    energy_kcal_per_100g >= 0
    and protein_g_per_100g >= 0
    and carbohydrate_g_per_100g >= 0
    and fat_g_per_100g >= 0
    and fiber_g_per_100g >= 0
  ),
  unique (owner_id, last_mutation_id)
);

-- Recipe tags are the lowercase, comma separated list stored locally in
-- fit_recipes.tags. Empty segments are rejected so a tag filter can rely on
-- string_to_array without cleaning the value first.
alter table kal_tracker.recipes
  add column tags text
  constraint recipes_tags_lowercase_csv_check check (
    tags is null
    or (
      btrim(tags) <> ''
      and char_length(tags) <= 240
      and tags = lower(tags)
      and tags ~ '^[^,]+(,[^,]+)*$'
    )
  );

do $triggers$
declare
  table_name text;
begin
  foreach table_name in array array[
    'meal_templates',
    'meal_template_items'
  ] loop
    execute format(
      'create trigger %I before insert or update on kal_tracker.%I '
      'for each row execute function kal_tracker.prepare_write()',
      table_name || '_prepare_write',
      table_name
    );
    execute format(
      'create trigger %I after insert or update on kal_tracker.%I '
      'for each row execute function kal_tracker.record_sync_change()',
      table_name || '_record_change',
      table_name
    );
  end loop;
end;
$triggers$;

create index meal_templates_updated_idx
  on kal_tracker.meal_templates(owner_id, profile_id, updated_at desc)
  where deleted_at is null;

-- Uniqueness of (template_id, position) holds across live rows only: replacing
-- the items of a template writes tombstones that keep their old position, like
-- recipe_items. The partial index is also the ordered read path.
create unique index meal_template_items_position_idx
  on kal_tracker.meal_template_items(owner_id, template_id, position)
  where deleted_at is null;

do $policies$
declare
  table_name text;
begin
  foreach table_name in array array[
    'meal_templates',
    'meal_template_items'
  ] loop
    execute format(
      'alter table kal_tracker.%I enable row level security',
      table_name
    );
    execute format(
      'create policy %I on kal_tracker.%I for select to authenticated '
      'using (owner_id = (select auth.uid()))',
      table_name || '_select_own',
      table_name
    );
    execute format(
      'create policy %I on kal_tracker.%I for insert to authenticated '
      'with check (owner_id = (select auth.uid()))',
      table_name || '_insert_own',
      table_name
    );
    execute format(
      'create policy %I on kal_tracker.%I for update to authenticated '
      'using (owner_id = (select auth.uid())) '
      'with check (owner_id = (select auth.uid()))',
      table_name || '_update_own',
      table_name
    );
  end loop;
end;
$policies$;

grant select, insert, update
  on kal_tracker.meal_templates,
     kal_tracker.meal_template_items
  to authenticated;

grant all on
  kal_tracker.meal_templates,
  kal_tracker.meal_template_items
  to service_role;

notify pgrst, 'reload schema';

commit;
