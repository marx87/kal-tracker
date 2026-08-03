# Meal worker

Worker locale a job singolo per il flusso privato:

```text
Supabase queued -> claim/lease -> foto privata -> verifica
                -> CLI AI (Claude o Codex) -> JSON strutturato -> needs_review
```

Non calcola calorie e non conferma il pasto: il modello restituisce soltanto
alimenti candidati, preparazione, confidenza, fascia di grammi e domande. Marco
deve confermare alimenti e quantita prima del calcolo nutrizionale.

## Provider di analisi

Il worker supporta due CLI intercambiabili, entrambe senza API key:

- **claude** (predefinito): Claude Code, autenticata via OAuth con il piano
  Max di Marco. Verificare il login con `claude auth status`.
- **codex**: la Codex CLI, con l'accesso ChatGPT del piano di Marco.
  Verificare il login con `codex login status`.

La scelta avviene con `--provider claude|codex` su `kal-meal-worker serve` e
`kal-meal-analyze`, oppure con la variabile `KAL_MEAL_ANALYZER_PROVIDER`.
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
`supabase/migrations/202608020003_meal_worker_rpc.sql`, aggiungere
`kal_tracker` agli **Exposed schemas** del progetto e seguire il provisioning
amministrativo in
[`docs/MEAL_WORKER_PROTOCOL.md`](../../docs/MEAL_WORKER_PROTOCOL.md):

1. creare un utente Auth dedicato con registrazione pubblica disabilitata;
2. collegarlo a Marco in `kal_tracker.automation_bindings` con scope
   `meal_analysis`;
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

Con l'app **Accesso Portachiavi**, creare un nuovo elemento password:

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

## launchd: solo template

[`launchd/com.kaltracker.meal-worker.plist.template`](launchd/com.kaltracker.meal-worker.plist.template)
contiene un esempio con placeholder per virtualenv, directory, log, URL,
publishable key, email e percorso assoluto della CLI Claude (con un commento
per tornare a Codex). Il repository non lo installa e non esegue `launchctl`:
copiarlo e abilitarlo resta un passaggio manuale dopo la prova in foreground.

La publishable key nel plist non e un segreto; password Supabase e credenziali
Claude/Codex non devono essere copiate nel plist.

## Analisi manuale di una foto

L'entrypoint preesistente resta disponibile senza Supabase:

```bash
PYTHONPATH=. python3 -m kal_meal_worker.cli /percorso/pasto.jpg
PYTHONPATH=. python3 -m kal_meal_worker.cli --provider codex /percorso/pasto.jpg
```

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
