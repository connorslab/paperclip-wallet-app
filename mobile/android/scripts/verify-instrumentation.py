"""Reject successful runner exits that did not execute the requested test class."""
import argparse
from pathlib import Path
import xml.etree.ElementTree as ET


def verify(directory, expected_class, started):
    reports = list(Path(directory).rglob('TEST-*.xml'))
    if not reports:
        raise ValueError('No instrumentation XML reports were produced')
    names = set()
    passed = 0
    for report in reports:
        if report.stat().st_mtime < started:
            raise ValueError('Instrumentation report predates this run')
        root = ET.parse(report).getroot()
        cases = list(root.iter('testcase'))
        if any(int(suite.get(key, '0')) != 0 for suite in root.iter()
               if suite.tag in ('testsuite', 'testsuites') for key in ('failures', 'errors')):
            raise ValueError('Instrumentation report records failures')
        if 'tests' in root.attrib and int(root.get('tests')) != len(cases):
            raise ValueError('Instrumentation test count does not match its cases')
        for case in cases:
            if case.get('classname') != expected_class:
                raise ValueError('Runner executed a different test class')
            name = case.get('name')
            if not name or name in names:
                raise ValueError('Missing or duplicate instrumentation test name')
            names.add(name)
            if case.find('failure') is not None or case.find('error') is not None:
                raise ValueError('Instrumentation test failed')
            if case.find('skipped') is None:
                passed += 1
    if passed == 0:
        raise ValueError('Requested class had no passing, non-skipped tests')
    return passed


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('expected_class')
    parser.add_argument('started', type=int)
    args = parser.parse_args()
    print(f'{args.expected_class}: {verify(args.directory, args.expected_class, args.started)} tests passed')
