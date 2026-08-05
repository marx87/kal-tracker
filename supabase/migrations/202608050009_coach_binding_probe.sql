begin;

-- Sonda di SOLA LETTURA per il binding del coach.
--
-- Nasce da un difetto della diagnostica, non della coda. `kal-meal-worker
-- doctor` provava il binding 'coaching' con un claim vero, perche'
-- `claim_coach_job` e' l'unica delle quattro RPC che guarda
-- `automation_bindings` PRIMA di scegliere un job: `heartbeat_coach_job` e
-- `fail_coach_job` scartano il job inesistente con P0002 e al binding non ci
-- arrivano mai. Ma un claim non e' una domanda: incrementa `attempt_count`, e
-- quando il job acquisito era al nono tentativo il rilascio con
-- `fail_coach_job(retryable => true)` trova `attempt_count < 10` falso e lo
-- chiude come 'failed'. La diagnosi distruggeva il lavoro che doveva
-- diagnosticare, e si firmava nell'error_code.
--
-- Questa funzione risponde alla sola domanda che serve — «questo worker ha un
-- binding 'coaching' attivo?» — senza toccare la coda, senza scrivere nel
-- ledger delle mutazioni e senza dire niente di piu': legge esclusivamente le
-- righe intestate al chiamante.
--
-- Restituisce jsonb e non boolean perche' il worker legge le risposte RPC
-- sempre come oggetti: uno scalare sarebbe l'unico caso speciale del gateway.

create or replace function kal_tracker.coaching_binding_active()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select pg_catalog.jsonb_build_object(
    'active',
    exists (
      select 1
      from kal_tracker.automation_bindings b
      where b.worker_user_id = auth.uid()
        and b.scope = 'coaching'
        and b.is_active
    )
  );
$$;

revoke all privileges on function
  kal_tracker.coaching_binding_active()
  from public, anon, authenticated;

-- Il worker e' un utente `authenticated` come gli altri: la funzione non
-- espone dati di nessuno, dice solo al chiamante se e' abilitato.
grant execute on function
  kal_tracker.coaching_binding_active()
  to authenticated;

notify pgrst, 'reload schema';

commit;
