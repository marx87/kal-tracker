#!/usr/bin/env bash

set +x
set -Eeuo pipefail
umask 077

SOURCE_REPO="marx87/kal-tracker"
RELEASES_REPO="marx87/kal-tracker-releases"
ENVIRONMENT_NAME="release"
VERSION=""
BUILD_NUMBER=""
EXPECTED_SOURCE_COMMIT=""
TEMP_DIR=""
readonly MAX_ANDROID_BUILD_NUMBER=2100000000

usage() {
  cat <<EOF
Uso:
  KAL_PREFLIGHT_GH_TOKEN=... $(basename "$0") \\
    --version 0.1.0 --build-number 1 --expected-source-commit COMMIT

Opzioni:
  --source-repo OWNER/REPO       Default: $SOURCE_REPO
  --releases-repo OWNER/REPO     Default: $RELEASES_REPO
  --environment NOME             Default: $ENVIRONMENT_NAME
  --version SEMVER                Versione candidata
  --build-number NUMERO           VersionCode candidato
  --expected-source-commit COMMIT SHA sorgente nella storia di main (da 7 a 40 caratteri)

Usa esclusivamente KAL_PREFLIGHT_GH_TOKEN e una configurazione gh temporanea:
il login gh gia presente sul Mac viene ignorato. Esegue solo richieste GET e non
stampa valori di secret, variabili, token o chiavi.
EOF
}

fail() {
  printf 'Errore preflight: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  local exit_code=$?
  if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
    case "$(basename "$TEMP_DIR")" in
      kal-release-preflight.*)
        find "$TEMP_DIR" -depth -mindepth 1 -delete
        rmdir -- "$TEMP_DIR"
        ;;
      *) printf 'Rifiuto cleanup di un percorso temporaneo inatteso.\n' >&2 ;;
    esac
  fi
  unset GH_TOKEN GH_HOST GH_CONFIG_DIR GH_PROMPT_DISABLED GH_PAGER
  exit "$exit_code"
}
trap cleanup EXIT

api_get() {
  local endpoint="$1"
  local destination="$2"
  gh api --method GET "$endpoint" >"$destination"
}

require_secret_name() {
  local name="$1"
  jq -e --arg name "$name" '.secrets | any(.name == $name)' \
    "$TEMP_DIR/environment-secrets.json" >/dev/null || fail "manca un secret richiesto nell environment"
}

read_variable_value() {
  local name="$1"
  local count=""
  count="$(jq -r --arg name "$name" '[.variables[] | select(.name == $name)] | length' \
    "$TEMP_DIR/environment-vars.json")"
  [[ "$count" == "1" ]] || fail "manca una variabile pubblica richiesta nell environment"
  jq -r --arg name "$name" '.variables[] | select(.name == $name) | .value' \
    "$TEMP_DIR/environment-vars.json"
}

validate_semver() {
  local value="$1"
  local major minor patch
  [[ "$value" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || return 1
  IFS=. read -r major minor patch <<<"$value"
  (( ${#major} <= 10 && 10#$major <= 2147483647 )) || return 1
  (( ${#minor} <= 10 && 10#$minor <= 2147483647 )) || return 1
  (( ${#patch} <= 10 && 10#$patch <= 2147483647 )) || return 1
}

semver_is_lower_than() {
  local candidate="$1"
  local existing="$2"
  local c_major c_minor c_patch e_major e_minor e_patch
  IFS=. read -r c_major c_minor c_patch <<<"$candidate"
  IFS=. read -r e_major e_minor e_patch <<<"$existing"
  if ((10#$c_major != 10#$e_major)); then
    ((10#$c_major < 10#$e_major))
  elif ((10#$c_minor != 10#$e_minor)); then
    ((10#$c_minor < 10#$e_minor))
  else
    ((10#$c_patch < 10#$e_patch))
  fi
}

while (($# > 0)); do
  case "$1" in
    --source-repo)
      (($# >= 2)) || fail "manca il valore di --source-repo"
      SOURCE_REPO="$2"
      shift 2
      ;;
    --releases-repo)
      (($# >= 2)) || fail "manca il valore di --releases-repo"
      RELEASES_REPO="$2"
      shift 2
      ;;
    --environment)
      (($# >= 2)) || fail "manca il valore di --environment"
      ENVIRONMENT_NAME="$2"
      shift 2
      ;;
    --version)
      (($# >= 2)) || fail "manca il valore di --version"
      VERSION="$2"
      shift 2
      ;;
    --build-number)
      (($# >= 2)) || fail "manca il valore di --build-number"
      BUILD_NUMBER="$2"
      shift 2
      ;;
    --expected-source-commit)
      (($# >= 2)) || fail "manca il valore di --expected-source-commit"
      EXPECTED_SOURCE_COMMIT="$2"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) fail "opzione sconosciuta: $1" ;;
  esac
done

[[ "$SOURCE_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail "source repo non valido"
[[ "$RELEASES_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail "releases repo non valido"
[[ "$ENVIRONMENT_NAME" =~ ^[A-Za-z0-9_.-]+$ ]] || fail "environment non valido"
validate_semver "$VERSION" || fail "versione SemVer non valida"
[[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || fail "build number non valido"
(( ${#BUILD_NUMBER} <= 10 )) || fail "build number troppo lungo"
((10#$BUILD_NUMBER <= MAX_ANDROID_BUILD_NUMBER)) || fail "build number oltre il limite Android"
[[ "$EXPECTED_SOURCE_COMMIT" =~ ^[0-9a-f]{7,40}$ ]] || fail "commit atteso non valido"
[[ -n "${KAL_PREFLIGHT_GH_TOKEN:-}" ]] ||
  fail "imposta KAL_PREFLIGHT_GH_TOKEN; il token del login gh corrente non verra usato"

command -v gh >/dev/null 2>&1 || fail "gh CLI non disponibile"
command -v jq >/dev/null 2>&1 || fail "jq non disponibile"
command -v openssl >/dev/null 2>&1 || fail "openssl non disponibile"
command -v mktemp >/dev/null 2>&1 || fail "mktemp non disponibile"

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kal-release-preflight.XXXXXX")"
chmod 700 "$TEMP_DIR"
mkdir "$TEMP_DIR/gh-config"
chmod 700 "$TEMP_DIR/gh-config"

# GH_TOKEN prevale sulla configurazione gh. GH_CONFIG_DIR vuoto impedisce qualunque
# fallback al login gia presente. Il token esplicito viene rimosso dal suo nome
# originale prima di avviare gh.
export GH_TOKEN="$KAL_PREFLIGHT_GH_TOKEN"
export GH_HOST="github.com"
export GH_PROMPT_DISABLED=1
export GH_PAGER=cat
unset KAL_PREFLIGHT_GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN GH_DEBUG GH_FORCE_TTY
export GH_CONFIG_DIR="$TEMP_DIR/gh-config"

api_get "repos/$SOURCE_REPO" "$TEMP_DIR/source-repo.json"
api_get "repos/$RELEASES_REPO" "$TEMP_DIR/releases-repo.json"
jq -e '.private == true and .default_branch == "main"' "$TEMP_DIR/source-repo.json" >/dev/null ||
  fail "il repository sorgente deve essere privato e avere main come default branch"
jq -e '.private == false and .visibility == "public"' "$TEMP_DIR/releases-repo.json" >/dev/null ||
  fail "il repository binari deve essere pubblico"
printf 'OK repository: sorgente privato e repository release pubblico.\n'

api_get "repos/$SOURCE_REPO/branches/main" "$TEMP_DIR/main-branch.json"
ACTUAL_MAIN_COMMIT="$(jq -r '.commit.sha // empty' "$TEMP_DIR/main-branch.json")"
[[ "$ACTUAL_MAIN_COMMIT" =~ ^[0-9a-f]{40}$ ]] || fail "SHA main non leggibile"
api_get "repos/$SOURCE_REPO/commits/$EXPECTED_SOURCE_COMMIT" "$TEMP_DIR/source-commit.json"
RESOLVED_SOURCE_COMMIT="$(jq -r '.sha // empty' "$TEMP_DIR/source-commit.json")"
[[ "$RESOLVED_SOURCE_COMMIT" =~ ^[0-9a-f]{40}$ ]] || fail "commit sorgente non risolvibile"
[[ "$RESOLVED_SOURCE_COMMIT" == "$EXPECTED_SOURCE_COMMIT"* ]] || fail "il prefisso identifica un commit diverso"
api_get "repos/$SOURCE_REPO/compare/$RESOLVED_SOURCE_COMMIT...main" "$TEMP_DIR/source-compare.json"
jq -e --arg source "$RESOLVED_SOURCE_COMMIT" \
  '(.status == "ahead" or .status == "identical") and .merge_base_commit.sha == $source' \
  "$TEMP_DIR/source-compare.json" >/dev/null || fail "il commit sorgente non appartiene alla storia di main"
api_get "repos/$SOURCE_REPO/actions/workflows/android-release.yml" "$TEMP_DIR/workflow.json"
jq -e '.state == "active"' "$TEMP_DIR/workflow.json" >/dev/null || fail "workflow Android release non attivo su main"
printf 'OK sorgente: commit candidato presente nella storia di main e workflow attivo.\n'

api_get "repos/$SOURCE_REPO/environments/$ENVIRONMENT_NAME" "$TEMP_DIR/environment.json"
jq -e '.deployment_branch_policy.protected_branches == false and
       .deployment_branch_policy.custom_branch_policies == true' \
  "$TEMP_DIR/environment.json" >/dev/null || fail "l environment deve usare una policy custom per i branch"
api_get "repos/$SOURCE_REPO/environments/$ENVIRONMENT_NAME/deployment-branch-policies?per_page=100" \
  "$TEMP_DIR/branch-policies.json"
jq -e '.branch_policies | length == 1 and .[0].name == "main" and .[0].type == "branch"' \
  "$TEMP_DIR/branch-policies.json" >/dev/null || fail "l environment release deve consentire soltanto il branch main"
printf 'OK environment: accesso limitato al solo branch main.\n'

api_get "repos/$SOURCE_REPO/environments/$ENVIRONMENT_NAME/secrets?per_page=100" \
  "$TEMP_DIR/environment-secrets.json"
for required_secret in \
  ANDROID_KEYSTORE_BASE64 \
  ANDROID_KEY_ALIAS \
  ANDROID_STORE_PASSWORD \
  ANDROID_KEY_PASSWORD \
  OTA_ED25519_PRIVATE_KEY_BASE64 \
  RELEASES_REPO_TOKEN; do
  require_secret_name "$required_secret"
done
printf 'OK secrets: presenti tutti i 6 nomi richiesti; i valori non sono accessibili ne stampati.\n'

api_get "repos/$SOURCE_REPO/environments/$ENVIRONMENT_NAME/variables?per_page=100" \
  "$TEMP_DIR/environment-vars.json"
OTA_PUBLIC_KEY_BASE64="$(read_variable_value OTA_PUBLIC_KEY_BASE64)"
ANDROID_SIGNER_SHA256="$(read_variable_value ANDROID_SIGNER_SHA256)"
[[ "$(printf '%s' "$OTA_PUBLIC_KEY_BASE64" | openssl base64 -d -A 2>/dev/null | wc -c | tr -d '[:space:]')" == "32" ]] ||
  fail "OTA_PUBLIC_KEY_BASE64 non contiene esattamente 32 byte"
[[ "$ANDROID_SIGNER_SHA256" =~ ^[0-9a-f]{64}$ ]] || fail "ANDROID_SIGNER_SHA256 non e nel formato canonico"
OTA_PUBLIC_KEY_BASE64=""
ANDROID_SIGNER_SHA256=""
printf 'OK variables: chiave OTA e fingerprint hanno formato valido; valori non stampati.\n'

api_get "repos/$RELEASES_REPO/releases?per_page=100" "$TEMP_DIR/releases.json"
jq -e --arg tag "v${VERSION}-b${BUILD_NUMBER}" 'any(.tag_name == $tag)' \
  "$TEMP_DIR/releases.json" >/dev/null && fail "il tag candidato esiste gia, anche come draft"
while IFS= read -r existing_tag; do
  [[ -n "$existing_tag" ]] || continue
  if [[ "$existing_tag" =~ ^v((0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*))-b([1-9][0-9]*)$ ]]; then
    existing_version="${BASH_REMATCH[1]}"
    existing_build="${BASH_REMATCH[5]}"
    validate_semver "$existing_version" || fail "una release esistente ha SemVer oltre i limiti supportati"
    (( ${#existing_build} <= 10 )) || fail "una release esistente ha build troppo lunga"
    ((10#$existing_build <= MAX_ANDROID_BUILD_NUMBER)) || fail "una release esistente ha build oltre il limite Android"
    ((10#$BUILD_NUMBER > 10#$existing_build)) || fail "il build number candidato non e strettamente crescente"
    semver_is_lower_than "$VERSION" "$existing_version" && fail "la versione candidata e precedente a una release esistente"
  fi
done < <(jq -r '.[] | select(.draft == false) | .tag_name' "$TEMP_DIR/releases.json")
printf 'OK release candidate: tag libero, SemVer non regressivo e build number crescente.\n'

printf 'Preflight remoto completato con sole richieste GET. Nessuna configurazione o release e stata modificata.\n'
