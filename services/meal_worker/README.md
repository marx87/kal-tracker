# Meal worker

Worker locale a job singolo per il flusso privato:

```text
Supabase queued -> claim/lease -> foto privata -> verifica
                -> CLI AI (Claude o Codex) -> JSON strutturato -> needs_review
```

Non calcola calorie e non conferma il pasto: il modello restituisce soltanto
alimenti candidati, preparazione, confidenza, fascia di grammi e domande. Marco
deve confermare alimenti e quantita prima del calcolo nutrizionale.

Le code servite sono tre e un solo processo le serve a turno
(`--scope all`, il default):

| Coda | Tabella | Ambito binding | Cosa produce |
| --- | --- | --- | --- |
| Foto dei pasti | `meal_analysis_jobs` | `meal_analysis` | alimenti e grammi da confermare |
| Piano settimanale | `weekly_plan_jobs` | `meal_planning` | solo scelte: ricetta e porzioni |
| Coach | `coach_jobs` | `coaching` | solo testo: il perche' della settimana |

## Coach: entrano numeri gia' fatti, esce solo il racconto

La terza coda ha il verso del traffico INVERTITO rispetto al piano. Nel piano
il modello sceglie e l'app calcola; qui l'app ha gia' calcolato tutto — TDEE
misurato, aderenza, ricomposizione, proiezione, semaforo del sovrallenamento —
e manda quei numeri gia' fatti dentro `request`. Dal Mac torna soltanto:

```json
{"headline": "Settimana solida, proteine da rialzare", "paragraphs": ["...", "..."]}
```

Non e' una convenzione: la funzione SQL `kal_tracker.coach_result_is_text_only`
**rifiuta qualunque campo del risultato che non sia una stringa o un array di
stringhe**, e la CHECK sulla colonna `result` la applica. Il worker verifica lo
stesso predicato prima di inviare (`coach_contract.ensure_text_only`), cosi' un
errore si legge invece di presentarsi come una CHECK violation di Postgres. Da
questo discendono due dettagli che sembrano minuzie e non lo sono:

- il titolo assente si **omette**, non si manda a `null`: `null` non e' una
  stringa e verrebbe rifiutato;
- `dropped` (quanti capoversi sono stati buttati) resta nel log del worker e
  non nel risultato: e' un numero.

Qualunque cifra prodotta dal modello viene scartata **insieme al capoverso che
la conteneva**, con la stessa regola del piano e per la stessa ragione: un
«circa 600 kcal» accanto ai «772 kcal» calcolati dall'app darebbe a Marco due
numeri diversi, e quello sbagliato sarebbe il primo. Si scarta il capoverso e
non tutto il commento; solo se non resta niente il job fallisce
(`COACH_EMPTY_NARRATIVE`, ritentabile: e' il modello ad aver scritto male, non
l'app).

Il filtro non guarda solo `0-9`: scarta qualunque carattere che valga come
numero, comprese le frazioni e i numerali (`½`, `¾`, `Ⅶ`, `①`), perche' «hai
perso ½ chilo piu' del previsto» e' un numero del modello esattamente come
«0,5». La CHECK del database non lo coprirebbe: quella verifica il **tipo** dei
campi, non il contenuto della prosa.

Limite noto: restano fuori i numeri scritti in lettere. «settecento kcal in
meno» passerebbe entrambi i filtri, qui e nell'app, perche' un test sulle
parole cancellerebbe anche «un chilo» e «una settimana». Quel pezzo di regola
lo porta solo il prompt.

Guasti della macchina, non del job: se la CLI Claude non si trova
(`COACH_CLAUDE_UNAVAILABLE`, tipicamente il `PATH` del plist) o manca lo schema
nel pacchetto (`COACH_SCHEMA_MISSING`), il job si chiude **senza ritentare**.
Ritentare su una macchina rotta darebbe dieci volte lo stesso esito in tre
minuti e chiuderebbe comunque il job: cosi' invece il codice arriva subito
all'app, `doctor` dice cosa aggiustare e basta richiedere il commento.

## Piano settimanale: i giorni di allenamento

La seconda coda (`weekly_plan_jobs`) riceve anche `workouts`, l'elenco dei
giorni in cui Marco si allena dentro il periodo del piano:

```json
"workouts": [
  {"date": "2026-08-06", "name": "Spinta: petto e tricipiti", "proteinMeal": "cena"}
]
```

Non e' una scelta del modello e non torna mai indietro: gli allenamenti li
decide la settimana delle schede dentro l'app. Servono a collocare il pasto
proteico DOPO la sessione invece che a caso nella giornata.

`proteinMeal` lo calcola l'app dall'ora in cui Marco si allena davvero
(mediana delle sue sessioni reali), non il modello: e' un dato come i target.
Puo' mancare — senza storico non si indovina un orario — e allora quel giorno
non porta nessuna indicazione. Il contratto verifica che ogni allenamento cada
in un giorno del piano, che non ce ne siano due nello stesso giorno e che
`proteinMeal` sia fra i pasti richiesti.

La chiave e' facoltativa: una richiesta scritta prima del piano unificato
resta valida e lo schema resta `1`.

## Provider di analisi

Il worker supporta due CLI intercambiabili, entrambe senza API key:

- **claude** (predefinito): Claude Code, autenticata via OAuth con il piano
  Max di Marco. Verificare il login con `claude auth status`.
- **codex**: la Codex CLI, con l'accesso ChatGPT del piano di Marco.
  Verificare il login con `codex login status`.

La scelta avviene con `--provider claude|codex` su `kal-meal-worker serve` e
`kal-meal-analyze`, oppure con la variabile `KAL_MEAL_ANALYZER_PROVIDER`. Piano
settimanale e commento del coach li genera **solo Claude**: con `codex` serve
`--scope meal_analysis`.
Entrambi gli adapter applicano lo stesso contratto
(`meal_analysis.schema.json`), gli stessi limiti su immagine e output e codici
errore stabili con prefisso `CLAUDE_*` / `CODEX_*`.

L'adapter Claude non inoltra `ANTHROPIC_API_KEY` all'ambiente figlio, quello
Codex non inoltra `OPENAI_API_KEY` e `CODEX_API_KEY` (allowlist minima in
entrambi i casi). Nessuno dei due puo pero trasformare un eventuale login API
gia salvato nella CLI in un login in abbonamento: va verificato a mano con i
comandi sopra.

## Confini di sicurezza

- Sul Mac sono ammessi soltanto URL Supabase, publishable key e credenziali di
  un utente Auth dedicato. Una chiave `sb_secret_*` o un JWT `service_role`
  viene rifiutato; il codice non legge `SUPABASE_SERVICE_ROLE_KEY`.
- La password Auth non e un argomento o una variabile d'ambiente. Viene letta
  al bisogno dal Portachiavi con `/usr/bin/security find-generic-password`,
  passando gli argomenti direttamente e senza shell.
- Il worker usa solo le quattro RPC della migrazione `003` e il download
  Storage dell'oggetto coperto dal lease; non interroga direttamente la
  tabella dei job e non elenca il bucket.
- Ogni mutazione usa un UUID nuovo. I retry della stessa operazione riusano
  esattamente quell'UUID, come richiesto dal ledger idempotente.
- Prima di avviare l'analisi verifica dimensione esatta, SHA-256, magic bytes
  e MIME JPEG/PNG/WebP. Il file temporaneo ha permessi `0600` ed e eliminato
  al termine anche quando l'analisi fallisce.
- La CLI di analisi gira in modo effimero dentro una directory temporanea, con
  una allowlist minima di variabili d'ambiente: non riceve token, URL Supabase
  o percorsi fuori dalla directory temporanea. Codex usa `--ephemeral`,
  configurazione e regole ignorate, sandbox read-only e schema JSON
  obbligatorio; Claude usa `--print` con `--no-session-persistence`,
  `--safe-mode`, `--strict-mcp-config`, il solo strumento `Read` e lo stesso
  schema obbligatorio via `--json-schema`.
- I log contengono soltanto ID job e codici stabili, non foto, note, token,
  password o output grezzo del modello.

Il Mac apre soltanto connessioni in uscita verso Supabase e il provider AI
scelto; non espone porte domestiche.

## Prerequisiti Supabase

Applicare le migrazioni fino a
`supabase/migrations/202608050009_coach_binding_probe.sql` (le RPC del worker
partono da `202608020003_meal_worker_rpc.sql`), aggiungere
`kal_tracker` agli **Exposed schemas** del progetto e seguire il provisioning
amministrativo in
[`docs/MEAL_WORKER_PROTOCOL.md`](../../docs/MEAL_WORKER_PROTOCOL.md):

1. creare un utente Auth dedicato con registrazione pubblica disabilitata;
2. collegarlo a Marco in `kal_tracker.automation_bindings` con **una riga per
   ogni ambito servito**: `meal_analysis`, `meal_planning` e `coaching`. Senza
   la riga giusta le RPC di quella coda rispondono `42501`;
3. usare nell'app e sul worker solo la publishable key del progetto.

## Installazione locale del pacchetto

```bash
cd services/meal_worker
python3 -m venv .venv
.venv/bin/python -m pip install -e .
```

Il runtime non ha dipendenze Python esterne. Richiede Python 3.11+, macOS e la
CLI del provider scelto (Claude Code predefinita, Codex in alternativa) gia
installata e autenticata come descritto in "Provider di analisi".

## Portachiavi

Il percorso consigliato e `scripts/provision_meal_worker.sh` (vedi
[`docs/MEAL_WORKER_PROTOCOL.md`](../../docs/MEAL_WORKER_PROTOCOL.md)): crea
l'utente worker con password generata e salva l'elemento Portachiavi con i
nomi attesi, senza mai stampare segreti. In alternativa manuale, con l'app
**Accesso Portachiavi**, creare un nuovo elemento password:

- nome/servizio: `com.kaltracker.meal-worker.supabase`;
- account: email dell'utente Auth worker;
- password: password Supabase di quell'utente.

Usare Accesso Portachiavi evita di inserire la password nella cronologia della
shell. Al primo avvio in background macOS puo chiedere di autorizzare
`/usr/bin/security`; eseguire prima una prova `--once` nella sessione grafica.

## Configurazione e avvio

Le variabili non segrete richieste sono:

```bash
export KAL_SUPABASE_URL="https://PROJECT_REF.supabase.co"
export KAL_SUPABASE_PUBLISHABLE_KEY="PUBLISHABLE_KEY"
export KAL_MEAL_WORKER_EMAIL="worker@example.invalid"
export KAL_CLAUDE_EXECUTABLE="/percorso/assoluto/claude"
```

Opzionali:

- `KAL_MEAL_ANALYZER_PROVIDER`, default `claude` (`codex` per tornare alla
  Codex CLI);
- `KAL_CODEX_EXECUTABLE`, default `codex`, usato solo con provider `codex`;
- `KAL_MEAL_WORKER_KEYCHAIN_SERVICE`, default
  `com.kaltracker.meal-worker.supabase`;
- `KAL_MEAL_WORKER_KEYCHAIN_ACCOUNT`, default uguale all'email worker.

Una prova acquisisce al massimo un job:

```bash
.venv/bin/kal-meal-worker serve --once
.venv/bin/kal-meal-worker serve --scope coaching --once   # solo il coach
```

Il servizio continuo usa polling con backoff, un job alla volta, heartbeat
durante l'analisi e gestione `complete`/`fail`:

```bash
.venv/bin/kal-meal-worker serve
```

Per le opzioni di provider, lease, timeout e polling:

```bash
.venv/bin/kal-meal-worker serve --help
```

## Diagnostica: `doctor`

Con le stesse variabili non segrete di `serve`:

```bash
.venv/bin/kal-meal-worker doctor
```

Stampa un esito leggibile per riga (`OK`/`ERRORE`/`SALTATO`): password nel
Portachiavi, CLI del provider presente e autenticata, raggiungibilita del
progetto Supabase, login dell'utente worker, RPC dello schema `kal_tracker`,
RPC del piano, **binding del coach** e schema del bucket foto. Non stampa
segreti; codice di uscita 0 solo con tutti i controlli superati.

Un solo controllo prova davvero un binding, ed e' quello del coach. Il motivo
e' un difetto vissuto: con `meal_planning` la riga in `automation_bindings` fu
dimenticata, il doctor rimase verde e il `42501` si scopri' soltanto a `serve`
avviato. Il sondaggio con heartbeat non puo' vederlo, perche' la RPC scarta il
job inesistente (`P0002`) prima ancora di guardare il binding.

**Nessun controllo tocca la coda.** La prima versione provava il binding con un
`claim_coach_job` vero — l'unica RPC che il binding lo guarda prima del job — e
questo consumava un tentativo del job di Marco: al decimo, `fail_coach_job`
trovava `attempt_count < 10` falso e chiudeva il job come `failed` con
`error_code = 'DOCTOR_BINDING_PROBE'`. Una diagnosi che distrugge il lavoro che
sta diagnosticando. Adesso la domanda la fa
`kal_tracker.coaching_binding_active()` (migrazione
`202608050009_coach_binding_probe.sql`): sola lettura, nessuna riga toccata,
nessuna scrittura nel ledger. Si puo' rilanciare quante volte si vuole.

- sonda assente (`404`) -> mancano le migrazioni del coach;
- `42501` -> token worker non valido o `execute` mancante sulla funzione;
- `{"active": false}` -> binding assente o disattivo, con l'`insert` da
  eseguire nel messaggio.

Per `meal_analysis` e `meal_planning` la prova del binding resta
`kal-meal-worker serve --scope AMBITO --once`.

## launchd: solo template

[`launchd/com.kaltracker.meal-worker.plist.template`](launchd/com.kaltracker.meal-worker.plist.template)
contiene un esempio con placeholder per virtualenv, directory, log, URL,
publishable key, email, percorso assoluto della CLI Claude (con un commento
per tornare a Codex) e `__CLAUDE_BIN_DIRECTORY__`, la directory che contiene
`claude` da anteporre al `PATH` del servizio (launchd non eredita il PATH
della shell). Il repository non lo installa e non esegue `launchctl`:
copiarlo e abilitarlo resta un passaggio manuale dopo la prova in foreground.

La publishable key nel plist non e un segreto; password Supabase e credenziali
Claude/Codex non devono essere copiate nel plist.

[`launchd/com.kaltracker.coach-worker.plist.template`](launchd/com.kaltracker.coach-worker.plist.template)
e' il gemello per la sola coda del coach (`--scope coaching`), con log propri.
E' un'**alternativa** al servizio unico, non un'aggiunta: quello gira con
`KAL_MEAL_WORKER_SCOPE=all`, che serve gia' tutte e tre le code, e caricarli
entrambi significherebbe due Claude accesi sullo stesso abbonamento senza
nessun guadagno.

## Analisi manuale di una foto

L'entrypoint preesistente resta disponibile senza Supabase:

```bash
PYTHONPATH=. python3 -m kal_meal_worker.cli /percorso/pasto.jpg
PYTHONPATH=. python3 -m kal_meal_worker.cli --provider codex /percorso/pasto.jpg
```

## Commento del coach a mano, senza Supabase

Lo stesso entrypoint scrive il commento partendo da un file con la `request`
del job (quella che l'app mette nella coda):

```bash
PYTHONPATH=. python3 -m kal_meal_worker.cli --coach-request /percorso/rapporto.json
```

Stampa esattamente il payload che finirebbe in `complete_coach_job`, gia'
verificato come testo puro, e su stderr quanti capoversi sono stati scartati
perche' contenevano cifre. Serve a rileggere con i propri occhi cosa direbbe il
Mac prima di far partire il servizio.

Il tetto predefinito qui e' **300 s**, lo stesso di `serve --coach-timeout`:
un'anteprima che scade prima del worker non direbbe quanto costa davvero un
commento. Ed e' anche il modo di misurarlo: le costanti del budget
(`60 s + 20 s per tema`, pavimento 90 s) sono un margine e non una misura, a
differenza di quelle del piano che vengono da una prova cronometrata.

## Test offline

I test usano trasporti, gateway, Portachiavi e analizzatore iniettati; non
aprono la rete, non leggono il Portachiavi e non avviano Claude o Codex:

```bash
cd services/meal_worker
PYTHONPATH=. python3 -m unittest discover -s tests -v
python3 -m compileall -q kal_meal_worker tests
```

## Limiti intenzionali

- I token Auth restano soltanto in memoria: al riavvio il worker rilegge la
  password dal Portachiavi e crea una nuova sessione.
- Un `SIGKILL` o uno spegnimento improvviso puo lasciare un file nella directory
  temporanea di macOS; arresti normali, errori e `SIGTERM` eseguono la pulizia.
- Le RPC dinamiche e le policy Storage devono essere collaudate anche contro un
  progetto Supabase di test; gli unit test Python non sostituiscono quel test.
- Se il lease viene perso mentre l'analisi termina, il worker non forza un
  completamento: lascia scadere il job, che potra essere reclamato in modo
  sicuro.
