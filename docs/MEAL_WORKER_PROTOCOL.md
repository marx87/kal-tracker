# Protocollo worker: foto dei pasti e piano settimanale

Il worker del Mac mini usa un utente **Supabase Auth dedicato** e non l'utente
Marco. Sul Mac non va mai salvata la chiave `service_role`: sono sufficienti
l'URL pubblico Supabase, la chiave anon/publishable e le credenziali del solo
utente worker, conservate nel Portachiavi.

Le code servite sono due e indipendenti:

| Coda | Tabella | Ambito binding | Cosa produce |
| --- | --- | --- | --- |
| Foto dei pasti | `kal_tracker.meal_analysis_jobs` | `meal_analysis` | alimenti, grammi e valori per 100 g da confermare |
| Piano settimanale | `kal_tracker.weekly_plan_jobs` | `meal_planning` | solo scelte: quale ricetta e quante porzioni |

Un solo processo le serve **a turno** (`--scope all`, il default): una sola
lavorazione alla volta, una sola password nel Portachiavi, un solo servizio
launchd. Il turno avanza dopo ogni ciclo, anche quando una coda fallisce, così
nessuna delle due resta senza servizio.

## Provisioning una tantum

1. Un amministratore crea l'utente worker da Supabase Auth con registrazione
   pubblica disabilitata.
2. Dal SQL editor amministrativo collega il worker al proprietario, **una riga
   per ogni ambito**:

   ```sql
   insert into kal_tracker.automation_bindings (
     worker_user_id,
     owner_id,
     scope
   ) values
     ('WORKER_AUTH_USER_UUID', 'MARCO_AUTH_USER_UUID', 'meal_analysis'),
     ('WORKER_AUTH_USER_UUID', 'MARCO_AUTH_USER_UUID', 'meal_planning')
   on conflict (worker_user_id, owner_id, scope) do nothing;
   ```

   Senza la riga `meal_planning` le RPC del piano rispondono `42501`
   (`meal_planning binding is missing or inactive`) e il `doctor` **non** lo
   intercetta: il suo controllo verifica solo che le RPC esistano.
3. Per revocarlo immediatamente imposta `is_active = false` sulla riga
   dell'ambito da fermare. La revoca blocca nuovi claim, retry RPC e lettura
   delle foto anche se un lease non è scaduto.

`automation_bindings` e i due ledger di idempotenza (`automation_rpc_mutations`
per le foto, `automation_plan_rpc_mutations` per il piano) non hanno policy RLS
né grant diretti per utenti autenticati: si usano soltanto attraverso le RPC. I
ledger sono separati perché la chiave esterna `job_id` punta a due tabelle
diverse.

Anche `meal_analysis_jobs` è separata per capacità: l'app può leggere i propri
job e inserire soltanto le colonne necessarie a una richiesta `queued`; non ha
un `UPDATE` diretto e non può valorizzare claim, risultato o stato. Le future
azioni proprietario (`cancel`, `confirm` e pulizia/tombstone) richiederanno RPC
dedicate con transizioni di stato esplicite. La v0.2 non le usa ancora.

## Ciclo di un job foto

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
   confermare alimenti, quantità e valori per 100 g prima che l'app calcoli
   calorie e nutrienti dai grammi confermati.
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

## Ciclo di un job del piano settimanale

Stessa meccanica, senza Storage e senza immagini: la richiesta viaggia dentro
il job.

1. L'app accoda un job `queued` in `kal_tracker.weekly_plan_jobs` con la
   richiesta completa in `request`: giorni, pasti scelti da Marco, obiettivi
   giornalieri, note libere e il **catalogo reale delle ricette** (id, nome,
   tag, minuti di preparazione e valori per porzione già calcolati dall'app).
2. `claim_weekly_plan_job(mutation_id, lease_seconds)` assegna il job più
   vecchio dei proprietari legati allo scope `meal_planning`
   (`FOR UPDATE SKIP LOCKED`). La risposta ha otto campi e nessuno riguarda le
   foto: `claimed`, `job_id`, `owner_id`, `profile_id`, `request`,
   `attempt_count`, `row_version`, `lease_expires_at`.
3. `heartbeat_weekly_plan_job(job_id, mutation_id, lease_seconds)` porta lo
   stato a `processing` e rinnova il lease mentre il modello compone il piano.
4. `complete_weekly_plan_job(job_id, mutation_id, result)` salva il piano e
   porta il job a `needs_review`: il piano è una **previsione**, non entra nel
   diario finché Marco non tocca "Fatto" su uno slot.
5. `fail_weekly_plan_job(job_id, mutation_id, error_code, retryable)` rimette
   in coda o chiude come `failed`, con le stesse regole delle foto.

Il client può soltanto leggere i propri job e inserire le cinque colonne di una
richiesta (`id`, `owner_id`, `profile_id`, `request`, `last_mutation_id`): non
ha `UPDATE`, quindi non può fingersi il worker né confermare un piano. Come per
le foto, la chiusura di uno slot resta locale e la riga remota rimane a
`needs_review`.

### Contratto del piano

La richiesta e il risultato hanno `"schema": 1`. Il risultato contiene **solo
scelte**:

```json
{
  "schema": 1,
  "days": [
    {
      "date": "2026-08-05",
      "slots": [
        {
          "meal": "cena",
          "recipeId": "<id preso dal catalogo della richiesta>",
          "servings": 1.5,
          "why": "una riga in italiano"
        }
      ]
    }
  ],
  "notes": "commento generale, massimo 400 caratteri"
}
```

Il worker rifiuta il piano intero (nessun piano a metà) con codici errore
stabili, che sono l'unica cosa che l'app vede:

| Codice | Quando |
| --- | --- |
| `PLAN_UNKNOWN_RECIPE` | un `recipeId` non è nel catalogo inviato: l'AI sceglie, non inventa |
| `PLAN_BAD_SERVINGS` | porzioni fuori da 0.5–4 o non multiple di mezza porzione |
| `PLAN_BAD_DATES` | giorni mancanti, ripetuti o fuori dal periodo richiesto |
| `PLAN_DUPLICATE_SLOT` | due volte lo stesso pasto nello stesso giorno |
| `PLAN_BAD_MEAL` | un pasto che Marco non aveva selezionato |
| `PLAN_BAD_REQUEST` | la richiesta nel job è incoerente (fallimento **non** ritentabile) |
| `PLAN_BAD_RESULT` | forma del piano fuori contratto (note o motivazioni troppo lunghe, ecc.) |

**Nessun numero nutrizionale attraversa questa coda nel verso worker → app.**
Lo schema JSON passato alla CLI non ha alcun campo di calorie o macronutrienti,
il prompt lo vieta esplicitamente e il contratto Python ignora (non rifiuta)
qualunque chiave in più che il modello aggiungesse: un `kcal` inventato non
arriva mai al risultato salvato. I totali li calcola sempre l'app dalle ricette
reali con `NutritionCalculator`. La stessa validazione va rifatta dall'app in
lettura, perché il piano transita in un `jsonb` libero e una ricetta può essere
stata cancellata dopo la generazione.

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
grezzo del modello. Il contratto del risultato è identico per i due provider.

Il **piano settimanale** lo genera solo Claude (`ClaudePlanner`), con gli
stessi limiti dell'analisi foto e due differenze volute:

- **nessuno strumento**: la CLI parte con `--tools ""`, la sua forma per
  disabilitare tutti gli strumenti. Il piano non deve leggere né scrivere
  niente: dati e catalogo stanno nel prompt, la directory di lavoro è una
  cartella temporanea vuota;
- **timeout più generoso** (`--plan-timeout`, 170 s di default): comporre una
  settimana costa più che leggere una foto. Deve restare entro
  `--lease-seconds` (il worker rifiuta l'avvio se lo supera), che nel frattempo
  l'heartbeat rinnova.

Con `--provider codex` la coda del piano non parte: usare
`--scope meal_analysis`.

### Contratto del risultato foto

Ogni risultato contiene al massimo 12 alimenti; per ogni voce il modello
propone fascia di grammi, confidenza, preparazione, ingredienti nascosti e
l'oggetto obbligatorio `per100g`, cioè i valori nutrizionali stimati per
100 g dell'alimento così com'è preparato, come letti da un'etichetta:
`energyKcal` (0..900), `proteinG`, `carbsG` e `fatG` (0..100), al massimo una
cifra decimale (il worker normalizza arrotondando). Sono stime da presentare
come tali: in revisione restano modificabili come tutto il resto.

Il modello **non fornisce mai le calorie totali** del piatto o della
porzione: i totali mostrati dall'app sono sempre
`NutritionCalculator.scale(per100g, grams)` sui grammi confermati da Marco.
Il contratto applica anche un controllo di coerenza Atwater lasco: se
`energyKcal` si discosta oltre il 40% da `4·proteine + 4·carboidrati +
9·grassi` la voce viene segnalata nel campo `uncertainty` senza essere
rifiutata.

Compatibilità con i risultati storici: i job analizzati prima di questa
versione non hanno `per100g` e restano leggibili dall'app, che tratta i
per-100 g mancanti come campi vuoti da compilare in revisione. Il worker
nuovo invece esige sempre `per100g` nei risultati che produce: l'opzionalità
è solo lato app per i dati vecchi.

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
4. registra i binding `meal_analysis` **e** `meal_planning` via REST quando i
   permessi lo consentono; altrimenti stampa, per ogni ambito mancante, l'SQL
   idempotente pronto da incollare nel SQL editor (la tabella è riservata,
   quindi il fallback manuale è normale). Il riepilogo finale elenca i binding
   attivi e quelli ancora da completare.

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

Il comando verifica, con un esito leggibile per riga (sette controlli):
password nel Portachiavi, CLI del provider presente e autenticata,
raggiungibilità del progetto Supabase, login dell'utente worker, esposizione
delle RPC foto, esposizione delle RPC del piano e schema del bucket foto
(privato, 10 MiB, JPEG/PNG/WebP; se i metadati sono riservati al worker ripiega
su un oggetto di prova che deve essere negato).

I due controlli RPC usano un `heartbeat` su un UUID casuale, che le RPC
rifiutano con `P0002` senza toccare dati né ledger: non rubano job in coda ma
**non provano il binding**, perché il job inesistente viene scartato prima del
controllo di `automation_bindings`. La prova completa è il passo successivo.

### 4. Prova in foreground (sblocca il Portachiavi)

Nella sessione grafica, così macOS può chiedere l'autorizzazione per
`/usr/bin/security` una sola volta:

```bash
.venv/bin/kal-meal-worker serve --once                          # entrambe le code
.venv/bin/kal-meal-worker serve --scope meal_planning --once    # solo il piano
```

Con i binding attivi e nessun job in coda l'esito atteso è un poll vuoto. Se
manca il binding dell'ambito provato, il log riporta un ciclo fallito con
`SUPABASE_HTTP_403`/`42501`: è lì che si scopre un `meal_planning` dimenticato.

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

Il plist avvia **un solo** `serve`, con `KAL_MEAL_WORKER_SCOPE=all`: un unico
processo serve le due code a turno. Servirle con due processi richiederebbe un
secondo plist, un secondo utente Auth e una seconda password nel Portachiavi.

## Verifica locale

Le migrazioni richiedono un PostgreSQL/Supabase reale per i test dinamici.
Quando la Supabase CLI non è installata, eseguire almeno i controlli statici:

```bash
supabase/tests/meal_worker_rpc_static_test.sh
supabase/tests/weekly_plan_jobs_static_test.sh
```

e la suite del worker:

```bash
cd services/meal_worker && python3 -m unittest discover -s tests
```

Prima dell'uso reale vanno poi provati con due utenti di test: claim concorrenti,
lease scaduto, binding revocato (per entrambi gli ambiti), replay identico,
replay alterato e accesso Storage fuori lease.
