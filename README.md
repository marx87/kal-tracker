# Kal Tracker

App privata Flutter per il diario alimentare di Marco, con funzionamento local-first, sincronizzazione Supabase, analisi fotografica sul Mac mini e collegamento a Gym Tracker.

## Stato attuale

La beta locale `0.2.0` è operativa (fase 3 completata il 3 agosto 2026):

- app Flutter iOS/Android;
- dashboard giocosa con profilo Marco, anello calorie e quattro pasti;
- diario navigabile per giorno (frecce, selettore data, «Torna a oggi»), modifica delle voci con anteprima live, duplica, copia di un pasto da un altro giorno e modelli di pasto riapplicabili;
- catalogo offline con ricerca, preferiti, recenti, aggiunta rapida e alimenti personali (creazione, modifica, filtro «Solo i miei», controllo di coerenza Atwater);
- obiettivi calorie/macro, acqua giornaliera, peso, cronologia e grafico;
- ricette fit con modifica, duplicazione, tag, ricerca/filtri offline e suggerimenti in base ai macro rimanenti;
- backup locale: export JSON versionato con checksum SHA-256 e ripristino unisci/sostituisci transazionale (Progressi → Backup);
- calcolo deterministico di calorie e macro, mai delegato all'AI;
- persistenza Drift/SQLite con migrazioni `v1 → v3` verificate;
- tombstone e outbox locale per la sincronizzazione futura;
- schema Supabase con RLS, Storage foto privato, coda worker a lease/privilegi minimi e migrazione per i modelli di pasto;
- adapter Codex CLI strutturato, senza API key e senza calcolo di calorie;
- fondazione OTA Android con manifest Ed25519 firmato e protezione anti-rollback;
- client di sincronizzazione Supabase (push/pull dell'outbox, conflitti last-write-wins, backoff) con schermata dedicata, spento finché non configurato;
- worker foto con provider selezionabile: Claude CLI predefinito, Codex disponibile;
- 154 test Flutter, 47 test Python e tooling di sicurezza eseguiti in CI;
- build APK debug e iOS Simulator verificate.

Supabase non è ancora collegato a un progetto remoto. Upload foto, sincronizzazione tra dispositivi e import Gym Tracker restano quindi disattivati. Anche l’OTA di produzione resta disabilitato finché non vengono create e configurate le chiavi definitive; l’APK debug usa un package separato e non è una baseline OTA.

## Struttura

```text
apps/mobile/             app Flutter
supabase/migrations/     schema Postgres e RLS
services/meal_worker/    adapter e servizio automatico Codex sul Mac mini
docs/                    architettura e rilascio
.github/workflows/       CI e release Android
```

## Avvio locale

Prerequisiti: Flutter 3.44.6 o successivo compatibile, Xcode, Android SDK e CocoaPods.

```bash
cd apps/mobile
flutter pub get
dart run build_runner build
flutter test
flutter run
```

Senza `--dart-define` l’app lavora completamente offline. Per collegare Supabase:

```bash
flutter run \
  --dart-define=SUPABASE_URL=https://PROJECT_REF.supabase.co \
  --dart-define=SUPABASE_PUBLISHABLE_KEY=YOUR_PUBLISHABLE_KEY
```

Non inserire mai `service_role`, keystore o credenziali Codex/Claude nell’app o nel repository.

## Rilascio

- La CI crea un APK debug con application ID separato (`it.marcomartelli.kaltracker.debug`) per gli smoke test.
- Le release installabili richiedono un keystore dedicato e vengono pubblicate nel repository pubblico `marx87/kal-tracker-releases`.
- L’app verifica firma e key ID Ed25519, provenienza del sorgente, application ID, canale, build number, URL esatto, dimensione e SHA-256 prima di aprire l’installer Android.
- iOS richiede una build firmata Ad Hoc o TestFlight; non supporta l’auto-installazione di un IPA dall’app.

Configurazione dettagliata: [docs/OTA.md](docs/OTA.md).

Collegamento verificato con Gym Tracker: [docs/GYM_TRACKER_INTEGRATION.md](docs/GYM_TRACKER_INTEGRATION.md).

Protocollo least-privilege del worker: [docs/MEAL_WORKER_PROTOCOL.md](docs/MEAL_WORKER_PROTOCOL.md).
