begin;

-- Composizione corporea e anagrafica del profilo (Coach360, traguardo M6.1).
--
-- Della bilancia si conserva la misura GREZZA: `impedance_ohm` è l'unica cosa
-- che il dispositivo misura davvero, tutto il resto è formula. Le percentuali
-- derivate viaggiano insieme alla `formula_version` che le ha prodotte, così
-- una formula migliore ricalcola lo storico invece di spezzarlo in due serie
-- incoerenti.
--
-- Non esistono colonne per le masse in kg (peso x percentuale), per il BMI
-- (peso / altezza^2) né per i giudizi proprietari della bilancia (eta
-- metabolica, peso ottimale, tipo di corpo): i primi si calcolano, gli altri
-- non sono misure.

-- 1. Anagrafica: senza altezza, nascita e sesso non si calcolano BMI, BMR ne
--    le formule di composizione. Nullable perche i profili gia esistenti non
--    li hanno e vanno chiesti, non inventati. `birth_date` e una data e non un
--    timestamp, cosi non puo slittare di un giorno cambiando fuso.
alter table kal_tracker.profiles
  add column if not exists height_cm numeric(5,1)
    check (height_cm is null or height_cm between 50 and 260),
  add column if not exists birth_date date
    check (birth_date is null or birth_date > date '1900-01-01'),
  add column if not exists sex text
    check (sex is null or sex in ('M', 'F'));

-- 2. Composizione corporea. `has_impedance` distingue la pesata completa da
--    quella con i piedi appoggiati male, dove la bilancia restituisce il solo
--    peso: in quel caso i derivati restano vuoti invece di sembrare misure.
alter table kal_tracker.body_measurements
  add column if not exists has_impedance boolean not null default false,
  add column if not exists impedance_ohm numeric(7,2)
    check (impedance_ohm is null or
           (impedance_ohm > 0 and impedance_ohm <= 2000)),
  add column if not exists body_fat_pct numeric(5,2)
    check (body_fat_pct is null or body_fat_pct between 0 and 100),
  add column if not exists muscle_pct numeric(5,2)
    check (muscle_pct is null or muscle_pct between 0 and 100),
  add column if not exists skeletal_muscle_pct numeric(5,2)
    check (skeletal_muscle_pct is null or
           skeletal_muscle_pct between 0 and 100),
  add column if not exists bone_pct numeric(5,2)
    check (bone_pct is null or bone_pct between 0 and 100),
  add column if not exists protein_pct numeric(5,2)
    check (protein_pct is null or protein_pct between 0 and 100),
  add column if not exists water_pct numeric(5,2)
    check (water_pct is null or water_pct between 0 and 100),
  add column if not exists subcutaneous_fat_pct numeric(5,2)
    check (subcutaneous_fat_pct is null or
           subcutaneous_fat_pct between 0 and 100),
  add column if not exists visceral_fat_index integer
    check (visceral_fat_index is null or visceral_fat_index between 1 and 60),
  add column if not exists bmr_kcal integer
    check (bmr_kcal is null or (bmr_kcal > 0 and bmr_kcal < 10000)),
  add column if not exists formula_version text
    check (formula_version is null or btrim(formula_version) <> '');

-- 3. Sorgenti scrivibili dal client.
--
--    Le policy della migrazione 0002 ammettevano dal client il solo
--    source = 'kal_tracker', perche ogni altra provenienza sarebbe arrivata da
--    un bridge con identita dedicata. Con la fusione quel disegno decade:
--    l'app legge la bilancia da se via Bluetooth, importa il CSV Renpho e
--    importa una volta sola lo storico di Gym Tracker. Tutte queste righe
--    nascono ormai sul telefono.
--
--    'kal_tracker' resta ammesso: e il valore delle righe gia scritte e non va
--    riscritto. L'unicita (owner_id, source, external_id) della 0002 continua
--    a proteggere dai doppioni di importazione.
drop policy if exists body_measurements_insert_manual
  on kal_tracker.body_measurements;
drop policy if exists body_measurements_update_manual
  on kal_tracker.body_measurements;

create policy body_measurements_insert_client
  on kal_tracker.body_measurements for insert to authenticated
  with check (
    owner_id = (select auth.uid())
    and source in ('kal_tracker', 'manual', 'renpho_ble', 'renpho_csv',
                   'gym_tracker', 'health_connect')
  );

create policy body_measurements_update_client
  on kal_tracker.body_measurements for update to authenticated
  using (
    owner_id = (select auth.uid())
    and source in ('kal_tracker', 'manual', 'renpho_ble', 'renpho_csv',
                   'gym_tracker', 'health_connect')
  )
  with check (
    owner_id = (select auth.uid())
    and source in ('kal_tracker', 'manual', 'renpho_ble', 'renpho_csv',
                   'gym_tracker', 'health_connect')
  );

-- 4. Le pesate si leggono quasi sempre come serie ordinata nel tempo per
--    calcolare le medie mobili a 7 giorni: l'indice della 0002 su
--    (owner_id, profile_id, measured_at desc) copre gia questo accesso.

notify pgrst, 'reload schema';

commit;
