"""Personal packaging boundaries; no Apple account, device or simulator required."""
import copy
import plistlib
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import yaml
from prepare_personal_project import personal_spec
from package_personal_ipa import inspect_personal
from archive_device_release import verify_device_image
from test_simulator import review_test_products


class PersonalPackageTests(unittest.TestCase):
    def testPersonalVariantUsesSameSourceAndDependenciesWithoutMutatingStoreCapabilities(self):
        source = yaml.safe_load(Path('project.yml').read_text())
        original = copy.deepcopy(source)
        personal = personal_spec(source)
        self.assertEqual(source, original)
        self.assertNotIn('EntrixyWidget', personal['targets'])
        app = personal['targets']['Entrixy']
        self.assertEqual(app['sources'], source['targets']['Entrixy']['sources'])
        self.assertEqual(personal['packages'], source['packages'])
        self.assertTrue(all(item.get('target') != 'EntrixyWidget' for item in app['dependencies']))
        self.assertEqual(plistlib.loads(Path('scripts/personal.entitlements').read_bytes()), {})
        self.assertEqual(app['settings']['base']['CODE_SIGN_ENTITLEMENTS[sdk=iphoneos*]'],'scripts/personal.entitlements')
        self.assertEqual(app['settings']['base']['CODE_SIGN_ENTITLEMENTS[sdk=iphonesimulator*]'],source['targets']['Entrixy']['settings']['base']['CODE_SIGN_ENTITLEMENTS[sdk=iphonesimulator*]'])
        properties = app['info']['properties']
        self.assertEqual(properties['UIBackgroundModes'], ['location', 'bluetooth-central'])
        self.assertNotIn('EntrixyAppGroup', properties)
        self.assertNotIn('EntrixyPushEnvironment', properties)
        self.assertEqual(personal['options']['deploymentTarget']['iOS'], '16.0')
        self.assertIn('EntrixyAppTests', personal['targets'])
        self.assertIn('EntrixyUITests', personal['targets'])

    def testPersonalPackageRejectsPaidIntegrationBeforeReadingLibrariesOrPackaging(self):
        for invalid in [{'EntrixyAppGroup':'group.test.app'}, {'EntrixyPushEnvironment':'production'},
                        {'UIBackgroundModes':['remote-notification']}, {'EntrixyBuildVariant':'store'}]:
            with self.subTest(invalid=invalid), tempfile.TemporaryDirectory() as temporary:
                app = Path(temporary)
                info = dict(EntrixyBuildVariant='personal', UIBackgroundModes=['location','bluetooth-central'])
                info.update(invalid)
                (app/'Info.plist').write_bytes(plistlib.dumps(info))
                with patch('package_personal_ipa.bundle_record', return_value={'minimum_ios':'16.0'}):
                    with self.assertRaises(ValueError): inspect_personal(app)

    def testArm64SimulatorCannotBeDistributedAsAnIPhonePackage(self):
        import struct
        def binary(platform):
            return struct.pack('<IiiIIIII',0xFEEDFACF,0x0100000C,0,2,1,24,0,0) + struct.pack('<IIIIII',0x32,24,platform,0,0,0)
        verify_device_image(binary(2))
        with self.assertRaises(ValueError): verify_device_image(binary(7))

    def testWholeSuiteKeepsCheckpointAssertionsButDoesNotEnableScreenshotCapture(self):
        with tempfile.TemporaryDirectory() as temporary:
            products = Path(temporary)
            source = products/'app.xctestrun'
            source.write_bytes(plistlib.dumps({'EntrixyUITests':{'TestBundlePath':'EntrixyUITests.xctest'}}))
            generated = review_test_products(products,capture=False)
            environment = plistlib.loads(generated.read_bytes())['EntrixyUITests']['EnvironmentVariables']
            self.assertEqual(environment['ENTRIXY_REVIEW_CAPTURE'],'0')
            self.assertEqual(environment['ENTRIXY_CHECKPOINT_ASSERTIONS'],'1')
            self.assertNotIn('EnvironmentVariables',plistlib.loads(source.read_bytes())['EntrixyUITests'])


if __name__ == '__main__': unittest.main()
