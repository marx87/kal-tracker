# Meal worker

Worker locale a job singolo per il flusso privato:

```text
Supabase queued -> claim/lease -> foto privata -> verifica -> Codex
                -> JSON strutturato -> needs_review
```

Non calcola calorie e non conferma il pasto: Codex restituisce soltanto
alimenti candidati, preparazione, confidenza, fascia di grammi e domande. Marco
deve confermare alimenti e quantita prima del calcolo nutrizionale.

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
- Prima di avviare Codex verifica dimensione esatta, SHA-256, magic bytes e
  MIME JPEG/PNG/WebP. Il file temporaneo ha permessi `0600` ed e eliminato al
  termine anche quando l'analisi fallisce.
- Codex gira con sessione effimera, configurazione/regole ignorate, sandbox
  read-only, schema JSON obbligatorio e una allowlist minima di variabili
  d'ambiente. Non riceve token, URL Supabase o percorsi fuori dalla directory
  temporanea.
- I log contengono soltanto ID job e codici stabili, non foto, note, token,
  password o output grezzo del modello.

Il Mac apre soltanto connessioni in uscita verso Supabase e Codex; non espone
porte domestiche.

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

Il runtime non ha dipendenze Python esterne. Richiede Python 3.11+, macOS,
Codex CLI gia installata e autenticata.

Verificare manualmente che Codex usi l'accesso ChatGPT del piano di Marco e
non un login con API key:

```bash
codex login status
```

L'adapter rimuove `OPENAI_API_KEY` e `CODEX_API_KEY` dall'ambiente figlio, ma
non puo trasformare un eventuale login API gia salvato da Codex in un login
ChatGPT.

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
export KAL_CODEX_EXECUTABLE="/percorso/assoluto/codex"
```

Opzionali:

- `KAL_MEAL_WORKER_KEYCHAIN_SERVICE`, default
  `com.kaltracker.meal-worker.supabase`;
- `KAL_MEAL_WORKER_KEYCHAIN_ACCOUNT`, default uguale all'email worker.

Una prova acquisisce al massimo un job:

```bash
.venv/bin/kal-meal-worker serve --once
```

Il servizio continuo usa polling con backoff, un job alla volta, heartbeat
durante Codex e gestione `complete`/`fail`:

```bash
.venv/bin/kal-meal-worker serve
```

Per le opzioni di lease, timeout e polling:

```bash
.venv/bin/kal-meal-worker serve --help
```

## launchd: solo template

[`launchd/com.kaltracker.meal-worker.plist.template`](launchd/com.kaltracker.meal-worker.plist.template)
contiene un esempio con placeholder per virtualenv, directory, log, URL,
publishable key, email e percorso assoluto di Codex. Il repository non lo
installa e non esegue `launchctl`: copiarlo e abilitarlo resta un passaggio
manuale dopo la prova in foreground.

La publishable key nel plist non e un segreto; password Supabase e credenziali
Codex non devono essere copiate nel plist.

## Analisi manuale di una foto

L'entrypoint preesistente resta disponibile senza Supabase:

```bash
PYTHONPATH=. python3 -m kal_meal_worker.cli /percorso/pasto.jpg
```

## Test offline

I test usano trasporti, gateway, Portachiavi e analizzatore iniettati; non
aprono la rete, non leggono il Portachiavi e non avviano Codex:

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
- Se il lease viene perso mentre Codex termina, il worker non forza un
  completamento: lascia scadere il job, che potra essere reclamato in modo
  sicuro.
