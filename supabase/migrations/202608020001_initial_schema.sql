begin;

create schema if not exists kal_tracker;

create table kal_tracker.profiles (
  id uuid primary key,
  owner_id uuid not null default auth.uid()
    references auth.users(id) on delete cascade,
  display_name text not null check (btrim(display_name) <> ''),
  time_zone text not null default 'Europe/Rome'
    check (btrim(time_zone) <> ''),
  locale text not null default 'it_IT' check (btrim(locale) <> ''),
  last_mutation_id uuid not null,
  row_version bigint not null default 1 check (row_version > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  unique (owner_id),
  unique (owner_id, id),
  unique (owner_id, last_mutation_id)
);

create table kal_tracker.nutrition_targets (
  id uuid primary key,
  owner_id uuid not null default auth.uid(),
  profile_id uuid not null,
  effective_from date not null,
  goal_type text not null default 'maintain'
    check (goal_type in ('lose', 'maintain', 'gain')),
  energy_kcal numeric(9,2) not null check (energy_kcal > 0),
  protein_g numeric(9,2) not null check (protein_g >= 0),
  carbohydrate_g numeric(9,2) not null check (carbohydrate_g >= 0),
  fat_g numeric(9,2) not null check (fat_g >= 0),
  fiber_g numeric(9,2) not null default 0 check (fiber_g >= 0),
  water_ml integer check (water_ml is null or water_ml >= 0),
  notes text,
  last_mutation_id uuid not null,
  row_version bigint not null default 1 check (row_version > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  constraint nutrition_targets_profile_fk
    foreign key (owner_id, profile_id)
    references kal_tracker.profiles(owner_id, id)
    on delete cascade,
  unique (owner_id, profile_id, effective_from),
  unique (owner_id, last_mutation_id)
);

create table kal_tracker.foods (
  id uuid primary key,
  owner_id uuid not null default auth.uid()
    references auth.users(id) on delete cascade,
  name text not null check (btrim(name) <> ''),
  brand text,
  barcode text,
  source text not null default 'personal' check (btrim(source) <> ''),
  external_id text check (external_id is null or btrim(external_id) <> ''),
  source_version text,
  preparation_state text not null default 'unspecified'
    check (preparation_state in ('raw', 'cooked', 'prepared', 'unspecified')),
  data_quality text not null default 'personal'
    check (data_quality in ('verified', 'curated', 'personal', 'unverified')),
  serving_label text,
  serving_size_g numeric(10,3)
    check (serving_size_g is null or serving_size_g > 0),
  is_favorite boolean not null default false,
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
  constraint foods_nutrients_non_negative check (
    energy_kcal_per_100g >= 0
    and protein_g_per_100g >= 0
    and carbohydrate_g_per_100g >= 0
    and fat_g_per_100g >= 0
    and fiber_g_per_100g >= 0
  ),
  unique (owner_id, id),
  unique (owner_id, source, external_id),
  unique (owner_id, last_mutation_id)
);

create table kal_tracker.meals (
  id uuid primary key,
  owner_id uuid not null default auth.uid(),
  profile_id uuid not null,
  eaten_at timestamptz not null,
  local_date date not null,
  time_zone text not null default 'Europe/Rome'
    check (btrim(time_zone) <> ''),
  meal_type text not null
    check (meal_type in ('breakfast', 'lunch', 'dinner', 'snack', 'other')),
  title text,
  notes text,
  entry_source text not null default 'manual'
    check (entry_source in ('manual', 'barcode', 'photo', 'recipe', 'copied')),
  status text not null default 'confirmed'
    check (status in ('draft', 'confirmed')),
  last_mutation_id uuid not null,
  row_version bigint not null default 1 check (row_version > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  constraint meals_profile_fk
    foreign key (owner_id, profile_id)
    references kal_tracker.profiles(owner_id, id)
    on delete cascade,
  unique (owner_id, id),
  unique (owner_id, last_mutation_id)
);

create table kal_tracker.meal_items (
  id uuid primary key,
  owner_id uuid not null default auth.uid(),
  meal_id uuid not null,
  food_id uuid,
  position integer not null default 0 check (position >= 0),
  quantity_value numeric(12,3) not null check (quantity_value > 0),
  quantity_unit text not null default 'g' check (btrim(quantity_unit) <> ''),
  quantity_g numeric(12,3) not null check (quantity_g > 0),
  food_name_snapshot text not null check (btrim(food_name_snapshot) <> ''),
  brand_snapshot text,
  food_source_snapshot text not null check (btrim(food_source_snapshot) <> ''),
  food_source_version_snapshot text,
  energy_kcal_per_100g numeric(10,3) not null,
  protein_g_per_100g numeric(10,3) not null,
  carbohydrate_g_per_100g numeric(10,3) not null,
  fat_g_per_100g numeric(10,3) not null,
  fiber_g_per_100g numeric(10,3) not null default 0,
  energy_kcal numeric generated always as (
    quantity_g * energy_kcal_per_100g / 100
  ) stored,
  protein_g numeric generated always as (
    quantity_g * protein_g_per_100g / 100
  ) stored,
  carbohydrate_g numeric generated always as (
    quantity_g * carbohydrate_g_per_100g / 100
  ) stored,
  fat_g numeric generated always as (
    quantity_g * fat_g_per_100g / 100
  ) stored,
  fiber_g numeric generated always as (
    quantity_g * fiber_g_per_100g / 100
  ) stored,
  notes text,
  last_mutation_id uuid not null,
  row_version bigint not null default 1 check (row_version > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  constraint meal_items_meal_fk
    foreign key (owner_id, meal_id)
    references kal_tracker.meals(owner_id, id)
    on delete cascade,
  constraint meal_items_food_fk
    foreign key (owner_id, food_id)
    references kal_tracker.foods(owner_id, id),
  constraint meal_items_nutrients_non_negative check (
    energy_kcal_per_100g >= 0
    and protein_g_per_100g >= 0
    and carbohydrate_g_per_100g >= 0
    and fat_g_per_100g >= 0
    and fiber_g_per_100g >= 0
  ),
  unique (owner_id, last_mutation_id)
);

create table kal_tracker.sync_changes (
  change_id bigint generated always as identity primary key,
  owner_id uuid not null references auth.users(id) on delete cascade,
  entity_type text not null check (btrim(entity_type) <> ''),
  entity_id uuid not null,
  operation text not null check (operation in ('upsert', 'delete')),
  row_version bigint not null check (row_version > 0),
  mutation_id uuid not null,
  payload jsonb not null,
  changed_at timestamptz not null default clock_timestamp(),
  unique (owner_id, entity_type, mutation_id)
);

create or replace function kal_tracker.prepare_write()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  applied_entity_id uuid;
  write_time timestamptz;
begin
  if new.owner_id is null then
    new.owner_id := auth.uid();
  end if;

  if new.id is null or new.owner_id is null or new.last_mutation_id is null then
    raise exception 'id, owner_id and last_mutation_id are required'
      using errcode = '23502';
  end if;

  if tg_op = 'UPDATE' then
    if new.id is distinct from old.id
       or new.owner_id is distinct from old.owner_id then
      raise exception 'id and owner_id are immutable'
        using errcode = '22023';
    end if;
  end if;

  select sc.entity_id
    into applied_entity_id
  from kal_tracker.sync_changes sc
  where sc.owner_id = new.owner_id
    and sc.entity_type = tg_table_name
    and sc.mutation_id = new.last_mutation_id;

  if found then
    if applied_entity_id is distinct from new.id then
      raise exception
        'mutation_id % was already used for another % row',
        new.last_mutation_id,
        tg_table_name
        using errcode = '23505';
    end if;

    -- Retry idempotente: first write wins e il trigger AFTER non viene eseguito.
    return null;
  end if;

  write_time := clock_timestamp();

  if tg_op = 'UPDATE' then
    if new.last_mutation_id = old.last_mutation_id then
      raise exception
        'last_mutation_id is unchanged but missing from sync ledger'
        using errcode = '22023';
    end if;
    new.created_at := old.created_at;
    new.row_version := old.row_version + 1;
  else
    new.created_at := write_time;
    new.row_version := 1;
  end if;

  new.updated_at := write_time;
  return new;
end;
$$;

create or replace function kal_tracker.record_sync_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into kal_tracker.sync_changes (
    owner_id,
    entity_type,
    entity_id,
    operation,
    row_version,
    mutation_id,
    payload
  ) values (
    new.owner_id,
    tg_table_name,
    new.id,
    case when new.deleted_at is null then 'upsert' else 'delete' end,
    new.row_version,
    new.last_mutation_id,
    to_jsonb(new)
  );
  return new;
end;
$$;

do $triggers$
declare
  table_name text;
begin
  foreach table_name in array array[
    'profiles',
    'nutrition_targets',
    'foods',
    'meals',
    'meal_items'
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

create index nutrition_targets_effective_idx
  on kal_tracker.nutrition_targets(owner_id, profile_id, effective_from desc)
  where deleted_at is null;
create index foods_name_idx
  on kal_tracker.foods(owner_id, lower(name))
  where deleted_at is null;
create index foods_barcode_idx
  on kal_tracker.foods(owner_id, barcode)
  where barcode is not null and deleted_at is null;
create index meals_daily_idx
  on kal_tracker.meals(owner_id, profile_id, local_date, eaten_at)
  where deleted_at is null;
create index meal_items_meal_idx
  on kal_tracker.meal_items(owner_id, meal_id, position)
  where deleted_at is null;
create index sync_changes_cursor_idx
  on kal_tracker.sync_changes(owner_id, change_id);

do $policies$
declare
  table_name text;
begin
  foreach table_name in array array[
    'profiles',
    'nutrition_targets',
    'foods',
    'meals',
    'meal_items'
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

alter table kal_tracker.sync_changes enable row level security;
create policy sync_changes_select_own
  on kal_tracker.sync_changes
  for select to authenticated
  using (owner_id = (select auth.uid()));

revoke all on schema kal_tracker from public, anon;
grant usage on schema kal_tracker to authenticated, service_role;

revoke all on all tables in schema kal_tracker from anon, authenticated;
revoke all on all sequences in schema kal_tracker from anon, authenticated;

grant select, insert, update
  on kal_tracker.profiles,
     kal_tracker.nutrition_targets,
     kal_tracker.foods,
     kal_tracker.meals,
     kal_tracker.meal_items
  to authenticated;
grant select on kal_tracker.sync_changes to authenticated;

grant all on all tables in schema kal_tracker to service_role;
grant all on all sequences in schema kal_tracker to service_role;

revoke execute on function kal_tracker.prepare_write() from public;
revoke execute on function kal_tracker.record_sync_change() from public;

notify pgrst, 'reload schema';

commit;
