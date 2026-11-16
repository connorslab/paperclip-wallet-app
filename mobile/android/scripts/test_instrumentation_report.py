import importlib.util
import os
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('instrumentation_report', Path(__file__).with_name('verify-instrumentation.py'))
report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(report)


class InstrumentationReportTest(unittest.TestCase):
    def test_report_totals_cannot_hide_failure_or_missing_cases(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'TEST-device.xml'
            for attributes in ['tests="2"', 'tests="1" failures="1"', 'tests="1" errors="1"']:
                with self.subTest(attributes=attributes):
                    path.write_text('<testsuite ' + attributes + '><testcase classname="Expected" name="one"/></testsuite>')
                    with self.assertRaises(ValueError):
                        report.verify(directory, 'Expected', 0)

    def test_missing_empty_skipped_wrong_failed_and_stale_reports_fail(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(ValueError):
                report.verify(directory, 'Expected', 100)
            path = Path(directory) / 'TEST-device.xml'
            for body in ['', '<testcase classname="Other" name="one"/>',
                    '<testcase classname="Expected" name="one"><skipped/></testcase>',
                    '<testcase classname="Expected" name="one"><failure/></testcase>',
                    '<testcase classname="Expected" name="one"><error/></testcase>',
                    '<testcase classname="Expected" name="one"/>' * 2]:
                with self.subTest(body=body):
                    path.write_text('<testsuites><testsuite>' + body + '</testsuite></testsuites>')
                    with self.assertRaises(ValueError):
                        report.verify(directory, 'Expected', 100)
            path.write_text('<testsuite><testcase classname="Expected" name="one"/></testsuite>')
            self.assertEqual(report.verify(directory, 'Expected', 100), 1)
            os.utime(path, (99, 99))
            with self.assertRaises(ValueError):
                report.verify(directory, 'Expected', 100)


if __name__ == '__main__':
    unittest.main()
