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

Stato: in corso.

- [x] monorepo Flutter iOS/Android;
- [x] package `it.marcomartelli.kaltracker`;
- [x] CI Android/iOS;
- [x] database Drift, profilo Marco e outbox;
- [x] migrazione Supabase con RLS e sync ledger;
- [x] release Android firmata e OTA con manifest Ed25519;
- [ ] configurazione sicura delle chiavi e prima Release firmata;
- [ ] provisioning iPhone scelto e test su dispositivo reale.

### M1 — Diario personale

- obiettivi calorie e macro;
- alimenti personali, recenti e preferiti;
- modifica, copia e modelli di pasto;
- peso, acqua e andamento settimanale;
- sync offline-first Supabase con retry, conflitti e tombstone;
- export e ripristino verificati.

Criterio: una giornata completa è registrabile con Mac e rete spenti, poi si sincronizza senza duplicati.

### M2 — Catalogo e barcode

- catalogo italiano iniziale curato;
- barcode Open Food Facts con fonte e versione;
- cache offline e correzione rapida;
- controlli di coerenza sui nutrienti.

### M3 — Foto assistita sul Mac mini

Flusso: `Flutter → Storage privato + job Supabase → worker launchd → Codex/Claude → bozza → conferma → diario`.

- riduzione foto e rimozione EXIF/GPS;
- coda con lease, timeout, retry e recupero dopo sleep;
- una sola analisi alla volta;
- JSON Schema obbligatorio;
- alimenti alternativi, grammi stimati, confidenza e dubbi;
- eliminazione della foto temporanea;
- benchmark Codex/Claude sullo stesso corpus personale.

Criterio: nessuna proposta AI entra nel diario senza conferma e un Mac spento non blocca l'inserimento manuale.

### M4 — Ricette fit

- ingredienti, porzioni e ridimensionamento automatico;
- calcolo per ricetta e per porzione;
- preferiti, tag, filtri e ricerca;
- suggerimenti in base ai macro rimanenti;
- inserimento della porzione nel diario.

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

1. Creare le chiavi release con backup cifrato e pubblicare il primo APK firmato.
2. Collegare un progetto Supabase dedicato e applicare/testare le RLS.
3. Implementare push/pull dell'outbox con conflitti tramite `row_version`.
4. Completare diario, alimenti e obiettivi prima di iniziare la fotografia.
5. Costruire il worker Mac con Codex come primo adapter.
6. Aggiungere ricette e soltanto dopo il bridge Gym Tracker.
