begin;

create table kal_tracker.water_logs (
  id uuid primary key,
  owner_id uuid not null default auth.uid(),
  profile_id uuid not null,
  milliliters integer not null check (milliliters > 0 and milliliters <= 10000),
  logged_at timestamptz not null,
  local_date date not null,
  last_mutation_id uuid not null,
  row_version bigint not null default 1 check (row_version > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  constraint water_logs_profile_fk
    foreign key (owner_id, profile_id)
    references kal_tracker.profiles(owner_id, id)
    on delete cascade,
  unique (owner_id, last_mutation_id)
);

create table kal_tracker.body_measurements (
  id uuid primary key,
  owner_id uuid not null default auth.uid(),
  profile_id uuid not null,
  measured_at timestamptz not null,
  weight_kg numeric(7,3) not null check (weight_kg between 20 and 500),
  note text check (note is null or char_length(note) <= 240),
  source text not null default 'kal_tracker' check (btrim(source) <> ''),
  external_id text check (external_id is null or btrim(external_id) <> ''),
  source_updated_at timestamptz,
  last_mutation_id uuid not null,
  row_version bigint not null default 1 check (row_version > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  constraint body_measurements_profile_fk
    foreign key (owner_id, profile_id)
    references kal_tracker.profiles(owner_id, id)
    on delete cascade,
  unique (owner_id, source, external_id),
  unique (owner_id, last_mutation_id)
);

create table kal_tracker.recipes (
  id uuid primary key,
  owner_id uuid not null default auth.uid(),
  profile_id uuid not null,
  name text not null check (btrim(name) <> '' and char_length(name) <= 160),
  description text check (description is null or char_length(description) <= 600),
  instructions text check (instructions is null or char_length(instructions) <= 4000),
  servings integer not null check (servings between 1 and 100),
  prep_minutes integer not null default 0 check (prep_minutes between 0 and 10080),
  is_favorite boolean not null default false,
  last_mutation_id uuid not null,
  row_version bigint not null default 1 check (row_version > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  constraint recipes_profile_fk
    foreign key (owner_id, profile_id)
    references kal_tracker.profiles(owner_id, id)
    on delete cascade,
  unique (owner_id, id),
  unique (owner_id, last_mutation_id)
);

create table kal_tracker.recipe_items (
  id uuid primary key,
  owner_id uuid not null default auth.uid(),
  recipe_id uuid not null,
  food_id uuid,
  position integer not null check (position >= 0),
  quantity_g numeric(12,3) not null check (quantity_g > 0),
  food_name_snapshot text not null
    check (btrim(food_name_snapshot) <> '' and char_length(food_name_snapshot) <= 160),
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
  constraint recipe_items_recipe_fk
    foreign key (owner_id, recipe_id)
    references kal_tracker.recipes(owner_id, id)
    on delete cascade,
  constraint recipe_items_food_fk
    foreign key (owner_id, food_id)
    references kal_tracker.foods(owner_id, id),
  constraint recipe_items_nutrients_non_negative check (
    energy_kcal_per_100g >= 0
    and protein_g_per_100g >= 0
    and carbohydrate_g_per_100g >= 0
    and fat_g_per_100g >= 0
    and fiber_g_per_100g >= 0
  ),
  unique (owner_id, last_mutation_id)
);

create table kal_tracker.external_workouts (
  id uuid primary key,
  owner_id uuid not null default auth.uid(),
  profile_id uuid not null,
  source text not null check (source in ('gym_tracker', 'health_connect', 'healthkit')),
  external_id text not null check (btrim(external_id) <> ''),
  started_at timestamptz not null,
  ended_at timestamptz not null check (ended_at >= started_at),
  duration_seconds integer not null check (duration_seconds >= 0 and duration_seconds <= 86400),
  energy_kcal numeric(10,3) check (energy_kcal is null or energy_kcal >= 0),
  routine_name text check (routine_name is null or char_length(routine_name) <= 160),
  rpe integer check (rpe is null or rpe between 1 and 10),
  source_updated_at timestamptz,
  raw_summary jsonb not null default '{}'::jsonb check (
    jsonb_typeof(raw_summary) = 'object'
    and octet_length(raw_summary::text) <= 65536
  ),
  last_mutation_id uuid not null,
  row_version bigint not null default 1 check (row_version > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  constraint external_workouts_profile_fk
    foreign key (owner_id, profile_id)
    references kal_tracker.profiles(owner_id, id)
    on delete cascade,
  unique (owner_id, source, external_id),
  unique (owner_id, last_mutation_id)
);

create table kal_tracker.meal_analysis_jobs (
  id uuid primary key,
  owner_id uuid not null default auth.uid(),
  profile_id uuid not null,
  storage_object text not null check (
    btrim(storage_object) <> ''
    and storage_object like owner_id::text || '/' || id::text || '/%'
  ),
  image_sha256 text not null check (image_sha256 ~ '^[0-9a-f]{64}$'),
  image_size_bytes integer not null check (image_size_bytes between 1 and 10485760),
  image_mime_type text not null check (
    image_mime_type in ('image/jpeg', 'image/png', 'image/webp')
  ),
  requested_meal_type text check (
    requested_meal_type is null
    or requested_meal_type in ('breakfast', 'lunch', 'dinner', 'snack', 'other')
  ),
  user_note text check (user_note is null or char_length(user_note) <= 500),
  status text not null default 'queued' check (
    status in (
      'queued', 'claimed', 'processing', 'needs_review',
      'confirmed', 'failed', 'cancelled', 'expired'
    )
  ),
  claimed_by uuid references auth.users(id) on delete set null,
  claimed_at timestamptz,
  lease_expires_at timestamptz,
  completed_at timestamptz,
  attempt_count integer not null default 0 check (attempt_count between 0 and 10),
  analysis_result jsonb check (
    analysis_result is null
    or (
      jsonb_typeof(analysis_result) = 'object'
      and octet_length(analysis_result::text) <= 524288
    )
  ),
  error_code text check (error_code is null or char_length(error_code) <= 80),
  last_mutation_id uuid not null,
  row_version bigint not null default 1 check (row_version > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  constraint meal_analysis_jobs_profile_fk
    foreign key (owner_id, profile_id)
    references kal_tracker.profiles(owner_id, id)
    on delete cascade,
  constraint meal_analysis_jobs_lease_check check (
    (
      claimed_by is null
      and claimed_at is null
      and lease_expires_at is null
    )
    or (
      claimed_by is not null
      and claimed_at is not null
      and lease_expires_at is not null
      and lease_expires_at >= claimed_at
    )
  ),
  constraint meal_analysis_jobs_timestamps_check check (
    (claimed_at is null or claimed_at >= created_at)
    and (completed_at is null or completed_at >= created_at)
    and (
      claimed_at is null
      or completed_at is null
      or completed_at >= claimed_at
    )
  ),
  unique (owner_id, last_mutation_id)
);

do $triggers$
declare
  table_name text;
begin
  foreach table_name in array array[
    'water_logs',
    'body_measurements',
    'recipes',
    'recipe_items',
    'external_workouts',
    'meal_analysis_jobs'
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

create index water_logs_daily_idx
  on kal_tracker.water_logs(owner_id, profile_id, local_date, logged_at)
  where deleted_at is null;
create index body_measurements_time_idx
  on kal_tracker.body_measurements(owner_id, profile_id, measured_at desc)
  where deleted_at is null;
create index recipes_name_idx
  on kal_tracker.recipes(owner_id, profile_id, lower(name))
  where deleted_at is null;
create index recipe_items_position_idx
  on kal_tracker.recipe_items(owner_id, recipe_id, position)
  where deleted_at is null;
create index external_workouts_time_idx
  on kal_tracker.external_workouts(owner_id, profile_id, started_at desc)
  where deleted_at is null;
create index meal_analysis_jobs_queue_idx
  on kal_tracker.meal_analysis_jobs(
    owner_id,
    status,
    lease_expires_at,
    created_at
  )
  where deleted_at is null and status in ('queued', 'claimed', 'processing');

do $policies$
declare
  table_name text;
begin
  foreach table_name in array array[
    'water_logs',
    'body_measurements',
    'recipes',
    'recipe_items',
    'external_workouts',
    'meal_analysis_jobs'
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

-- External imports are read-only in the mobile app. A future bridge will write
-- through narrowly scoped SECURITY DEFINER RPCs using a dedicated identity.
drop policy external_workouts_insert_own
  on kal_tracker.external_workouts;
drop policy external_workouts_update_own
  on kal_tracker.external_workouts;

-- Mobile clients can only create and edit measurements entered in Kal Tracker.
-- Imported measurements will use the same dedicated bridge pattern as workouts.
drop policy body_measurements_insert_own
  on kal_tracker.body_measurements;
drop policy body_measurements_update_own
  on kal_tracker.body_measurements;

create policy body_measurements_insert_manual
  on kal_tracker.body_measurements for insert to authenticated
  with check (
    owner_id = (select auth.uid())
    and source = 'kal_tracker'
  );

create policy body_measurements_update_manual
  on kal_tracker.body_measurements for update to authenticated
  using (
    owner_id = (select auth.uid())
    and source = 'kal_tracker'
  )
  with check (
    owner_id = (select auth.uid())
    and source = 'kal_tracker'
  );

grant select, insert, update
  on kal_tracker.water_logs,
     kal_tracker.body_measurements,
     kal_tracker.recipes,
     kal_tracker.recipe_items,
     kal_tracker.meal_analysis_jobs
  to authenticated;

grant select
  on kal_tracker.external_workouts
  to authenticated;

grant all on
  kal_tracker.water_logs,
  kal_tracker.body_measurements,
  kal_tracker.recipes,
  kal_tracker.recipe_items,
  kal_tracker.external_workouts,
  kal_tracker.meal_analysis_jobs
  to service_role;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'kal-tracker-meal-photos',
  'kal-tracker-meal-photos',
  false,
  10485760,
  array['image/jpeg', 'image/png', 'image/webp']
)
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

create policy kal_tracker_meal_photos_select_own
  on storage.objects for select to authenticated
  using (
    bucket_id = 'kal-tracker-meal-photos'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

create policy kal_tracker_meal_photos_insert_own
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'kal-tracker-meal-photos'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

create policy kal_tracker_meal_photos_delete_own
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'kal-tracker-meal-photos'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

notify pgrst, 'reload schema';

commit;
