# Roadmap di Kal Tracker

Kal Tracker è un'app privata iOS/Android per Marco. Il diario deve continuare a funzionare offline; Supabase sincronizza i dispositivi e il Mac mini elabora in seguito le fotografie tramite un worker Codex o Claude senza API a consumo.

> **Stato al 3 agosto 2026 (sera).** Fasi 3 e 4 sviluppate con Claude Code (crediti Codex esauriti). Suite: **154 test Flutter + 47 test Python verdi**, analyze e format puliti. Schema Drift **v3**. Infrastruttura VIVA: chiavi di firma generate (bundle in `~/Documents/KalTracker-Signing/ota-2026-08` — Marco deve ancora fare i 2 backup cifrati), environment GitHub `release` completo di tutti i secret, progetto Supabase reale `kamljzffqwfaluicznti` (eu-central-1) con le 4 migrazioni applicate, registrazioni disabilitate, utente Marco creato e schema `kal_tracker` esposto a PostgREST. Le note di handoff sono in fondo al documento.

## Principi

1. L'AI riconosce e propone; Marco corregge e conferma.
2. Calorie e macro derivano sempre da valori nutrizionali per 100 g e quantità.
3. Drift/SQLite è la fonte operativa sul telefono; Supabase è sincronizzazione e backup.
4. Nessuna credenziale Codex, Claude, `service_role` o chiave di firma entra nell'app.
5. Gym Tracker resta indipendente e viene collegato con una replica in sola lettura.

## Traguardi

### M0 — Fondazione installabile

Stato: codice completato, configurazione privata ancora da eseguire.

- [x] monorepo Flutter iOS/Android;
- [x] package `it.marcomartelli.kaltracker`;
- [x] CI Android/iOS;
- [x] database Drift, profilo Marco e outbox;
- [x] migrazione Supabase con RLS e sync ledger;
- [x] release Android firmata e OTA con manifest Ed25519;
- [x] configurazione sicura delle chiavi (bundle generato e validato, secret nell'environment `release`, PAT fine-grained per il repo release creato da Marco con scadenza 03/08/2027); *(fase 4)*
- [ ] prima release firmata `v0.1.0` pubblicata (workflow in corso; corretti due difetti del workflow alla prima esecuzione reale: aapt rimosso dalle build-tools 37 → aapt2, e assert silenziosi → guardie con messaggio);
- [ ] provisioning iPhone scelto e test su dispositivo reale.

### M1 — Diario personale

- [x] obiettivi calorie e macro collegati alla dashboard;
- [x] catalogo offline, recenti, preferiti e inserimento manuale;
- [x] peso, acqua, cronologia e grafico;
- [x] calcoli e snapshot nutrizionali deterministici;
- [x] navigazione tra i giorni (frecce, selettore data in italiano, «Torna a oggi», nessun giorno futuro); *(fase 3)*
- [x] modifica di una voce con anteprima nutrizionale live e ricalcolo deterministico; *(fase 3)*
- [x] duplica voce e copia di un intero pasto da un altro giorno; *(fase 3)*
- [x] modelli di pasto: salva un pasto come modello, applica, rinomina, elimina (soft), con outbox `meal_template`; *(fase 3)*
- [x] export e ripristino verificati: backup JSON versionato con checksum SHA-256, ripristino in modalità unisci/sostituisci in una sola transazione, schermata in Progressi → Backup; *(fase 3)*
- [x] sync offline-first Supabase: gateway astratto + motore push→pull (mutation id = riga di outbox, backoff 1m→24h, cursore persistente sul change feed, conflitti last-write-wins su `updated_at`, tombstone rispettati), auth email+password con sessione persistita, schermata Progressi → Sincronizzazione; con `AppConfig` vuoto resta tutto spento; *(fase 4)*
- [ ] collaudo end-to-end della sync su dispositivo reale contro il progetto Supabase (build con `--dart-define`; il backend è già pronto e lo schema `kal_tracker` è esposto).

Criterio: una giornata completa è registrabile con Mac e rete spenti, poi si sincronizza senza duplicati.

### M2 — Catalogo e barcode

- [x] alimenti personali: creazione, modifica, cancellazione soft, filtro «Solo i miei»; la modifica di un alimento di base (seed) crea una copia personale senza alterare l'originale; *(fase 3)*
- [x] campo codice a barre (solo cifre, vincolo di unicità con errore leggibile); *(fase 3)*
- [x] controllo di coerenza sui nutrienti: avviso non bloccante quando le calorie dichiarate si discostano oltre il 20% dai fattori di Atwater; *(fase 3)*
- [ ] catalogo italiano iniziale curato (oggi: 12 seed + alimenti personali);
- [ ] lookup barcode Open Food Facts con fonte e versione, cache offline.

### M3 — Foto assistita sul Mac mini

Flusso: `Flutter → Storage privato + job Supabase → worker launchd → Codex/Claude → bozza → conferma → diario`.

- [ ] acquisizione Flutter, riduzione foto e rimozione EXIF/GPS;
- [x] schema coda con lease, timeout, retry e claim atomico;
- [x] identità worker Supabase dedicata, senza `service_role`;
- [x] una sola analisi alla volta e pulizia dei file temporanei;
- [x] Codex CLI effimera/read-only con JSON Schema obbligatorio;
- [x] adapter Claude CLI (`claude --print --output-format json`, sessione effimera, stesso schema) con provider selezionabile e **claude come predefinito** — i crediti Codex sono esauriti; *(fase 4)*
- [x] alimenti alternativi, grammi stimati, confidenza e dubbi;
- [ ] schermata Flutter di revisione e conferma;
- [ ] installazione e prova reale del servizio `launchd`;
- [ ] benchmark Codex/Claude sullo stesso corpus personale.

Criterio: nessuna proposta AI entra nel diario senza conferma e un Mac spento non blocca l'inserimento manuale.

### M4 — Ricette fit

- [x] sei ricette fit iniziali;
- [x] ricette personali con ingredienti, grammi, porzioni e istruzioni;
- [x] calcolo per ricetta e per porzione;
- [x] preferiti e inserimento della porzione nel diario;
- [x] modifica di una ricetta esistente (ingredienti aggiunti/rimossi, posizioni ricompattate) e duplicazione; *(fase 3)*
- [x] tag (chip, max 8, CSV minuscolo), ricerca per nome e ingrediente, filtri per tag e preferite, tutto offline; *(fase 3)*
- [x] suggerimenti deterministici «Adatte a quello che ti resta oggi» in base ai macro rimanenti (`recipe_suggestions.dart`, funzione pura testata); *(fase 3)*
- [x] eliminazione di una ricetta con conferma; *(fase 3)*
- [x] scelta del numero di porzioni all'inserimento nel diario, con totali esatti da `NutritionCalculator`; *(fase 4)*
- [ ] immagini per le ricette.

### M5 — Collegamento Gym Tracker

- bridge idempotente Firestore → Supabase;
- workout completati, durata, volume, RPE e calorie stimate;
- vincolo `(owner_id, source, external_id)` contro i duplicati;
- calorie allenamento mostrate separatamente dal budget alimentare.

### M6 — Beta stabile

- Android e iPhone reali;
- modalità aereo, rete lenta, Mac spento e retry multipli;
- backup, reinstallazione e ripristino;
- accessibilità, dark mode, notifiche ed export;
- sette giorni di uso reale senza perdita dati o duplicati.

## Ordine del prossimo lavoro

1. **(solo Marco)** Due backup cifrati su supporti separati di `~/Documents/KalTracker-Signing` (chiavi di firma + password Supabase: è l'unica copia).
2. Collaudo end-to-end della sync: build con `--dart-define=SUPABASE_URL=… --dart-define=SUPABASE_PUBLISHABLE_KEY=…`, accesso con `marco.mart87@gmail.com` (password in `KalTracker-Signing/supabase/marco-app-password.txt`), giornata offline → sync senza duplicati su due dispositivi.
3. Installare la `v0.1.0` firmata sul telefono e poi pubblicare una release aggiornata per collaudare il banner OTA.
4. Acquisizione foto in Flutter (riduzione + rimozione EXIF/GPS), schermata di revisione/conferma, upload sullo Storage.
5. Installare e provare il servizio `launchd` del worker sul Mac (provider claude, credenziali worker nel Portachiavi).
6. Lookup barcode Open Food Facts (il campo barcode locale esiste già).
7. Implementare il bridge Gym Tracker in sola lettura.

Regola sempre valida: il baseline OTA `21e728b` deve restare nella storia di `main` → merge normale o fast-forward, **mai squash o rebase**.

## Note di handoff (fase 3, 3 agosto 2026)

Scelte fatte e cose da sapere prima di continuare. Fonte: sviluppo + revisione avversariale con Claude Code.

**Schema e migrazioni**
- Drift `schemaVersion = 3`: nuove tabelle `MealTemplates` e `MealTemplateItems`, nuova colonna `FitRecipes.tags` (CSV minuscolo, max 240). Il ramo `from < 3` aggiunge `tags` **solo se `from >= 2`**: il `createTable(fitRecipes)` del ramo v1→v2 la crea già, senza la guardia la migrazione da v1 esplodeva con `duplicate column name`. Non rimuovere quella guardia.
- Il test `app_database_v2_test.dart` ora si aspetta `user_version = 3` (unica riga cambiata: copre di fatto v1→v3). Il nuovo `app_database_v3_test.dart` usa una fixture SQL v2 scritta a mano; chi porterà lo schema a v4 dovrà scrivere la propria fixture v3 con lo stesso pattern.
- Migrazione Supabase `202608030004_meal_templates.sql`: sul remoto le tabelle si chiamano `kal_tracker.meal_templates` / `meal_template_items` e i tag stanno su `kal_tracker.recipes` (il nome remoto delle ricette è `recipes`, non `fit_recipes`). L'UNIQUE sulle posizioni è un indice parziale `WHERE deleted_at IS NULL` per permettere la sostituzione in blocco delle voci. Il CHECK sui tag pretende stringhe minuscole non vuote: il client già normalizza così.

**Per chi scrive la sync (punto 3 qui sopra)**
- Il payload outbox `meal_template` elenca le voci **senza id per voce** (solo position + valori); le tabelle remote hanno id per voce. Decidere in fase di sync se generare gli id lato client o trattare le voci come sostituzione in blocco (coerente con l'indice parziale remoto).
- Il payload `fit_recipe` è stato uniformato alla forma del backup (tags CSV, ingredienti con id/recipe_id/position): usare quella come contratto.
- I tombstone del ripristino usano la chiave giusta per entità: `food_preference` → `{profile_id, food_id}`, `nutrition_target` → `{profile_id}`, il resto → `{id}`.

**Comportamenti scelti deliberatamente (non bug)**
- A mezzanotte il giorno selezionato **non** salta a oggi: chi sta guardando ieri sera resta lì, l'etichetta diventa «Ieri» e c'è «Torna a oggi». Far avanzare solo chi è su «oggi» richiederebbe un notifier dedicato al posto dello `StateProvider`.
- Eliminare una voce del diario chiede conferma ma non offre «Annulla»: un vero undo richiede un'API di ripristino in `DiaryRepository` che oggi non esiste (`duplicateEntry` rifiuta le righe cancellate). Duplica/copia/modelli invece hanno l'Annulla.
- «Ripristina da file» nella schermata Backup chiede il percorso (o il JSON incollato): in pubspec non c'è `file_picker` e la fase 3 non aggiungeva dipendenze. Se si vuole il selettore nativo, aggiungere `file_picker` è il primo candidato.
- La modalità «Sostituisci» del ripristino svuota tutte le tabelle utente, profilo compreso, e reinserisce il profilo del backup: serve a evitare il doppio profilo su un telefono nuovo.
- La sezione «Adatte a quello che ti resta oggi» nelle ricette compare solo quando il diario di oggi ha già almeno una voce.

**Note della fase 4 (sync client)**
- `food_preference` NON viene sincronizzata (nessuna tabella remota; i preferiti restano locali) e `foods.is_favorite` remoto non viene toccato.
- `recipe_items.food_id` viaggia come `null`: il collegamento all'alimento resta locale, sul server va lo snapshot (nome + valori per 100 g).
- Push "a testa di coda": al primo errore la coda si ferma per preservare l'ordine per entità; gli errori permanenti non-auth scartano la riga con avviso in UI (nessun archivio dead-letter persistente, per ora).
- La traduzione payload locale ⇄ tabelle remote vive tutta in `sync_gateway.dart` (nomi campi diversi, id derivati con uuid v5 per template/target, tombstone-prima-di-insert per i figli con UNIQUE parziale): ogni nuovo entityType va mappato lì.
- Il primo collegamento reale non è ancora stato provato: la logica è coperta da 30+ test su gateway/motore con fake, ma PostgREST vero può riservare sorprese (punto 2 dell'ordine di lavoro).

**Infrastruttura (viva dal 3 agosto)**
- Supabase: progetto `kamljzffqwfaluicznti` (eu-central-1, org Marfloor), migrazioni 0001-0004 applicate, `disable_signup` attivo, schema `kal_tracker` negli Exposed schemas, utente `marco.mart87@gmail.com` confermato.
- GitHub: environment `release` (solo branch `main`) con i 6 secret e le 4 variabili; PAT release con scadenza 03/08/2027.
- Chiavi e password: tutto in `~/Documents/KalTracker-Signing` (bundle firma `ota-2026-08/`, password Supabase in `supabase/`).

**Piccole cose rimaste aperte**
- L'app non ha ancora un'icona propria né splash screen personalizzata.
- Il build number è `0.2.0+2`: alla prossima release da main va portato a `0.3.0+3` (l'OTA rifiuta regressioni di build number).
