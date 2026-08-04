begin;

-- Coda del piano settimanale: gemella di meal_analysis_jobs, senza foto.
-- Il client accoda una richiesta (giorni, pasti scelti, obiettivi e il
-- catalogo REALE delle ricette) e il worker sul Mac restituisce solo delle
-- SCELTE: recipeId presi da quel catalogo e numero di porzioni. Nessun numero
-- nutrizionale attraversa questa tabella nel verso worker -> app: i totali li
-- calcola sempre l'app dalle ricette vere.
create table kal_tracker.weekly_plan_jobs (
  id uuid primary key,
  owner_id uuid not null default auth.uid(),
  profile_id uuid not null,
  request jsonb not null check (
    jsonb_typeof(request) = 'object'
    and octet_length(request::text) <= 524288
  ),
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
  result jsonb check (
    result is null
    or (
      jsonb_typeof(result) = 'object'
      and octet_length(result::text) <= 524288
    )
  ),
  error_code text check (error_code is null or char_length(error_code) <= 80),
  last_mutation_id uuid not null,
  row_version bigint not null default 1 check (row_version > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  constraint weekly_plan_jobs_profile_fk
    foreign key (owner_id, profile_id)
    references kal_tracker.profiles(owner_id, id)
    on delete cascade,
  constraint weekly_plan_jobs_lease_check check (
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
  constraint weekly_plan_jobs_timestamps_check check (
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
    'weekly_plan_jobs'
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

create index weekly_plan_jobs_queue_idx
  on kal_tracker.weekly_plan_jobs(
    owner_id,
    status,
    lease_expires_at,
    created_at
  )
  where deleted_at is null and status in ('queued', 'claimed', 'processing');

alter table kal_tracker.weekly_plan_jobs enable row level security;

create policy weekly_plan_jobs_select_own
  on kal_tracker.weekly_plan_jobs for select to authenticated
  using (owner_id = (select auth.uid()));

-- Come per le foto: il proprietario accoda e legge, ma non può fingersi il
-- worker scrivendo stato, lease o risultato. Nessun UPDATE al client.
grant select on kal_tracker.weekly_plan_jobs to authenticated;

grant insert (
  id,
  owner_id,
  profile_id,
  request,
  last_mutation_id
) on kal_tracker.weekly_plan_jobs
  to authenticated;

create policy weekly_plan_jobs_enqueue_own
  on kal_tracker.weekly_plan_jobs for insert to authenticated
  with check (
    owner_id = (select auth.uid())
    and status = 'queued'
    and claimed_by is null
    and claimed_at is null
    and lease_expires_at is null
    and completed_at is null
    and attempt_count = 0
    and result is null
    and error_code is null
    and deleted_at is null
  );

-- Secondo ambito di automazione. Senza questa riga ogni RPC del piano
-- fallirebbe con 42501 'meal_planning binding is missing or inactive'.
alter table kal_tracker.automation_bindings
  drop constraint if exists automation_bindings_scope_check;
alter table kal_tracker.automation_bindings
  add constraint automation_bindings_scope_check
  check (scope in ('meal_analysis', 'meal_planning'));

-- Registro di idempotenza gemello: automation_rpc_mutations ha job_id legato
-- a meal_analysis_jobs, quindi un job di pianificazione non può scriverci.
create table kal_tracker.automation_plan_rpc_mutations (
  actor_id uuid not null references auth.users(id) on delete restrict,
  mutation_id uuid not null,
  operation text not null check (
    operation in ('claim', 'heartbeat', 'complete', 'fail')
  ),
  owner_id uuid not null references auth.users(id) on delete restrict,
  job_id uuid not null references kal_tracker.weekly_plan_jobs(id)
    on delete restrict,
  request_payload jsonb not null check (
    jsonb_typeof(request_payload) = 'object'
    and octet_length(request_payload::text) <= 524288
  ),
  response_payload jsonb not null check (
    jsonb_typeof(response_payload) = 'object'
    and octet_length(response_payload::text) <= 65536
  ),
  created_at timestamptz not null default now(),
  primary key (actor_id, mutation_id)
);

create index automation_plan_rpc_mutations_job_idx
  on kal_tracker.automation_plan_rpc_mutations(job_id, created_at desc);

alter table kal_tracker.automation_plan_rpc_mutations
  enable row level security;

revoke all privileges on kal_tracker.automation_plan_rpc_mutations
  from public, anon, authenticated;

create or replace function kal_tracker.claim_weekly_plan_job(
  p_mutation_id uuid,
  p_lease_seconds integer default 180
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_id uuid := auth.uid();
  v_now timestamptz;
  v_job kal_tracker.weekly_plan_jobs%rowtype;
  v_existing kal_tracker.automation_plan_rpc_mutations%rowtype;
  v_request jsonb;
  v_response jsonb;
begin
  if v_actor_id is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;
  if p_mutation_id is null then
    raise exception 'p_mutation_id is required' using errcode = '22023';
  end if;
  if p_lease_seconds is null or p_lease_seconds not between 30 and 900 then
    raise exception 'p_lease_seconds must be between 30 and 900'
      using errcode = '22023';
  end if;

  v_request := pg_catalog.jsonb_build_object(
    'lease_seconds', p_lease_seconds
  );

  -- Serialize retries of the same worker mutation before reading the ledger.
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      v_actor_id::text || ':' || p_mutation_id::text,
      0
    )
  );

  select m.*
    into v_existing
  from kal_tracker.automation_plan_rpc_mutations m
  where m.actor_id = v_actor_id
    and m.mutation_id = p_mutation_id;

  if found then
    if v_existing.operation <> 'claim'
       or v_existing.request_payload is distinct from v_request then
      raise exception 'mutation UUID was already used for another request'
        using errcode = '23505';
    end if;
    if not exists (
      select 1
      from kal_tracker.automation_bindings b
      where b.worker_user_id = v_actor_id
        and b.owner_id = v_existing.owner_id
        and b.scope = 'meal_planning'
        and b.is_active
    ) then
      raise exception 'meal_planning binding is missing or inactive'
        using errcode = '42501';
    end if;
    return v_existing.response_payload;
  end if;

  if not exists (
    select 1
    from kal_tracker.automation_bindings b
    where b.worker_user_id = v_actor_id
      and b.scope = 'meal_planning'
      and b.is_active
  ) then
    raise exception 'meal_planning binding is missing or inactive'
      using errcode = '42501';
  end if;

  v_now := pg_catalog.clock_timestamp();

  select j.*
    into v_job
  from kal_tracker.weekly_plan_jobs j
  join kal_tracker.automation_bindings b
    on b.owner_id = j.owner_id
   and b.worker_user_id = v_actor_id
   and b.scope = 'meal_planning'
   and b.is_active
  where j.deleted_at is null
    and j.attempt_count < 10
    and (
      j.status = 'queued'
      or (
        j.status in ('claimed', 'processing')
        and j.lease_expires_at <= v_now
      )
    )
  order by j.created_at, j.id
  for update of j skip locked
  limit 1;

  if not found then
    -- No state changed, so this empty poll is intentionally not recorded in
    -- the mutation ledger. A later poll must normally use a fresh UUID.
    return pg_catalog.jsonb_build_object('claimed', false);
  end if;

  update kal_tracker.weekly_plan_jobs
  set status = 'claimed',
      claimed_by = v_actor_id,
      claimed_at = v_now,
      lease_expires_at = v_now
        + pg_catalog.make_interval(secs => p_lease_seconds),
      completed_at = null,
      attempt_count = attempt_count + 1,
      result = null,
      error_code = null,
      last_mutation_id = p_mutation_id
  where id = v_job.id
  returning * into v_job;

  v_response := pg_catalog.jsonb_build_object(
    'claimed', true,
    'job_id', v_job.id,
    'owner_id', v_job.owner_id,
    'profile_id', v_job.profile_id,
    'request', v_job.request,
    'attempt_count', v_job.attempt_count,
    'row_version', v_job.row_version,
    'lease_expires_at', v_job.lease_expires_at
  );

  insert into kal_tracker.automation_plan_rpc_mutations (
    actor_id,
    mutation_id,
    operation,
    owner_id,
    job_id,
    request_payload,
    response_payload
  ) values (
    v_actor_id,
    p_mutation_id,
    'claim',
    v_job.owner_id,
    v_job.id,
    v_request,
    v_response
  );

  return v_response;
end;
$$;

create or replace function kal_tracker.heartbeat_weekly_plan_job(
  p_job_id uuid,
  p_mutation_id uuid,
  p_lease_seconds integer default 180
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_id uuid := auth.uid();
  v_now timestamptz;
  v_job kal_tracker.weekly_plan_jobs%rowtype;
  v_existing kal_tracker.automation_plan_rpc_mutations%rowtype;
  v_request jsonb;
  v_response jsonb;
begin
  if v_actor_id is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;
  if p_job_id is null or p_mutation_id is null then
    raise exception 'p_job_id and p_mutation_id are required'
      using errcode = '22023';
  end if;
  if p_lease_seconds is null or p_lease_seconds not between 30 and 900 then
    raise exception 'p_lease_seconds must be between 30 and 900'
      using errcode = '22023';
  end if;

  v_request := pg_catalog.jsonb_build_object(
    'job_id', p_job_id,
    'lease_seconds', p_lease_seconds
  );

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      v_actor_id::text || ':' || p_mutation_id::text,
      0
    )
  );

  select m.*
    into v_existing
  from kal_tracker.automation_plan_rpc_mutations m
  where m.actor_id = v_actor_id
    and m.mutation_id = p_mutation_id;

  if found then
    if v_existing.operation <> 'heartbeat'
       or v_existing.request_payload is distinct from v_request then
      raise exception 'mutation UUID was already used for another request'
        using errcode = '23505';
    end if;
    if not exists (
      select 1
      from kal_tracker.automation_bindings b
      where b.worker_user_id = v_actor_id
        and b.owner_id = v_existing.owner_id
        and b.scope = 'meal_planning'
        and b.is_active
    ) then
      raise exception 'meal_planning binding is missing or inactive'
        using errcode = '42501';
    end if;
    return v_existing.response_payload;
  end if;

  v_now := pg_catalog.clock_timestamp();

  select j.*
    into v_job
  from kal_tracker.weekly_plan_jobs j
  where j.id = p_job_id
  for update;

  if not found then
    raise exception 'weekly-plan job not found' using errcode = 'P0002';
  end if;
  if not exists (
    select 1
    from kal_tracker.automation_bindings b
    where b.worker_user_id = v_actor_id
      and b.owner_id = v_job.owner_id
      and b.scope = 'meal_planning'
      and b.is_active
  ) then
    raise exception 'meal_planning binding is missing or inactive'
      using errcode = '42501';
  end if;
  if v_job.claimed_by is distinct from v_actor_id
     or v_job.status not in ('claimed', 'processing')
     or v_job.lease_expires_at is null
     or v_job.lease_expires_at <= v_now then
    raise exception 'job is not actively leased by this worker'
      using errcode = '42501';
  end if;

  update kal_tracker.weekly_plan_jobs
  set status = 'processing',
      lease_expires_at = v_now
        + pg_catalog.make_interval(secs => p_lease_seconds),
      last_mutation_id = p_mutation_id
  where id = v_job.id
  returning * into v_job;

  v_response := pg_catalog.jsonb_build_object(
    'job_id', v_job.id,
    'status', v_job.status,
    'row_version', v_job.row_version,
    'lease_expires_at', v_job.lease_expires_at
  );

  insert into kal_tracker.automation_plan_rpc_mutations (
    actor_id,
    mutation_id,
    operation,
    owner_id,
    job_id,
    request_payload,
    response_payload
  ) values (
    v_actor_id,
    p_mutation_id,
    'heartbeat',
    v_job.owner_id,
    v_job.id,
    v_request,
    v_response
  );

  return v_response;
end;
$$;

create or replace function kal_tracker.complete_weekly_plan_job(
  p_job_id uuid,
  p_mutation_id uuid,
  p_result jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_id uuid := auth.uid();
  v_now timestamptz;
  v_job kal_tracker.weekly_plan_jobs%rowtype;
  v_existing kal_tracker.automation_plan_rpc_mutations%rowtype;
  v_request jsonb;
  v_response jsonb;
begin
  if v_actor_id is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;
  if p_job_id is null or p_mutation_id is null then
    raise exception 'p_job_id and p_mutation_id are required'
      using errcode = '22023';
  end if;
  if p_result is null
     or pg_catalog.jsonb_typeof(p_result) <> 'object'
     or pg_catalog.octet_length(p_result::text) > 524288 then
    raise exception 'p_result must be a JSON object up to 524288 bytes'
      using errcode = '22023';
  end if;

  v_request := pg_catalog.jsonb_build_object(
    'job_id', p_job_id,
    'result', p_result
  );

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      v_actor_id::text || ':' || p_mutation_id::text,
      0
    )
  );

  select m.*
    into v_existing
  from kal_tracker.automation_plan_rpc_mutations m
  where m.actor_id = v_actor_id
    and m.mutation_id = p_mutation_id;

  if found then
    if v_existing.operation <> 'complete'
       or v_existing.request_payload is distinct from v_request then
      raise exception 'mutation UUID was already used for another request'
        using errcode = '23505';
    end if;
    if not exists (
      select 1
      from kal_tracker.automation_bindings b
      where b.worker_user_id = v_actor_id
        and b.owner_id = v_existing.owner_id
        and b.scope = 'meal_planning'
        and b.is_active
    ) then
      raise exception 'meal_planning binding is missing or inactive'
        using errcode = '42501';
    end if;
    return v_existing.response_payload;
  end if;

  v_now := pg_catalog.clock_timestamp();

  select j.*
    into v_job
  from kal_tracker.weekly_plan_jobs j
  where j.id = p_job_id
  for update;

  if not found then
    raise exception 'weekly-plan job not found' using errcode = 'P0002';
  end if;
  if not exists (
    select 1
    from kal_tracker.automation_bindings b
    where b.worker_user_id = v_actor_id
      and b.owner_id = v_job.owner_id
      and b.scope = 'meal_planning'
      and b.is_active
  ) then
    raise exception 'meal_planning binding is missing or inactive'
      using errcode = '42501';
  end if;
  if v_job.claimed_by is distinct from v_actor_id
     or v_job.status not in ('claimed', 'processing')
     or v_job.lease_expires_at is null
     or v_job.lease_expires_at <= v_now then
    raise exception 'job is not actively leased by this worker'
      using errcode = '42501';
  end if;

  -- Come per le foto, 'needs_review' e non 'confirmed': il piano resta una
  -- previsione finche Marco non tocca "Fatto" sui singoli slot.
  update kal_tracker.weekly_plan_jobs
  set status = 'needs_review',
      lease_expires_at = v_now,
      completed_at = v_now,
      result = p_result,
      error_code = null,
      last_mutation_id = p_mutation_id
  where id = v_job.id
  returning * into v_job;

  v_response := pg_catalog.jsonb_build_object(
    'job_id', v_job.id,
    'status', v_job.status,
    'row_version', v_job.row_version,
    'completed_at', v_job.completed_at
  );

  insert into kal_tracker.automation_plan_rpc_mutations (
    actor_id,
    mutation_id,
    operation,
    owner_id,
    job_id,
    request_payload,
    response_payload
  ) values (
    v_actor_id,
    p_mutation_id,
    'complete',
    v_job.owner_id,
    v_job.id,
    v_request,
    v_response
  );

  return v_response;
end;
$$;

create or replace function kal_tracker.fail_weekly_plan_job(
  p_job_id uuid,
  p_mutation_id uuid,
  p_error_code text,
  p_retryable boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_id uuid := auth.uid();
  v_now timestamptz;
  v_job kal_tracker.weekly_plan_jobs%rowtype;
  v_existing kal_tracker.automation_plan_rpc_mutations%rowtype;
  v_request jsonb;
  v_response jsonb;
  v_retry boolean;
begin
  if v_actor_id is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;
  if p_job_id is null or p_mutation_id is null then
    raise exception 'p_job_id and p_mutation_id are required'
      using errcode = '22023';
  end if;
  if p_error_code is null
     or pg_catalog.btrim(p_error_code) = ''
     or pg_catalog.char_length(p_error_code) > 80 then
    raise exception 'p_error_code must contain 1 to 80 characters'
      using errcode = '22023';
  end if;
  if p_retryable is null then
    raise exception 'p_retryable is required' using errcode = '22023';
  end if;

  v_request := pg_catalog.jsonb_build_object(
    'job_id', p_job_id,
    'error_code', p_error_code,
    'retryable', p_retryable
  );

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      v_actor_id::text || ':' || p_mutation_id::text,
      0
    )
  );

  select m.*
    into v_existing
  from kal_tracker.automation_plan_rpc_mutations m
  where m.actor_id = v_actor_id
    and m.mutation_id = p_mutation_id;

  if found then
    if v_existing.operation <> 'fail'
       or v_existing.request_payload is distinct from v_request then
      raise exception 'mutation UUID was already used for another request'
        using errcode = '23505';
    end if;
    if not exists (
      select 1
      from kal_tracker.automation_bindings b
      where b.worker_user_id = v_actor_id
        and b.owner_id = v_existing.owner_id
        and b.scope = 'meal_planning'
        and b.is_active
    ) then
      raise exception 'meal_planning binding is missing or inactive'
        using errcode = '42501';
    end if;
    return v_existing.response_payload;
  end if;

  v_now := pg_catalog.clock_timestamp();

  select j.*
    into v_job
  from kal_tracker.weekly_plan_jobs j
  where j.id = p_job_id
  for update;

  if not found then
    raise exception 'weekly-plan job not found' using errcode = 'P0002';
  end if;
  if not exists (
    select 1
    from kal_tracker.automation_bindings b
    where b.worker_user_id = v_actor_id
      and b.owner_id = v_job.owner_id
      and b.scope = 'meal_planning'
      and b.is_active
  ) then
    raise exception 'meal_planning binding is missing or inactive'
      using errcode = '42501';
  end if;
  if v_job.claimed_by is distinct from v_actor_id
     or v_job.status not in ('claimed', 'processing')
     or v_job.lease_expires_at is null
     or v_job.lease_expires_at <= v_now then
    raise exception 'job is not actively leased by this worker'
      using errcode = '42501';
  end if;

  v_retry := p_retryable and v_job.attempt_count < 10;

  if v_retry then
    update kal_tracker.weekly_plan_jobs
    set status = 'queued',
        claimed_by = null,
        claimed_at = null,
        lease_expires_at = null,
        completed_at = null,
        result = null,
        error_code = p_error_code,
        last_mutation_id = p_mutation_id
    where id = v_job.id
    returning * into v_job;
  else
    update kal_tracker.weekly_plan_jobs
    set status = 'failed',
        lease_expires_at = v_now,
        completed_at = v_now,
        result = null,
        error_code = p_error_code,
        last_mutation_id = p_mutation_id
    where id = v_job.id
    returning * into v_job;
  end if;

  v_response := pg_catalog.jsonb_build_object(
    'job_id', v_job.id,
    'status', v_job.status,
    'retryable', v_retry,
    'attempt_count', v_job.attempt_count,
    'row_version', v_job.row_version,
    'completed_at', v_job.completed_at
  );

  insert into kal_tracker.automation_plan_rpc_mutations (
    actor_id,
    mutation_id,
    operation,
    owner_id,
    job_id,
    request_payload,
    response_payload
  ) values (
    v_actor_id,
    p_mutation_id,
    'fail',
    v_job.owner_id,
    v_job.id,
    v_request,
    v_response
  );

  return v_response;
end;
$$;

revoke all privileges on function
  kal_tracker.claim_weekly_plan_job(uuid, integer)
  from public, anon, authenticated;
revoke all privileges on function
  kal_tracker.heartbeat_weekly_plan_job(uuid, uuid, integer)
  from public, anon, authenticated;
revoke all privileges on function
  kal_tracker.complete_weekly_plan_job(uuid, uuid, jsonb)
  from public, anon, authenticated;
revoke all privileges on function
  kal_tracker.fail_weekly_plan_job(uuid, uuid, text, boolean)
  from public, anon, authenticated;

grant execute on function
  kal_tracker.claim_weekly_plan_job(uuid, integer),
  kal_tracker.heartbeat_weekly_plan_job(uuid, uuid, integer),
  kal_tracker.complete_weekly_plan_job(uuid, uuid, jsonb),
  kal_tracker.fail_weekly_plan_job(uuid, uuid, text, boolean)
  to authenticated;

notify pgrst, 'reload schema';

commit;
