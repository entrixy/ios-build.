"""Process lifecycle regressions; no Apple SDK, simulator, network or app data."""
import contextlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
from run_xctest import run_xctest


class XCTestProcessTests(unittest.TestCase):
    def invoke(self,source,path,**options):
        with contextlib.redirect_stdout(io.StringIO()):
            return run_xctest([sys.executable,'-u','-c',source],report_path=path,**options)

    def testSilentStartupStopsTheOwnedProcessGroupBeforeAnyScenario(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);marker=root/'must-not-run';report=root/'progress.json'
            child="import time;from pathlib import Path;time.sleep(0.8);Path("+repr(str(marker))+").write_text('replayed')"
            source="import subprocess,sys,time;subprocess.Popen([sys.executable,'-c',"+repr(child)+"]);time.sleep(20)"
            with self.assertRaises(subprocess.TimeoutExpired):
                self.invoke(source,report,startup_timeout=0.2,timeout=3)
            time.sleep(0.9)
            self.assertFalse(marker.exists())
            value=json.loads(report.read_text())
            self.assertEqual(value['phase'],'startup-timeout');self.assertFalse(value['tests_started'])

    def testAStartedSuiteKeepsItsRuntimeBudgetAndIsNeverReplayed(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);marker=root/'invocations';report=root/'progress.json'
            source="from pathlib import Path;import time;p=Path("+repr(str(marker))+");p.write_text(p.read_text()+'x' if p.exists() else 'x');print(\"Test Suite 'real suite' started\",flush=True);time.sleep(0.4)"
            self.invoke(source,report,startup_timeout=0.2,timeout=3)
            self.assertEqual(marker.read_text(),'x')
            self.assertEqual(json.loads(report.read_text())['phase'],'passed')

    def testAnActualTestFailureIsPreservedWithoutRetry(self):
        with tempfile.TemporaryDirectory() as temporary:
            report=Path(temporary)/'progress.json'
            with self.assertRaises(subprocess.CalledProcessError) as error:
                self.invoke("print(\"Test Suite 'suite' started\",flush=True);raise SystemExit(7)",report,startup_timeout=1,timeout=3)
            self.assertEqual(error.exception.returncode,7)
            self.assertEqual(json.loads(report.read_text())['phase'],'failed')

    def testOverallTimeoutStillAppliesAfterTheFirstTestStarts(self):
        with tempfile.TemporaryDirectory() as temporary:
            report=Path(temporary)/'progress.json'
            with self.assertRaises(subprocess.TimeoutExpired):
                self.invoke("import time;print(\"Test Case 'case' started\",flush=True);time.sleep(20)",report,startup_timeout=0.2,timeout=0.4)
            value=json.loads(report.read_text())
            self.assertEqual(value['phase'],'runtime-timeout');self.assertTrue(value['tests_started'])

    def testZeroExitWithoutAnyTestIsNotReportedAsSuccess(self):
        with tempfile.TemporaryDirectory() as temporary:
            report=Path(temporary)/'progress.json'
            with self.assertRaisesRegex(RuntimeError,'without starting'):
                self.invoke("print('No test was launched')",report,startup_timeout=1,timeout=3)
            self.assertEqual(json.loads(report.read_text())['phase'],'no-tests')

    def testProtectedProcessGroupStillStopsOwnedChildAndPreservesTimeoutEvidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            report=Path(temporary)/'progress.json'
            with patch('run_xctest.os.killpg',side_effect=PermissionError('protected descendant')):
                with self.assertRaises(subprocess.TimeoutExpired):
                    self.invoke("import time;print(\"Test Case 'case' started\",flush=True);time.sleep(20)",report,startup_timeout=0.2,timeout=0.4)
            value=json.loads(report.read_text())
            self.assertEqual(value['phase'],'runtime-timeout')
            self.assertTrue(value['tests_started']);self.assertIsNotNone(value['exit_code'])


if __name__ == '__main__':unittest.main()
