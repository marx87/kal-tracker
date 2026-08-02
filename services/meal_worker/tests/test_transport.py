import unittest

from kal_meal_worker.transport import ResponseTooLargeError, _read_limited


class ChunkReader:
    def __init__(self, chunks):
        self.chunks = list(chunks)
        self.read_sizes = []

    def read(self, size):
        self.read_sizes.append(size)
        if not self.chunks:
            return b""
        return self.chunks.pop(0)


class ReadLimitedTest(unittest.TestCase):
    def test_reads_until_eof_when_reader_returns_partial_chunks(self) -> None:
        reader = ChunkReader([b"abc", b"def", b"ghi"])

        self.assertEqual(_read_limited(reader, 9), b"abcdefghi")
        self.assertEqual(reader.read_sizes[-1], 1)

    def test_detects_limit_exceeded_across_multiple_chunks(self) -> None:
        reader = ChunkReader([b"1234", b"5678", b"9"])

        with self.assertRaises(ResponseTooLargeError):
            _read_limited(reader, 8)


if __name__ == "__main__":
    unittest.main()
