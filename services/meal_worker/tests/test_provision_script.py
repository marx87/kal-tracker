"""Guardie di sicurezza dello script di provisioning del worker.

Il difetto storico: con ``--owner-id`` (o email uguali a maiuscole diverse)
lo script risolveva l'email worker sull'account personale di Marco e ne
resettava la password PRIMA del controllo worker != proprietario. Qui si
verifica che il guard scatti prima di qualunque scrittura amministrativa.
"""

from __future__ import annotations

import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
SCRIPT = REPO_ROOT / "scripts" / "provision_meal_worker.sh"
PROTOCOL_DOC = REPO_ROOT / "docs" / "MEAL_WORKER_PROTOCOL.md"

OWNER_UUID = "11111111-2222-3333-4444-555555555555"

FAKE_CURL = """#!/bin/bash
set -eu
config="$(cat)"
url="$(printf '%s\\n' "$config" | sed -n 's/^url = "\\(.*\\)"$/\\1/p' | head -n 1)"
method="$(printf '%s\\n' "$config" | sed -n 's/^request = "\\(.*\\)"$/\\1/p' | head -n 1)"
printf '%s %s\\n' "$method" "$url" >> "$FAKE_CURL_LOG"
case "$url" in
  *"/auth/v1/admin/users?"*)
    printf '{"users":[{"id":"%s","email":"%s"}]}\\n200' \\
      "$FAKE_OWNER_UUID" "$FAKE_WORKER_EMAIL"
    ;;
  *"/auth/v1/admin/users/"*)
    printf '{"id":"%s"}\\n200' "$FAKE_OWNER_UUID"
    ;;
  *)
    printf '{}\\n200'
    ;;
esac
"""


class ProvisionScriptGuardTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        bin_dir = Path(self.tmp.name) / "bin"
        bin_dir.mkdir()
        fake_curl = bin_dir / "curl"
        fake_curl.write_text(FAKE_CURL, encoding="utf-8")
        fake_curl.chmod(fake_curl.stat().st_mode | stat.S_IXUSR)
        self.curl_log = Path(self.tmp.name) / "curl.log"
        self.env = {
            **os.environ,
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "KAL_PROVISION_PROJECT_REF": "abcdefghijklmnop",
            "KAL_PROVISION_SERVICE_ROLE_KEY": "sb_secret_finto_solo_test",
            "FAKE_CURL_LOG": str(self.curl_log),
            "FAKE_OWNER_UUID": OWNER_UUID,
            "FAKE_WORKER_EMAIL": "marco.mart87@example.com",
        }

    def _run(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(SCRIPT), *args],
            capture_output=True,
            text=True,
            env=self.env,
            timeout=60,
        )

    def test_guard_scatta_prima_del_reset_password(self) -> None:
        # Typo reale: l'email "worker" è quella del proprietario, passato
        # per UUID. Lo script deve fermarsi PRIMA della PUT admin che
        # distruggerebbe la password personale di Marco.
        result = self._run(
            "--owner-id",
            OWNER_UUID,
            "--worker-email",
            "marco.mart87@example.com",
            "--keychain-service",
            "com.kaltracker.test-inesistente",
            "--create",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("worker e proprietario coincidono", result.stderr)
        log = self.curl_log.read_text(encoding="utf-8")
        self.assertNotIn("PUT ", log)
        self.assertNotIn("POST ", log)

    def test_email_uguali_a_maiuscole_diverse_sono_rifiutate(self) -> None:
        # py_find_user_id normalizza in minuscolo: il confronto tra le
        # email deve fare lo stesso, senza nemmeno toccare la rete.
        result = self._run(
            "--owner-email",
            "MARCO.MART87@EXAMPLE.COM",
            "--worker-email",
            "marco.mart87@example.com",
            "--create",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(
            "worker e proprietario devono essere utenti diversi",
            result.stderr,
        )
        self.assertFalse(self.curl_log.exists())


class ProtocolDocSecretHygieneTest(unittest.TestCase):
    def test_la_service_role_key_non_passa_dalla_history(self) -> None:
        # La procedura documentata non deve far digitare la chiave in un
        # `export KEY="..."`: zsh la persisterebbe in chiaro in
        # ~/.zsh_history, contraddicendo la promessa dello script.
        text = PROTOCOL_DOC.read_text(encoding="utf-8")
        self.assertNotIn('export KAL_PROVISION_SERVICE_ROLE_KEY="', text)
        self.assertIn("read -rs KAL_PROVISION_SERVICE_ROLE_KEY", text)
        self.assertIn("zsh_history", text)


if __name__ == "__main__":
    unittest.main()
