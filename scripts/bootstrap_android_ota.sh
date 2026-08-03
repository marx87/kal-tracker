#!/usr/bin/env bash

set +x
set -Eeuo pipefail
umask 077

readonly SCRIPT_NAME="$(basename "$0")"
readonly DEFAULT_ALIAS="kal-tracker"
readonly DEFAULT_DNAME="CN=Kal Tracker, OU=Personal, O=Kal Tracker, L=Rome, ST=Rome, C=IT"
readonly DEFAULT_VALIDITY_DAYS="10000"

OUTPUT_DIR=""
KEY_ALIAS="$DEFAULT_ALIAS"
DISTINGUISHED_NAME="$DEFAULT_DNAME"
VALIDITY_DAYS="$DEFAULT_VALIDITY_DAYS"
KEYTOOL_BIN=""
MODE=""
CREATED_OUTPUT=0
COMPLETED=0

usage() {
  cat <<EOF
Uso:
  $SCRIPT_NAME --output-dir /percorso/assoluto/fuori-repository --dry-run
  $SCRIPT_NAME --output-dir /percorso/assoluto/fuori-repository --create [opzioni]

Opzioni:
  --alias NOME             Alias del keystore (default: $DEFAULT_ALIAS)
  --dname NOME_DN          Distinguished Name del certificato Android
  --validity-days GIORNI   Validita del certificato (default: $DEFAULT_VALIDITY_DAYS)
  --keytool PERCORSO       Percorso esplicito a keytool
  --dry-run                Controlla percorso e dipendenze, senza creare file
  --create                 Genera il bundle una sola volta; non sovrascrive mai
  -h, --help               Mostra questo aiuto

Lo script non stampa password, chiavi o valori base64 e non contatta GitHub.
EOF
}

fail() {
  printf 'Errore: %s\n' "$*" >&2
  exit 1
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

file_mode() {
  local path="$1"
  if stat -f '%Lp' "$path" >/dev/null 2>&1; then
    stat -f '%Lp' "$path"
  else
    stat -c '%a' "$path"
  fi
}

base64_file_one_line() {
  base64 <"$1" | tr -d '\r\n'
}

find_keytool() {
  local candidate=""
  local candidates=()

  if [[ -n "$KEYTOOL_BIN" ]]; then
    candidates+=("$KEYTOOL_BIN")
  fi
  if [[ -n "${JAVA_HOME:-}" ]]; then
    candidates+=("$JAVA_HOME/bin/keytool")
  fi
  if command_exists keytool; then
    candidates+=("$(command -v keytool)")
  fi
  candidates+=(
    "/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin/keytool"
    "/opt/android-studio/jbr/bin/keytool"
  )

  for candidate in "${candidates[@]}"; do
    if [[ -x "$candidate" ]] && "$candidate" -help >/dev/null 2>&1; then
      KEYTOOL_BIN="$candidate"
      return 0
    fi
  done

  fail "keytool non disponibile. Installa Android Studio/JDK oppure usa --keytool."
}

cleanup() {
  local exit_code=$?
  if ((exit_code != 0 && CREATED_OUTPUT == 1 && COMPLETED == 0)); then
    rm -f -- \
      "$OUTPUT_DIR/.store-password" \
      "$OUTPUT_DIR/.key-password" \
      "$OUTPUT_DIR/.self-check-message" \
      "$OUTPUT_DIR/.self-check-signature" \
      "$OUTPUT_DIR/kal-tracker-release.jks" \
      "$OUTPUT_DIR/android-signer-cert.pem" \
      "$OUTPUT_DIR/ota-ed25519-private.pem" \
      "$OUTPUT_DIR/ota-ed25519-public.pem" \
      "$OUTPUT_DIR/github-actions-secrets.env" \
      "$OUTPUT_DIR/github-actions-vars.env" \
      "$OUTPUT_DIR/github-actions-secret-names.txt" \
      "$OUTPUT_DIR/github-actions-var-names.txt" \
      "$OUTPUT_DIR/METADATA.txt" \
      "$OUTPUT_DIR/README_FIRST.txt"
    rm -f -- "$OUTPUT_DIR/.INCOMPLETE"
    if rmdir -- "$OUTPUT_DIR" 2>/dev/null; then
      printf 'Generazione interrotta: i file parziali noti sono stati rimossi.\n' >&2
    else
      touch "$OUTPUT_DIR/.INCOMPLETE" 2>/dev/null || true
      chmod 700 "$OUTPUT_DIR" 2>/dev/null || true
      chmod 600 "$OUTPUT_DIR/.INCOMPLETE" 2>/dev/null || true
      printf 'Generazione interrotta: directory incompleta conservata per controllo: %s\n' "$OUTPUT_DIR" >&2
    fi
  fi
  exit "$exit_code"
}
trap cleanup EXIT

while (($# > 0)); do
  case "$1" in
    --output-dir)
      (($# >= 2)) || fail "manca il valore di --output-dir"
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --alias)
      (($# >= 2)) || fail "manca il valore di --alias"
      KEY_ALIAS="$2"
      shift 2
      ;;
    --dname)
      (($# >= 2)) || fail "manca il valore di --dname"
      DISTINGUISHED_NAME="$2"
      shift 2
      ;;
    --validity-days)
      (($# >= 2)) || fail "manca il valore di --validity-days"
      VALIDITY_DAYS="$2"
      shift 2
      ;;
    --keytool)
      (($# >= 2)) || fail "manca il valore di --keytool"
      KEYTOOL_BIN="$2"
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
    *)
      fail "opzione sconosciuta: $1"
      ;;
  esac
done

[[ -n "$OUTPUT_DIR" ]] || fail "--output-dir e obbligatorio"
[[ -n "$MODE" ]] || fail "specifica --dry-run oppure --create"
[[ "$OUTPUT_DIR" == /* ]] || fail "--output-dir deve essere un percorso assoluto"
[[ "$KEY_ALIAS" =~ ^[A-Za-z0-9._-]+$ ]] || fail "alias non valido"
[[ "$VALIDITY_DAYS" =~ ^[1-9][0-9]*$ ]] || fail "--validity-days deve essere un intero positivo"
((VALIDITY_DAYS >= 9125)) || fail "il certificato Android deve essere valido per almeno 25 anni (9125 giorni)"
[[ -n "${DISTINGUISHED_NAME// }" ]] || fail "--dname non puo essere vuoto"

REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)" ||
  fail "impossibile determinare la radice del repository"
[[ -n "$REPO_ROOT" && -d "$REPO_ROOT" ]] || fail "radice repository non valida"
REPO_ROOT="$(cd "$REPO_ROOT" && pwd -P)"
readonly REPO_ROOT
readonly OUTPUT_PARENT_INPUT="$(dirname "$OUTPUT_DIR")"
readonly OUTPUT_LEAF="$(basename "$OUTPUT_DIR")"
[[ "$OUTPUT_LEAF" != "." && "$OUTPUT_LEAF" != ".." ]] || fail "nome directory di output non valido"
[[ "$OUTPUT_LEAF" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || fail "nome directory di output non valido"
[[ -d "$OUTPUT_PARENT_INPUT" ]] || fail "la directory padre deve gia esistere: $OUTPUT_PARENT_INPUT"
readonly OUTPUT_PARENT="$(cd "$OUTPUT_PARENT_INPUT" && pwd -P)"
[[ "$OUTPUT_PARENT" != "/" ]] || fail "non creare il bundle direttamente nella radice del filesystem"
OUTPUT_DIR="$OUTPUT_PARENT/$OUTPUT_LEAF"

[[ ! -e "$OUTPUT_DIR" && ! -L "$OUTPUT_DIR" ]] ||
  fail "la directory di output esiste gia; non verra sovrascritta: $OUTPUT_DIR"
case "$OUTPUT_DIR/" in
  "$REPO_ROOT/"*) fail "la directory delle chiavi deve essere esterna al repository" ;;
esac
case "$OUTPUT_DIR/" in
  /tmp/* | /private/tmp/* | /var/tmp/*) fail "usa una directory persistente, non una directory temporanea" ;;
esac

command_exists openssl || fail "openssl non disponibile"
command_exists base64 || fail "base64 non disponibile"
command_exists stat || fail "stat non disponibile"
command_exists git || fail "git non disponibile"
openssl list -public-key-algorithms 2>/dev/null | grep -qi 'ED25519' ||
  fail "questa versione di openssl non supporta Ed25519"
find_keytool

if [[ "$MODE" == "dry-run" ]]; then
  printf 'Preflight locale OK: percorso esterno, nuovo e persistente.\n'
  printf 'Dipendenze OK: OpenSSL con Ed25519, base64, stat e keytool.\n'
  printf 'Nessun file creato e nessuna richiesta GitHub eseguita.\n'
  exit 0
fi

mkdir -- "$OUTPUT_DIR"
chmod 700 "$OUTPUT_DIR"
CREATED_OUTPUT=1
touch "$OUTPUT_DIR/.INCOMPLETE"
chmod 600 "$OUTPUT_DIR/.INCOMPLETE"

readonly KEYSTORE="$OUTPUT_DIR/kal-tracker-release.jks"
readonly SIGNER_CERT="$OUTPUT_DIR/android-signer-cert.pem"
readonly OTA_PRIVATE_KEY="$OUTPUT_DIR/ota-ed25519-private.pem"
readonly OTA_PUBLIC_KEY="$OUTPUT_DIR/ota-ed25519-public.pem"
readonly STORE_PASSWORD_FILE="$OUTPUT_DIR/.store-password"
readonly KEY_PASSWORD_FILE="$OUTPUT_DIR/.key-password"
readonly SELF_CHECK_MESSAGE="$OUTPUT_DIR/.self-check-message"
readonly SELF_CHECK_SIGNATURE="$OUTPUT_DIR/.self-check-signature"
readonly SECRETS_FILE="$OUTPUT_DIR/github-actions-secrets.env"
readonly VARS_FILE="$OUTPUT_DIR/github-actions-vars.env"

STORE_PASSWORD="$(openssl rand -hex 32)"
KEY_PASSWORD="$(openssl rand -hex 32)"
printf '%s' "$STORE_PASSWORD" >"$STORE_PASSWORD_FILE"
printf '%s' "$KEY_PASSWORD" >"$KEY_PASSWORD_FILE"
chmod 600 "$STORE_PASSWORD_FILE" "$KEY_PASSWORD_FILE"

"$KEYTOOL_BIN" -genkeypair -noprompt \
  -keystore "$KEYSTORE" \
  -storetype JKS \
  -storepass:file "$STORE_PASSWORD_FILE" \
  -keypass:file "$KEY_PASSWORD_FILE" \
  -alias "$KEY_ALIAS" \
  -keyalg RSA \
  -keysize 4096 \
  -sigalg SHA256withRSA \
  -validity "$VALIDITY_DAYS" \
  -dname "$DISTINGUISHED_NAME" >/dev/null

"$KEYTOOL_BIN" -exportcert -rfc \
  -keystore "$KEYSTORE" \
  -storepass:file "$STORE_PASSWORD_FILE" \
  -alias "$KEY_ALIAS" >"$SIGNER_CERT"

openssl genpkey -algorithm ED25519 -out "$OTA_PRIVATE_KEY" 2>/dev/null
openssl pkey -in "$OTA_PRIVATE_KEY" -pubout -out "$OTA_PUBLIC_KEY" 2>/dev/null
chmod 600 "$KEYSTORE" "$SIGNER_CERT" "$OTA_PRIVATE_KEY" "$OTA_PUBLIC_KEY"

ANDROID_SIGNER_SHA256="$(
  openssl x509 -in "$SIGNER_CERT" -outform DER 2>/dev/null |
    openssl dgst -sha256 -hex 2>/dev/null |
    awk '{print tolower($NF)}'
)"
[[ "$ANDROID_SIGNER_SHA256" =~ ^[0-9a-f]{64}$ ]] || fail "fingerprint Android non valido"

OTA_PUBLIC_KEY_BASE64="$(
  openssl pkey -in "$OTA_PRIVATE_KEY" -pubout -outform DER 2>/dev/null |
    tail -c 32 |
    base64 |
    tr -d '\r\n'
)"
[[ "$(printf '%s' "$OTA_PUBLIC_KEY_BASE64" | openssl base64 -d -A | wc -c | tr -d '[:space:]')" == "32" ]] ||
  fail "chiave pubblica OTA non valida"

printf 'kal-tracker-ota-bootstrap-self-check\n' >"$SELF_CHECK_MESSAGE"
openssl pkeyutl -sign -rawin \
  -inkey "$OTA_PRIVATE_KEY" \
  -in "$SELF_CHECK_MESSAGE" \
  -out "$SELF_CHECK_SIGNATURE" 2>/dev/null
openssl pkeyutl -verify -rawin -pubin \
  -inkey "$OTA_PUBLIC_KEY" \
  -in "$SELF_CHECK_MESSAGE" \
  -sigfile "$SELF_CHECK_SIGNATURE" >/dev/null 2>&1 || fail "self-check firma OTA fallito"

ANDROID_KEYSTORE_BASE64="$(base64_file_one_line "$KEYSTORE")"
OTA_PRIVATE_KEY_BASE64="$(base64_file_one_line "$OTA_PRIVATE_KEY")"

{
  printf '# File sensibile: non eseguire con source, non commettere e non stampare.\n'
  printf 'ANDROID_KEYSTORE_BASE64=%s\n' "$ANDROID_KEYSTORE_BASE64"
  printf 'ANDROID_KEY_ALIAS=%s\n' "$KEY_ALIAS"
  printf 'ANDROID_STORE_PASSWORD=%s\n' "$STORE_PASSWORD"
  printf 'ANDROID_KEY_PASSWORD=%s\n' "$KEY_PASSWORD"
  printf 'OTA_ED25519_PRIVATE_KEY_BASE64=%s\n' "$OTA_PRIVATE_KEY_BASE64"
  printf '# RELEASES_REPO_TOKEN non viene generato: crearlo separatamente con accesso al solo repository release.\n'
} >"$SECRETS_FILE"

{
  printf '# Valori pubblici per le GitHub Actions environment variables.\n'
  printf 'OTA_PUBLIC_KEY_BASE64=%s\n' "$OTA_PUBLIC_KEY_BASE64"
  printf 'ANDROID_SIGNER_SHA256=%s\n' "$ANDROID_SIGNER_SHA256"
} >"$VARS_FILE"

{
  printf '%s\n' \
    ANDROID_KEYSTORE_BASE64 \
    ANDROID_KEY_ALIAS \
    ANDROID_STORE_PASSWORD \
    ANDROID_KEY_PASSWORD \
    OTA_ED25519_PRIVATE_KEY_BASE64 \
    RELEASES_REPO_TOKEN
} >"$OUTPUT_DIR/github-actions-secret-names.txt"

{
  printf '%s\n' \
    OTA_PUBLIC_KEY_BASE64 \
    ANDROID_SIGNER_SHA256 \
    SUPABASE_URL \
    SUPABASE_PUBLISHABLE_KEY
} >"$OUTPUT_DIR/github-actions-var-names.txt"

{
  printf 'createdAt=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf 'androidKeyAlias=%s\n' "$KEY_ALIAS"
  printf 'androidSignerSha256=%s\n' "$ANDROID_SIGNER_SHA256"
  printf 'otaKeyId=ota-2026-01\n'
  printf 'certificateValidityDays=%s\n' "$VALIDITY_DAYS"
} >"$OUTPUT_DIR/METADATA.txt"

{
  printf 'BUNDLE DI FIRMA KAL TRACKER - CONSERVARE FUORI DAL REPOSITORY\n\n'
  printf '1. Creare due backup cifrati e verificare di poterli leggere.\n'
  printf '2. Inserire i valori nei secret/var dell environment GitHub release tramite interfaccia web.\n'
  printf '3. Creare RELEASES_REPO_TOKEN separatamente; non usare il token gh gia autenticato.\n'
  printf '4. Non rinominare o rigenerare il keystore dopo la prima installazione release.\n'
  printf '5. Eseguire scripts/validate_ota_bundle.sh prima di ogni ripristino/configurazione.\n'
} >"$OUTPUT_DIR/README_FIRST.txt"

rm -f -- "$STORE_PASSWORD_FILE" "$KEY_PASSWORD_FILE" "$SELF_CHECK_MESSAGE" "$SELF_CHECK_SIGNATURE"
STORE_PASSWORD=""
KEY_PASSWORD=""
ANDROID_KEYSTORE_BASE64=""
OTA_PRIVATE_KEY_BASE64=""

for generated_file in "$OUTPUT_DIR"/*; do
  [[ -f "$generated_file" && ! -L "$generated_file" ]] || fail "output inatteso nel bundle"
  chmod 600 "$generated_file"
  [[ "$(file_mode "$generated_file")" == "600" ]] || fail "permessi non sicuri: $generated_file"
done
[[ "$(file_mode "$OUTPUT_DIR")" == "700" ]] || fail "la directory output non ha permessi 700"

rm -f -- "$OUTPUT_DIR/.INCOMPLETE"
COMPLETED=1

printf 'Bootstrap completato in: %s\n' "$OUTPUT_DIR"
printf 'I valori sensibili sono nel solo file github-actions-secrets.env e non sono stati stampati.\n'
printf 'Nessuna modifica GitHub e stata eseguita.\n'
