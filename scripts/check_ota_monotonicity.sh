#!/usr/bin/env bash

set +x
set -Eeuo pipefail
umask 077

readonly MAX_ANDROID_BUILD_NUMBER=2100000000
readonly MAX_MANIFEST_BYTES=1048576
readonly MAX_APK_BYTES=314572800

CANDIDATE_VERSION=""
CANDIDATE_BUILD=""
PUBLIC_KEY_BASE64=""
EXPECTED_KEY_ID=""
SOURCE_REPO="marx87/kal-tracker"
RELEASES_REPO="marx87/kal-tracker-releases"
LATEST_MANIFEST=""
LATEST_TAG=""
FIRST_RELEASE=0
TEMP_DIR=""

usage() {
  cat <<'EOF'
Uso:
  check_ota_monotonicity.sh \
    --candidate-version 0.2.0 --candidate-build 2 \
    --public-key-base64 CHIAVE_PUBBLICA --expected-key-id ota-2026-01 \
    --latest-manifest /percorso/kal-tracker-update.json \
    --latest-tag v0.1.0-b1

Per il primo rilascio, usare --first-release al posto di --latest-manifest/--latest-tag.
Il chiamante deve usare --first-release soltanto dopo avere verificato che l'API
GitHub /releases/latest abbia restituito 404 per il repository release.

Lo script non usa la chiave privata e non contatta GitHub. Verifica la firma
Ed25519 della release corrente prima di confrontare SemVer e VersionCode.
EOF
}

fail() {
  printf 'Errore monotonicita OTA: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  local exit_code=$?
  if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
    rm -f -- \
      "$TEMP_DIR/public-key.raw" \
      "$TEMP_DIR/public-key.der" \
      "$TEMP_DIR/public-key.pem" \
      "$TEMP_DIR/payload.json" \
      "$TEMP_DIR/signature.bin"
    rmdir -- "$TEMP_DIR" 2>/dev/null || true
  fi
  PUBLIC_KEY_BASE64=""
  exit "$exit_code"
}
trap cleanup EXIT

file_size() {
  wc -c <"$1" | tr -d '[:space:]'
}

validate_semver() {
  local value="$1"
  local major minor patch
  [[ "$value" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || return 1
  IFS=. read -r major minor patch <<<"$value"
  ((10#$major <= 2147483647)) || return 1
  ((10#$minor <= 2147483647)) || return 1
  ((10#$patch <= 2147483647)) || return 1
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

decode_standard_base64() {
  local value="$1"
  local destination="$2"
  [[ "$value" =~ ^[A-Za-z0-9+/]+={0,2}$ ]] || fail "base64 standard non valida"
  (( ${#value} % 4 == 0 )) || fail "lunghezza base64 standard non valida"
  printf '%s' "$value" | openssl base64 -d -A >"$destination" 2>/dev/null ||
    fail "base64 standard non decodificabile"
}

decode_base64url() {
  local value="$1"
  local destination="$2"
  local normalized padding_length
  [[ -n "$value" && "$value" =~ ^[A-Za-z0-9_-]+$ ]] || fail "base64url non valida"
  normalized="$(printf '%s' "$value" | tr '_-' '/+')"
  padding_length=$(( (4 - ${#normalized} % 4) % 4 ))
  case "$padding_length" in
    0) ;;
    1) normalized="${normalized}=" ;;
    2) normalized="${normalized}==" ;;
    *) fail "lunghezza base64url non valida" ;;
  esac
  printf '%s' "$normalized" | openssl base64 -d -A >"$destination" 2>/dev/null ||
    fail "base64url non decodificabile"
}

while (($# > 0)); do
  case "$1" in
    --candidate-version)
      (($# >= 2)) || fail "manca il valore di --candidate-version"
      CANDIDATE_VERSION="$2"
      shift 2
      ;;
    --candidate-build)
      (($# >= 2)) || fail "manca il valore di --candidate-build"
      CANDIDATE_BUILD="$2"
      shift 2
      ;;
    --public-key-base64)
      (($# >= 2)) || fail "manca il valore di --public-key-base64"
      PUBLIC_KEY_BASE64="$2"
      shift 2
      ;;
    --expected-key-id)
      (($# >= 2)) || fail "manca il valore di --expected-key-id"
      EXPECTED_KEY_ID="$2"
      shift 2
      ;;
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
    --latest-manifest)
      (($# >= 2)) || fail "manca il valore di --latest-manifest"
      LATEST_MANIFEST="$2"
      shift 2
      ;;
    --latest-tag)
      (($# >= 2)) || fail "manca il valore di --latest-tag"
      LATEST_TAG="$2"
      shift 2
      ;;
    --first-release)
      FIRST_RELEASE=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) fail "opzione sconosciuta: $1" ;;
  esac
done

validate_semver "$CANDIDATE_VERSION" || fail "versione candidata non valida"
[[ "$CANDIDATE_BUILD" =~ ^[1-9][0-9]*$ ]] || fail "build candidata non valida"
(( ${#CANDIDATE_BUILD} <= 10 )) || fail "build candidata troppo lunga"
((10#$CANDIDATE_BUILD <= MAX_ANDROID_BUILD_NUMBER)) || fail "build candidata oltre il limite Android"
[[ "$EXPECTED_KEY_ID" =~ ^[A-Za-z0-9._-]+$ ]] || fail "key ID non valido"
[[ "$SOURCE_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail "source repo non valido"
[[ "$RELEASES_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail "releases repo non valido"
[[ -n "$PUBLIC_KEY_BASE64" ]] || fail "chiave pubblica OTA mancante"

if ((FIRST_RELEASE == 1)); then
  [[ -z "$LATEST_MANIFEST" && -z "$LATEST_TAG" ]] ||
    fail "--first-release non e compatibile con una release esistente"
else
  [[ -n "$LATEST_MANIFEST" && -n "$LATEST_TAG" ]] ||
    fail "servono insieme --latest-manifest e --latest-tag"
  [[ -f "$LATEST_MANIFEST" && ! -L "$LATEST_MANIFEST" ]] ||
    fail "manifest latest mancante, non regolare o symlink"
  [[ "$(file_size "$LATEST_MANIFEST")" -le "$MAX_MANIFEST_BYTES" ]] ||
    fail "manifest latest oltre 1 MiB"
  [[ "$LATEST_TAG" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)-b[1-9][0-9]*$ ]] ||
    fail "tag latest non valido"
fi

command -v openssl >/dev/null 2>&1 || fail "openssl non disponibile"
command -v jq >/dev/null 2>&1 || fail "jq non disponibile"
command -v mktemp >/dev/null 2>&1 || fail "mktemp non disponibile"

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kal-ota-monotonicity.XXXXXX")"
chmod 700 "$TEMP_DIR"
decode_standard_base64 "$PUBLIC_KEY_BASE64" "$TEMP_DIR/public-key.raw"
[[ "$(file_size "$TEMP_DIR/public-key.raw")" == "32" ]] || fail "chiave pubblica OTA diversa da 32 byte"

# SubjectPublicKeyInfo DER per Ed25519 (OID 1.3.101.112), seguito dai 32 byte raw.
printf '\060\052\060\005\006\003\053\145\160\003\041\000' >"$TEMP_DIR/public-key.der"
cat "$TEMP_DIR/public-key.raw" >>"$TEMP_DIR/public-key.der"
openssl pkey -pubin -inform DER \
  -in "$TEMP_DIR/public-key.der" -out "$TEMP_DIR/public-key.pem" 2>/dev/null ||
  fail "chiave pubblica Ed25519 non valida"
chmod 600 "$TEMP_DIR"/*

if ((FIRST_RELEASE == 1)); then
  printf 'OK monotonicita OTA: nessuna release pubblicata, candidata iniziale %s build %s.\n' \
    "$CANDIDATE_VERSION" "$CANDIDATE_BUILD"
  exit 0
fi

jq -e 'type == "object" and .schema == 1 and
       (.keyId | type == "string") and
       (.payload | type == "string") and
       (.signature | type == "string")' \
  "$LATEST_MANIFEST" >/dev/null || fail "envelope latest non valido"
[[ "$(jq -r '.keyId' "$LATEST_MANIFEST")" == "$EXPECTED_KEY_ID" ]] || fail "key ID latest inatteso"

decode_base64url "$(jq -r '.payload' "$LATEST_MANIFEST")" "$TEMP_DIR/payload.json"
decode_base64url "$(jq -r '.signature' "$LATEST_MANIFEST")" "$TEMP_DIR/signature.bin"
[[ "$(file_size "$TEMP_DIR/signature.bin")" == "64" ]] || fail "firma latest diversa da 64 byte"
[[ "$(file_size "$TEMP_DIR/payload.json")" -le "$MAX_MANIFEST_BYTES" ]] || fail "payload latest oltre 1 MiB"

openssl pkeyutl -verify -rawin -pubin \
  -inkey "$TEMP_DIR/public-key.pem" \
  -in "$TEMP_DIR/payload.json" \
  -sigfile "$TEMP_DIR/signature.bin" >/dev/null 2>&1 || fail "firma Ed25519 della latest non valida"

jq -e 'type == "object" and
       .applicationId == "it.marcomartelli.kaltracker" and
       .platform == "android" and
       .channel == "personal" and
       (.version | type == "string") and
       (.buildNumber | type == "number" and . == floor and . > 0) and
       (.minimumSupportedBuild | type == "number" and . == floor and . > 0) and
       .minimumSupportedBuild <= .buildNumber and
       (.tag | type == "string") and
       (.assetUrl | type == "string") and
       (.sha256 | type == "string") and
       (.sizeBytes | type == "number" and . == floor and . > 0) and
       (.notes | type == "string" and length > 0) and
       (.publishedAt | type == "string") and
       (.sourceRepository | type == "string") and
       (.sourceCommit | type == "string")' \
  "$TEMP_DIR/payload.json" >/dev/null || fail "payload latest incompleto o non valido"

EXISTING_VERSION="$(jq -r '.version' "$TEMP_DIR/payload.json")"
EXISTING_BUILD="$(jq -r '.buildNumber' "$TEMP_DIR/payload.json")"
EXISTING_TAG="$(jq -r '.tag' "$TEMP_DIR/payload.json")"
EXISTING_ASSET_URL="$(jq -r '.assetUrl' "$TEMP_DIR/payload.json")"
EXISTING_SHA256="$(jq -r '.sha256' "$TEMP_DIR/payload.json")"
EXISTING_SIZE="$(jq -r '.sizeBytes' "$TEMP_DIR/payload.json")"
EXISTING_PUBLISHED_AT="$(jq -r '.publishedAt' "$TEMP_DIR/payload.json")"
EXISTING_SOURCE_REPO="$(jq -r '.sourceRepository' "$TEMP_DIR/payload.json")"
EXISTING_SOURCE_COMMIT="$(jq -r '.sourceCommit' "$TEMP_DIR/payload.json")"

validate_semver "$EXISTING_VERSION" || fail "SemVer latest non valida"
[[ "$EXISTING_BUILD" =~ ^[1-9][0-9]*$ ]] || fail "build latest non valida"
(( ${#EXISTING_BUILD} <= 10 )) || fail "build latest troppo lunga"
((10#$EXISTING_BUILD <= MAX_ANDROID_BUILD_NUMBER)) || fail "build latest oltre il limite Android"
[[ "$EXISTING_TAG" == "v${EXISTING_VERSION}-b${EXISTING_BUILD}" ]] || fail "tag nel payload latest non coerente"
[[ "$EXISTING_TAG" == "$LATEST_TAG" ]] || fail "tag della Release e del manifest non coincidono"
EXPECTED_ASSET_URL="https://github.com/${RELEASES_REPO}/releases/download/${EXISTING_TAG}/kal-tracker-${EXISTING_TAG}.apk"
[[ "$EXISTING_ASSET_URL" == "$EXPECTED_ASSET_URL" ]] || fail "URL APK latest non autorizzato"
[[ "$EXISTING_SHA256" =~ ^[0-9a-f]{64}$ ]] || fail "SHA-256 latest non canonico"
[[ "$EXISTING_SIZE" =~ ^[1-9][0-9]*$ ]] || fail "dimensione APK latest non valida"
(( ${#EXISTING_SIZE} <= 10 )) || fail "dimensione APK latest troppo lunga"
((10#$EXISTING_SIZE <= MAX_APK_BYTES)) || fail "dimensione APK latest oltre 300 MiB"
[[ "$EXISTING_PUBLISHED_AT" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] ||
  fail "data latest non canonica"
[[ "$EXISTING_SOURCE_REPO" == "$SOURCE_REPO" ]] || fail "repository sorgente latest inatteso"
[[ "$EXISTING_SOURCE_COMMIT" =~ ^[0-9a-f]{40}$ ]] || fail "commit sorgente latest non valido"

((10#$CANDIDATE_BUILD > 10#$EXISTING_BUILD)) ||
  fail "build candidata non strettamente maggiore della latest firmata"
semver_is_lower_than "$CANDIDATE_VERSION" "$EXISTING_VERSION" &&
  fail "versione candidata precedente alla latest firmata"

printf 'OK monotonicita OTA: latest firmata %s build %s; candidata %s build %s.\n' \
  "$EXISTING_VERSION" "$EXISTING_BUILD" "$CANDIDATE_VERSION" "$CANDIDATE_BUILD"
