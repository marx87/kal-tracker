# Roadmap di Kal Tracker

Kal Tracker è un'app privata iOS/Android per Marco. Il diario deve continuare a funzionare offline; Supabase sincronizza i dispositivi e il Mac mini elabora in seguito le fotografie tramite un worker Codex o Claude senza API a consumo.

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
- [ ] configurazione sicura delle chiavi e prima Release firmata;
- [ ] provisioning iPhone scelto e test su dispositivo reale.

### M1 — Diario personale

- [x] obiettivi calorie e macro collegati alla dashboard;
- [x] catalogo offline, recenti, preferiti e inserimento manuale;
- [x] peso, acqua, cronologia e grafico;
- [x] calcoli e snapshot nutrizionali deterministici;
- [ ] modifica, copia e modelli di pasto;
- [ ] sync offline-first Supabase con retry, conflitti e tombstone;
- [ ] export e ripristino verificati.

Criterio: una giornata completa è registrabile con Mac e rete spenti, poi si sincronizza senza duplicati.

### M2 — Catalogo e barcode

- catalogo italiano iniziale curato;
- barcode Open Food Facts con fonte e versione;
- cache offline e correzione rapida;
- controlli di coerenza sui nutrienti.

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
- [ ] modifica/duplicazione di una ricetta esistente;
- [ ] immagini, tag, filtri e ricerca;
- [ ] suggerimenti in base ai macro rimanenti.

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

1. Creare le chiavi release con due backup cifrati e pubblicare il primo APK firmato.
2. Collegare un progetto Supabase dedicato e applicare/testare le tre migrazioni.
3. Implementare Auth Marco e push/pull dell'outbox con conflitti tramite `row_version`.
4. Collegare upload foto e revisione Flutter al worker Codex già predisposto.
5. Provare il servizio sul Mac e misurarlo su foto di pasti realmente pesati.
6. Implementare il bridge Gym Tracker in sola lettura.
