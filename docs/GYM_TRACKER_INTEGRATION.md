# Collegamento con Gym Tracker

> ⛔ **DOCUMENTO SUPERATO — 5 agosto 2026.** Marco ha scelto la **fusione totale** al posto del bridge:
> Gym Tracker viene assorbito nell'app unificata e poi spento. Il piano descritto qui sotto
> (replica continua Firestore → Supabase, credenziale read-only, checkpoint, `external_workouts`)
> **non va implementato**: l'export completo pesa 351 KB ed è un import una-tantum.
> Fa fede `ROADMAP.md`, traguardo **M5**. Resta valido di questo documento soltanto il
> **mapping dei campi** più in basso, utile a scrivere l'importer.

## Sorgente verificata

- repository: `marx87/gym-tracker-source`;
- package Android: `com.marcomart.gym_tracker`;
- backend: Firebase Auth + Firestore;
- workout: `users/{uid}/workouts/{workoutId}`;
- misure: `users/{uid}/measurements/{measurementId}`.

Gym Tracker salva gia per gli allenamenti conclusi i campi necessari a Kal
Tracker: `startedAt`, `endedAt`, `finalDurationSeconds`, `routineName`,
`totalKcal`, `rpe`, `mood` e `satisfaction`. Le calorie sono una stima MET e
restano sempre distinte dal budget alimentare.

## Flusso scelto

```text
Gym Tracker / Firestore
        | sola lettura
        v
bridge sul Mac mini -----> Supabase kal_tracker.external_workouts
                                   |
                                   v
                         Kal Tracker iOS / Android
```

Il bridge usa connessioni in uscita e non espone porte domestiche. Per ogni
documento crea una chiave idempotente `(owner_id, source, external_id)`, con
`source = gym_tracker`; rileggere lo stesso workout non crea duplicati.

Il collegamento Firestore e preferibile a un passaggio esclusivamente Health
Connect perche rende gli stessi dati disponibili anche nell'app iOS. Su Android
Health Connect potra essere aggiunto come accelerazione/fallback, non come
seconda fonte autorevole dello stesso workout.

## Identita e segreti

Gym Tracker parte con Firebase Auth anonimo e supporta il collegamento Google.
Prima del bridge l'account che contiene lo storico deve essere collegato a
Google, cosi il relativo UID rimane recuperabile dopo reinstallazioni.

Il bridge avra:

- credenziale Firebase con sola lettura sul progetto Gym Tracker;
- identita Supabase dedicata o RPC limitata all'upsert degli allenamenti;
- segreti nel Portachiavi macOS, mai nel repository o in variabili globali;
- checkpoint locale dell'ultima sincronizzazione e rilettura sovrapposta per
  recuperare eventuali aggiornamenti tardivi.

Non verra usata la `service_role` dentro l'app Flutter.

## Mapping

| Gym Tracker | Kal Tracker | Regola |
|---|---|---|
| ID documento | `external_id` | invariato |
| `startedAt` | `started_at` | UTC |
| `endedAt` | `ended_at` | importare solo se valorizzato |
| `finalDurationSeconds` | `duration_seconds` | massimo 24 ore |
| `totalKcal` | `energy_kcal` | mostrare come stima |
| `routineName` | `routine_name` | snapshot |
| `rpe` | `rpe` | 1–10 |
| timestamp modifica | `source_updated_at` | usato per upsert |

Le misure con `weightKg` confluiscono in `body_measurements` con
`source = gym_tracker`, sempre deduplicate tramite `external_id`.

## Regole prodotto

- Le calorie allenamento non aumentano automaticamente le calorie disponibili.
- La dashboard mostra separatamente “mangiate” e “stimate nell'allenamento”.
- L'eventuale compensazione calorica sara una preferenza esplicita e disattiva
  per impostazione predefinita.
- Gym Tracker resta indipendente: il bridge non scrive mai nel suo Firestore.

## Criteri di attivazione

1. Progetto Supabase scelto e migrazioni applicate.
2. Account Gym Tracker collegato a Google e UID confermato.
3. Credenziale Firebase read-only creata e salvata in Portachiavi.
4. Dieci workout importati senza duplicati, inclusa una rilettura completa.
5. Arresto/riavvio del Mac e recupero automatico del checkpoint verificati.
