# Roadmap di Coach360 (ex Kal Tracker)

App privata Android/iOS per Marco: diario alimentare, allenamenti, composizione corporea e coach in un solo prodotto. Il diario deve continuare a funzionare offline; Supabase sincronizza i dispositivi e il Mac mini elabora in seguito foto, piani e analisi tramite un worker Claude senza API a consumo.

> **Svolta del 5 agosto 2026 — fusione con Gym Tracker.** Decisione di Marco: **fusione totale**, non bridge. La base tecnica è Kal Tracker (local-first, cross-platform, infrastruttura già viva); Gym Tracker (`marx87/gym-tracker-source`, Firestore, solo Android) viene assorbito e poi spento. La grafica di riferimento è quella di Kal, il layout adattivo per tablet viene invece preso dal codice di Gym. Priorità Android (telefono + tablet di Marco), iOS più avanti. I traguardi **M5→M11** qui sotto sono nuovi; **M0–M4-bis restano il registro di quanto già fatto** e non cambiano.

> **Stato al 3 agosto 2026 (sera).** Fasi 3 e 4 sviluppate con Claude Code (crediti Codex esauriti). Suite: **154 test Flutter + 47 test Python verdi**, analyze e format puliti. Schema Drift **v3**. Infrastruttura VIVA: chiavi di firma generate (bundle in `~/Documents/KalTracker-Signing/ota-2026-08` — Marco deve ancora fare i 2 backup cifrati), environment GitHub `release` completo di tutti i secret, progetto Supabase reale `kamljzffqwfaluicznti` (eu-central-1) con le 4 migrazioni applicate, registrazioni disabilitate, utente Marco creato e schema `kal_tracker` esposto a PostgREST. Le note di handoff sono in fondo al documento.

## Principi

1. L'AI riconosce e propone; Marco corregge e conferma.
2. Calorie e macro derivano sempre da valori nutrizionali per 100 g e quantità.
3. Drift/SQLite è la fonte operativa sul telefono; Supabase è sincronizzazione e backup.
4. Nessuna credenziale Codex, Claude, `service_role` o chiave di firma entra nell'app.
5. **Si conservano le misure grezze, mai i giudizi altrui.** Dalla bilancia si salva l'impedenza; peso, percentuali e derivati si calcolano con formule nostre, versionate. Così una formula migliore ricalcola tutto lo storico invece di spezzarlo.
6. **Il coach non produce numeri.** Il motore deterministico calcola TDEE, target e trend; Claude legge quei numeri e scrive soltanto il perché — come già accade per il piano settimanale.
7. **La composizione corporea si legge a medie mobili di 7 giorni.** La BIA è rumorosa: nei dati reali di Marco il grasso è variato di 0,1 punti in 5 minuti e di 0,7 punti in 15 ore a peso identico. Nessun confronto giorno-su-giorno.

## Profilo di Marco (dati fissati il 5 agosto 2026)

| Dato | Valore | Fonte |
|---|---|---|
| Altezza | **182 cm** | confermato da Marco; coerente col BMI Renpho su 3 righe (182,1 / 182,0 / 181,9) |
| Data di nascita | **13/09/1987** | confermata da Marco |
| Sesso | **M** | confermato da Marco |
| Peso di riferimento | 95,80 kg (05/08/2026) | bilancia Renpho |
| Massa magra | 71,66 kg | bilancia Renpho |

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
- [x] prima release firmata **`v0.1.0-b1` PUBBLICATA** su `marx87/kal-tracker-releases` (APK + manifest OTA Ed25519 + SHA256SUMS + provenienza); il workflow, mai eseguito prima, è stato corretto in 3 punti rotti dalle build-tools 37 del runner (aapt→aapt2, assert muti→guardie con messaggio, nuovo formato output apksigner);
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
- [x] catalogo italiano offline: 795 piatti e alimenti in 10 categorie con porzioni tipiche e alias di ricerca, validazione automatica (range + Atwater) e revisione a campione; importer versionato e idempotente (`scripts/build_food_catalog.py` rigenera l'asset dai chunk sorgente); *(fase 7, v0.6.0-b6)*
- [x] scanner barcode (mobile_scanner) con lookup Open Food Facts v2, local-first e cache offline (source 'barcode'); conferma esplicita coi valori modificabili, mai resurrezioni implicite di alimenti eliminati; *(fase 8, v0.7.0-b7)*

### M3 — Foto assistita sul Mac mini

Flusso: `Flutter → Storage privato + job Supabase → worker launchd → Codex/Claude → bozza → conferma → diario`.

- [x] acquisizione Flutter, riduzione foto (1280px, JPEG q80) e rimozione EXIF/GPS sul telefono; *(fase 5)*
- [x] schema coda con lease, timeout, retry e claim atomico;
- [x] identità worker Supabase dedicata, senza `service_role`;
- [x] una sola analisi alla volta e pulizia dei file temporanei;
- [x] Codex CLI effimera/read-only con JSON Schema obbligatorio;
- [x] adapter Claude CLI (`claude --print --output-format json`, sessione effimera, stesso schema) con provider selezionabile e **claude come predefinito** — i crediti Codex sono esauriti; *(fase 4)*
- [x] alimenti alternativi, grammi stimati, confidenza e dubbi;
- [x] schermata Flutter di revisione e conferma (voci modificabili, conferma esplicita, giorno preservato, idempotente); *(fase 5)*
- [x] worker INSTALLATO e in esecuzione sul Mac via launchd (identità automation dedicata, password nel Portachiavi, binding attivo, `doctor` 6/6); *(fase 5)*
- [x] prova reale end-to-end COLLAUDATA con una foto vera di Marco (3/08 sera): telefono → Storage → coda → worker launchd → Claude CLI → needs_review in 37 s; scoperto e corretto sul campo il rifiuto del meta-schema draft 2020-12 da parte della CLI;
- [x] calorie stimate nelle proposte: il modello compila per100g (mai kcal totali), la revisione mostra «≈ N kcal · stima da foto» e il totale delle selezionate, sempre via NutritionCalculator; retrocompatibile coi risultati vecchi; *(fase 6, v0.5.0-b5)*
- [ ] benchmark Codex/Claude sullo stesso corpus personale.

Criterio: nessuna proposta AI entra nel diario senza conferma e un Mac spento non blocca l'inserimento manuale.

### M4 — Ricette fit

- [x] ricettario fit di 152 ricette originali (colazioni/pranzi/cene/spuntini/dolci) con ingredienti pesati e macro CALCOLATE; tag onesti (proteico >=20 g/porz, leggero <=500 kcal, veloce <=25 min); asset versionato `ricettario_fit_v1.json` + `scripts/build_recipe_catalog.py`; importer una-volta-per-profilo con id deterministici e tombstone rispettati; *(fase 9, v0.8.0-b8)*

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

### M4-bis — Piano settimanale AI e lista della spesa *(fase 10, v0.9.0-b9)*

- [x] quinta voce «Piano» nella barra; schema Drift **v4** (`weekly_plans`, `weekly_plan_slots`) e coda Supabase `weekly_plan_jobs` con RPC a privilegi minimi;
- [x] generazione via Claude CLI sul Mac: l'app invia il catalogo REALE delle ricette con i macro per porzione e i target, il modello può solo scegliere `recipeId` esistenti e porzioni (0,5-4); un id inventato invalida il risultato;
- [x] nessun numero dal modello: kcal e macro sempre da `NutritionCalculator`; anche il testo libero (`why`, `notes`) viene ripulito da eventuali cifre su entrambi i lati;
- [x] il piano non scrive nel diario: «Fatto» per slot (con Annulla), «Sostituisci», apertura ricetta;
- [x] lista della spesa: aggregazione scalata sulle porzioni, reparti del supermercato, quantità arrotondate «da spesa», spunte persistenti, copia come testo;
- [x] Mac spento = messaggio onesto con timeout (8 min in coda / 25 min in lavorazione) e piani precedenti sempre leggibili offline; **nessun generatore locale di riserva** (scelta di Marco);
- [x] **budget di tempo proporzionato agli slot** (5/08): il primo piano reale di Marco (7 giorni x 4 pasti = 28 slot, 158 ricette) falliva 10 volte con `PLAN_CLAUDE_TIMEOUT` perche' il tetto fisso era 170 s mentre la composizione richiede ~210-280 s. Ora il timeout si calcola per richiesta (60 s + 14 s per slot, pavimento 120 s, tetto `--plan-timeout` alzato a 600 s) e non e' piu' vincolato a `--lease-seconds`, dato che il thread di heartbeat rinnova il lease durante il lavoro. Verificato end-to-end: piano da 28 slot completato al primo tentativo in 207 s, 28 ricette diverse, giorni a 1951-2039 kcal su un obiettivo di 2000.
- [ ] follow-up noti: il piano non entra in backup/sync; niente foglio di condivisione di sistema per la lista (solo copia negli appunti, servirebbe `share_plus`); prompt ancora completo di tutte le ricette anche quando i pasti pianificati sono pochi (filtrarlo accorcerebbe la composizione).

### M5 — Fusione di Gym Tracker

**Sostituisce il bridge.** `docs/GYM_TRACKER_INTEGRATION.md` è superato e va archiviato: prevedeva una replica continua Firestore → Supabase con credenziale read-only, checkpoint e idempotenza su rilettura. Non serve più niente di tutto questo. L'export completo di Gym Tracker (`gym-tracker-export-20260805-1038.json`) pesa **351 KB**: è un import una-tantum, dopo il quale Firebase si spegne per sempre.

Inventario dell'export del 5 agosto 2026, verificato: **29 workout** (29/04→04/08, tutti con `endedAt`, 28 con kcal, 21 con esercizi dettagliati e 8 registrati a posteriori), **308 esercizi**, **14 schede** (con riscaldamento, superset e circuiti HIIT), **3 misure** di peso (96,2 → 95,7 → 94,5, una con vita 106), profilo con **11.370 XP**, streak, obiettivi settimanali e `healthConnectEnabled`.

Fattibilità verificata sul codice: **solo 10 file di Gym Tracker toccano Firestore**, tutti coppie modello+repository. La logica pesante è pura e si porta invariata — `superset_flow.dart`, `kcal_estimator.dart` e `personal_records.dart` hanno **zero** riferimenti a Firebase.

- [x] **M5.1** profilo esteso: `heightCm`, `birthDate` e `sex` in `AppProfiles` — Drift **v5** + migrazione Supabase `0006`; *(5 agosto 2026)*
- [ ] **M5.2** schema allenamento in Drift (`exercises`, `routines`, `workouts`, `workout_exercises`, `workout_sets`) con snapshot del nome esercizio e `trackingMode`, più migrazione Supabase `0006`;
- [ ] **M5.3** importer one-shot del JSON, idempotente sugli id originali, che porta dentro anche **XP, achievement e streak** (ripartire da zero sarebbe una regressione percepita);
- [ ] **M5.4** porting della logica pura, invariata: `superset_flow`, `kcal_estimator`, `personal_records`, `cool_down_sequence`, `rest_timer`, `plate_calculator`;
- [ ] **M5.5** porting della UI workout (live, circuiti, storico, schede, esercizi) sul tema di Kal;
- [ ] **M5.6** Health Connect push-only per workout e calorie, come già fa Gym (`health` plugin, plugin già collaudato);
- [ ] **M5.7** peso corporeo per il calcolo MET letto dall'**ultima pesata reale** invece del valore congelato `bodyWeightKg: 94.7` del profilo Gym;
- [ ] **M5.8** spegnimento di Firebase e archiviazione del repo `gym-tracker-source`.

Criterio: i 29 workout storici sono navigabili nella nuova app, una sessione nuova con superset si registra dall'inizio alla fine, e Firebase non è più nel `pubspec`.

### M6 — Bilancia Renpho e composizione corporea

La bilancia è `QN-Scale` sul Bluetooth; il protocollo è già decodificato da progetti open source (openScale, ble-scale-sync). Si legge **direttamente**, senza l'app Renpho e senza il suo cloud.

- [x] **M6.1** `BodyMeasurements` esteso — Drift **v5**, migrazione Supabase `0006`: *(5 agosto 2026)*
      `hasImpedance` (bool), `impedanceOhm` (grezzo), `bodyFatPct`, `musclePct`, `skeletalMusclePct`, `bonePct`, `proteinPct`, `waterPct`, `subcutaneousFatPct`, `visceralFatIndex`, `bmrKcal`, `formulaVersion`, `source`, `externalId`.
      **Le masse in kg non si salvano** (sono peso × percentuale) e nemmeno il BMI (peso / altezza²): si calcolano. `formulaVersion` è stata aggiunta rispetto al piano iniziale: senza, il ricalcolo dello storico di M6.3 non saprebbe quali righe rifare.
- [ ] **M6.2** lettura BLE della bilancia (`flutter_blue_plus`), con salvataggio dell'**impedenza grezza**;
- [ ] **M6.3** formula BIA propria, dichiarata e versionata, con **ricalcolo dello storico** quando la versione cambia;
- [ ] **M6.4** import del CSV Renpho, per lo storico e per la taratura;
- [ ] **M6.5** schermata **Corpo**: grafico ad aree impilate **kg di grasso + kg di massa magra** (non la linea del peso), medie mobili a 7 giorni, circonferenze a nastro;
- [ ] **M6.6** regola della pesata del giorno: vale **la prima con impedenza del mattino**; le altre restano nello storico ma non entrano nelle medie.

Taratura: 2–3 settimane di **doppia lettura** (bilancia via BLE + app Renpho in parallelo) prima di abbandonare l'app Renpho. Il CSV `RENPHO Health-Marco.csv` è il primo punto di questa taratura e va conservato.

Onestà dichiarata in UI: la BIA piede-piede misura soprattutto la parte bassa del corpo. **Il valore assoluto è indicativo, il trend è affidabile.**

### M7 — Obiettivo, fasi e motore adattivo

**È il cuore del prodotto, non un accessorio** (richiesta esplicita di Marco, 5 agosto 2026): l'app non deve misurare e basta, deve **portare a un traguardo e poi mantenerlo**. Tutto il resto — diario, ricette, allenamenti, acqua — esiste per servire questo.

**L'obiettivo si esprime in composizione, non in peso.** Un traguardo di peso raggiunto perdendo massa magra è un fallimento travestito da successo.

**Nessun traguardo è cablato nella roadmap: si sceglie nell'app e si può cambiare quando si vuole** (richiesta di Marco). Obiettivo e ritmo sono entrambi parametri vivi, non configurazione iniziale.

- [ ] **M7.1** entità **Obiettivo**: composizione o peso traguardo, ritmo scelto, data stimata, storico degli obiettivi (quelli raggiunti e quelli cambiati per strada);
- [ ] **M7.1z** **l'obiettivo si cambia in corsa senza ripartire da zero**: cambiandolo si ricalcolano deficit, data stimata e piano, mentre storico, tendenze e TDEE misurato restano — sono proprietà del corpo di Marco, non del traguardo. Cambiare idea a metà percorso è un'operazione normale, non un ricominciare;
- [ ] **M7.1a** **selettore in linguaggio umano** (richiesta di Marco): non si chiede una percentuale di grasso, si sceglie *come si vuole essere* — «80 kg definito», «86 kg asciutto». Le etichette per uomo adulto: morbido ~24 %, normale ~20 %, asciutto ~17 %, atletico ~14 %, definito ~11 %, molto definito ~9 %.
      **A massa magra invariata peso e definizione non sono indipendenti: se ne sceglie uno e l'altro segue.** Con i 71,66 kg di massa magra di Marco la curva è: 95 kg morbido → 90 normale → 86 asciutto → 84 atletico → **80 definito** → 78 molto definito. Il selettore è quindi **una manopola sola** con le due etichette che si muovono insieme, più tempo stimato e chili di grasso da perdere aggiornati in diretta;
- [ ] **M7.1b** **verdetto di fattibilità** su ogni combinazione fuori curva: sotto la curva serve *perdere* muscolo (l'app lo sconsiglia apertamente: 75 kg definito costerebbe 4,9 kg di massa magra), sopra serve *costruirne* (l'app propone prima una fase di massa). È il caso d'uso principale del «coach che sa dire di no»;
- [ ] **M7.1c** **il ritmo è sempre modificabile dall'app** (richiesta di Marco), non una scelta iniziale irreversibile: cambiandolo si ricalcolano deficit e data stimata, l'obiettivo resta. Il ritmo vive nell'Obiettivo, non in una costante di codice;
- [ ] **M7.2** **tre fasi con regole distinte** — oggi `NutritionTargets` ha quattro numeri fissi e nessuna nozione di direzione:
      **1. Avvicinamento** — deficit costante, proteine alte, ricalibrazione settimanale del deficit (mai dell'obiettivo);
      **2. Consolidamento** — risalita graduale di ~100 kcal/giorno a settimana fino al mantenimento reale; l'aumento di peso da glicogeno va **spiegato**, non subito;
      **3. Mantenimento** — non un numero ma una **banda** (es. 86,5–88,5 kg): dentro la banda nessun allarme; si rientra solo se la media a 7 giorni ne esce per **due settimane consecutive**;
- [ ] **M7.3** **limite di sicurezza non negoziabile**: massimo **0,7 % del peso a settimana** (0,67 kg per Marco). Obiettivi più aggressivi vengono **rifiutati** con la spiegazione e la controproposta. Se la massa magra cala per due settimane di fila, il deficit si riduce da solo;
- [ ] **M7.4** **TDEE adattivo** settimanale dai dati reali, con storico: le prime 2-3 settimane vale la stima da BMR × attività, poi solo il misurato;
- [ ] **M7.5** target derivati da obiettivo + fase + TDEE, con **proteine per kg di massa magra** (2 g → 143 g/giorno) e non di peso;
- [ ] **M7.6** **budget settimanale, non giornaliero**: uno sforo si redistribuisce sui giorni rimanenti invece di scontarsi tutto il giorno dopo. È la differenza fra un piano che regge e uno che si molla al primo imprevisto;
- [ ] **M7.7** **ripartizione del deficit su tre leve** — alimentazione, movimento, e l'acqua come qualità del dato: se il cibo non si comprime, il carico si sposta sugli allenamenti;
- [ ] **M7.8** **piano settimanale unico**: gli `WeeklyPlanSlots` accolgono anche slot di tipo allenamento, assorbendo il `weeklyPlan` (giorno → scheda) di Gym; il generatore colloca il pasto proteico **dopo** l'allenamento previsto;
- [ ] **M7.9** forza relativa: i record di `personal_records` rapportati al peso corporeo.

Criterio: Marco imposta un traguardo e l'app risponde con il ritmo, la data stimata e cosa comporta **oggi**; alla fine dell'avvicinamento passa da sola al consolidamento e poi al mantenimento, senza che il piano si spenga.

### M8 — Coach

Il coach **non è una chat dentro l'app**: è un terzo tipo di job sul Mac mini, accanto a `meal_analysis_jobs` e `weekly_plan_jobs`, con la stessa architettura già collaudata (launchd, Claude CLI, nessuna API a consumo).

- [ ] **M8.1** coda `coach_jobs` con RPC a privilegi minimi;
- [ ] **M8.2** **brief settimanale della domenica**: TDEE aggiornato, aderenza, ricomposizione, andamento carichi;
- [ ] **M8.3** avvisi incrociati, primo fra tutti il **semaforo del sovrallenamento** (RPE in salita + calo di peso rapido + proteine sotto target + acqua corporea in calo → deload);
- [ ] **M8.5** **schermata Oggi orientata all'azione**: non grafici ma «cosa faccio adesso» — kcal e proteine rimanenti, allenamento previsto, e le ricette del ricettario che ci stanno. Il suggeritore per macro rimanenti (`recipe_suggestions.dart`) esiste già ed è oggi una funzione secondaria dentro le ricette: **va promosso al centro dell'esperienza**;
- [ ] **M8.6** **spiegazione dei movimenti falsi**: quando il peso si muove per idratazione e non per grasso, il coach lo dice esplicitamente («ieri 1,1 L d'acqua: il −700 g di stamattina è acqua»). Serve a evitare sia le euforie sia gli scoraggiamenti senza causa reale;
- [ ] **M8.7** **proiezione del traguardo**: «a questo ritmo arrivi a 87,4 kg il 2 dicembre, due settimane dopo il previsto» — l'aderenza si comunica come distanza dalla data, non come colpa;
- [ ] **M8.4** **check-in mattutino da 10 secondi**: peso in automatico dalla bilancia, più due soli campi manuali — ore di sonno ed energia percepita 1-5. È qui che entrano i dati dell'orologio Huawei, **a mano** (scelta di Marco: niente Health Sync per ora).

Vincolo: il coach deve funzionare **con dati mancanti**. Nello storico reale RPE e soddisfazione sono compilati in 17 sessioni su 29, l'umore in 11, le note in nessuna.

### M9 — Navigazione a cinque voci e tablet

Le due app hanno cinque destinazioni ciascuna: fuse non possono diventare dieci.

| Voce | Contenuto |
|---|---|
| **Oggi** | dashboard: calorie, allenamento del giorno, peso, check-in |
| **Cibo** | diario, catalogo, ricette, barcode, foto |
| **Palestra** | workout live, schede, esercizi |
| **Corpo** | peso, composizione, misure, record, grafici |
| **Piano** | settimana di pasti e allenamenti |

- [ ] **M9.1** shell a cinque voci con `StatefulShellRoute` (Kal ne ha già cinque, vanno ridistribuite);
- [ ] **M9.2** **layout adattivo**: Kal non ha oggi nessun `NavigationRail`, `LayoutBuilder` o breakpoint; il pattern si prende dal codice di Gym, che li ha già;
- [ ] **M9.3** tablet come **sala controllo** (Piano e Corpo a due colonne) e telefono come **campo** (workout live e registrazione pasto, una mano sola);
- [ ] **M9.4** golden test a 390×844, 320 px, testo 150 % e dark mode, come già in Gym.

### M10 — Beta stabile

- Android telefono e tablet reali;
- modalità aereo, rete lenta, Mac spento e retry multipli;
- backup, reinstallazione e ripristino, con lo storico importato integro;
- accessibilità, dark mode, notifiche ed export;
- sette giorni di uso reale senza perdita dati o duplicati.

### M11 — iOS

- provisioning iPhone e test su dispositivo reale;
- HealthKit al posto di Health Connect;
- verifica del BLE della bilancia su iOS.

## Decisioni tecniche fissate il 5 agosto 2026

**Formule.** Tutte deterministiche, nessuna prodotta da un modello.

| Grandezza | Formula | Nota |
|---|---|---|
| BMI | `peso / altezza²` | non si salva |
| Massa grassa | `peso × grasso% / 100` | non si salva |
| Massa magra (FFM) | `peso − massa grassa` | **è la metrica guida** |
| BMR | **Katch-McArdle**: `370 + 21,6 × FFM` | verificata sui dati Renpho reali: riproduce il loro BMR entro **0,1–2,4 kcal** (1917,9 contro 1918). È la formula che usa la bilancia, e dipende dalla massa magra: migliora insieme ai dati |
| TDEE reale | `kcal medie ingerite − (Δ peso medio 7 gg × 7700 / 7)` | ricalcolato ogni settimana sui dati di Marco, sostituisce ogni stima da tabella |
| Proteine obiettivo | `g/kg × FFM` | si aggiorna a ogni pesata |
| Forza relativa | `carico record / peso corporeo` | |

Mifflin-St Jeor è stata scartata: sbaglia di 7–10 kcal sugli stessi dati e non segue la massa magra.

**Dati scartati dalla bilancia**, perché giudizi proprietari e non misure: età metabolica (è il BMR ridipinto), peso ottimale, livello di peso, tipo di corpo. Il "peso ottimale 72,90 kg / Sovrappeso" corrisponde a BMI 22 su 182 cm per una persona con 41,19 kg di muscolo scheletrico: non viene salvato e **il coach non lo vede mai**. Il WHR non è un dato della bilancia ma delle circonferenze inserite a mano, e vive con quelle.

**Identità dell'app.** Il nome scelto da Marco il 5 agosto 2026 è **Coach360**: dichiara il ruolo (guida, non misura) e la copertura completa dello stile di vita — cibo, allenamento, composizione corporea, acqua, sonno. Cambia **solo il nome visualizzato**: il package resta **`it.marcomartelli.kaltracker`**, perché cambiarlo romperebbe l'OTA e imporrebbe una reinstallazione da zero. Da aggiornare: `applicationLabel` Android, `CFBundleDisplayName` iOS, titolo in-app e schermata informazioni; i repository GitHub `kal-tracker` / `kal-tracker-releases` restano con i nomi attuali per non spezzare il manifest OTA già pubblicato.

**Regola OTA sempre valida:** il baseline `21e728b` deve restare nella storia di `main` → merge normale o fast-forward, **mai squash o rebase**.

## Ordine del prossimo lavoro

Riscritto il 5 agosto 2026 dopo la decisione di fondere le due app. I vecchi punti su foto, worker launchd e barcode sono stati completati nelle fasi 5-8 e rimossi da questa lista.

1. **(solo Marco, ancora aperto)** Due backup cifrati su supporti separati di `~/Documents/KalTracker-Signing` — chiavi di firma e password Supabase: è l'unica copia esistente.
2. **(solo Marco)** Mettere al sicuro `gym-tracker-export-20260805-1038.json` insieme ai backup: finché Firebase Auth resta anonimo, quel file è l'unica copia dello storico palestra svincolata dall'installazione corrente.
3. ~~**M5.1 + M6.1** — schema Drift **v5** e migrazione Supabase `0006`.~~ **FATTO il 5 agosto 2026** (branch `agent/coach360-schema-v5`): 466 test Flutter e 4 controlli statici SQL verdi, analyze e format puliti. Note in fondo.
4. **M5.2 + M5.3** — schema allenamento e importer one-shot del JSON: 29 workout, 308 esercizi, 14 schede, 3 misure, XP e achievement.
5. **M6.2 + M6.3** — lettura BLE della bilancia con impedenza grezza e prima versione della formula BIA; inizio delle 2-3 settimane di doppia lettura per la taratura.
6. **M5.4 + M5.5** — porting della logica pura e poi della UI workout. Ordine dal meno al più delicato: `measurements` ed `exercises` prima, `workouts` (superset e circuiti) per ultimo.
7. **M9** — shell a cinque voci e layout adattivo per il tablet.
8. **M7** — fase, TDEE adattivo e piano settimanale unico.
9. **M8** — coda `coach_jobs` e brief della domenica.
10. **M5.8** — spegnimento di Firebase e archiviazione di `gym-tracker-source`.

Resta aperto da prima della fusione: collaudo end-to-end della sync su dispositivo reale (build con `--dart-define=SUPABASE_URL=… --dart-define=SUPABASE_PUBLISHABLE_KEY=…`, accesso con `marco.mart87@gmail.com`, password in `KalTracker-Signing/supabase/marco-app-password.txt`), giornata offline → sync senza duplicati su due dispositivi.

## Rischi aperti

| Rischio | Stato |
|---|---|
| Storico palestra su account **Firebase anonimo** | mitigato dall'export del 5/08, **non ancora risolto**: finché non è importato in Drift, vive in un solo file |
| Formula BIA diversa da Renpho | atteso e accettato: si salva l'impedenza grezza, quindi lo storico si ricalcola. Taratura in doppia lettura prima di abbandonare l'app Renpho |
| Porting di `workouts/` (15k righe) | ridotto: la logica è pura, cambia solo il repository sotto. Da fare per ultimo, a fusione già in produzione |
| Dati dell'orologio Huawei | **rinviato per scelta**: Huawei Health non parla nativamente con Health Connect e servirebbe un ponte di terze parti a pagamento. Per ora sonno ed energia si inseriscono a mano nel check-in |
| Nome del prodotto | da decidere: "Kal Tracker" non descrive più l'app. Il package Android **non** va toccato |

## Note di handoff (schema v5, 5 agosto 2026)

Cose da sapere prima di scrivere il codice che userà queste colonne.

- **`app_profiles` si estende, non si ricrea.** È referenziata da dieci tabelle, quindi la migrazione usa `addColumn` e le tre colonne nuove sono nullable e **senza CHECK**: i limiti (altezza 50-260, sesso M/F) li impone il dominio. `body_measurements` invece non è referenziata da nessuno, quindi usa `alterTable`/`TableMigration` e i suoi CHECK valgono davvero anche sui telefoni aggiornati — c'è un test che verifica proprio questo confrontando un database migrato con uno appena creato.
- **Le foreign key durante la migrazione sono già spente**: `beforeOpen` le accende solo dopo, e dentro una transazione il `PRAGMA` non avrebbe effetto. Non aggiungerne uno pensando di proteggersi.
- **`birthDate` si scrive e si legge in UTC a mezzanotte**, come `WeeklyPlans.startDate`. Drift salva i `DateTime` come istante unix e li rilegge nel fuso locale: senza `toUtc()` nei confronti tornano le 02:00 dell'ora legale.
- **La policy RLS remota è cambiata.** La `0002` accettava dal client il solo `source = 'kal_tracker'` perché ogni altra provenienza doveva arrivare da un bridge. Con la fusione l'app legge la bilancia da sé, quindi la `0006` sostituisce quelle policy con `body_measurements_insert_client` / `_update_client`, che ammettono anche `manual`, `renpho_ble`, `renpho_csv`, `gym_tracker` e `health_connect`. `kal_tracker` resta ammesso: è il valore delle righe già scritte.
- **Vocabolario di `source` diverso fra locale e remoto**: in Drift il default è `manual`, sul server le righe storiche hanno `kal_tracker`. La traduzione va fatta in `sync_gateway.dart`, dove vive già tutta la mappatura per entityType. **La sincronizzazione delle nuove colonne non è ancora scritta**: lo schema è pronto da entrambi i lati, il gateway no.
- **La `0006` non è ancora applicata sul progetto Supabase reale.**
- Chi porterà lo schema a v6 deve scrivere la propria fixture v5 a mano, con il pattern di `app_database_v5_test.dart`. I test v2/v3/v4 asseriscono ora `user_version = 5`: coprono di fatto l'intera catena.
- Il controllo statico `supabase/tests/body_composition_static_test.sh` verifica anche ciò che **non** deve esistere (BMI, massa grassa in kg, età metabolica, peso ottimale, tipo di corpo): se un domani qualcuno prova a salvarli, il test glielo impedisce.

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

**Fase 8 — note**
- Quick-add smart nel diario (manuale/catalogo/foto/barcode), acqua in evidenza con promemoria configurabili (permesso solo al toggle, pianificazione DST-safe), porzioni del catalogo riviste (v2, l'importer aggiorna le righe catalog esistenti senza toccare le copie personali), prompt foto rafforzato sul peso reale del piatto.
- Da allineare: il _PROMPT di codex_analyzer.py ha ancora la vecchia riga debole sui grammi (il fallback Codex sottostimerebbe; claude e' il default quindi non urgente).
- Minori noti: 'Dal catalogo e ricette' porta solo al catalogo (le ricette si aggiungono dalla loro tab); 'Apri impostazioni' del pannello camera e' solo-iOS (su Android invito testuale); revoca del permesso notifiche dalle impostazioni non ri-verificata al riavvio.

**Piccole cose rimaste aperte**
- Nelle sezioni Preferiti e Recenti il filtro categoria è un post-filtro sui soli id `cat-*`: un preferito personalizzato sparisce con un chip categoria attivo in quelle due sezioni (stessa classe del difetto 5 di fase 7, corretto altrove).
- L'app non ha ancora un'icona propria né splash screen personalizzata.
- Versione corrente `0.9.0+9` (…, v0.7.0-b7 quick-add+acqua, v0.8.0-b8 ricettario 152 ricette + fix snackbar con azione che su questo Flutter/M3 non si chiudono MAI da sole: helper showAutoClosingSnackBar obbligatorio per ogni snackbar con azione); l'OTA rifiuta regressioni di build number.
