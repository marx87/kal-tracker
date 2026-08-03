# Protocollo worker per l'analisi dei pasti

Il worker del Mac mini usa un utente **Supabase Auth dedicato** e non l'utente
Marco. Sul Mac non va mai salvata la chiave `service_role`: sono sufficienti
l'URL pubblico Supabase, la chiave anon/publishable e le credenziali del solo
utente worker, conservate nel Portachiavi.

## Provisioning una tantum

1. Un amministratore crea l'utente worker da Supabase Auth con registrazione
   pubblica disabilitata.
2. Dal SQL editor amministrativo collega il worker al proprietario:

   ```sql
   insert into kal_tracker.automation_bindings (
     worker_user_id,
     owner_id,
     scope
   ) values (
     'WORKER_AUTH_USER_UUID',
     'MARCO_AUTH_USER_UUID',
     'meal_analysis'
   );
   ```

3. Per revocarlo immediatamente imposta `is_active = false`. La revoca blocca
   nuovi claim, retry RPC e lettura delle foto anche se un lease non è scaduto.

`automation_bindings` e il ledger di idempotenza non hanno policy RLS né grant
diretti per utenti autenticati: si usano soltanto attraverso le RPC.

Anche `meal_analysis_jobs` è separata per capacità: l'app può leggere i propri
job e inserire soltanto le colonne necessarie a una richiesta `queued`; non ha
un `UPDATE` diretto e non può valorizzare claim, risultato o stato. Le future
azioni proprietario (`cancel`, `confirm` e pulizia/tombstone) richiederanno RPC
dedicate con transizioni di stato esplicite. La v0.2 non le usa ancora.

## Ciclo di un job

1. L'app carica una foto immutabile nel bucket privato con percorso
   `owner_id/job_id/nomefile`, poi crea il job `queued` con hash SHA-256, MIME e
   dimensione verificabili.
2. Il worker chiama `claim_meal_analysis_job(mutation_id, lease_seconds)`. Il
   claim è atomico (`FOR UPDATE SKIP LOCKED`), sceglie soltanto proprietari
   associati allo scope `meal_analysis` e restituisce i metadati del job. Un
   lease dura da 30 a 900 secondi.
3. Soltanto durante il proprio lease attivo il worker può leggere l'esatto
   oggetto Storage restituito. Non può elencare o leggere altre foto.
4. Per lavori lunghi chiama
   `heartbeat_meal_analysis_job(job_id, mutation_id, lease_seconds)`, che porta
   lo stato a `processing` e rinnova il lease non ancora scaduto.
5. Con `complete_meal_analysis_job(job_id, mutation_id, analysis_result)` salva
   il JSON strutturato e porta il job a `needs_review`: Marco deve ancora
   confermare alimenti e quantità prima che l'app calcoli calorie e nutrienti.
6. Con `fail_meal_analysis_job(job_id, mutation_id, error_code, retryable)` il
   job torna in coda se ritentabile e sotto il limite di 10 tentativi;
   altrimenti diventa `failed`.

Ogni chiamata che modifica dati deve avere un UUID di mutation nuovo. Ripetere
la stessa identica chiamata con lo stesso UUID restituisce la risposta salvata;
riutilizzare l'UUID con parametri o operazione diversi viene rifiutato. Un poll
`claim` senza job non modifica dati e non viene registrato: il poll successivo
dovrebbe comunque usare un nuovo UUID.

Il worker non accede direttamente a `meal_analysis_jobs`: il suo `auth.uid()`
non coincide con `owner_id`, quindi le policy esistenti lo escludono. Le RPC
`SECURITY DEFINER` verificano a ogni passaggio identità, binding attivo, scope,
proprietario, assegnatario, stato e scadenza del lease.

## Provider di analisi

L'analisi della foto è delegata a una CLI AI locale, senza API key. Il worker
dipende solo dal protocollo `Analyzer` e supporta due adapter intercambiabili:

- **claude** (predefinito): Claude Code in modalità non interattiva
  (`claude --print --output-format json`), autenticata via OAuth con il piano
  Max di Marco. L'adapter passa lo schema `meal_analysis.schema.json` con
  `--json-schema` e limita la sessione con `--no-session-persistence`,
  `--safe-mode`, `--strict-mcp-config` e il solo strumento `Read`, così il
  modello può leggere soltanto la copia temporanea della foto. Il parsing è
  difensivo: accetta sia il wrapper della CLI (campi `result` e
  `structured_output`, anche con recinzioni markdown) sia il payload JSON puro.
- **codex**: la Codex CLI (`codex exec --ephemeral --sandbox read-only`) con
  lo stesso schema obbligatorio via `--output-schema`.

La selezione avviene con `--provider claude|codex` o con la variabile
`KAL_MEAL_ANALYZER_PROVIDER`; entrambi gli adapter validano l'immagine prima
di avviare la CLI, filtrano l'ambiente figlio con una allowlist (niente
`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, token o variabili `KAL_*`) e producono
codici errore stabili (`CLAUDE_*` / `CODEX_*`) senza mai includere l'output
grezzo del modello. Il contratto del risultato — massimo 12 alimenti, fasce di
grammi, confidenze, niente calorie né macro — è identico per i due provider:
il calcolo nutrizionale resta all'app dopo la conferma di Marco.

## Installazione reale sul Mac

Procedura completa per portare il worker in servizio su un Mac con macOS,
Python 3.11+ e la CLI Claude Code già installata e autenticata (`claude auth
status` deve rispondere con login attivo; per il provider `codex` vale
`codex login status`).

### 1. Pacchetto Python

```bash
cd services/meal_worker
python3 -m venv .venv
.venv/bin/python -m pip install -e .
```

### 2. Provisioning utente worker, binding e Portachiavi

Lo script `scripts/provision_meal_worker.sh` automatizza i passi 1-2 del
"Provisioning una tantum" e il salvataggio nel Portachiavi. Richiede il ref del
progetto e la service_role key **solo come variabili d'ambiente** (mai come
argomenti): la chiave serve unicamente durante l'esecuzione amministrativa e
non viene salvata né stampata.

```bash
export KAL_PROVISION_PROJECT_REF="PROJECT_REF"

# La service_role key si incolla in un prompt nascosto, MAI dentro un
# `export KEY="..."` digitato in shell: quella riga finirebbe in chiaro
# in ~/.zsh_history e resterebbe su disco anche dopo l'unset.
printf 'service_role key (input nascosto): '
IFS= read -rs KAL_PROVISION_SERVICE_ROLE_KEY && export KAL_PROVISION_SERVICE_ROLE_KEY
echo

# prima un controllo locale senza rete e senza modifiche
scripts/provision_meal_worker.sh \
  --worker-email kal-meal-worker@TUODOMINIO \
  --owner-email EMAIL_DI_MARCO \
  --dry-run

# poi l'esecuzione vera, rieseguibile senza danni
scripts/provision_meal_worker.sh \
  --worker-email kal-meal-worker@TUODOMINIO \
  --owner-email EMAIL_DI_MARCO \
  --create

unset KAL_PROVISION_SERVICE_ROLE_KEY
```

Lo script, in modo idempotente:

1. risolve il proprietario (da email o `--owner-id`), che deve già esistere;
2. cerca o crea l'utente Auth worker con una password generata (64 caratteri
   esadecimali); se l'utente esiste ma la password manca dal Portachiavi la
   rigenera e riallinea Supabase Auth;
3. salva la password nel Portachiavi macOS con i nomi attesi dal worker
   (servizio `com.kaltracker.meal-worker.supabase`, account = email worker);
4. registra il binding `meal_analysis` via REST quando i permessi lo
   consentono; altrimenti stampa l'SQL idempotente pronto da incollare nel SQL
   editor (la tabella è riservata, quindi il fallback manuale è normale).

La registrazione pubblica degli utenti deve restare disabilitata; la revoca del
binding resta un'azione manuale dal SQL editor (`is_active = false`).

### 3. Diagnosi con `doctor`

Con le variabili non segrete del worker esportate:

```bash
export KAL_SUPABASE_URL="https://PROJECT_REF.supabase.co"
export KAL_SUPABASE_PUBLISHABLE_KEY="PUBLISHABLE_KEY"
export KAL_MEAL_WORKER_EMAIL="kal-meal-worker@TUODOMINIO"
export KAL_CLAUDE_EXECUTABLE="$(command -v claude)"

.venv/bin/kal-meal-worker doctor
```

Il comando verifica, con un esito leggibile per riga: password nel Portachiavi,
CLI del provider presente e autenticata, raggiungibilità del progetto Supabase,
login dell'utente worker, esposizione dello schema `kal_tracker`/RPC e schema
del bucket foto (privato, 10 MiB, JPEG/PNG/WebP; se i metadati sono riservati
al worker ripiega su un oggetto di prova che deve essere negato). Il controllo
non esegue mai un claim, quindi non può rubare job in coda: la prova completa
del binding è il passo successivo.

### 4. Prova in foreground (sblocca il Portachiavi)

Nella sessione grafica, così macOS può chiedere l'autorizzazione per
`/usr/bin/security` una sola volta:

```bash
.venv/bin/kal-meal-worker serve --once
```

Con un binding attivo e nessun job in coda l'esito atteso è un poll vuoto.

### 5. Servizio launchd

Compilare i placeholder del template
`services/meal_worker/launchd/com.kaltracker.meal-worker.plist.template`:
`__VENV_PATH__`, `__MEAL_WORKER_DIRECTORY__`, `__PROJECT_REF__`,
`__PUBLISHABLE_KEY__`, `__WORKER_EMAIL__`,
`__CLAUDE_EXECUTABLE_ABSOLUTE_PATH__`, `__CLAUDE_BIN_DIRECTORY__` (la
directory che contiene `claude`, es. `/opt/homebrew/bin` o la `bin` di nvm,
perché launchd non eredita il PATH della shell) e `__LOG_DIRECTORY__`.

```bash
mkdir -p "$HOME/Library/Logs/kal-meal-worker"   # __LOG_DIRECTORY__
cp com.kaltracker.meal-worker.plist "$HOME/Library/LaunchAgents/"
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.kaltracker.meal-worker.plist"
launchctl kickstart -k "gui/$(id -u)/com.kaltracker.meal-worker"
```

Per fermarlo: `launchctl bootout "gui/$(id -u)/com.kaltracker.meal-worker"`.
La publishable key nel plist non è un segreto; password Supabase e credenziali
Claude/Codex non vanno mai copiate nel plist.

## Verifica locale

La migrazione richiede un PostgreSQL/Supabase reale per i test dinamici. Quando
la Supabase CLI non è installata, eseguire almeno il controllo statico:

```bash
supabase/tests/meal_worker_rpc_static_test.sh
```

Prima dell'uso reale vanno poi provati con due utenti di test: claim concorrenti,
lease scaduto, binding revocato, replay identico, replay alterato e accesso
Storage fuori lease.
