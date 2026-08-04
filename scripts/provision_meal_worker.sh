#!/usr/bin/env bash

# Provisioning una tantum dell'utente worker (foto dei pasti e piano
# settimanale).
#
# Lo script legge PROJECT_REF e service_role key SOLO da variabili d'ambiente
# (mai da argomenti, mai stampate), crea l'utente Supabase Auth dedicato con
# una password generata, prova a registrare i binding meal_analysis e
# meal_planning e salva le credenziali nel Portachiavi macOS con i nomi attesi
# da keychain.py (servizio com.kaltracker.meal-worker.supabase, account =
# email worker).
#
# La service_role key serve soltanto durante questa esecuzione amministrativa:
# non viene salvata su disco, nel Portachiavi o nei log.

set +x
set -Eeuo pipefail
umask 077

readonly SCRIPT_NAME="$(basename "$0")"
readonly DEFAULT_KEYCHAIN_SERVICE="com.kaltracker.meal-worker.supabase"
# Un binding per ogni coda servita dal worker: senza la riga meal_planning
# ogni RPC del piano fallisce con 42501 e il doctor non lo intercetta.
readonly BINDING_SCOPES=("meal_analysis" "meal_planning")
readonly SECURITY_BIN="/usr/bin/security"
readonly MAX_USER_PAGES=10
readonly USERS_PER_PAGE=200

WORKER_EMAIL=""
OWNER_EMAIL=""
OWNER_ID=""
KEYCHAIN_SERVICE="$DEFAULT_KEYCHAIN_SERVICE"
MODE=""

SUPABASE_URL=""
PYTHON_BIN=""
HTTP_STATUS=""
HTTP_BODY=""
WORKER_PASSWORD=""

usage() {
  cat <<EOF
Uso:
  KAL_PROVISION_PROJECT_REF=... KAL_PROVISION_SERVICE_ROLE_KEY=... \\
    $SCRIPT_NAME --worker-email EMAIL (--owner-email EMAIL | --owner-id UUID) --dry-run
  KAL_PROVISION_PROJECT_REF=... KAL_PROVISION_SERVICE_ROLE_KEY=... \\
    $SCRIPT_NAME --worker-email EMAIL (--owner-email EMAIL | --owner-id UUID) --create

Variabili d'ambiente richieste (mai argomenti, mai stampate):
  KAL_PROVISION_PROJECT_REF        ref del progetto Supabase (es. abcdefghijklmnopqrst)
  KAL_PROVISION_SERVICE_ROLE_KEY   service_role key, usata solo per questa esecuzione

Opzioni:
  --worker-email EMAIL       Email dell'utente Auth dedicato al worker (obbligatoria)
  --owner-email EMAIL        Email dell'account di Marco su Supabase Auth
  --owner-id UUID            In alternativa: UUID auth.users del proprietario
  --keychain-service NOME    Servizio Portachiavi (default: $DEFAULT_KEYCHAIN_SERVICE)
  --dry-run                  Controlli locali e piano d'azione, senza rete ne modifiche
  --create                   Esegue il provisioning; rieseguibile senza danni (idempotente)
  -h, --help                 Mostra questo aiuto

Lo script non stampa mai password, service_role key o publishable key.
EOF
}

fail() {
  printf 'Errore: %s\n' "$*" >&2
  exit 1
}

step() {
  printf -- '- %s\n' "$*"
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

to_lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

cleanup() {
  WORKER_PASSWORD=""
  HTTP_BODY=""
}
trap cleanup EXIT

while (($# > 0)); do
  case "$1" in
    --worker-email)
      (($# >= 2)) || fail "manca il valore di --worker-email"
      WORKER_EMAIL="$2"
      shift 2
      ;;
    --owner-email)
      (($# >= 2)) || fail "manca il valore di --owner-email"
      OWNER_EMAIL="$2"
      shift 2
      ;;
    --owner-id)
      (($# >= 2)) || fail "manca il valore di --owner-id"
      OWNER_ID="$2"
      shift 2
      ;;
    --keychain-service)
      (($# >= 2)) || fail "manca il valore di --keychain-service"
      KEYCHAIN_SERVICE="$2"
      shift 2
      ;;
    --dry-run | --create)
      [[ -z "$MODE" ]] || fail "scegli una sola modalita tra --dry-run e --create"
      MODE="${1#--}"
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    --project-ref | --service-role-key | --service-key)
      fail "$1 non e un argomento ammesso: usa le variabili d'ambiente KAL_PROVISION_*"
      ;;
    *)
      fail "opzione sconosciuta: $1"
      ;;
  esac
done

[[ -n "$MODE" ]] || fail "specifica --dry-run oppure --create"
[[ -n "$WORKER_EMAIL" ]] || fail "--worker-email e obbligatorio"
[[ -n "$OWNER_EMAIL" || -n "$OWNER_ID" ]] ||
  fail "serve --owner-email oppure --owner-id"
[[ -z "$OWNER_EMAIL" || -z "$OWNER_ID" ]] ||
  fail "usa uno solo tra --owner-email e --owner-id"

readonly EMAIL_PATTERN='^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'
readonly UUID_PATTERN='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

[[ "$WORKER_EMAIL" =~ $EMAIL_PATTERN ]] || fail "email worker non valida"
if [[ -n "$OWNER_EMAIL" ]]; then
  [[ "$OWNER_EMAIL" =~ $EMAIL_PATTERN ]] || fail "email proprietario non valida"
  # Confronto case-insensitive: Supabase Auth normalizza le email in
  # minuscolo, quindi Marco@... e marco@... sono lo stesso account.
  [[ "$(to_lower "$OWNER_EMAIL")" != "$(to_lower "$WORKER_EMAIL")" ]] ||
    fail "worker e proprietario devono essere utenti diversi"
fi
if [[ -n "$OWNER_ID" ]]; then
  [[ "$OWNER_ID" =~ $UUID_PATTERN ]] || fail "--owner-id non e un UUID"
fi
[[ "$KEYCHAIN_SERVICE" =~ ^[A-Za-z0-9._-]+$ ]] ||
  fail "nome servizio Portachiavi non valido"

readonly PROJECT_REF="${KAL_PROVISION_PROJECT_REF:-}"
readonly SERVICE_KEY="${KAL_PROVISION_SERVICE_ROLE_KEY:-}"
[[ -n "$PROJECT_REF" ]] || fail "variabile KAL_PROVISION_PROJECT_REF mancante"
[[ -n "$SERVICE_KEY" ]] || fail "variabile KAL_PROVISION_SERVICE_ROLE_KEY mancante"
[[ "$PROJECT_REF" =~ ^[a-z0-9]{16,32}$ ]] ||
  fail "KAL_PROVISION_PROJECT_REF non sembra un ref Supabase valido"
SUPABASE_URL="https://${PROJECT_REF}.supabase.co"
readonly SUPABASE_URL

command_exists curl || fail "curl non disponibile"
command_exists openssl || fail "openssl non disponibile"
[[ -x "$SECURITY_BIN" ]] || fail "$SECURITY_BIN non disponibile (serve macOS)"
PYTHON_BIN="$(command -v python3)" || fail "python3 non disponibile"
readonly PYTHON_BIN

# La chiave amministrativa non deve mai essere una publishable/anon key: la
# verifica avviene in locale (decodifica del payload JWT), senza stamparla.
service_key_kind() {
  printf '%s' "$SERVICE_KEY" | "$PYTHON_BIN" -c '
import base64
import json
import sys

key = sys.stdin.read().strip()
if key.startswith("sb_secret_"):
    print("secret")
    raise SystemExit(0)
parts = key.split(".")
if len(parts) != 3:
    print("sconosciuto")
    raise SystemExit(0)
raw = parts[1] + "=" * (-len(parts[1]) % 4)
try:
    payload = json.loads(base64.urlsafe_b64decode(raw).decode("utf-8"))
except Exception:
    print("sconosciuto")
    raise SystemExit(0)
role = payload.get("role") if isinstance(payload, dict) else None
print(role if isinstance(role, str) and role else "sconosciuto")
'
}

KEY_KIND="$(service_key_kind)"
case "$KEY_KIND" in
  secret | service_role | supabase_admin) ;;
  anon | authenticated)
    fail "la chiave fornita e una publishable/anon key: serve la service_role key"
    ;;
  *)
    fail "KAL_PROVISION_SERVICE_ROLE_KEY non riconosciuta come chiave amministrativa"
    ;;
esac

keychain_item_exists() {
  "$SECURITY_BIN" find-generic-password \
    -a "$WORKER_EMAIL" -s "$KEYCHAIN_SERVICE" >/dev/null 2>&1
}

if [[ "$MODE" == "dry-run" ]]; then
  printf 'Preflight %s (nessuna richiesta di rete, nessuna modifica)\n' "$SCRIPT_NAME"
  step "Variabili KAL_PROVISION_PROJECT_REF e KAL_PROVISION_SERVICE_ROLE_KEY presenti (valori non mostrati)"
  step "La chiave fornita risulta amministrativa ($KEY_KIND): ok per il provisioning"
  step "Dipendenze disponibili: curl, openssl, python3, $SECURITY_BIN"
  if keychain_item_exists; then
    step "Portachiavi: elemento gia presente (servizio $KEYCHAIN_SERVICE, account $WORKER_EMAIL)"
  else
    step "Portachiavi: elemento assente, --create lo creera (servizio $KEYCHAIN_SERVICE, account $WORKER_EMAIL)"
  fi
  printf 'Con --create lo script fara, in modo idempotente:\n'
  step "cerca/crea l'utente Auth worker $WORKER_EMAIL con password generata (64 caratteri esadecimali)"
  step "salva la password nel Portachiavi macOS (mai stampata, mai su disco)"
  if [[ -n "$OWNER_EMAIL" ]]; then
    step "risolve il proprietario dall'email $OWNER_EMAIL"
  else
    step "usa il proprietario indicato: $OWNER_ID"
  fi
  step "registra i binding ${BINDING_SCOPES[*]} (o stampa l'SQL da incollare nel SQL editor se il REST non e ammesso)"
  exit 0
fi

# --- Helper HTTP: la chiave viaggia nella config curl letta da stdin, mai in argv ---

cfg_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '%s' "$value"
}

# http_call METODO PATH BODY [HEADER_EXTRA...]
# Valorizza HTTP_STATUS e HTTP_BODY. Il corpo della richiesta puo contenere
# la password: resta in variabili di shell e nella config curl su stdin.
http_call() {
  local method="$1" path="$2" body="$3"
  shift 3
  local config extra_header response
  config="url = \"$(cfg_escape "${SUPABASE_URL}${path}")\"
request = \"$(cfg_escape "$method")\"
silent
show-error
max-time = 30
header = \"apikey: $(cfg_escape "$SERVICE_KEY")\"
header = \"Authorization: Bearer $(cfg_escape "$SERVICE_KEY")\"
header = \"Content-Type: application/json\"
header = \"Accept: application/json\"
write-out = \"\\n%{http_code}\"
"
  for extra_header in "$@"; do
    config+="header = \"$(cfg_escape "$extra_header")\"
"
  done
  if [[ -n "$body" ]]; then
    config+="data = \"$(cfg_escape "$body")\"
"
  fi
  response="$(printf '%s' "$config" | curl --config -)" ||
    fail "richiesta a Supabase non riuscita ($method $path)"
  HTTP_STATUS="${response##*$'\n'}"
  HTTP_BODY="${response%$'\n'*}"
}

py_find_user_id() {
  printf '%s' "$1" | "$PYTHON_BIN" -c '
import json
import sys

email = sys.argv[1].strip().lower()
try:
    document = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)
users = document.get("users") if isinstance(document, dict) else None
if not isinstance(users, list):
    raise SystemExit(0)
for user in users:
    if isinstance(user, dict) and str(user.get("email", "")).lower() == email:
        print(user.get("id", ""))
        break
' "$2"
}

py_users_count() {
  printf '%s' "$1" | "$PYTHON_BIN" -c '
import json
import sys

try:
    document = json.load(sys.stdin)
except Exception:
    print(0)
    raise SystemExit(0)
users = document.get("users") if isinstance(document, dict) else None
print(len(users) if isinstance(users, list) else 0)
'
}

py_json_field() {
  printf '%s' "$1" | "$PYTHON_BIN" -c '
import json
import sys

try:
    document = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)
value = document.get(sys.argv[1]) if isinstance(document, dict) else None
if isinstance(value, str):
    print(value)
' "$2"
}

py_binding_state() {
  printf '%s' "$1" | "$PYTHON_BIN" -c '
import json
import sys

try:
    rows = json.load(sys.stdin)
except Exception:
    print("errore")
    raise SystemExit(0)
if not isinstance(rows, list):
    print("errore")
elif not rows:
    print("assente")
elif any(isinstance(row, dict) and row.get("is_active") is True for row in rows):
    print("attivo")
else:
    print("disattivato")
'
}

find_user_id_by_email() {
  local email="$1" page=1 found="" count=""
  while ((page <= MAX_USER_PAGES)); do
    http_call GET "/auth/v1/admin/users?page=${page}&per_page=${USERS_PER_PAGE}" ""
    [[ "$HTTP_STATUS" == "200" ]] ||
      fail "elenco utenti Auth non disponibile (HTTP $HTTP_STATUS): la chiave e amministrativa?"
    found="$(py_find_user_id "$HTTP_BODY" "$email")"
    if [[ -n "$found" ]]; then
      printf '%s' "$found"
      return 0
    fi
    count="$(py_users_count "$HTTP_BODY")"
    ((count > 0)) || break
    ((page += 1))
  done
  return 0
}

store_worker_password_in_keychain() {
  # La password passa a `security` tramite stdin (modalita interattiva -i),
  # cosi non compare negli argomenti di processo. -U aggiorna se gia esiste.
  printf 'add-generic-password -U -a "%s" -s "%s" -l "%s" -w "%s"\n' \
    "$WORKER_EMAIL" "$KEYCHAIN_SERVICE" "$KEYCHAIN_SERVICE" "$WORKER_PASSWORD" |
    "$SECURITY_BIN" -i >/dev/null 2>&1 ||
    fail "salvataggio nel Portachiavi non riuscito"
}

binding_sql_hint() {
  local worker_id="$1" owner_id="$2" scope="$3"
  printf 'SQL da incollare nel SQL editor di Supabase (idempotente):\n'
  printf '  insert into kal_tracker.automation_bindings (worker_user_id, owner_id, scope)\n'
  printf "  values ('%s', '%s', '%s')\n" "$worker_id" "$owner_id" "$scope"
  printf '  on conflict (worker_user_id, owner_id, scope) do nothing;\n'
}

# ensure_binding SCOPE -> 0 se il binding e attivo, 1 se resta da completare.
ensure_binding() {
  local scope="$1" state=""
  step "Controllo il binding $scope worker -> proprietario"
  http_call GET \
    "/rest/v1/automation_bindings?select=is_active&worker_user_id=eq.${WORKER_ID}&owner_id=eq.${OWNER_ID}&scope=eq.${scope}" \
    "" \
    "Accept-Profile: kal_tracker"

  if [[ "$HTTP_STATUS" != "200" ]]; then
    step "Lettura binding $scope via REST non ammessa (HTTP $HTTP_STATUS): la tabella e riservata, completare dal SQL editor"
    binding_sql_hint "$WORKER_ID" "$OWNER_ID" "$scope"
    return 1
  fi

  state="$(py_binding_state "$HTTP_BODY")"
  case "$state" in
    attivo)
      step "Binding $scope gia presente e attivo: nulla da fare"
      return 0
      ;;
    disattivato)
      step "Binding $scope presente ma disattivato (is_active=false): la riattivazione e una scelta amministrativa"
      printf 'Per riattivarlo, dal SQL editor:\n'
      printf "  update kal_tracker.automation_bindings set is_active = true\n"
      printf "  where worker_user_id = '%s' and owner_id = '%s' and scope = '%s';\n" \
        "$WORKER_ID" "$OWNER_ID" "$scope"
      return 1
      ;;
    assente)
      step "Binding $scope assente: provo l'inserimento via REST"
      http_call POST "/rest/v1/automation_bindings" \
        "{\"worker_user_id\":\"${WORKER_ID}\",\"owner_id\":\"${OWNER_ID}\",\"scope\":\"${scope}\"}" \
        "Content-Profile: kal_tracker" \
        "Prefer: return=minimal"
      if [[ "$HTTP_STATUS" == "201" ]]; then
        step "Binding $scope creato e attivo"
        return 0
      fi
      step "Inserimento REST non ammesso (HTTP $HTTP_STATUS): completare a mano"
      binding_sql_hint "$WORKER_ID" "$OWNER_ID" "$scope"
      return 1
      ;;
    *)
      step "Risposta binding $scope non interpretabile: completare a mano"
      binding_sql_hint "$WORKER_ID" "$OWNER_ID" "$scope"
      return 1
      ;;
  esac
}

printf 'Provisioning meal worker su %s\n' "$SUPABASE_URL"

# 1. Proprietario --------------------------------------------------------------
if [[ -n "$OWNER_EMAIL" ]]; then
  step "Cerco il proprietario $OWNER_EMAIL su Supabase Auth"
  OWNER_ID="$(find_user_id_by_email "$OWNER_EMAIL")"
  [[ -n "$OWNER_ID" ]] ||
    fail "proprietario non trovato: l'account deve gia esistere (primo login dall'app)"
  step "Proprietario trovato: $OWNER_ID"
else
  step "Verifico il proprietario indicato ($OWNER_ID)"
  http_call GET "/auth/v1/admin/users/${OWNER_ID}" ""
  [[ "$HTTP_STATUS" == "200" ]] ||
    fail "proprietario $OWNER_ID non trovato su Supabase Auth (HTTP $HTTP_STATUS)"
fi

# 2. Utente worker -------------------------------------------------------------
step "Cerco l'utente worker $WORKER_EMAIL su Supabase Auth"
WORKER_ID="$(find_user_id_by_email "$WORKER_EMAIL")"

# Guardia PRIMA di qualunque scrittura: se l'email worker risolve
# all'account del proprietario (es. typo con --owner-id), procedere
# sovrascriverebbe la password personale di Marco su Supabase Auth.
[[ -z "$WORKER_ID" || "$WORKER_ID" != "$OWNER_ID" ]] ||
  fail "worker e proprietario coincidono: nessuna credenziale è stata toccata"

NEEDS_NEW_PASSWORD=0
if [[ -z "$WORKER_ID" ]]; then
  NEEDS_NEW_PASSWORD=1
  step "Utente worker assente: lo creo con una password generata"
elif ! keychain_item_exists; then
  NEEDS_NEW_PASSWORD=1
  step "Utente worker gia presente ($WORKER_ID) ma password assente dal Portachiavi: la rigenero"
else
  step "Utente worker gia presente ($WORKER_ID) con password nel Portachiavi: credenziali invariate"
fi

if ((NEEDS_NEW_PASSWORD == 1)); then
  WORKER_PASSWORD="$(openssl rand -hex 32)"
  if [[ -z "$WORKER_ID" ]]; then
    request_body="$(
      printf '%s' "$WORKER_PASSWORD" | "$PYTHON_BIN" -c '
import json
import sys

print(json.dumps({
    "email": sys.argv[1],
    "password": sys.stdin.read(),
    "email_confirm": True,
}))
' "$WORKER_EMAIL"
    )"
    http_call POST "/auth/v1/admin/users" "$request_body"
    request_body=""
    [[ "$HTTP_STATUS" == "200" || "$HTTP_STATUS" == "201" ]] ||
      fail "creazione utente worker non riuscita (HTTP $HTTP_STATUS)"
    WORKER_ID="$(py_json_field "$HTTP_BODY" "id")"
    [[ "$WORKER_ID" =~ $UUID_PATTERN ]] ||
      fail "risposta di creazione utente senza id valido"
    step "Utente worker creato: $WORKER_ID"
  else
    request_body="$(
      printf '%s' "$WORKER_PASSWORD" | "$PYTHON_BIN" -c '
import json
import sys

print(json.dumps({"password": sys.stdin.read()}))
'
    )"
    http_call PUT "/auth/v1/admin/users/${WORKER_ID}" "$request_body"
    request_body=""
    [[ "$HTTP_STATUS" == "200" ]] ||
      fail "aggiornamento password worker non riuscito (HTTP $HTTP_STATUS)"
    step "Password del worker rigenerata su Supabase Auth"
  fi
  store_worker_password_in_keychain
  WORKER_PASSWORD=""
  step "Password salvata nel Portachiavi (servizio $KEYCHAIN_SERVICE, account $WORKER_EMAIL); valore mai mostrato"
fi

[[ "$WORKER_ID" != "$OWNER_ID" ]] ||
  fail "worker e proprietario coincidono: il binding richiede utenti distinti"

# 3. Binding meal_analysis e meal_planning -------------------------------------
BINDINGS_ACTIVE=()
BINDINGS_PENDING=()
for scope in "${BINDING_SCOPES[@]}"; do
  if ensure_binding "$scope"; then
    BINDINGS_ACTIVE+=("$scope")
  else
    BINDINGS_PENDING+=("$scope")
  fi
done

# 4. Riepilogo -----------------------------------------------------------------
printf 'Provisioning completato.\n'
printf 'Riepilogo (nessun segreto mostrato):\n'
step "worker:       $WORKER_EMAIL ($WORKER_ID)"
step "proprietario: $OWNER_ID"
step "Portachiavi:  servizio $KEYCHAIN_SERVICE, account $WORKER_EMAIL"
if ((${#BINDINGS_ACTIVE[@]} > 0)); then
  step "binding attivi:      ${BINDINGS_ACTIVE[*]}"
fi
if ((${#BINDINGS_PENDING[@]} > 0)); then
  step "binding DA COMPLETARE dal SQL editor (vedi sopra): ${BINDINGS_PENDING[*]}"
fi
printf 'Prossimi passi:\n'
step "verifica: .venv/bin/kal-meal-worker doctor (con KAL_SUPABASE_URL, KAL_SUPABASE_PUBLISHABLE_KEY, KAL_MEAL_WORKER_EMAIL, KAL_CLAUDE_EXECUTABLE)"
step "prova in sessione grafica: .venv/bin/kal-meal-worker serve --once"
step "la service_role key non serve piu sul Mac: chiudi la shell o esegui unset KAL_PROVISION_SERVICE_ROLE_KEY"
