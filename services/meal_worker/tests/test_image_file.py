import hashlib
import tempfile
import unittest
from pathlib import Path

from kal_meal_worker.image_file import ImageIntegrityError, verify_and_write_photo
from kal_meal_worker.supabase_gateway import ClaimedJob, DownloadedPhoto


def job_for(data: bytes, *, mime="image/jpeg", sha256=None, size=None):
    return ClaimedJob(
        job_id="11111111-1111-4111-8111-111111111111",
        owner_id="22222222-2222-4222-8222-222222222222",
        profile_id="33333333-3333-4333-8333-333333333333",
        storage_bucket="kal-tracker-meal-photos",
        storage_object=(
            "22222222-2222-4222-8222-222222222222/"
            "11111111-1111-4111-8111-111111111111/photo.jpg"
        ),
        image_sha256=sha256 or hashlib.sha256(data).hexdigest(),
        image_size_bytes=len(data) if size is None else size,
        image_mime_type=mime,
        requested_meal_type=None,
        user_note=None,
        attempt_count=1,
        row_version=1,
        lease_expires_at="2026-08-02T12:00:00+00:00",
    )


class ImageFileTest(unittest.TestCase):
    def test_verifies_hash_size_and_magic_before_writing(self) -> None:
        data = b"\xff\xd8\xffminimal-jpeg"
        with tempfile.TemporaryDirectory() as temporary:
            result = verify_and_write_photo(
                DownloadedPhoto(data, "image/jpeg"),
                job_for(data),
                Path(temporary),
            )

            self.assertEqual(result.name, "meal.jpg")
            self.assertEqual(result.read_bytes(), data)
            self.assertEqual(result.stat().st_mode & 0o777, 0o600)

    def test_rejects_size_before_writing(self) -> None:
        data = b"\xff\xd8\xffjpeg"
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(
                ImageIntegrityError, "IMAGE_SIZE_MISMATCH"
            ):
                verify_and_write_photo(
                    DownloadedPhoto(data, "image/jpeg"),
                    job_for(data, size=len(data) + 1),
                    Path(temporary),
                )
            self.assertEqual(list(Path(temporary).iterdir()), [])

    def test_rejects_sha256_mismatch(self) -> None:
        data = b"\xff\xd8\xffjpeg"
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(
                ImageIntegrityError, "IMAGE_SHA256_MISMATCH"
            ):
                verify_and_write_photo(
                    DownloadedPhoto(data, "image/jpeg"),
                    job_for(data, sha256="0" * 64),
                    Path(temporary),
                )

    def test_rejects_claimed_mime_that_disagrees_with_magic(self) -> None:
        data = b"\x89PNG\r\n\x1a\ncontent"
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(
                ImageIntegrityError, "IMAGE_MAGIC_MIME_MISMATCH"
            ):
                verify_and_write_photo(
                    DownloadedPhoto(data, "image/png"),
                    job_for(data, mime="image/jpeg"),
                    Path(temporary),
                )

    def test_rejects_conflicting_http_content_type(self) -> None:
        data = b"RIFF\x00\x00\x00\x00WEBPcontent"
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(
                ImageIntegrityError, "IMAGE_HTTP_MIME_MISMATCH"
            ):
                verify_and_write_photo(
                    DownloadedPhoto(data, "image/png"),
                    job_for(data, mime="image/webp"),
                    Path(temporary),
                )

    def test_rejects_unknown_magic(self) -> None:
        data = b"not-an-image"
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(ImageIntegrityError, "IMAGE_MAGIC_UNKNOWN"):
                verify_and_write_photo(
                    DownloadedPhoto(data, None),
                    job_for(data),
                    Path(temporary),
                )


if __name__ == "__main__":
    unittest.main()
