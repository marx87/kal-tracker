import subprocess
import unittest

from kal_meal_worker.keychain import KeychainError, MacOSKeychainPassword


class MacOSKeychainPasswordTest(unittest.TestCase):
    def test_reads_generic_password_without_a_shell(self) -> None:
        observed = {}

        def runner(command, **kwargs):
            observed["command"] = command
            observed["kwargs"] = kwargs
            return subprocess.CompletedProcess(command, 0, "secret with spaces\n", "")

        provider = MacOSKeychainPassword(
            service="com.example.worker",
            account="worker@example.test",
            runner=runner,
        )

        self.assertEqual(provider(), "secret with spaces")
        self.assertEqual(
            observed["command"],
            [
                "/usr/bin/security",
                "find-generic-password",
                "-a",
                "worker@example.test",
                "-s",
                "com.example.worker",
                "-w",
            ],
        )
        self.assertIs(observed["kwargs"]["shell"], False)
        self.assertNotIn("secret with spaces", observed["command"])

    def test_does_not_expose_security_stderr(self) -> None:
        def runner(command, **kwargs):
            del kwargs
            return subprocess.CompletedProcess(command, 44, "", "sensitive detail")

        provider = MacOSKeychainPassword(
            service="service",
            account="account",
            runner=runner,
        )

        with self.assertRaisesRegex(KeychainError, "non trovata") as raised:
            provider()
        self.assertNotIn("sensitive detail", str(raised.exception))

    def test_rejects_empty_password(self) -> None:
        def runner(command, **kwargs):
            del kwargs
            return subprocess.CompletedProcess(command, 0, "\n", "")

        with self.assertRaisesRegex(KeychainError, "vuota"):
            MacOSKeychainPassword(
                service="service",
                account="account",
                runner=runner,
            )()


if __name__ == "__main__":
    unittest.main()
