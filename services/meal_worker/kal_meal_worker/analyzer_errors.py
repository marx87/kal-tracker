from __future__ import annotations


class AnalyzerError(RuntimeError):
    """Errore sicuro e presentabile di un provider di analisi."""

    def __init__(
        self,
        message: str,
        *,
        error_code: str,
        retryable: bool = True,
    ) -> None:
        self.error_code = error_code
        self.retryable = retryable
        super().__init__(message)
