from __future__ import annotations

import subprocess
from collections.abc import Callable, Sequence


class KeychainError(RuntimeError):
    """Il segreto non e disponibile nel Portachiavi macOS."""


CommandRunner = Callable[..., subprocess.CompletedProcess[str]]


class MacOSKeychainPassword:
    def __init__(
        self,
        *,
        service: str,
        account: str,
        executable: Sequence[str] = ("/usr/bin/security",),
        runner: CommandRunner = subprocess.run,
        timeout_seconds: float = 10,
    ) -> None:
        if not service or "\x00" in service:
            raise ValueError("Servizio Portachiavi non valido")
        if not account or "\x00" in account:
            raise ValueError("Account Portachiavi non valido")
        if not executable:
            raise ValueError("Eseguibile Portachiavi non valido")
        self._service = service
        self._account = account
        self._executable = tuple(executable)
        self._runner = runner
        self._timeout_seconds = timeout_seconds

    def __call__(self) -> str:
        command = [
            *self._executable,
            "find-generic-password",
            "-a",
            self._account,
            "-s",
            self._service,
            "-w",
        ]
        try:
            completed = self._runner(
                command,
                capture_output=True,
                text=True,
                timeout=self._timeout_seconds,
                check=False,
                shell=False,
            )
        except (FileNotFoundError, subprocess.TimeoutExpired, OSError) as error:
            raise KeychainError("Portachiavi macOS non disponibile") from error
        if completed.returncode != 0:
            raise KeychainError("Password worker non trovata nel Portachiavi")
        password = completed.stdout.rstrip("\r\n")
        if not password:
            raise KeychainError("Password worker vuota nel Portachiavi")
        return password
