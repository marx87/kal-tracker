begin;

-- Check-in, Obiettivo e impedenze multiple (Coach360, schema Drift v7).
--
-- Le prime due tabelle raccolgono due file JSON che vivevano fuori dal
-- database del telefono: fuori dal backup, fuori da questa sincronizzazione e
-- invisibili al coach, che invece li vuole — il semaforo del sovrallenamento
-- legge sonno ed energia (M8.3) e il motore adattivo legge l'obiettivo (M7).
--
-- La terza chiude un buco della lettura Bluetooth: la bilancia di Marco dà una
-- sola impedenza di corpo intero, ma una a otto elettrodi ne dà cinque o dieci
-- e una multifrequenza le ripete a frequenze diverse. Si conserva la misura
-- GREZZA, sempre: le percentuali sono formula, l'impedenza no.
--
-- Le tre tabelle rispecchiano la v7 di Drift una a una.

-- 1. Anagrafica della pesata: quale bilancia l'ha prodotta e la trama così
--    com'è arrivata. `raw_payload` non è un capriccio: se un domani si scopre
--    che quel pacchetto conteneva un campo che non sapevamo leggere, lo
--    storico si ridecodifica invece di ricominciare.
--
--    Sono ADD COLUMN e non una tabella ricreata perché `body_measurements` è
--    referenziata (da `body_measurement_values` della 0007 e ora dalle
--    impedenze): la regola vale identica sui due lati.
alter table kal_tracker.body_measurements
  add column if not exists device_model text
    check (device_model is null or
           (btrim(device_model) <> '' and char_length(device_model) <= 60)),
  add column if not exists raw_payload text
    check (raw_payload is null or
           (btrim(raw_payload) <> '' and char_length(raw_payload) <= 512));

-- 2. Il check-in del mattino. UNA tabella sola: sonno ed energia sono lo
--    stesso gesto sullo stesso giorno, e due tabelle sarebbero due righe da
--    tenere allineate senza una domanda che le voglia separate.
--
--    Entrambi i campi sono facoltativi — un check-in con il solo sonno è un
--    check-in valido, e il coach deve funzionare con dati mancanti — ma una
--    riga VIVA senza nessuno dei due farebbe contare come «compilato» un
--    giorno vuoto.
--
--    `day` è una data di calendario e non un timestamptz: mezzanotte di Roma
--    è le 22:00 del giorno prima in UTC, e il check-in del mattino deve cadere
--    nello stesso giorno della pesata e del diario.
--
--    Il peso NON sta qui: vive in `body_measurements`. Due tabelle con lo
--    stesso numero diventano due numeri diversi il giorno in cui una sbaglia.
create table kal_tracker.daily_check_ins (
  id uuid primary key,
  owner_id uuid not null default auth.uid(),
  profile_id uuid not null,
  day date not null,
  sleep_hours numeric(4,2)
    check (sleep_hours is null or sleep_hours between 0 and 16),
  energy_score integer
    check (energy_score is null or energy_score between 1 and 5),
  last_mutation_id uuid not null,
  row_version bigint not null default 1 check (row_version > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  constraint daily_check_ins_profile_fk
    foreign key (owner_id, profile_id)
    references kal_tracker.profiles(owner_id, id)
    on delete cascade,
  constraint daily_check_ins_not_blank check (
    deleted_at is not null
    or sleep_hours is not null
    or energy_score is not null
  ),
  -- Unicità TOTALE e non parziale sulle righe vive, a differenza delle tabelle
  -- a posizione della 0007. Là serviva il filtro perché la sostituzione in
  -- blocco dei figli sbatteva contro i propri tombstone; qui non esiste nessuna
  -- sostituzione in blocco: il client fa un upsert sulla coppia
  -- (profilo, giorno) e un giorno cancellato e poi ricompilato riprende la sua
  -- riga. L'id, per giunta, è derivato dalla chiave naturale (uuid v5 di
  -- profilo + giorno), quindi due dispositivi offline scrivono la stessa riga
  -- invece di litigare.
  unique (owner_id, profile_id, day),
  unique (owner_id, last_mutation_id)
);

-- 3. L'Obiettivo, con il suo storico. Una riga per traguardo: quello in corso
--    è la riga con `closed_at` nullo, gli altri sono il passato. Cambiare
--    traguardo non azzera niente.
--
--    `start_weight_kg` e `start_fat_free_mass_kg` sono lo stato di partenza di
--    QUEL traguardo e non si toccano più. Tendenze, pesate e TDEE misurato non
--    stanno qui: sono proprietà del corpo, non del traguardo.
--
--    **Nessun indice unico sull'obiettivo aperto**, a differenza di
--    `workouts_one_active_idx`. Due dispositivi offline che fissano un
--    traguardo ciascuno produrrebbero due righe aperte, e un vincolo qui
--    bloccherebbe la sincronizzazione invece di risolvere: l'elezione del
--    corrente (il più recente per `started_at`) la fa il client in lettura.
--
--    Il limite di sicurezza dello 0,7 % del peso a settimana non è un CHECK: è
--    una frazione del peso CORRENTE, che questa riga non conosce, e vive nel
--    dominio. Qui si ferma solo l'assurdo.
create table kal_tracker.goals (
  id uuid primary key,
  owner_id uuid not null default auth.uid(),
  profile_id uuid not null,
  target_weight_kg numeric(5,2) not null
    check (target_weight_kg between 20 and 500),
  target_level text not null check (target_level in (
    'soft', 'normal', 'lean', 'athletic', 'defined', 'veryDefined'
  )),
  pace_kg_per_week numeric(4,2) not null
    check (pace_kg_per_week > 0 and pace_kg_per_week <= 5),
  started_at timestamptz not null,
  start_weight_kg numeric(5,2) not null
    check (start_weight_kg between 20 and 500),
  start_fat_free_mass_kg numeric(5,2) not null
    check (start_fat_free_mass_kg > 0 and start_fat_free_mass_kg <= 500),
  phase text not null default 'approach'
    check (phase in ('approach', 'consolidation', 'maintenance')),
  phase_started_at timestamptz,
  closed_at timestamptz,
  outcome text
    check (outcome is null or outcome in ('reached', 'replaced', 'abandoned')),
  last_mutation_id uuid not null,
  row_version bigint not null default 1 check (row_version > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  constraint goals_profile_fk
    foreign key (owner_id, profile_id)
    references kal_tracker.profiles(owner_id, id)
    on delete cascade,
  -- Un esito senza data di chiusura è un obiettivo chiuso a metà.
  constraint goals_outcome_needs_closing check (
    outcome is null or closed_at is not null
  ),
  constraint goals_closed_after_start check (
    closed_at is null or closed_at >= started_at
  ),
  constraint goals_phase_after_start check (
    phase_started_at is null or phase_started_at >= started_at
  ),
  unique (owner_id, last_mutation_id)
);

-- 4. Ogni valore di impedenza che la bilancia ha emesso in una pesata.
--
--    `frequency_hz` è NULLABILE perché la maggior parte dei protocolli non la
--    dichiara, e scrivere «50 kHz» perché è il valore tipico sarebbe salvare
--    una supposizione accanto a una misura.
--
--    Il tetto è più alto di quello di `body_measurements.impedance_ohm`
--    (2000 Ω): alle basse frequenze e sui singoli arti l'impedenza è
--    legittimamente maggiore di quella di corpo intero a 50 kHz.
--
--    Il valore di corpo intero compare anche in
--    `body_measurements.impedance_ohm`: là è il numero che alimenta la formula
--    BIA, qui è il verbale completo della lettura.
create table kal_tracker.body_impedance_readings (
  id uuid primary key,
  owner_id uuid not null default auth.uid(),
  measurement_id uuid not null,
  segment text not null check (segment in (
    'whole', 'leftArm', 'rightArm', 'leftLeg', 'rightLeg', 'trunk'
  )),
  frequency_hz integer
    check (frequency_hz is null or frequency_hz between 1 and 10000000),
  ohm numeric(7,2) not null check (ohm > 0 and ohm <= 5000),
  last_mutation_id uuid not null,
  row_version bigint not null default 1 check (row_version > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  constraint body_impedance_readings_measurement_fk
    foreign key (owner_id, measurement_id)
    references kal_tracker.body_measurements(owner_id, id)
    on delete cascade,
  unique (owner_id, last_mutation_id)
);

do $triggers$
declare
  table_name text;
begin
  foreach table_name in array array[
    'daily_check_ins',
    'goals',
    'body_impedance_readings'
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

-- Il check-in si legge quasi sempre come serie ordinata nel tempo: è così che
-- il brief della domenica confronta sonno ed energia con carichi e peso.
create index daily_check_ins_day_idx
  on kal_tracker.daily_check_ins(owner_id, profile_id, day desc)
  where deleted_at is null;
create index goals_started_idx
  on kal_tracker.goals(owner_id, profile_id, started_at desc)
  where deleted_at is null;
create index body_impedance_readings_measurement_idx
  on kal_tracker.body_impedance_readings(owner_id, measurement_id)
  where deleted_at is null;

-- Due letture dello stesso segmento alla stessa frequenza sono la stessa
-- lettura scritta due volte. Servono due indici perché in Postgres, come in
-- SQLite, due NULL non collidono mai: senza il secondo, la lettura di corpo
-- intero senza frequenza dichiarata entrerebbe quante volte si vuole.
create unique index body_impedance_readings_declared_idx
  on kal_tracker.body_impedance_readings(
    owner_id, measurement_id, segment, frequency_hz
  )
  where deleted_at is null and frequency_hz is not null;
create unique index body_impedance_readings_undeclared_idx
  on kal_tracker.body_impedance_readings(owner_id, measurement_id, segment)
  where deleted_at is null and frequency_hz is null;

-- Nessuna policy di DELETE: la cancellazione è sempre un tombstone, come per
-- tutte le altre tabelle sincronizzate.
do $policies$
declare
  table_name text;
begin
  foreach table_name in array array[
    'daily_check_ins',
    'goals',
    'body_impedance_readings'
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
  on kal_tracker.daily_check_ins,
     kal_tracker.goals,
     kal_tracker.body_impedance_readings
  to authenticated;

grant all on
  kal_tracker.daily_check_ins,
  kal_tracker.goals,
  kal_tracker.body_impedance_readings
  to service_role;

comment on table kal_tracker.daily_check_ins is
  'Sonno ed energia percepita, un giorno per riga. Il peso non sta qui: vive '
  'in body_measurements. Il client fa upsert su (profile_id, day), mai '
  'cancella-e-reinserisci.';
comment on table kal_tracker.goals is
  'Traguardi di composizione corporea, correnti e archiviati. La riga con '
  'closed_at nullo e started_at piu recente e l obiettivo in corso.';

notify pgrst, 'reload schema';

commit;
