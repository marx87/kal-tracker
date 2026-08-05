# Coach360

App privata Flutter di Marco: diario alimentare, allenamenti, composizione corporea e coach in un solo prodotto. Local-first — il diario funziona con rete e Mac spenti — con sincronizzazione Supabase fra telefono e tablet e un worker sul Mac che elabora foto, piani settimanali e rapporti del coach.

> **Il nome del prodotto è Coach360; il repository si chiama ancora `kal-tracker`.** Non è una dimenticanza: il package Android è `it.marcomartelli.kaltracker` e il manifesto OTA già pubblicato punta a `marx87/kal-tracker-releases`. Rinominare l'uno o l'altro romperebbe l'aggiornamento in-app e imporrebbe una reinstallazione da zero. Cambiano il nome mostrato, l'icona e i testi; non gli identificatori.

## Stato attuale

Versione `1.0.0+11`, schema Drift **v7**, migrazioni Supabase applicate fino alla `0009`.

- interfaccia a cinque voci — **Oggi · Cibo · Palestra · Corpo · Piano** — con layout adattivo: barra in basso sul telefono, guida laterale sul tablet;
- **Oggi** orientata all'azione: kcal e proteine rimanenti, allenamento previsto, ricette che ci stanno nel residuo;
- **Cibo**: diario navigabile per giorno, catalogo italiano offline di 795 voci, 152 ricette fit, modelli di pasto, scanner barcode con Open Food Facts, foto del piatto analizzata sul Mac;
- **Palestra**: sessione dal vivo con superset e circuiti, schede, catalogo esercizi, storico — con i 29 allenamenti importati da Gym Tracker;
- **Corpo**: peso e composizione a medie mobili di 7 giorni, grafico ad aree di grasso e massa magra, circonferenze;
- **Obiettivo**: traguardo in composizione (non in peso), ritmo modificabile, verdetto di fattibilità, tre fasi (avvicinamento, consolidamento, mantenimento);
- **Coach**: brief settimanale, semaforo del sovrallenamento, spiegazione dei movimenti falsi del peso, proiezione del traguardo — i numeri li calcola l'app, il modello scrive solo il perché;
- **Piano**: settimana di pasti e allenamenti generata sul Mac, con lista della spesa per reparti;
- backup JSON versionato con checksum SHA-256 e ripristino unisci/sostituisci transazionale;
- sincronizzazione Supabase offline-first (outbox, last-write-wins, tombstone), spenta finché non è configurata;
- release Android firmata con aggiornamento OTA verificato Ed25519;
- oltre 1191 test Flutter, i test Python del worker e 8 controlli statici sullo schema Supabase.

Formule e principi — perché la massa magra è la metrica guida, perché Katch-McArdle e non Mifflin-St Jeor, perché non si salvano né BMI né età metabolica — stanno in [docs/ROADMAP.md](docs/ROADMAP.md).

## Struttura

```text
apps/mobile/             app Flutter
apps/mobile/assets/icon/ marchio e generatore delle icone Android
supabase/migrations/     schema Postgres e RLS
supabase/tests/          controlli statici sulle migrazioni
services/meal_worker/    worker Claude/Codex sul Mac (foto, piani, coach)
scripts/                 catalogo alimenti, ricette, firma e verifica OTA
docs/                    roadmap, architettura, protocollo worker, rilascio
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

Senza `--dart-define` l'app lavora completamente offline. Per collegare Supabase:

```bash
flutter run \
  --dart-define=SUPABASE_URL=https://PROJECT_REF.supabase.co \
  --dart-define=SUPABASE_PUBLISHABLE_KEY=YOUR_PUBLISHABLE_KEY
```

Non inserire mai `service_role`, keystore o credenziali Codex/Claude nell'app o nel repository.

## Icona e schermata d'avvio

Il marchio è geometria, non un disegno: `assets/icon/build_icon.py` lo rigenera in tutte le densità Android — icona di sistema, icona adattiva con livello monocromatico, logo d'avvio chiaro e scuro, glifo delle notifiche.

```bash
cd apps/mobile
python3 assets/icon/build_icon.py
```

`flutter_launcher_icons.yaml` descrive la stessa configurazione per il giorno in cui il pacchetto entrerà fra le `dev_dependencies`.

## Rilascio

- La CI crea un APK debug con application ID separato (`it.marcomartelli.kaltracker.debug`) per gli smoke test.
- Le release installabili richiedono un keystore dedicato e vengono pubblicate nel repository pubblico `marx87/kal-tracker-releases`.
- L'app verifica firma e key ID Ed25519, provenienza del sorgente, application ID, canale, build number, URL esatto, dimensione e SHA-256 prima di aprire l'installer Android.
- iOS richiede una build firmata Ad Hoc o TestFlight; non supporta l'auto-installazione di un IPA dall'app.

Configurazione dettagliata: [docs/OTA.md](docs/OTA.md).

Protocollo least-privilege del worker: [docs/MEAL_WORKER_PROTOCOL.md](docs/MEAL_WORKER_PROTOCOL.md).

Il ponte con Gym Tracker ([docs/GYM_TRACKER_INTEGRATION.md](docs/GYM_TRACKER_INTEGRATION.md)) è superato: dal 5 agosto 2026 le due app sono fuse e l'import è una-tantum.
