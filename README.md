# Kal Tracker

App privata Flutter per il diario alimentare di Marco, con funzionamento local-first, sincronizzazione Supabase, analisi fotografica futura e collegamento a Gym Tracker.

## Stato attuale

Il primo vertical slice è operativo:

- app Flutter iOS/Android;
- profilo locale Marco;
- diario giornaliero diviso per pasto;
- inserimento manuale di grammi e valori per 100 g;
- calcolo deterministico di calorie e macro;
- persistenza Drift/SQLite;
- tombstone e outbox locale per la sincronizzazione futura;
- fondazione OTA Android con manifest Ed25519 firmato;
- test di dominio, database su memoria e disco, cambio ora legale, interfaccia e firma del manifest;
- CI GitHub riproducibile e flusso di release Android firmato con protezione anti-rollback.

Supabase non è ancora collegato a un progetto remoto e l’OTA resta disabilitato nelle build locali finché non viene incorporata la chiave pubblica.

## Struttura

```text
apps/mobile/             app Flutter
supabase/migrations/     schema Postgres e RLS
services/meal_worker/    worker AI, fase successiva
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
