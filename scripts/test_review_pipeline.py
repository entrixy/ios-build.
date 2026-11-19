#!/usr/bin/env python3
"""Isolated CI contract checks; no simulator, network, credentials or user data."""
import contextlib
import hashlib
import io
import json
from pathlib import Path
import plistlib
import struct
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import zlib
from export_ui_review import export_review
from test_simulator import review_test_products
from capture_simulator import create_booted_device


class ReviewPipelineTests(unittest.TestCase):
    def testUIServiceStallIsRecoveredBeforeAnyTestStarts(self):
        commands = []
        def execute(*args, **kwargs):
            commands.append(args)
            if args[1:3] == ('simctl', 'create'):
                return 'first' if sum(c[1:3] == ('simctl', 'create') for c in commands) == 1 else 'second'
            if args[1:4] == ('simctl', 'ui', 'first'):
                raise subprocess.TimeoutExpired(args, 60)
            return ''
        with patch('capture_simulator.run', side_effect=execute), patch.dict('os.environ', {'GITHUB_ACTIONS':'true'}):
            result = create_booted_device('tests', 'iphone', 'runtime', appearance='light')
        self.assertEqual(result, 'second')
        self.assertIn(('xcrun','simctl','delete','first'), commands)
        self.assertIn(('killall','-9','com.apple.CoreSimulator.CoreSimulatorService'), commands)
        self.assertEqual(commands[-1], ('xcrun','simctl','ui','second','appearance','light'))

    def testRepeatedPreparationFailureStopsInsteadOfStartingTests(self):
        def execute(*args, **kwargs):
            if args[1:3] == ('simctl','create'): return 'device'
            if args[1:3] == ('simctl','ui'): raise subprocess.TimeoutExpired(args,60)
            return ''
        with patch('capture_simulator.run',side_effect=execute),patch.dict('os.environ',{'GITHUB_ACTIONS':'false'}):
            with self.assertRaises(subprocess.TimeoutExpired):
                create_booted_device('tests','iphone','runtime',appearance='light')

    def testReviewConfigurationPreservesOriginalProductsAndAddsCaptureOnlyToUITarget(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            original = root / 'Entrixy.xctestrun'
            value = {'TestConfigurations':[{'TestTargets':[
                {'TestBundlePath':'__TESTROOT__/EntrixyAppTests.xctest','EnvironmentVariables':{'KEEP':'native'}},
                {'TestBundlePath':'__TESTROOT__/EntrixyUITests.xctest','EnvironmentVariables':{'KEEP':'ui'}}]}]}
            original.write_bytes(plistlib.dumps(value)); before = original.read_bytes()
            result = review_test_products(root)
            self.assertEqual(result.parent,original.parent); self.assertEqual(original.read_bytes(),before)
            targets = plistlib.loads(result.read_bytes())['TestConfigurations'][0]['TestTargets']
            self.assertNotIn('ENTRIXY_REVIEW_CAPTURE',targets[0]['EnvironmentVariables'])
            self.assertEqual(targets[1]['EnvironmentVariables'],{'KEEP':'ui','ENTRIXY_REVIEW_CAPTURE':'1'})
            self.assertEqual(targets[1]['TestBundlePath'],'__TESTROOT__/EntrixyUITests.xctest')

    def exportFixture(self, *, duplicate=False, failed=False):
        source = Path(__file__).resolve().parents[1] / 'Tests/EntrixyUITests/NavigationUITests.swift'
        import re
        states = set(re.findall(r'reviewCapture\("([a-z0-9-]+)"',source.read_text()))
        def chunk(kind,data): return struct.pack('>I',len(data))+kind+data+struct.pack('>I',zlib.crc32(kind+data)&0xffffffff)
        raw = b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',1179,2556,8,0,0,0,0))
        raw += chunk(b'IDAT',zlib.compress((b'\0'+b'\xff'*1179)*2556))+chunk(b'IEND',b'')
        def export(command,**kwargs):
            root = Path(command[-1]); attachments=[]
            selected = sorted(states)[:1] if failed else sorted(states)
            for i,state in enumerate(selected):
                filename = str(i)+'.png';(root/filename).write_bytes(raw)
                attachments.append({'suggestedHumanReadableName':'review-'+state+'_0_fixture.png','exportedFileName':filename})
            if duplicate: attachments.append(attachments[0])
            (root/'manifest.json').write_text(json.dumps([{'testIdentifier':'NavigationUITests/fixture()','attachments':attachments}]))
        return states,raw,export

    def testOriginalScreenshotsAreCopiedWithoutRetouchingAndAllStatesAreRequired(self):
        states,raw,export = self.exportFixture()
        from prepare_ui_gallery import SCREENS
        self.assertEqual(states,set(SCREENS))
        with tempfile.TemporaryDirectory() as temporary,patch('export_ui_review.subprocess.run',side_effect=export),contextlib.redirect_stdout(io.StringIO()):
            report = export_review('fixture.xcresult',temporary,tests_succeeded=True,source_sha='a'*40)
            self.assertTrue(report['complete']);self.assertEqual(len(report['captures']),len(states))
            for frame in report['captures']:
                self.assertEqual((Path(temporary)/frame['file']).read_bytes(),raw)
                self.assertEqual(frame['sha256'],hashlib.sha256(raw).hexdigest())
            self.assertEqual(report['visual_review'],'pending');self.assertEqual(report['full_android_parity'],'pending')

    def testFailedRunRetainsPartialPicturesWithoutClaimingCompleteReview(self):
        _,_,export = self.exportFixture(failed=True)
        with tempfile.TemporaryDirectory() as temporary,patch('export_ui_review.subprocess.run',side_effect=export),contextlib.redirect_stdout(io.StringIO()):
            report = export_review('fixture.xcresult',temporary,tests_succeeded=False,source_sha='b'*40)
            self.assertFalse(report['complete']);self.assertFalse(report['tests_succeeded']);self.assertTrue(report['missing_states'])
            self.assertEqual(len(list(Path(temporary).glob('*.png'))),1)

    def testDuplicateStateFailsInsteadOfPublishingTenVersionsOfOneScreen(self):
        _,_,export = self.exportFixture(duplicate=True)
        with tempfile.TemporaryDirectory() as temporary,patch('export_ui_review.subprocess.run',side_effect=export):
            with self.assertRaisesRegex(RuntimeError,'Duplicate review state'):
                export_review('fixture.xcresult',temporary,tests_succeeded=True,source_sha='c'*40)


if __name__ == '__main__': unittest.main()
