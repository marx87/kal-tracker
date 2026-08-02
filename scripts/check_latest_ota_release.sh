#!/usr/bin/env bash

set +x
set -Eeuo pipefail
umask 077

CANDIDATE_VERSION=""
CANDIDATE_BUILD=""
PUBLIC_KEY_BASE64=""
EXPECTED_KEY_ID=""
SOURCE_REPO="marx87/kal-tracker"
RELEASES_REPO="marx87/kal-tracker-releases"
CHECKER=""
TEMP_DIR=""

usage() {
  cat <<'EOF'
Uso: check_latest_ota_release.sh \
  --candidate-version 0.2.0 --candidate-build 2 \
  --public-key-base64 CHIAVE_PUBBLICA --expected-key-id ota-2026-01 \
  [--checker /percorso/check_ota_monotonicity.sh]

Legge soltanto la release pubblica latest tramite HTTPS. Un 404 e accettato come
prima release solo quando proviene dall'endpoint API /releases/latest; se una
release esiste, il manifest deve essere presente, coerente e firmato.
EOF
}

fail() {
  printf 'Errore latest OTA: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  local exit_code=$?
  if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
    rm -f -- "$TEMP_DIR/latest-release.json" "$TEMP_DIR/kal-tracker-update.json"
    rmdir -- "$TEMP_DIR" 2>/dev/null || true
  fi
  PUBLIC_KEY_BASE64=""
  exit "$exit_code"
}
trap cleanup EXIT

file_size() {
  wc -c <"$1" | tr -d '[:space:]'
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
    --checker)
      (($# >= 2)) || fail "manca il valore di --checker"
      CHECKER="$2"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) fail "opzione sconosciuta: $1" ;;
  esac
done

[[ -n "$CANDIDATE_VERSION" && -n "$CANDIDATE_BUILD" ]] || fail "versione e build candidate sono obbligatorie"
[[ -n "$PUBLIC_KEY_BASE64" && -n "$EXPECTED_KEY_ID" ]] || fail "chiave pubblica e key ID sono obbligatori"
[[ "$SOURCE_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail "source repo non valido"
[[ "$RELEASES_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail "releases repo non valido"

if [[ -z "$CHECKER" ]]; then
  CHECKER="$(cd "$(dirname "$0")" && pwd -P)/check_ota_monotonicity.sh"
fi
[[ -f "$CHECKER" && -x "$CHECKER" && ! -L "$CHECKER" ]] || fail "checker monotonicita non disponibile"
command -v curl >/dev/null 2>&1 || fail "curl non disponibile"
command -v jq >/dev/null 2>&1 || fail "jq non disponibile"
command -v mktemp >/dev/null 2>&1 || fail "mktemp non disponibile"

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kal-latest-ota.XXXXXX")"
chmod 700 "$TEMP_DIR"
readonly RELEASE_JSON="$TEMP_DIR/latest-release.json"
readonly MANIFEST="$TEMP_DIR/kal-tracker-update.json"
readonly API_URL="https://api.github.com/repos/${RELEASES_REPO}/releases/latest"

HTTP_STATUS="$(
  curl --disable --silent --show-error --location \
    --proto '=https' --proto-redir '=https' \
    --connect-timeout 10 --max-time 30 --max-filesize 1048576 \
    --retry 3 --retry-all-errors \
    --header 'Accept: application/vnd.github+json' \
    --header 'X-GitHub-Api-Version: 2022-11-28' \
    --output "$RELEASE_JSON" --write-out '%{http_code}' \
    "$API_URL"
)" || fail "lettura API GitHub latest fallita"
chmod 600 "$RELEASE_JSON"

case "$HTTP_STATUS" in
  404)
    jq -e '.message == "Not Found"' "$RELEASE_JSON" >/dev/null ||
      fail "risposta 404 GitHub inattesa"
    "$CHECKER" \
      --candidate-version "$CANDIDATE_VERSION" \
      --candidate-build "$CANDIDATE_BUILD" \
      --public-key-base64 "$PUBLIC_KEY_BASE64" \
      --expected-key-id "$EXPECTED_KEY_ID" \
      --source-repo "$SOURCE_REPO" \
      --releases-repo "$RELEASES_REPO" \
      --first-release
    ;;
  200)
    jq -e 'type == "object" and .draft == false and .prerelease == false and
           (.tag_name | type == "string") and (.assets | type == "array")' \
      "$RELEASE_JSON" >/dev/null || fail "metadata GitHub latest non validi"
    LATEST_TAG="$(jq -r '.tag_name' "$RELEASE_JSON")"
    [[ "$LATEST_TAG" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)-b[1-9][0-9]*$ ]] ||
      fail "tag GitHub latest non valido"
    ASSET_COUNT="$(jq -r '[.assets[] | select(.name == "kal-tracker-update.json")] | length' "$RELEASE_JSON")"
    [[ "$ASSET_COUNT" == "1" ]] || fail "la latest deve avere un solo manifest OTA"
    MANIFEST_URL="$(
      jq -r '.assets[] | select(.name == "kal-tracker-update.json") | .browser_download_url' \
        "$RELEASE_JSON"
    )"
    EXPECTED_MANIFEST_URL="https://github.com/${RELEASES_REPO}/releases/download/${LATEST_TAG}/kal-tracker-update.json"
    [[ "$MANIFEST_URL" == "$EXPECTED_MANIFEST_URL" ]] || fail "URL manifest latest inatteso"

    curl --disable --fail --silent --show-error --location \
      --proto '=https' --proto-redir '=https' \
      --connect-timeout 10 --max-time 60 --max-filesize 1048576 \
      --retry 3 --retry-all-errors \
      --output "$MANIFEST" "$MANIFEST_URL" || fail "download manifest latest fallito"
    chmod 600 "$MANIFEST"
    [[ "$(file_size "$MANIFEST")" -le 1048576 ]] || fail "manifest latest oltre 1 MiB"

    "$CHECKER" \
      --candidate-version "$CANDIDATE_VERSION" \
      --candidate-build "$CANDIDATE_BUILD" \
      --public-key-base64 "$PUBLIC_KEY_BASE64" \
      --expected-key-id "$EXPECTED_KEY_ID" \
      --source-repo "$SOURCE_REPO" \
      --releases-repo "$RELEASES_REPO" \
      --latest-manifest "$MANIFEST" \
      --latest-tag "$LATEST_TAG"
    ;;
  *) fail "API GitHub latest ha restituito HTTP $HTTP_STATUS" ;;
esac

printf 'Controllo read-only della release latest completato.\n'
