#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

readonly REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
readonly TEST_PARENT="$(dirname "$REPO_ROOT")"
TEST_ROOT="$(mktemp -d "$TEST_PARENT/.kal-release-tooling-test.XXXXXX")"

cleanup() {
  local exit_code=$?
  case "$TEST_ROOT" in
    "$TEST_PARENT"/.kal-release-tooling-test.*) rm -rf -- "$TEST_ROOT" ;;
    *) printf 'Rifiuto cleanup di un percorso inatteso.\n' >&2 ;;
  esac
  exit "$exit_code"
}
trap cleanup EXIT

fail() {
  printf 'TEST FALLITO: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local file="$1"
  local pattern="$2"
  grep -q -- "$pattern" "$file" || fail "pattern mancante: $pattern"
}

assert_not_contains() {
  local file="$1"
  local pattern="$2"
  if grep -q -- "$pattern" "$file"; then
    fail "valore inatteso nell output: $pattern"
  fi
}

mkdir "$TEST_ROOT/bin" "$TEST_ROOT/tmp" "$TEST_ROOT/current-gh"
chmod 700 "$TEST_ROOT/bin" "$TEST_ROOT/tmp" "$TEST_ROOT/current-gh"
export TMPDIR="$TEST_ROOT/tmp"

cat >"$TEST_ROOT/bin/keytool" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 700 "$TEST_ROOT/bin/keytool"

# La modalita dry-run valida tutto ma non crea il target e non genera chiavi.
"$REPO_ROOT/scripts/bootstrap_android_ota.sh" \
  --output-dir "$TEST_ROOT/would-be-created" \
  --keytool "$TEST_ROOT/bin/keytool" \
  --dry-run >"$TEST_ROOT/bootstrap.out"
[[ ! -e "$TEST_ROOT/would-be-created" ]] || fail "dry-run ha creato la directory output"
assert_contains "$TEST_ROOT/bootstrap.out" "Nessun file creato"

# Anche in dry-run una directory interna al repository deve essere rifiutata.
if "$REPO_ROOT/scripts/bootstrap_android_ota.sh" \
  --output-dir "$REPO_ROOT/never-create-ota-test" \
  --keytool "$TEST_ROOT/bin/keytool" \
  --dry-run >"$TEST_ROOT/inside-repo.out" 2>&1; then
  fail "accettata una directory interna al repository"
fi
[[ ! -e "$REPO_ROOT/never-create-ota-test" ]] || fail "creato un output interno al repository"
assert_contains "$TEST_ROOT/inside-repo.out" "esterna al repository"

# Fixture pubblica firmata con il vettore di test Ed25519 RFC 8032. Nessuna
# chiave privata reale o generata viene usata dal test.
readonly FIXTURE_PUBLIC_KEY="11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo="
readonly FIXTURE_PAYLOAD="eyJhcHBsaWNhdGlvbklkIjoiaXQubWFyY29tYXJ0ZWxsaS5rYWx0cmFja2VyIiwicGxhdGZvcm0iOiJhbmRyb2lkIiwiY2hhbm5lbCI6InBlcnNvbmFsIiwidmVyc2lvbiI6IjAuMS4wIiwiYnVpbGROdW1iZXIiOjEsIm1pbmltdW1TdXBwb3J0ZWRCdWlsZCI6MSwidGFnIjoidjAuMS4wLWIxIiwiYXNzZXRVcmwiOiJodHRwczovL2dpdGh1Yi5jb20vbWFyeDg3L2thbC10cmFja2VyLXJlbGVhc2VzL3JlbGVhc2VzL2Rvd25sb2FkL3YwLjEuMC1iMS9rYWwtdHJhY2tlci12MC4xLjAtYjEuYXBrIiwic2hhMjU2IjoiYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYSIsInNpemVCeXRlcyI6MTIzNDU2LCJub3RlcyI6IlRlc3QgZml4dHVyZSBwdWJibGljbyIsInB1Ymxpc2hlZEF0IjoiMjAyNi0wOC0wMlQxMjowMDowMFoiLCJzb3VyY2VSZXBvc2l0b3J5IjoibWFyeDg3L2thbC10cmFja2VyIiwic291cmNlQ29tbWl0IjoiMjFlNzI4YmE0YmIxM2Y2MzMxYTdlNzYwZGQ5NzlkYjM1OGE4ZDAwOSJ9"
readonly FIXTURE_SIGNATURE="N5rpS0zB6PhuYbfi-teL-BAR1K9bUaYuICoesABZAmmPkReoucc7bU20B3SFkNFlm19BWhbl_dHzCPhpsD7HAA"
printf '{"schema":1,"keyId":"ota-2026-01","payload":"%s","signature":"%s"}\n' \
  "$FIXTURE_PAYLOAD" "$FIXTURE_SIGNATURE" >"$TEST_ROOT/latest-valid.json"

"$REPO_ROOT/scripts/check_ota_monotonicity.sh" \
  --candidate-version 0.2.0 \
  --candidate-build 2 \
  --public-key-base64 "$FIXTURE_PUBLIC_KEY" \
  --expected-key-id ota-2026-01 \
  --latest-manifest "$TEST_ROOT/latest-valid.json" \
  --latest-tag v0.1.0-b1 >"$TEST_ROOT/monotonic.out"
assert_contains "$TEST_ROOT/monotonic.out" "latest firmata 0.1.0 build 1"

if "$REPO_ROOT/scripts/check_ota_monotonicity.sh" \
  --candidate-version 0.2.0 \
  --candidate-build 1 \
  --public-key-base64 "$FIXTURE_PUBLIC_KEY" \
  --expected-key-id ota-2026-01 \
  --latest-manifest "$TEST_ROOT/latest-valid.json" \
  --latest-tag v0.1.0-b1 >"$TEST_ROOT/rollback-build.out" 2>&1; then
  fail "accettato un build number non crescente"
fi
assert_contains "$TEST_ROOT/rollback-build.out" "non strettamente maggiore"

if "$REPO_ROOT/scripts/check_ota_monotonicity.sh" \
  --candidate-version 0.0.9 \
  --candidate-build 2 \
  --public-key-base64 "$FIXTURE_PUBLIC_KEY" \
  --expected-key-id ota-2026-01 \
  --latest-manifest "$TEST_ROOT/latest-valid.json" \
  --latest-tag v0.1.0-b1 >"$TEST_ROOT/rollback-version.out" 2>&1; then
  fail "accettata una regressione SemVer"
fi
assert_contains "$TEST_ROOT/rollback-version.out" "precedente alla latest firmata"

jq '.signature = ("A" + (.signature[1:]))' \
  "$TEST_ROOT/latest-valid.json" >"$TEST_ROOT/latest-tampered.json"
if "$REPO_ROOT/scripts/check_ota_monotonicity.sh" \
  --candidate-version 0.2.0 \
  --candidate-build 2 \
  --public-key-base64 "$FIXTURE_PUBLIC_KEY" \
  --expected-key-id ota-2026-01 \
  --latest-manifest "$TEST_ROOT/latest-tampered.json" \
  --latest-tag v0.1.0-b1 >"$TEST_ROOT/tampered.out" 2>&1; then
  fail "accettata una latest con firma manomessa"
fi
assert_contains "$TEST_ROOT/tampered.out" "firma Ed25519 della latest non valida"

"$REPO_ROOT/scripts/check_ota_monotonicity.sh" \
  --candidate-version 0.1.0 \
  --candidate-build 1 \
  --public-key-base64 "$FIXTURE_PUBLIC_KEY" \
  --expected-key-id ota-2026-01 \
  --first-release >"$TEST_ROOT/first-release.out"
assert_contains "$TEST_ROOT/first-release.out" "candidata iniziale 0.1.0 build 1"
if find "$TEST_ROOT/tmp" -maxdepth 1 -name 'kal-ota-monotonicity.*' -print -quit | grep -q .; then
  fail "il controllo monotonicita ha lasciato file temporanei"
fi

# Il wrapper remoto usa solo endpoint pubblici HTTPS e distingue una vera prima
# release da una release latest priva/manomessa del manifest.
cat >"$TEST_ROOT/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

output=""
write_out=0
url=""
while (($# > 0)); do
  case "$1" in
    --output)
      output="$2"
      shift 2
      ;;
    --write-out)
      write_out=1
      shift 2
      ;;
    --proto | --proto-redir | --connect-timeout | --max-time | --max-filesize | --retry | --header)
      shift 2
      ;;
    --disable | --silent | --show-error | --location | --fail | --retry-all-errors)
      shift
      ;;
    https://*)
      url="$1"
      shift
      ;;
    *) exit 98 ;;
  esac
done
[[ -n "$output" && -n "$url" ]] || exit 97
printf '%s\n' "$url" >>"$FAKE_CURL_LOG"

case "$url" in
  https://api.github.com/repos/marx87/kal-tracker-releases/releases/latest)
    if [[ "$FAKE_LATEST_MODE" == "404" ]]; then
      printf '%s\n' '{"message":"Not Found"}' >"$output"
      ((write_out == 1)) && printf '404'
    else
      printf '%s\n' \
        '{"draft":false,"prerelease":false,"tag_name":"v0.1.0-b1","assets":[{"name":"kal-tracker-update.json","browser_download_url":"https://github.com/marx87/kal-tracker-releases/releases/download/v0.1.0-b1/kal-tracker-update.json"}]}' \
        >"$output"
      ((write_out == 1)) && printf '200'
    fi
    ;;
  https://github.com/marx87/kal-tracker-releases/releases/download/v0.1.0-b1/kal-tracker-update.json)
    cp "$FAKE_MANIFEST" "$output"
    ;;
  *) exit 96 ;;
esac
EOF
chmod 700 "$TEST_ROOT/bin/curl"

FAKE_CURL_LOG="$TEST_ROOT/latest-200.log" \
  FAKE_LATEST_MODE=200 \
  FAKE_MANIFEST="$TEST_ROOT/latest-valid.json" \
  PATH="$TEST_ROOT/bin:$PATH" \
  "$REPO_ROOT/scripts/check_latest_ota_release.sh" \
  --candidate-version 0.2.0 \
  --candidate-build 2 \
  --public-key-base64 "$FIXTURE_PUBLIC_KEY" \
  --expected-key-id ota-2026-01 >"$TEST_ROOT/latest-200.out"
assert_contains "$TEST_ROOT/latest-200.out" "Controllo read-only"
[[ "$(wc -l <"$TEST_ROOT/latest-200.log" | tr -d '[:space:]')" == "2" ]] ||
  fail "numero download latest inatteso"

FAKE_CURL_LOG="$TEST_ROOT/latest-404.log" \
  FAKE_LATEST_MODE=404 \
  FAKE_MANIFEST="$TEST_ROOT/latest-valid.json" \
  PATH="$TEST_ROOT/bin:$PATH" \
  "$REPO_ROOT/scripts/check_latest_ota_release.sh" \
  --candidate-version 0.1.0 \
  --candidate-build 1 \
  --public-key-base64 "$FIXTURE_PUBLIC_KEY" \
  --expected-key-id ota-2026-01 >"$TEST_ROOT/latest-404.out"
assert_contains "$TEST_ROOT/latest-404.out" "candidata iniziale"
[[ "$(wc -l <"$TEST_ROOT/latest-404.log" | tr -d '[:space:]')" == "1" ]] ||
  fail "il caso prima release ha eseguito download inattesi"
if find "$TEST_ROOT/tmp" -maxdepth 1 -name 'kal-latest-ota.*' -print -quit | grep -q .; then
  fail "il controllo latest ha lasciato file temporanei"
fi

# Il preflight deve rifiutare il login gh corrente quando manca il token esplicito.
cat >"$TEST_ROOT/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf 'CALLED\n' >>"$FAKE_GH_LOG"
exit 99
EOF
chmod 700 "$TEST_ROOT/bin/gh"
printf 'oauth_token: current-login-token-must-not-be-used\n' >"$TEST_ROOT/current-gh/hosts.yml"
FAKE_GH_LOG="$TEST_ROOT/missing-token-gh.log" \
  GH_CONFIG_DIR="$TEST_ROOT/current-gh" \
  GH_TOKEN="current-login-token-must-not-be-used" \
  PATH="$TEST_ROOT/bin:$PATH" \
  "$REPO_ROOT/scripts/release_preflight.sh" \
  --version 0.1.0 \
  --build-number 1 \
  --expected-source-commit 21e728b >"$TEST_ROOT/missing-token.out" 2>&1 &&
  fail "preflight eseguito senza KAL_PREFLIGHT_GH_TOKEN"
[[ ! -e "$TEST_ROOT/missing-token-gh.log" ]] || fail "gh invocato usando il login corrente"

# Fake GitHub in sola lettura: include sentinelle valide che non devono apparire in output.
cat >"$TEST_ROOT/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

[[ "${GH_TOKEN:-}" == "explicit-preflight-token" ]] || exit 90
[[ "${GH_CONFIG_DIR:-}" == "$FAKE_EXPECTED_CONFIG_PREFIX"/* ]] || exit 91
[[ "${GH_HOST:-}" == "github.com" ]] || exit 96
[[ -z "${GH_DEBUG:-}" ]] || exit 97
[[ "$1" == "api" ]] || exit 92
shift

method=""
endpoint=""
while (($# > 0)); do
  case "$1" in
    --method)
      method="$2"
      shift 2
      ;;
    repos/*)
      endpoint="$1"
      shift
      ;;
    *) exit 93 ;;
  esac
done
[[ "$method" == "GET" && -n "$endpoint" ]] || exit 94
printf '%s %s\n' "$method" "$endpoint" >>"$FAKE_GH_LOG"

case "$endpoint" in
  repos/marx87/kal-tracker)
    printf '%s\n' '{"private":true,"visibility":"private","default_branch":"main"}'
    ;;
  repos/marx87/kal-tracker-releases)
    printf '%s\n' '{"private":false,"visibility":"public","default_branch":"main"}'
    ;;
  repos/marx87/kal-tracker/branches/main)
    printf '%s\n' '{"commit":{"sha":"21e728b000000000000000000000000000000000"}}'
    ;;
  repos/marx87/kal-tracker/commits/21e728b)
    printf '%s\n' '{"sha":"21e728b000000000000000000000000000000000"}'
    ;;
  repos/marx87/kal-tracker/compare/21e728b000000000000000000000000000000000...main)
    printf '%s\n' '{"status":"identical","merge_base_commit":{"sha":"21e728b000000000000000000000000000000000"}}'
    ;;
  repos/marx87/kal-tracker/actions/workflows/android-release.yml)
    printf '%s\n' '{"state":"active"}'
    ;;
  repos/marx87/kal-tracker/environments/release)
    printf '%s\n' '{"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}'
    ;;
  'repos/marx87/kal-tracker/environments/release/deployment-branch-policies?per_page=100')
    printf '%s\n' '{"branch_policies":[{"name":"main","type":"branch"}]}'
    ;;
  'repos/marx87/kal-tracker/environments/release/secrets?per_page=100')
    printf '%s\n' '{"secrets":[{"name":"ANDROID_KEYSTORE_BASE64"},{"name":"ANDROID_KEY_ALIAS"},{"name":"ANDROID_STORE_PASSWORD"},{"name":"ANDROID_KEY_PASSWORD"},{"name":"OTA_ED25519_PRIVATE_KEY_BASE64"},{"name":"RELEASES_REPO_TOKEN"}]}'
    ;;
  'repos/marx87/kal-tracker/environments/release/variables?per_page=100')
    printf '%s\n' '{"variables":[{"name":"OTA_PUBLIC_KEY_BASE64","value":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="},{"name":"ANDROID_SIGNER_SHA256","value":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}'
    ;;
  'repos/marx87/kal-tracker-releases/releases?per_page=100')
    printf '%s\n' '[]'
    ;;
  *) exit 95 ;;
esac
EOF
chmod 700 "$TEST_ROOT/bin/gh"

FAKE_GH_LOG="$TEST_ROOT/gh-read-only.log" \
  FAKE_EXPECTED_CONFIG_PREFIX="$TEST_ROOT/tmp" \
  TMPDIR="$TEST_ROOT/tmp" \
  GH_CONFIG_DIR="$TEST_ROOT/current-gh" \
  GH_TOKEN="current-login-token-must-not-be-used" \
  GH_DEBUG="api" \
  KAL_PREFLIGHT_GH_TOKEN="explicit-preflight-token" \
  PATH="$TEST_ROOT/bin:$PATH" \
  "$REPO_ROOT/scripts/release_preflight.sh" \
  --version 0.1.0 \
  --build-number 1 \
  --expected-source-commit 21e728b >"$TEST_ROOT/preflight.out"

assert_contains "$TEST_ROOT/preflight.out" "Preflight remoto completato con sole richieste GET"
assert_not_contains "$TEST_ROOT/preflight.out" "explicit-preflight-token"
assert_not_contains "$TEST_ROOT/preflight.out" "current-login-token-must-not-be-used"
assert_not_contains "$TEST_ROOT/preflight.out" "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
assert_not_contains "$TEST_ROOT/preflight.out" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
[[ "$(wc -l <"$TEST_ROOT/gh-read-only.log" | tr -d '[:space:]')" == "11" ]] || fail "numero richieste GET inatteso"
if grep -Ev '^GET repos/' "$TEST_ROOT/gh-read-only.log" | grep -q .; then
  fail "rilevata una richiesta diversa da GET"
fi
if find "$TEST_ROOT/tmp" -maxdepth 1 -name 'kal-release-preflight.*' -print -quit | grep -q .; then
  fail "il preflight ha lasciato file temporanei"
fi

grep -q 'source_commit:' "$REPO_ROOT/.github/workflows/android-release.yml" ||
  fail "workflow privo dell input source_commit"
grep -q 'git merge-base --is-ancestor "$RELEASE_SOURCE_SHA" "$GITHUB_SHA"' \
  "$REPO_ROOT/.github/workflows/android-release.yml" ||
  fail "workflow privo del vincolo tra sorgente e main"
[[ "$(grep -c 'check_latest_ota_release.sh' "$REPO_ROOT/.github/workflows/android-release.yml")" -ge 3 ]] ||
  fail "workflow privo del doppio controllo della latest firmata"
grep -q 'git diff --exit-code -- lib/core/database/app_database.g.dart' \
  "$REPO_ROOT/.github/workflows/android-release.yml" ||
  fail "workflow non verifica gli output generati"
grep -q 'workflowCommit:$workflowCommit' "$REPO_ROOT/.github/workflows/android-release.yml" ||
  fail "provenienza firmata priva del commit workflow"
grep -q 'Remove all transient release material' "$REPO_ROOT/.github/workflows/android-release.yml" ||
  fail "workflow privo del cleanup finale"
if grep -Eq 'sha256sum|base64 -w' "$REPO_ROOT/.github/workflows/android-release.yml"; then
  fail "workflow usa comandi checksum/base64 non portabili"
fi

while IFS= read -r action_ref; do
  [[ "$action_ref" =~ @[0-9a-f]{40}$ ]] || fail "action non fissata a SHA: $action_ref"
done < <(sed -n 's/^[[:space:]]*uses:[[:space:]]*\([^[:space:]#]*\).*/\1/p' \
  "$REPO_ROOT/.github/workflows/android-release.yml")

[[ "$(grep -c '\${{ secrets.RELEASES_REPO_TOKEN }}' "$REPO_ROOT/.github/workflows/android-release.yml")" == "1" ]] ||
  fail "token repository release esposto in piu punti"
FIRST_SECRET_LINE="$(grep -n '\${{ secrets\.' "$REPO_ROOT/.github/workflows/android-release.yml" | head -1 | cut -d: -f1)"
TEST_LINE="$(grep -n 'flutter test' "$REPO_ROOT/.github/workflows/android-release.yml" | head -1 | cut -d: -f1)"
[[ -n "$FIRST_SECRET_LINE" && -n "$TEST_LINE" && "$FIRST_SECRET_LINE" -gt "$TEST_LINE" ]] ||
  fail "segreti caricati prima dei test del sorgente"

printf 'OK: test release tooling non distruttivi completati.\n'
