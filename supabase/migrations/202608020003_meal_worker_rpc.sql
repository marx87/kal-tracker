begin;

-- A worker is a dedicated Supabase Auth user. Bindings are provisioned only by
-- a trusted database administrator; mobile users and workers cannot inspect or
-- edit this table directly.
create table kal_tracker.automation_bindings (
  worker_user_id uuid not null
    references auth.users(id) on delete cascade,
  owner_id uuid not null
    references auth.users(id) on delete cascade,
  scope text not null check (scope in ('meal_analysis')),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  constraint automation_bindings_dedicated_identity_check
    check (worker_user_id <> owner_id),
  primary key (worker_user_id, owner_id, scope)
);

-- Private idempotency ledger for mutating worker RPCs. A mutation UUID belongs
-- to one worker and one exact request for its full retention lifetime.
create table kal_tracker.automation_rpc_mutations (
  actor_id uuid not null references auth.users(id) on delete restrict,
  mutation_id uuid not null,
  operation text not null check (
    operation in ('claim', 'heartbeat', 'complete', 'fail')
  ),
  owner_id uuid not null references auth.users(id) on delete restrict,
  job_id uuid not null references kal_tracker.meal_analysis_jobs(id)
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

create index automation_bindings_claim_idx
  on kal_tracker.automation_bindings(worker_user_id, scope, owner_id)
  where is_active;

create index automation_rpc_mutations_job_idx
  on kal_tracker.automation_rpc_mutations(job_id, created_at desc);

alter table kal_tracker.automation_bindings enable row level security;
alter table kal_tracker.automation_rpc_mutations enable row level security;

revoke all privileges on kal_tracker.automation_bindings
  from public, anon, authenticated;
revoke all privileges on kal_tracker.automation_rpc_mutations
  from public, anon, authenticated;

-- The owner can enqueue a request, but cannot impersonate the worker by
-- writing claim/result/status columns. Owner-side cancel, confirm and cleanup
-- will be added later as separate, narrow RPCs.
revoke insert, update on kal_tracker.meal_analysis_jobs
  from authenticated;
drop policy meal_analysis_jobs_insert_own
  on kal_tracker.meal_analysis_jobs;
drop policy meal_analysis_jobs_update_own
  on kal_tracker.meal_analysis_jobs;

grant insert (
  id,
  owner_id,
  profile_id,
  storage_object,
  image_sha256,
  image_size_bytes,
  image_mime_type,
  requested_meal_type,
  user_note,
  last_mutation_id
) on kal_tracker.meal_analysis_jobs
  to authenticated;

create policy meal_analysis_jobs_enqueue_own
  on kal_tracker.meal_analysis_jobs for insert to authenticated
  with check (
    owner_id = (select auth.uid())
    and status = 'queued'
    and claimed_by is null
    and claimed_at is null
    and lease_expires_at is null
    and completed_at is null
    and attempt_count = 0
    and analysis_result is null
    and error_code is null
    and deleted_at is null
  );

create or replace function kal_tracker.claim_meal_analysis_job(
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
  v_job kal_tracker.meal_analysis_jobs%rowtype;
  v_existing kal_tracker.automation_rpc_mutations%rowtype;
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
  from kal_tracker.automation_rpc_mutations m
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
        and b.scope = 'meal_analysis'
        and b.is_active
    ) then
      raise exception 'meal_analysis binding is missing or inactive'
        using errcode = '42501';
    end if;
    return v_existing.response_payload;
  end if;

  if not exists (
    select 1
    from kal_tracker.automation_bindings b
    where b.worker_user_id = v_actor_id
      and b.scope = 'meal_analysis'
      and b.is_active
  ) then
    raise exception 'meal_analysis binding is missing or inactive'
      using errcode = '42501';
  end if;

  v_now := pg_catalog.clock_timestamp();

  select j.*
    into v_job
  from kal_tracker.meal_analysis_jobs j
  join kal_tracker.automation_bindings b
    on b.owner_id = j.owner_id
   and b.worker_user_id = v_actor_id
   and b.scope = 'meal_analysis'
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

  update kal_tracker.meal_analysis_jobs
  set status = 'claimed',
      claimed_by = v_actor_id,
      claimed_at = v_now,
      lease_expires_at = v_now
        + pg_catalog.make_interval(secs => p_lease_seconds),
      completed_at = null,
      attempt_count = attempt_count + 1,
      analysis_result = null,
      error_code = null,
      last_mutation_id = p_mutation_id
  where id = v_job.id
  returning * into v_job;

  v_response := pg_catalog.jsonb_build_object(
    'claimed', true,
    'job_id', v_job.id,
    'owner_id', v_job.owner_id,
    'profile_id', v_job.profile_id,
    'storage_bucket', 'kal-tracker-meal-photos',
    'storage_object', v_job.storage_object,
    'image_sha256', v_job.image_sha256,
    'image_size_bytes', v_job.image_size_bytes,
    'image_mime_type', v_job.image_mime_type,
    'requested_meal_type', v_job.requested_meal_type,
    'user_note', v_job.user_note,
    'attempt_count', v_job.attempt_count,
    'row_version', v_job.row_version,
    'lease_expires_at', v_job.lease_expires_at
  );

  insert into kal_tracker.automation_rpc_mutations (
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

create or replace function kal_tracker.heartbeat_meal_analysis_job(
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
  v_job kal_tracker.meal_analysis_jobs%rowtype;
  v_existing kal_tracker.automation_rpc_mutations%rowtype;
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
  from kal_tracker.automation_rpc_mutations m
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
        and b.scope = 'meal_analysis'
        and b.is_active
    ) then
      raise exception 'meal_analysis binding is missing or inactive'
        using errcode = '42501';
    end if;
    return v_existing.response_payload;
  end if;

  v_now := pg_catalog.clock_timestamp();

  select j.*
    into v_job
  from kal_tracker.meal_analysis_jobs j
  where j.id = p_job_id
  for update;

  if not found then
    raise exception 'meal-analysis job not found' using errcode = 'P0002';
  end if;
  if not exists (
    select 1
    from kal_tracker.automation_bindings b
    where b.worker_user_id = v_actor_id
      and b.owner_id = v_job.owner_id
      and b.scope = 'meal_analysis'
      and b.is_active
  ) then
    raise exception 'meal_analysis binding is missing or inactive'
      using errcode = '42501';
  end if;
  if v_job.claimed_by is distinct from v_actor_id
     or v_job.status not in ('claimed', 'processing')
     or v_job.lease_expires_at is null
     or v_job.lease_expires_at <= v_now then
    raise exception 'job is not actively leased by this worker'
      using errcode = '42501';
  end if;

  update kal_tracker.meal_analysis_jobs
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

  insert into kal_tracker.automation_rpc_mutations (
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

create or replace function kal_tracker.complete_meal_analysis_job(
  p_job_id uuid,
  p_mutation_id uuid,
  p_analysis_result jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_id uuid := auth.uid();
  v_now timestamptz;
  v_job kal_tracker.meal_analysis_jobs%rowtype;
  v_existing kal_tracker.automation_rpc_mutations%rowtype;
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
  if p_analysis_result is null
     or pg_catalog.jsonb_typeof(p_analysis_result) <> 'object'
     or pg_catalog.octet_length(p_analysis_result::text) > 524288 then
    raise exception 'p_analysis_result must be a JSON object up to 524288 bytes'
      using errcode = '22023';
  end if;

  v_request := pg_catalog.jsonb_build_object(
    'job_id', p_job_id,
    'analysis_result', p_analysis_result
  );

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      v_actor_id::text || ':' || p_mutation_id::text,
      0
    )
  );

  select m.*
    into v_existing
  from kal_tracker.automation_rpc_mutations m
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
        and b.scope = 'meal_analysis'
        and b.is_active
    ) then
      raise exception 'meal_analysis binding is missing or inactive'
        using errcode = '42501';
    end if;
    return v_existing.response_payload;
  end if;

  v_now := pg_catalog.clock_timestamp();

  select j.*
    into v_job
  from kal_tracker.meal_analysis_jobs j
  where j.id = p_job_id
  for update;

  if not found then
    raise exception 'meal-analysis job not found' using errcode = 'P0002';
  end if;
  if not exists (
    select 1
    from kal_tracker.automation_bindings b
    where b.worker_user_id = v_actor_id
      and b.owner_id = v_job.owner_id
      and b.scope = 'meal_analysis'
      and b.is_active
  ) then
    raise exception 'meal_analysis binding is missing or inactive'
      using errcode = '42501';
  end if;
  if v_job.claimed_by is distinct from v_actor_id
     or v_job.status not in ('claimed', 'processing')
     or v_job.lease_expires_at is null
     or v_job.lease_expires_at <= v_now then
    raise exception 'job is not actively leased by this worker'
      using errcode = '42501';
  end if;

  update kal_tracker.meal_analysis_jobs
  set status = 'needs_review',
      lease_expires_at = v_now,
      completed_at = v_now,
      analysis_result = p_analysis_result,
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

  insert into kal_tracker.automation_rpc_mutations (
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

create or replace function kal_tracker.fail_meal_analysis_job(
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
  v_job kal_tracker.meal_analysis_jobs%rowtype;
  v_existing kal_tracker.automation_rpc_mutations%rowtype;
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
  from kal_tracker.automation_rpc_mutations m
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
        and b.scope = 'meal_analysis'
        and b.is_active
    ) then
      raise exception 'meal_analysis binding is missing or inactive'
        using errcode = '42501';
    end if;
    return v_existing.response_payload;
  end if;

  v_now := pg_catalog.clock_timestamp();

  select j.*
    into v_job
  from kal_tracker.meal_analysis_jobs j
  where j.id = p_job_id
  for update;

  if not found then
    raise exception 'meal-analysis job not found' using errcode = 'P0002';
  end if;
  if not exists (
    select 1
    from kal_tracker.automation_bindings b
    where b.worker_user_id = v_actor_id
      and b.owner_id = v_job.owner_id
      and b.scope = 'meal_analysis'
      and b.is_active
  ) then
    raise exception 'meal_analysis binding is missing or inactive'
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
    update kal_tracker.meal_analysis_jobs
    set status = 'queued',
        claimed_by = null,
        claimed_at = null,
        lease_expires_at = null,
        completed_at = null,
        analysis_result = null,
        error_code = p_error_code,
        last_mutation_id = p_mutation_id
    where id = v_job.id
    returning * into v_job;
  else
    update kal_tracker.meal_analysis_jobs
    set status = 'failed',
        lease_expires_at = v_now,
        completed_at = v_now,
        analysis_result = null,
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

  insert into kal_tracker.automation_rpc_mutations (
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

-- RLS on storage.objects calls this narrow predicate. It reveals no paths and
-- succeeds only for the exact object of an active, unexpired lease.
create or replace function kal_tracker.worker_can_read_meal_photo(
  p_storage_object text
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from kal_tracker.meal_analysis_jobs j
    join kal_tracker.automation_bindings b
      on b.owner_id = j.owner_id
     and b.worker_user_id = auth.uid()
     and b.scope = 'meal_analysis'
     and b.is_active
    where j.storage_object = p_storage_object
      and j.deleted_at is null
      and j.claimed_by = auth.uid()
      and j.status in ('claimed', 'processing')
      and j.lease_expires_at > pg_catalog.now()
  );
$$;

create policy kal_tracker_meal_photos_select_leased_worker
  on storage.objects for select to authenticated
  using (
    bucket_id = 'kal-tracker-meal-photos'
    and kal_tracker.worker_can_read_meal_photo(name)
  );

revoke all privileges on function
  kal_tracker.claim_meal_analysis_job(uuid, integer)
  from public, anon, authenticated;
revoke all privileges on function
  kal_tracker.heartbeat_meal_analysis_job(uuid, uuid, integer)
  from public, anon, authenticated;
revoke all privileges on function
  kal_tracker.complete_meal_analysis_job(uuid, uuid, jsonb)
  from public, anon, authenticated;
revoke all privileges on function
  kal_tracker.fail_meal_analysis_job(uuid, uuid, text, boolean)
  from public, anon, authenticated;
revoke all privileges on function
  kal_tracker.worker_can_read_meal_photo(text)
  from public, anon, authenticated;

grant execute on function
  kal_tracker.claim_meal_analysis_job(uuid, integer),
  kal_tracker.heartbeat_meal_analysis_job(uuid, uuid, integer),
  kal_tracker.complete_meal_analysis_job(uuid, uuid, jsonb),
  kal_tracker.fail_meal_analysis_job(uuid, uuid, text, boolean),
  kal_tracker.worker_can_read_meal_photo(text)
  to authenticated;

notify pgrst, 'reload schema';

commit;
