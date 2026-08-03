# Roadmap di Kal Tracker

Kal Tracker è un'app privata iOS/Android per Marco. Il diario deve continuare a funzionare offline; Supabase sincronizza i dispositivi e il Mac mini elabora in seguito le fotografie tramite un worker Codex o Claude senza API a consumo.

> **Stato al 3 agosto 2026.** La fase 3 è stata sviluppata con Claude Code (crediti Codex esauriti) direttamente nel working tree locale. Suite: **122 test Flutter verdi**, `flutter analyze` pulito, `dart format` pulito. Schema Drift portato a **v3** (migrazione v1→v3 e v2→v3 testate). Le note di handoff per chi riprende il lavoro sono in fondo a questo documento.

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
- [ ] configurazione sicura delle chiavi e prima Release firmata — **solo Marco**: `scripts/bootstrap_android_ota.sh --create` + secret GitHub (vedi `docs/OTA.md`);
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
- [ ] sync offline-first Supabase con retry, conflitti e tombstone (l'outbox locale si riempie già, manca il push/pull).

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
- [ ] immagini per le ricette;
- [ ] scelta del numero di porzioni all'inserimento nel diario (oggi fisso a 1).

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

1. **(solo Marco)** Creare le chiavi release con due backup cifrati (`scripts/bootstrap_android_ota.sh`), configurare i secret GitHub e pubblicare il primo APK firmato `v0.1.0`. Attenzione: il baseline OTA `21e728b` deve restare nella storia di `main` → merge normale o fast-forward delle PR, **mai squash o rebase**.
2. **(solo Marco)** Creare un progetto Supabase dedicato, `supabase db push` delle **quattro** migrazioni e verifica RLS con due utenti di test.
3. Implementare Auth Marco e push/pull dell'outbox con conflitti tramite `row_version` (leggere prima le note di handoff qui sotto: due payload da uniformare).
4. Collegare upload foto e revisione Flutter al worker Codex già predisposto.
5. Provare il servizio `launchd` sul Mac e misurarlo su foto di pasti realmente pesati.
6. Lookup barcode Open Food Facts (il campo barcode locale esiste già).
7. Implementare il bridge Gym Tracker in sola lettura.

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

**Piccole cose rimaste aperte**
- Eliminare un modello di pasto non chiede conferma.
- L'app non ha ancora un'icona propria né splash screen personalizzata.
- Il build number è `0.2.0+2`: alla prima release firmata va portato a `0.3.0+3` (l'OTA rifiuta regressioni di build number).
