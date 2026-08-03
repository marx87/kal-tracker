#!/usr/bin/env bash

set +x
set -Eeuo pipefail
umask 077

BUNDLE_DIR=""
KEYTOOL_BIN=""
TEMP_DIR=""

usage() {
  cat <<EOF
Uso: $(basename "$0") --bundle-dir /percorso/assoluto/al/bundle [--keytool /percorso/keytool]

Valida permessi, keystore, fingerprint e coppia Ed25519 senza stampare valori sensibili.
Non modifica il bundle e non contatta GitHub.
EOF
}

fail() {
  printf 'Errore: %s\n' "$*" >&2
  exit 1
}

file_mode() {
  local path="$1"
  if stat -f '%Lp' "$path" >/dev/null 2>&1; then
    stat -f '%Lp' "$path"
  else
    stat -c '%a' "$path"
  fi
}

find_keytool() {
  local candidate=""
  local candidates=()

  [[ -z "$KEYTOOL_BIN" ]] || candidates+=("$KEYTOOL_BIN")
  [[ -z "${JAVA_HOME:-}" ]] || candidates+=("$JAVA_HOME/bin/keytool")
  if command -v keytool >/dev/null 2>&1; then
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
  fail "keytool non disponibile"
}

read_assignment() {
  local file="$1"
  local name="$2"
  local count=""
  local value=""

  count="$(awk -F= -v name="$name" '$1 == name {count++} END {print count+0}' "$file")"
  [[ "$count" == "1" ]] || fail "$name deve comparire esattamente una volta in $(basename "$file")"
  value="$(awk -v prefix="$name=" 'index($0, prefix) == 1 {print substr($0, length(prefix) + 1)}' "$file")"
  [[ -n "$value" ]] || fail "$name e vuoto"
  printf '%s' "$value"
}

decode_base64_to_file() {
  local encoded="$1"
  local destination="$2"
  printf '%s' "$encoded" | openssl base64 -d -A >"$destination" 2>/dev/null ||
    fail "valore base64 non valido"
  chmod 600 "$destination"
}

cleanup() {
  local exit_code=$?
  if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
    rm -f -- \
      "$TEMP_DIR/decoded-keystore.jks" \
      "$TEMP_DIR/decoded-ota-private.pem" \
      "$TEMP_DIR/key-roundtrip.p12" \
      "$TEMP_DIR/store-password" \
      "$TEMP_DIR/key-password" \
      "$TEMP_DIR/message" \
      "$TEMP_DIR/signature" \
      "$TEMP_DIR/signer-cert.pem"
    rmdir -- "$TEMP_DIR" 2>/dev/null || true
  fi
  exit "$exit_code"
}
trap cleanup EXIT

while (($# > 0)); do
  case "$1" in
    --bundle-dir)
      (($# >= 2)) || fail "manca il valore di --bundle-dir"
      BUNDLE_DIR="$2"
      shift 2
      ;;
    --keytool)
      (($# >= 2)) || fail "manca il valore di --keytool"
      KEYTOOL_BIN="$2"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) fail "opzione sconosciuta: $1" ;;
  esac
done

[[ -n "$BUNDLE_DIR" ]] || fail "--bundle-dir e obbligatorio"
[[ "$BUNDLE_DIR" == /* ]] || fail "--bundle-dir deve essere assoluto"
[[ -d "$BUNDLE_DIR" && ! -L "$BUNDLE_DIR" ]] || fail "bundle inesistente o symlink non consentito"
BUNDLE_DIR="$(cd "$BUNDLE_DIR" && pwd -P)"
[[ "$(file_mode "$BUNDLE_DIR")" == "700" ]] || fail "la directory bundle deve avere permessi 700"

readonly KEYSTORE="$BUNDLE_DIR/kal-tracker-release.jks"
readonly PRIVATE_KEY="$BUNDLE_DIR/ota-ed25519-private.pem"
readonly PUBLIC_KEY="$BUNDLE_DIR/ota-ed25519-public.pem"
readonly SECRETS_FILE="$BUNDLE_DIR/github-actions-secrets.env"
readonly VARS_FILE="$BUNDLE_DIR/github-actions-vars.env"

for required_file in "$KEYSTORE" "$PRIVATE_KEY" "$PUBLIC_KEY" "$SECRETS_FILE" "$VARS_FILE"; do
  [[ -f "$required_file" && ! -L "$required_file" ]] || fail "file richiesto mancante o symlink: $required_file"
  [[ "$(file_mode "$required_file")" == "600" ]] || fail "permessi diversi da 600: $required_file"
done
for bundle_file in "$BUNDLE_DIR"/*; do
  [[ -f "$bundle_file" && ! -L "$bundle_file" ]] || fail "il bundle contiene un elemento inatteso"
  [[ "$(file_mode "$bundle_file")" == "600" ]] || fail "tutti i file del bundle devono avere permessi 600"
done

command -v openssl >/dev/null 2>&1 || fail "openssl non disponibile"
command -v mktemp >/dev/null 2>&1 || fail "mktemp non disponibile"
find_keytool

ANDROID_KEYSTORE_BASE64="$(read_assignment "$SECRETS_FILE" ANDROID_KEYSTORE_BASE64)"
ANDROID_KEY_ALIAS="$(read_assignment "$SECRETS_FILE" ANDROID_KEY_ALIAS)"
ANDROID_STORE_PASSWORD="$(read_assignment "$SECRETS_FILE" ANDROID_STORE_PASSWORD)"
ANDROID_KEY_PASSWORD="$(read_assignment "$SECRETS_FILE" ANDROID_KEY_PASSWORD)"
OTA_PRIVATE_KEY_BASE64="$(read_assignment "$SECRETS_FILE" OTA_ED25519_PRIVATE_KEY_BASE64)"
OTA_PUBLIC_KEY_BASE64="$(read_assignment "$VARS_FILE" OTA_PUBLIC_KEY_BASE64)"
EXPECTED_SIGNER_SHA256="$(read_assignment "$VARS_FILE" ANDROID_SIGNER_SHA256)"

[[ "$ANDROID_KEY_ALIAS" =~ ^[A-Za-z0-9._-]+$ ]] || fail "alias Android non valido"
[[ "$ANDROID_STORE_PASSWORD" =~ ^[0-9a-f]{64}$ ]] || fail "password keystore nel formato inatteso"
[[ "$ANDROID_KEY_PASSWORD" =~ ^[0-9a-f]{64}$ ]] || fail "password chiave nel formato inatteso"
[[ "$EXPECTED_SIGNER_SHA256" =~ ^[0-9a-f]{64}$ ]] || fail "fingerprint configurato non valido"

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kal-ota-validate.XXXXXX")"
chmod 700 "$TEMP_DIR"
readonly DECODED_KEYSTORE="$TEMP_DIR/decoded-keystore.jks"
readonly DECODED_PRIVATE_KEY="$TEMP_DIR/decoded-ota-private.pem"
readonly STORE_PASSWORD_FILE="$TEMP_DIR/store-password"
readonly KEY_PASSWORD_FILE="$TEMP_DIR/key-password"
readonly SIGNER_CERT="$TEMP_DIR/signer-cert.pem"
readonly KEY_ROUNDTRIP="$TEMP_DIR/key-roundtrip.p12"

decode_base64_to_file "$ANDROID_KEYSTORE_BASE64" "$DECODED_KEYSTORE"
decode_base64_to_file "$OTA_PRIVATE_KEY_BASE64" "$DECODED_PRIVATE_KEY"
cmp -s "$KEYSTORE" "$DECODED_KEYSTORE" || fail "il keystore e la sua copia base64 non coincidono"
cmp -s "$PRIVATE_KEY" "$DECODED_PRIVATE_KEY" || fail "la chiave OTA e la sua copia base64 non coincidono"

printf '%s' "$ANDROID_STORE_PASSWORD" >"$STORE_PASSWORD_FILE"
printf '%s' "$ANDROID_KEY_PASSWORD" >"$KEY_PASSWORD_FILE"
chmod 600 "$STORE_PASSWORD_FILE" "$KEY_PASSWORD_FILE"
"$KEYTOOL_BIN" -list \
  -keystore "$DECODED_KEYSTORE" \
  -storepass:file "$STORE_PASSWORD_FILE" \
  -alias "$ANDROID_KEY_ALIAS" >/dev/null 2>&1 || fail "keystore, alias o password non validi"
"$KEYTOOL_BIN" -importkeystore -noprompt \
  -srckeystore "$DECODED_KEYSTORE" \
  -srcstoretype JKS \
  -srcstorepass:file "$STORE_PASSWORD_FILE" \
  -srcalias "$ANDROID_KEY_ALIAS" \
  -srckeypass:file "$KEY_PASSWORD_FILE" \
  -destkeystore "$KEY_ROUNDTRIP" \
  -deststoretype PKCS12 \
  -deststorepass:file "$STORE_PASSWORD_FILE" \
  -destkeypass:file "$STORE_PASSWORD_FILE" >/dev/null 2>&1 || fail "password della chiave Android non valida"
"$KEYTOOL_BIN" -exportcert -rfc \
  -keystore "$DECODED_KEYSTORE" \
  -storepass:file "$STORE_PASSWORD_FILE" \
  -alias "$ANDROID_KEY_ALIAS" >"$SIGNER_CERT" 2>/dev/null

ACTUAL_SIGNER_SHA256="$(
  openssl x509 -in "$SIGNER_CERT" -outform DER 2>/dev/null |
    openssl dgst -sha256 -hex 2>/dev/null |
    awk '{print tolower($NF)}'
)"
[[ "$ACTUAL_SIGNER_SHA256" == "$EXPECTED_SIGNER_SHA256" ]] || fail "fingerprint Android non corrispondente"

DERIVED_PUBLIC_KEY_BASE64="$(
  openssl pkey -in "$DECODED_PRIVATE_KEY" -pubout -outform DER 2>/dev/null |
    tail -c 32 |
    base64 |
    tr -d '\r\n'
)"
[[ "$DERIVED_PUBLIC_KEY_BASE64" == "$OTA_PUBLIC_KEY_BASE64" ]] || fail "chiave pubblica OTA non corrispondente"
[[ "$(printf '%s' "$OTA_PUBLIC_KEY_BASE64" | openssl base64 -d -A | wc -c | tr -d '[:space:]')" == "32" ]] ||
  fail "chiave pubblica OTA non valida"

printf 'kal-tracker-ota-validation\n' >"$TEMP_DIR/message"
openssl pkeyutl -sign -rawin \
  -inkey "$DECODED_PRIVATE_KEY" \
  -in "$TEMP_DIR/message" \
  -out "$TEMP_DIR/signature" 2>/dev/null
openssl pkeyutl -verify -rawin -pubin \
  -inkey "$PUBLIC_KEY" \
  -in "$TEMP_DIR/message" \
  -sigfile "$TEMP_DIR/signature" >/dev/null 2>&1 || fail "verifica firma OTA fallita"

ANDROID_KEYSTORE_BASE64=""
ANDROID_STORE_PASSWORD=""
ANDROID_KEY_PASSWORD=""
OTA_PRIVATE_KEY_BASE64=""

printf 'Bundle OTA valido: permessi, keystore, fingerprint e firma Ed25519 verificati.\n'
printf 'Nessun valore sensibile e stato stampato e nessuna richiesta GitHub e stata eseguita.\n'
