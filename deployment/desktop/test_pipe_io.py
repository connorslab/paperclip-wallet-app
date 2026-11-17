"""Native pipe deadlines and EOF behavior; no wallet data or transport."""
import os
import subprocess
import sys
import threading
import time
import unittest

from pipe_io import read_available


class OwnedPipe(unittest.TestCase):
    def setUp(self):
        self.reader, self.writer = os.pipe()
        self.addCleanup(os.close, self.reader)
        self.addCleanup(self.close_writer)

    def close_writer(self):
        if self.writer is not None:
            os.close(self.writer)
            self.writer = None

    def test_empty_live_pipe_times_out_without_becoming_eof(self):
        start = time.monotonic()
        self.assertIsNone(read_available(self.reader, 256, .03))
        self.assertLess(time.monotonic() - start, 2)
        os.write(self.writer, b'next')
        self.assertEqual(read_available(self.reader, 256, 1), b'next')

    def test_partial_message_is_returned_without_waiting_for_a_newline(self):
        os.write(self.writer, b'{')
        self.assertEqual(read_available(self.reader, 256, 1), b'{')
        self.assertIsNone(read_available(self.reader, 256, 0))

    def test_limit_does_not_consume_the_rest_of_the_message(self):
        os.write(self.writer, b'abcdef')
        self.assertEqual(read_available(self.reader, 2, 1), b'ab')
        self.assertEqual(read_available(self.reader, 4, 1), b'cdef')

    def test_protocol_bytes_are_not_translated_or_treated_as_text_eof(self):
        os.write(self.writer, b'\r\x1a\n')
        self.assertEqual(read_available(self.reader, 1, 1), b'\r')
        self.assertEqual(read_available(self.reader, 1, 1), b'\x1a')
        self.assertEqual(read_available(self.reader, 1, 1), b'\n')

    def test_buffered_data_precedes_eof(self):
        os.write(self.writer, b'last')
        self.close_writer()
        self.assertEqual(read_available(self.reader, 256, 1), b'last')
        self.assertEqual(read_available(self.reader, 256, 1), b'')

    def test_delayed_data_arrives_before_deadline(self):
        writer = threading.Timer(.03, os.write, args=(self.writer, b'ready'))
        writer.start()
        try:
            self.assertEqual(read_available(self.reader, 256, 2), b'ready')
        finally:
            writer.join()

    def test_child_death_closes_real_subprocess_pipe(self):
        child = subprocess.Popen([sys.executable, '-c', 'import os; os._exit(3)'],
                                 stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        try:
            self.assertEqual(read_available(child.stdout.fileno(), 256, 5), b'')
            self.assertEqual(child.wait(timeout=5), 3)
        finally:
            if child.poll() is None:
                child.kill(); child.wait(timeout=5)
            child.stdout.close()

    def test_invalid_read_parameters_fail_before_reading(self):
        for limit, timeout in [(0, 0), (65537, 0), (1, -1), (1, float('inf'))]:
            with self.assertRaises(ValueError):
                read_available(self.reader, limit, timeout)


if __name__ == '__main__':
    unittest.main()
