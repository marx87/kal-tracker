from __future__ import annotations

import hashlib
from pathlib import Path

from .supabase_gateway import ClaimedJob, DownloadedPhoto


class ImageIntegrityError(RuntimeError):
    def __init__(self, error_code: str) -> None:
        self.error_code = error_code
        super().__init__(error_code)


_EXTENSIONS = {
    "image/jpeg": ".jpg",
    "image/png": ".png",
    "image/webp": ".webp",
}


def detect_image_mime(data: bytes) -> str | None:
    if len(data) >= 3 and data.startswith(b"\xff\xd8\xff"):
        return "image/jpeg"
    if len(data) >= 8 and data.startswith(b"\x89PNG\r\n\x1a\n"):
        return "image/png"
    if len(data) >= 12 and data.startswith(b"RIFF") and data[8:12] == b"WEBP":
        return "image/webp"
    return None


def verify_and_write_photo(
    photo: DownloadedPhoto,
    job: ClaimedJob,
    directory: Path,
) -> Path:
    data = photo.body
    if len(data) != job.image_size_bytes:
        raise ImageIntegrityError("IMAGE_SIZE_MISMATCH")
    if hashlib.sha256(data).hexdigest() != job.image_sha256:
        raise ImageIntegrityError("IMAGE_SHA256_MISMATCH")

    detected_mime = detect_image_mime(data)
    if detected_mime is None:
        raise ImageIntegrityError("IMAGE_MAGIC_UNKNOWN")
    if detected_mime != job.image_mime_type:
        raise ImageIntegrityError("IMAGE_MAGIC_MIME_MISMATCH")
    if photo.content_type in _EXTENSIONS and photo.content_type != detected_mime:
        raise ImageIntegrityError("IMAGE_HTTP_MIME_MISMATCH")

    destination = directory / f"meal{_EXTENSIONS[detected_mime]}"
    try:
        destination.write_bytes(data)
        destination.chmod(0o600)
    except OSError as error:
        raise ImageIntegrityError("IMAGE_TEMP_WRITE_FAILED") from error
    return destination
