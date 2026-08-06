-- Chiusura di una proposta foto da parte del proprietario.
--
-- **Il buco che tappa.** La migrazione 202608020003 ha tolto l'UPDATE al
-- client con una nota: «Owner-side cancel, confirm and cleanup will be added
-- later as separate, narrow RPCs». Quel «later» non era mai arrivato, e la
-- conseguenza si vedeva su due dispositivi: il job restava `needs_review` sul
-- server per sempre, «già gestita» era un file JSON dentro un solo telefono, e
-- il tablet continuava a mostrare «Proposta pronta da rivedere» per una foto
-- registrata mezz'ora prima dall'altro apparecchio.
--
-- **Perché una RPC e non un permesso di UPDATE.** Ridare `update` al client
-- vorrebbe dire poter riscrivere `analysis_result`, `claimed_by`, il contatore
-- dei tentativi: cioè fingersi il worker. Qui invece si può fare una cosa
-- sola, e solo dal punto in cui ha senso farla.
--
-- **Idempotente di proposito.** Il telefono di Marco chiude un job che il
-- tablet ha appena chiuso, o la stessa chiamata viene ritentata dopo un
-- timeout: la seconda volta non è un errore, è la stessa verità di prima.

create or replace function kal_tracker.resolve_meal_analysis_job(
  p_job_id uuid,
  p_outcome text
)
returns jsonb
language plpgsql
security definer
set search_path = kal_tracker, pg_catalog, pg_temp
as $$
declare
  v_owner uuid := (select auth.uid());
  v_status text;
  v_target text;
begin
  if v_owner is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;

  v_target := case p_outcome
    when 'confirmed' then 'confirmed'
    when 'discarded' then 'cancelled'
    -- Il client parla di esiti («confermata», «scartata»), la tabella parla
    -- di stati. La traduzione sta qui e non nel client, così un client
    -- vecchio non può inventarsi uno stato che la tabella non prevede.
    else null
  end;
  if v_target is null then
    raise exception 'unknown outcome %', p_outcome using errcode = '22023';
  end if;

  -- Il lock serve perché due dispositivi possono chiudere lo stesso job nello
  -- stesso istante, ed è esattamente lo scenario che ha generato il difetto.
  select status into v_status
  from kal_tracker.meal_analysis_jobs
  where id = p_job_id
    and owner_id = v_owner
  for update;

  if v_status is null then
    -- Non esiste, oppure non è di chi chiama. Le due cose si rispondono
    -- uguale: dire «esiste ma non è tuo» sarebbe raccontare a un estraneo
    -- che quel job c'è.
    raise exception 'job not found' using errcode = 'P0002';
  end if;

  if v_status in ('confirmed', 'cancelled') then
    -- Già chiuso: si torna lo stato che ha, senza toccarlo. È il caso della
    -- doppia chiamata, e non è un guasto.
    return jsonb_build_object(
      'id', p_job_id,
      'status', v_status,
      'changed', false
    );
  end if;

  if v_status <> 'needs_review' then
    -- Un job ancora in coda o in lavorazione non si chiude da qui: lo
    -- strapperebbe di mano al worker a metà.
    raise exception 'job is % and cannot be resolved', v_status
      using errcode = '22023';
  end if;

  update kal_tracker.meal_analysis_jobs
  set status = v_target,
      completed_at = coalesce(completed_at, now()),
      updated_at = now()
  where id = p_job_id;

  return jsonb_build_object(
    'id', p_job_id,
    'status', v_target,
    'changed', true
  );
end;
$$;

revoke all on function kal_tracker.resolve_meal_analysis_job(uuid, text)
  from public, anon;

grant execute on function kal_tracker.resolve_meal_analysis_job(uuid, text)
  to authenticated;
