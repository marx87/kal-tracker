begin;

-- Chiude il contratto dati introdotto dagli schemi Drift v9-v11: profilo di
-- allenamento, riepiloghi salute e feed del coach. Estende inoltre il check-in
-- con il movimento, che sul telefono esiste dalla v9.

alter table kal_tracker.daily_check_ins
  add column if not exists steps integer
    check (steps is null or steps between 0 and 200000),
  add column if not exists walk_minutes integer
    check (walk_minutes is null or walk_minutes between 0 and 1440);

alter table kal_tracker.daily_check_ins
  drop constraint if exists daily_check_ins_not_blank;
alter table kal_tracker.daily_check_ins
  add constraint daily_check_ins_not_blank check (
    deleted_at is not null
    or sleep_hours is not null
    or energy_score is not null
    or steps is not null
    or walk_minutes is not null
  );

create table kal_tracker.training_profiles (
  id uuid primary key,
  owner_id uuid not null default auth.uid(),
  profile_id uuid not null,
  equipment text not null default '' check (char_length(equipment) <= 400),
  sessions_per_week integer
    check (sessions_per_week is null or sessions_per_week between 1 and 14),
  minutes_per_session integer
    check (minutes_per_session is null or minutes_per_session between 10 and 300),
  preferred_days text not null default ''
    check (char_length(preferred_days) <= 60),
  deload_preference text not null default 'suggerito'
    check (deload_preference in ('automatico', 'suggerito')),
  last_mutation_id uuid not null,
  row_version bigint not null default 1 check (row_version > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  constraint training_profiles_profile_fk
    foreign key (owner_id, profile_id)
    references kal_tracker.profiles(owner_id, id)
    on delete cascade,
  unique (owner_id, profile_id),
  unique (owner_id, last_mutation_id)
);

create table kal_tracker.training_limitations (
  id uuid primary key,
  owner_id uuid not null default auth.uid(),
  profile_id uuid not null,
  body_part text not null check (body_part in (
    'spalla_dx', 'spalla_sx', 'gomito_dx', 'gomito_sx',
    'polso_dx', 'polso_sx', 'collo', 'costole', 'lombari',
    'anca_dx', 'anca_sx', 'ginocchio_dx', 'ginocchio_sx',
    'caviglia_dx', 'caviglia_sx'
  )),
  severity text not null check (severity in ('fastidio', 'dolore', 'stop')),
  note text check (note is null or char_length(note) <= 300),
  started_at timestamptz not null,
  resolved_at timestamptz,
  last_mutation_id uuid not null,
  row_version bigint not null default 1 check (row_version > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  constraint training_limitations_profile_fk
    foreign key (owner_id, profile_id)
    references kal_tracker.profiles(owner_id, id)
    on delete cascade,
  constraint training_limitations_resolution_after_start check (
    resolved_at is null or resolved_at >= started_at
  ),
  unique (owner_id, last_mutation_id)
);

create table kal_tracker.daily_health_summaries (
  id uuid primary key,
  owner_id uuid not null default auth.uid(),
  profile_id uuid not null,
  day date not null,
  source text not null
    check (btrim(source) <> '' and char_length(source) <= 40),
  external_id text check (
    external_id is null or
    (btrim(external_id) <> '' and char_length(external_id) <= 120)
  ),
  steps integer check (steps is null or steps between 0 and 200000),
  sleep_minutes integer
    check (sleep_minutes is null or sleep_minutes between 0 and 1440),
  resting_heart_rate integer check (
    resting_heart_rate is null or resting_heart_rate between 20 and 250
  ),
  last_mutation_id uuid not null,
  row_version bigint not null default 1 check (row_version > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  constraint daily_health_summaries_profile_fk
    foreign key (owner_id, profile_id)
    references kal_tracker.profiles(owner_id, id)
    on delete cascade,
  constraint daily_health_summaries_not_blank check (
    deleted_at is not null
    or steps is not null
    or sleep_minutes is not null
    or resting_heart_rate is not null
  ),
  unique (owner_id, profile_id, day, source),
  unique (owner_id, last_mutation_id)
);

create table kal_tracker.coach_feed_items (
  id uuid primary key,
  owner_id uuid not null default auth.uid(),
  profile_id uuid not null,
  kind text not null check (btrim(kind) <> '' and char_length(kind) <= 40),
  source text not null check (source in ('deterministic', 'ai')),
  external_id text check (
    external_id is null or
    (btrim(external_id) <> '' and char_length(external_id) <= 120)
  ),
  title text not null check (btrim(title) <> '' and char_length(title) <= 120),
  body text not null check (btrim(body) <> '' and char_length(body) <= 1200),
  action_label text check (
    action_label is null or
    (btrim(action_label) <> '' and char_length(action_label) <= 60)
  ),
  action_path text check (
    action_path is null or
    (btrim(action_path) <> '' and char_length(action_path) <= 200)
  ),
  occurred_at timestamptz not null,
  read_at timestamptz,
  dismissed_at timestamptz,
  last_mutation_id uuid not null,
  row_version bigint not null default 1 check (row_version > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  constraint coach_feed_items_profile_fk
    foreign key (owner_id, profile_id)
    references kal_tracker.profiles(owner_id, id)
    on delete cascade,
  unique (owner_id, profile_id, source, external_id),
  unique (owner_id, last_mutation_id)
);

do $triggers$
declare
  table_name text;
begin
  foreach table_name in array array[
    'training_profiles',
    'training_limitations',
    'daily_health_summaries',
    'coach_feed_items'
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

create index training_limitations_active_idx
  on kal_tracker.training_limitations(owner_id, profile_id, started_at desc)
  where deleted_at is null and resolved_at is null;
create index daily_health_summaries_day_idx
  on kal_tracker.daily_health_summaries(owner_id, profile_id, day desc)
  where deleted_at is null;
create index coach_feed_items_occurred_idx
  on kal_tracker.coach_feed_items(owner_id, profile_id, occurred_at desc)
  where deleted_at is null and dismissed_at is null;

do $policies$
declare
  table_name text;
begin
  foreach table_name in array array[
    'training_profiles',
    'training_limitations',
    'daily_health_summaries',
    'coach_feed_items'
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

grant select, insert, update on
  kal_tracker.training_profiles,
  kal_tracker.training_limitations,
  kal_tracker.daily_health_summaries,
  kal_tracker.coach_feed_items
to authenticated;

grant all on
  kal_tracker.training_profiles,
  kal_tracker.training_limitations,
  kal_tracker.daily_health_summaries,
  kal_tracker.coach_feed_items
to service_role;

notify pgrst, 'reload schema';

commit;
