begin;

-- Allenamenti (Coach360, traguardo M5.2). Gym Tracker viene assorbito: lo
-- storico entra una volta sola dall'export JSON e Firebase si spegne.
--
-- Della sessione si conserva il dato GREZZO — serie, ripetizioni, carico,
-- tempo — e mai i derivati: volume, e1RM, record personali e calorie MET si
-- ricalcolano dalle stesse funzioni pure che girano sul telefono. L'unica
-- eccezione è `total_kcal`, che non è un derivato ma il valore con cui quella
-- sessione è stata effettivamente chiusa.
--
-- Le 13 tabelle rispecchiano la v6 di Drift una a una. Dove il nome remoto
-- diverge da quello locale vale la convenzione già usata per ricette e pasti
-- (vedi supabase/README.md): la traduzione appartiene al livello di
-- sincronizzazione, non allo schema.

-- PRECONDIZIONE. La FK di `body_measurement_values` punta alla coppia
-- (owner_id, id) di `body_measurements`, ma la 0002 su quella tabella ha
-- soltanto `unique (owner_id, source, external_id)` e
-- `unique (owner_id, last_mutation_id)`. Senza questo vincolo la CREATE TABLE
-- fallisce con 42830 e, dato che l'intera migrazione sta in un solo
-- begin/commit, non verrebbe applicato NIENTE: né le tabelle, né i trigger,
-- né le RLS. Va quindi prima delle create table.
alter table kal_tracker.body_measurements
  add constraint body_measurements_owner_id_id_key unique (owner_id, id);

-- 1. Catalogo esercizi. `is_synthetic` marca gli otto stretch di defaticamento
--    che l'app genera da sé: sono righe di sistema, non esercizi di Marco, e
--    ogni schermata di catalogo le filtra. Esistono come righe perché lo
--    storico le cita per id.
create table kal_tracker.exercises (
  id uuid primary key,
  owner_id uuid not null default auth.uid(),
  profile_id uuid not null,
  name text not null check (btrim(name) <> '' and char_length(name) <= 160),
  muscle_group text not null check (muscle_group in (
    'petto', 'schiena', 'spalle', 'bicipiti', 'tricipiti', 'gambe',
    'polpacci', 'addome', 'cardio', 'fullbody', 'mobilita', 'altro'
  )),
  tracking_mode text not null check (tracking_mode in (
    'weightReps', 'bodyweightReps', 'timeOnly', 'timed', 'distanceTime'
  )),
  notes text check (notes is null or char_length(notes) <= 600),
  image_url text check (image_url is null or char_length(image_url) <= 500),
  default_rest_sec integer
    check (default_rest_sec is null or default_rest_sec between 0 and 3600),
  is_preset boolean not null default false,
  is_synthetic boolean not null default false,
  source text not null default 'manual'
    check (source in ('manual', 'gym_tracker', 'cooldown_preset')),
  external_id text check (external_id is null or btrim(external_id) <> ''),
  last_mutation_id uuid not null,
  row_version bigint not null default 1 check (row_version > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  constraint exercises_profile_fk
    foreign key (owner_id, profile_id)
    references kal_tracker.profiles(owner_id, id)
    on delete cascade,
  unique (owner_id, id),
  unique (owner_id, source, external_id),
  unique (owner_id, last_mutation_id)
);

-- 2. Schede. I sei parametri a tempo servono solo quando `is_circuit` è vero,
--    ma restano NOT NULL con i default di Gym: sono la configurazione
--    proposta quando la scheda diventa un circuito, e un NULL costringerebbe
--    ogni lettore a riapplicare gli stessi default a mano.
create table kal_tracker.routines (
  id uuid primary key,
  owner_id uuid not null default auth.uid(),
  profile_id uuid not null,
  name text not null check (btrim(name) <> '' and char_length(name) <= 160),
  notes text check (notes is null or char_length(notes) <= 1000),
  is_circuit boolean not null default false,
  work_sec integer not null default 30 check (work_sec between 1 and 3600),
  short_rest_sec integer not null default 30
    check (short_rest_sec between 0 and 3600),
  long_rest_sec integer not null default 60
    check (long_rest_sec between 0 and 3600),
  rounds integer not null default 3 check (rounds between 1 and 50),
  warmup_work_sec integer not null default 30
    check (warmup_work_sec between 1 and 3600),
  warmup_rest_sec integer not null default 15
    check (warmup_rest_sec between 0 and 3600),
  source text not null default 'manual'
    check (source in ('manual', 'gym_tracker')),
  external_id text check (external_id is null or btrim(external_id) <> ''),
  last_mutation_id uuid not null,
  row_version bigint not null default 1 check (row_version > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  constraint routines_profile_fk
    foreign key (owner_id, profile_id)
    references kal_tracker.profiles(owner_id, id)
    on delete cascade,
  unique (owner_id, id),
  unique (owner_id, source, external_id),
  unique (owner_id, last_mutation_id)
);

-- 3. Le tre liste ordinate della scheda (riscaldamento, principale, finisher)
--    in una tabella sola: stessa forma, attributi diversi, li distingue
--    `block`. `position` è densa e ripartita per blocco perché la finestra dei
--    blocchi a tempo indicizza esattamente il blocco 'main'.
--
--    `exercise_ref_id` è l'id ORIGINALE e non è mai nullo: è la chiave di
--    raggruppamento del dominio. `exercise_id` è solo la FK viva, che si
--    svuota quando l'esercizio viene cancellato; se il raggruppamento pendesse
--    da lì, due esercizi cancellati diversi collasserebbero in una voce sola.
create table kal_tracker.routine_exercises (
  id uuid primary key,
  owner_id uuid not null default auth.uid(),
  routine_id uuid not null,
  exercise_ref_id uuid not null,
  exercise_id uuid,
  block text not null check (block in ('warmup', 'main', 'finisher')),
  position integer not null check (position >= 0),
  exercise_name_snapshot text not null check (
    btrim(exercise_name_snapshot) <> ''
    and char_length(exercise_name_snapshot) <= 160
  ),
  in_superset_with_previous boolean not null default false,
  warmup_duration_sec integer check (
    warmup_duration_sec is null or warmup_duration_sec between 1 and 3600
  ),
  presc_sets integer check (presc_sets is null or presc_sets between 1 and 50),
  presc_reps integer check (presc_reps is null or presc_reps between 1 and 500),
  presc_duration_sec integer check (
    presc_duration_sec is null or presc_duration_sec between 1 and 7200
  ),
  presc_rest_sec integer
    check (presc_rest_sec is null or presc_rest_sec between 0 and 3600),
  last_mutation_id uuid not null,
  row_version bigint not null default 1 check (row_version > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  constraint routine_exercises_routine_fk
    foreign key (owner_id, routine_id)
    references kal_tracker.routines(owner_id, id)
    on delete cascade,
  constraint routine_exercises_exercise_fk
    foreign key (owner_id, exercise_id)
    references kal_tracker.exercises(owner_id, id),
  constraint routine_exercises_ref_consistent check (
    exercise_id is null or exercise_id = exercise_ref_id
  ),
  constraint routine_exercises_warmup_duration check (
    (block = 'warmup') = (warmup_duration_sec is not null)
  ),
  constraint routine_exercises_superset_scope check (
    in_superset_with_previous is false
    or (block = 'main' and position > 0)
  ),
  unique (owner_id, last_mutation_id)
);

-- 4. Blocchi a tempo della scheda: finestra semiaperta [start_idx, end_idx)
--    sulle posizioni del blocco 'main'. `segment_index` è la chiave con cui le
--    sessioni registrano il completamento e con cui le route passano `?seg=N`:
--    deve restare densa da 0 e stabile, quindi è parte della UNIQUE e non un
--    id opaco.
create table kal_tracker.routine_interval_segments (
  id uuid primary key,
  owner_id uuid not null default auth.uid(),
  routine_id uuid not null,
  segment_index integer not null check (segment_index >= 0),
  start_idx integer not null check (start_idx >= 0),
  end_idx integer not null,
  work_sec integer not null default 40 check (work_sec between 1 and 3600),
  rest_sec integer not null default 20 check (rest_sec between 0 and 3600),
  long_rest_sec integer not null default 0
    check (long_rest_sec between 0 and 3600),
  rounds integer not null default 1 check (rounds between 1 and 50),
  last_mutation_id uuid not null,
  row_version bigint not null default 1 check (row_version > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  constraint routine_interval_segments_routine_fk
    foreign key (owner_id, routine_id)
    references kal_tracker.routines(owner_id, id)
    on delete cascade,
  constraint routine_interval_segments_window check (end_idx > start_idx),
  unique (owner_id, last_mutation_id)
);

-- 5. Piano settimanale ricorrente: giorno ISO -> scheda. I giorni assenti sono
--    riposo, quindi la riga mancante È l'informazione.
--
--    `routine_external_id` conserva l'id anche quando la scheda non esiste
--    più: nei dati reali il mercoledì punta a una scheda cancellata, e
--    ricollegarlo per nome inventerebbe una storia mai avvenuta.
create table kal_tracker.routine_weekly_plan (
  id uuid primary key,
  owner_id uuid not null default auth.uid(),
  profile_id uuid not null,
  weekday smallint not null check (weekday between 1 and 7),
  routine_id uuid,
  routine_external_id uuid,
  routine_name_snapshot text check (
    routine_name_snapshot is null or char_length(routine_name_snapshot) <= 160
  ),
  last_mutation_id uuid not null,
  row_version bigint not null default 1 check (row_version > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  constraint routine_weekly_plan_profile_fk
    foreign key (owner_id, profile_id)
    references kal_tracker.profiles(owner_id, id)
    on delete cascade,
  constraint routine_weekly_plan_routine_fk
    foreign key (owner_id, routine_id)
    references kal_tracker.routines(owner_id, id),
  constraint routine_weekly_plan_ref_consistent check (
    routine_id is null or routine_id = routine_external_id
  ),
  unique (owner_id, last_mutation_id)
);

-- 6. Sessioni. `ended_at` nullo significa «in corso», ed è l'invariante
--    protetta dall'indice unico parziale più sotto: in Firestore serviva un
--    documento puntatore e una risoluzione lato client quando ne restavano due
--    aperte.
--
--    NESSUN tetto a 86400 su `final_duration_seconds` e
--    `accumulated_pause_seconds`: in Gym il clamp a 24 h vive solo nel getter
--    di lettura, mai nello scrittore. Un vincolo qui rifiuterebbe la chiusura
--    di una sessione dimenticata aperta più a lungo — nei dati reali ce n'è
--    una da 536 ore, ed è esattamente il motivo per cui `external_workouts`
--    (che il tetto ce l'ha) non poteva ospitare questo storico.
--    `duration_suspect` la marca: il dato resta grezzo e segnalato, non
--    rettificato.
create table kal_tracker.workouts (
  id uuid primary key,
  owner_id uuid not null default auth.uid(),
  profile_id uuid not null,
  started_at timestamptz not null,
  ended_at timestamptz check (ended_at is null or ended_at >= started_at),
  paused_at timestamptz check (paused_at is null or ended_at is null),
  accumulated_pause_seconds integer not null default 0
    check (accumulated_pause_seconds >= 0),
  final_duration_seconds integer
    check (final_duration_seconds is null or final_duration_seconds >= 0),
  duration_suspect boolean not null default false,
  routine_id uuid,
  routine_external_id uuid,
  routine_name_snapshot text check (
    routine_name_snapshot is null or char_length(routine_name_snapshot) <= 160
  ),
  notes text check (notes is null or char_length(notes) <= 1000),
  -- numeric(12,6) e non (10,3): i valori veri hanno dodici decimali
  -- (477.7840476190476), e il pull li riscrive sul telefono. L'arrotondamento
  -- resta, ma alla sesta cifra: 5e-7 kcal invece dei 5e-4 di (10,3), su una
  -- stima MET. L'esattezza piena vorrebbe `double precision`, cioè il tipo con
  -- cui il telefono lo tiene: è il cambio da fare se un giorno un test
  -- pretenderà il round-trip identico.
  total_kcal numeric(12,6) check (total_kcal is null or total_kcal >= 0),
  mood smallint check (mood is null or mood between 1 and 5),
  rpe smallint check (rpe is null or rpe between 1 and 10),
  satisfaction smallint
    check (satisfaction is null or satisfaction between 1 and 5),
  feedback_notes text
    check (feedback_notes is null or char_length(feedback_notes) <= 1000),
  -- NULL e 0 sono stati diversi: NULL vuol dire «mai premiato» ed è la
  -- guardia di idempotenza dell'assegnazione XP.
  xp_earned integer check (xp_earned is null or xp_earned >= 0),
  resume_path text check (resume_path is null or char_length(resume_path) <= 200),
  -- Locale è una colonna di testo con dentro il JSON del checkpoint: qui è
  -- jsonb perché il server possa almeno rifiutare quello malformato.
  circuit_checkpoint jsonb check (
    circuit_checkpoint is null
    or (
      jsonb_typeof(circuit_checkpoint) = 'object'
      and octet_length(circuit_checkpoint::text) <= 65536
    )
  ),
  synced_to_health_connect boolean not null default false,
  health_sync_state text check (
    health_sync_state is null
    or health_sync_state in ('writing', 'synced', 'uncertain')
  ),
  -- Il claim della scrittura su Health Connect (M5.6, ancora da implementare)
  -- è un uuid come ogni altro claim dello schema: chi scriverà quel codice
  -- deve generarlo, non inventare un formato proprio.
  health_sync_claim_id uuid,
  health_sync_attempted_at timestamptz,
  health_sync_completed_at timestamptz,
  source text not null default 'manual'
    check (source in ('manual', 'gym_tracker')),
  external_id text check (external_id is null or btrim(external_id) <> ''),
  last_mutation_id uuid not null,
  row_version bigint not null default 1 check (row_version > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  constraint workouts_profile_fk
    foreign key (owner_id, profile_id)
    references kal_tracker.profiles(owner_id, id)
    on delete cascade,
  constraint workouts_routine_fk
    foreign key (owner_id, routine_id)
    references kal_tracker.routines(owner_id, id),
  constraint workouts_routine_ref_consistent check (
    routine_id is null or routine_id = routine_external_id
  ),
  unique (owner_id, id),
  unique (owner_id, source, external_id),
  unique (owner_id, last_mutation_id)
);

-- 7. Righe della sessione. Nome, modalità e gruppo muscolare sono istantanee
--    congelate: il nome sopravvive alle rinomine e la modalità è quella
--    EFFETTIVA di quella sessione — nei dati reali 72 righe su 250 divergono
--    dal catalogo di oggi.
create table kal_tracker.workout_exercises (
  id uuid primary key,
  owner_id uuid not null default auth.uid(),
  workout_id uuid not null,
  exercise_ref_id uuid not null,
  exercise_id uuid,
  position integer not null check (position >= 0),
  exercise_name_snapshot text not null check (
    btrim(exercise_name_snapshot) <> ''
    and char_length(exercise_name_snapshot) <= 160
  ),
  tracking_mode text not null check (tracking_mode in (
    'weightReps', 'bodyweightReps', 'timeOnly', 'timed', 'distanceTime'
  )),
  muscle_group_snapshot text check (
    muscle_group_snapshot is null or muscle_group_snapshot in (
      'petto', 'schiena', 'spalle', 'bicipiti', 'tricipiti', 'gambe',
      'polpacci', 'addome', 'cardio', 'fullbody', 'mobilita', 'altro'
    )
  ),
  rest_seconds integer
    check (rest_seconds is null or rest_seconds between 0 and 3600),
  is_warmup boolean not null default false,
  is_cooldown boolean not null default false,
  is_finisher boolean not null default false,
  is_in_superset_with_previous boolean not null default false,
  interval_segment_index integer
    check (interval_segment_index is null or interval_segment_index >= 0),
  last_mutation_id uuid not null,
  row_version bigint not null default 1 check (row_version > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  constraint workout_exercises_workout_fk
    foreign key (owner_id, workout_id)
    references kal_tracker.workouts(owner_id, id)
    on delete cascade,
  constraint workout_exercises_exercise_fk
    foreign key (owner_id, exercise_id)
    references kal_tracker.exercises(owner_id, id),
  constraint workout_exercises_ref_consistent check (
    exercise_id is null or exercise_id = exercise_ref_id
  ),
  constraint workout_exercises_single_block check (
    is_warmup::int + is_cooldown::int + is_finisher::int <= 1
  ),
  constraint workout_exercises_superset_scope check (
    is_in_superset_with_previous is false or position > 0
  ),
  unique (owner_id, id),
  unique (owner_id, last_mutation_id)
);

-- 8. Serie. I cinque campi metrici restano NULL e senza default: «non
--    inserito» e «zero» sono valori diversi. Nessun vincolo lega la metrica
--    alla modalità, perché nei dati veri esistono serie 'weightReps' con le
--    sole ripetizioni e serie 'timed' con il peso: un vincolo del tipo «se
--    weightReps allora weight_kg NOT NULL» farebbe fallire l'import.
--
--    `workout_id` è denormalizzato e NON esiste nella tabella Drift: lo deriva
--    il mapper dal padre. Serve perché la sostituzione in blocco dei figli
--    avviene con un solo swap per sessione; uno swap per esercizio lascerebbe
--    vive le serie degli esercizi rimossi dalla sessione.
create table kal_tracker.workout_sets (
  id uuid primary key,
  owner_id uuid not null default auth.uid(),
  workout_id uuid not null,
  workout_exercise_id uuid not null,
  position integer not null check (position >= 0),
  weight_kg numeric(7,3)
    check (weight_kg is null or weight_kg between 0 and 1000),
  reps integer check (reps is null or reps between 0 and 1000),
  duration_sec integer
    check (duration_sec is null or duration_sec between 0 and 86400),
  distance_m numeric(10,2)
    check (distance_m is null or distance_m between 0 and 200000),
  rpe smallint check (rpe is null or rpe between 1 and 10),
  is_warmup boolean not null default false,
  completed boolean not null default false,
  last_mutation_id uuid not null,
  row_version bigint not null default 1 check (row_version > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  constraint workout_sets_workout_fk
    foreign key (owner_id, workout_id)
    references kal_tracker.workouts(owner_id, id)
    on delete cascade,
  constraint workout_sets_exercise_fk
    foreign key (owner_id, workout_exercise_id)
    references kal_tracker.workout_exercises(owner_id, id)
    on delete cascade,
  unique (owner_id, last_mutation_id)
);

-- 9. Punti dolenti segnalati dopo la sessione. Non è una CSV in colonna
--    perché la domanda vera è «quante volte la spalla destra negli ultimi due
--    mesi», e a quella una stringa non risponde.
create table kal_tracker.workout_pain_points (
  id uuid primary key,
  owner_id uuid not null default auth.uid(),
  workout_id uuid not null,
  label text not null check (btrim(label) <> '' and char_length(label) <= 40),
  last_mutation_id uuid not null,
  row_version bigint not null default 1 check (row_version > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  constraint workout_pain_points_workout_fk
    foreign key (owner_id, workout_id)
    references kal_tracker.workouts(owner_id, id)
    on delete cascade,
  unique (owner_id, last_mutation_id)
);

-- 10. Marcatori dei blocchi a tempo di una sessione. I due marker sono
--     INDIPENDENTI e non un enum a due valori: in Gym sono due liste che
--     possono contenere lo stesso indice quando la scheda cambia fra l'uscita
--     anticipata e il rientro, e hanno precedenze diverse nella ripresa (prima
--     i parziali). Comprimerli in una colonna sola manderebbe la ripresa del
--     circuito sulla schermata sbagliata.
--
--     `completion_signature` è il JSON canonico della configurazione, salvato
--     verbatim perché il confronto avviene contro firme già scritte, e
--     appartiene solo al marker di completamento.
create table kal_tracker.workout_interval_segments (
  id uuid primary key,
  owner_id uuid not null default auth.uid(),
  workout_id uuid not null,
  segment_index integer not null check (segment_index >= 0),
  completed_marker boolean not null default false,
  partial_marker boolean not null default false,
  completion_signature text check (
    completion_signature is null or char_length(completion_signature) <= 8192
  ),
  last_mutation_id uuid not null,
  row_version bigint not null default 1 check (row_version > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  constraint workout_interval_segments_workout_fk
    foreign key (owner_id, workout_id)
    references kal_tracker.workouts(owner_id, id)
    on delete cascade,
  constraint workout_interval_segments_has_marker check (
    completed_marker or partial_marker
  ),
  constraint workout_interval_segments_signature_scope check (
    completion_signature is null or completed_marker
  ),
  unique (owner_id, last_mutation_id)
);

-- 11. XP, streak, obiettivi e preferenze: il singleton di Gym. Non sono
--     colonne di `profiles` perché quella tabella è referenziata da dodici
--     tabelle e si estende solo con colonne nullable.
--
--     `gym_body_weight_kg` è il peso congelato nel profilo Gym: si conserva
--     per spiegare i `total_kcal` storici, ma NON è la fonte del MET — quella
--     è l'ultima pesata reale (traguardo M5.7).
--
--     `last_workout_day` è una DATE e non un istante: il client deve mandare
--     la data di calendario romana ('2026-08-04'), non l'istante UTC che la
--     rappresenta ('2026-08-03T22:00:00Z'), altrimenti Postgres tronca al
--     giorno prima e lo streak risulta interrotto. È lo stesso motivo per cui
--     `birth_date` nella 0006 è una data.
create table kal_tracker.workout_profile_stats (
  id uuid primary key,
  owner_id uuid not null default auth.uid(),
  profile_id uuid not null,
  total_xp integer not null default 0 check (total_xp >= 0),
  current_streak integer not null default 0 check (current_streak >= 0),
  longest_streak integer not null default 0
    check (longest_streak >= current_streak),
  last_workout_day date,
  weekly_workout_goal integer not null default 3
    check (weekly_workout_goal between 1 and 14),
  weekly_kcal_goal integer not null default 1500
    check (weekly_kcal_goal between 0 and 100000),
  reminder_enabled boolean not null default false,
  reminder_hour smallint not null default 18
    check (reminder_hour between 0 and 23),
  reminder_minute smallint not null default 0
    check (reminder_minute between 0 and 59),
  health_connect_enabled boolean not null default false,
  voice_enabled boolean not null default true,
  gym_body_weight_kg numeric(6,2) check (
    gym_body_weight_kg is null or gym_body_weight_kg between 20 and 500
  ),
  gym_exported_at timestamptz,
  last_mutation_id uuid not null,
  row_version bigint not null default 1 check (row_version > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  constraint workout_profile_stats_profile_fk
    foreign key (owner_id, profile_id)
    references kal_tracker.profiles(owner_id, id)
    on delete cascade,
  unique (owner_id, last_mutation_id)
);

-- 12. Trofei sbloccati: di persistito c'è solo lo slug, il catalogo dei
--     traguardi (nome, icona, bonus XP, predicato) resta codice.
--
--     `unlocked_at` è nullabile e per i ventidue importati resta vuoto:
--     riempirlo con l'istante dell'import schiaccerebbe la timeline sul giorno
--     della migrazione facendo sembrare vero un dato che non lo è. Il limite
--     superiore certo è `workout_profile_stats.gym_exported_at`.
create table kal_tracker.workout_achievements (
  id uuid primary key,
  owner_id uuid not null default auth.uid(),
  profile_id uuid not null,
  slug text not null check (btrim(slug) <> '' and char_length(slug) <= 60),
  unlocked_at timestamptz,
  last_mutation_id uuid not null,
  row_version bigint not null default 1 check (row_version > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  constraint workout_achievements_profile_fk
    foreign key (owner_id, profile_id)
    references kal_tracker.profiles(owner_id, id)
    on delete cascade,
  unique (owner_id, last_mutation_id)
);

-- 13. Circonferenze libere di una pesata ('Vita', 'Braccio', …: le etichette
--     le decide Marco). Non sono colonne di `body_measurements` proprio perché
--     l'insieme è aperto, e non sono un JSON perché la domanda è «la vita
--     negli ultimi sei mesi», cioè una serie nel tempo.
create table kal_tracker.body_measurement_values (
  id uuid primary key,
  owner_id uuid not null default auth.uid(),
  measurement_id uuid not null,
  label text not null check (btrim(label) <> '' and char_length(label) <= 40),
  value numeric(7,2) not null check (value > 0 and value <= 1000),
  last_mutation_id uuid not null,
  row_version bigint not null default 1 check (row_version > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  constraint body_measurement_values_measurement_fk
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
    'exercises',
    'routines',
    'routine_exercises',
    'routine_interval_segments',
    'routine_weekly_plan',
    'workouts',
    'workout_exercises',
    'workout_sets',
    'workout_pain_points',
    'workout_interval_segments',
    'workout_profile_stats',
    'workout_achievements',
    'body_measurement_values'
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

-- Gli indici sono tutti parziali sulle righe vive: l'unicità di una posizione
-- vale solo fra quelle, altrimenti la sostituzione in blocco dei figli
-- (tombstone della vecchia riga + upsert della nuova nella stessa posizione)
-- sbatterebbe contro il proprio tombstone.
create index exercises_name_idx
  on kal_tracker.exercises(owner_id, profile_id, lower(name))
  where deleted_at is null;
create index routines_name_idx
  on kal_tracker.routines(owner_id, profile_id, lower(name))
  where deleted_at is null;
create unique index routine_exercises_position_idx
  on kal_tracker.routine_exercises(owner_id, routine_id, block, position)
  where deleted_at is null;
create index routine_exercises_ref_idx
  on kal_tracker.routine_exercises(owner_id, exercise_ref_id)
  where deleted_at is null;
create unique index routine_interval_segments_index_idx
  on kal_tracker.routine_interval_segments(owner_id, routine_id, segment_index)
  where deleted_at is null;
create unique index routine_weekly_plan_day_idx
  on kal_tracker.routine_weekly_plan(owner_id, profile_id, weekday)
  where deleted_at is null;
create index workouts_time_idx
  on kal_tracker.workouts(owner_id, profile_id, started_at desc)
  where deleted_at is null;
-- Una sola sessione aperta per profilo: in Firestore era un documento
-- puntatore da riconciliare a mano, qui è un vincolo del database.
create unique index workouts_one_active_idx
  on kal_tracker.workouts(owner_id, profile_id)
  where deleted_at is null and ended_at is null;
create unique index workout_exercises_position_idx
  on kal_tracker.workout_exercises(owner_id, workout_id, position)
  where deleted_at is null;
create index workout_exercises_ref_idx
  on kal_tracker.workout_exercises(owner_id, exercise_ref_id)
  where deleted_at is null;
create unique index workout_sets_position_idx
  on kal_tracker.workout_sets(owner_id, workout_exercise_id, position)
  where deleted_at is null;
create index workout_sets_workout_idx
  on kal_tracker.workout_sets(owner_id, workout_id)
  where deleted_at is null;
create unique index workout_pain_points_label_idx
  on kal_tracker.workout_pain_points(owner_id, workout_id, label)
  where deleted_at is null;
create unique index workout_interval_segments_index_idx
  on kal_tracker.workout_interval_segments(owner_id, workout_id, segment_index)
  where deleted_at is null;
create unique index workout_profile_stats_profile_idx
  on kal_tracker.workout_profile_stats(owner_id, profile_id)
  where deleted_at is null;
create unique index workout_achievements_slug_idx
  on kal_tracker.workout_achievements(owner_id, profile_id, slug)
  where deleted_at is null;
create unique index body_measurement_values_label_idx
  on kal_tracker.body_measurement_values(owner_id, measurement_id, label)
  where deleted_at is null;

-- Nessuna policy di DELETE: la cancellazione è sempre un tombstone, come per
-- tutte le altre tabelle sincronizzate.
do $policies$
declare
  table_name text;
begin
  foreach table_name in array array[
    'exercises',
    'routines',
    'routine_exercises',
    'routine_interval_segments',
    'routine_weekly_plan',
    'workouts',
    'workout_exercises',
    'workout_sets',
    'workout_pain_points',
    'workout_interval_segments',
    'workout_profile_stats',
    'workout_achievements',
    'body_measurement_values'
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
  on kal_tracker.exercises,
     kal_tracker.routines,
     kal_tracker.routine_exercises,
     kal_tracker.routine_interval_segments,
     kal_tracker.routine_weekly_plan,
     kal_tracker.workouts,
     kal_tracker.workout_exercises,
     kal_tracker.workout_sets,
     kal_tracker.workout_pain_points,
     kal_tracker.workout_interval_segments,
     kal_tracker.workout_profile_stats,
     kal_tracker.workout_achievements,
     kal_tracker.body_measurement_values
  to authenticated;

grant all on
  kal_tracker.exercises,
  kal_tracker.routines,
  kal_tracker.routine_exercises,
  kal_tracker.routine_interval_segments,
  kal_tracker.routine_weekly_plan,
  kal_tracker.workouts,
  kal_tracker.workout_exercises,
  kal_tracker.workout_sets,
  kal_tracker.workout_pain_points,
  kal_tracker.workout_interval_segments,
  kal_tracker.workout_profile_stats,
  kal_tracker.workout_achievements,
  kal_tracker.body_measurement_values
  to service_role;

-- `external_workouts` (0002) era il ponte per gli allenamenti importati da
-- fuori, con un tetto di 24 h sulla durata e nessun dettaglio delle serie.
-- Resta in piedi con le sue righe, ma non è più la destinazione di niente.
comment on table kal_tracker.external_workouts is
  'Superata dalla 0007: gli allenamenti vivono in kal_tracker.workouts. '
  'Nessun client scrive più qui.';

notify pgrst, 'reload schema';

commit;
