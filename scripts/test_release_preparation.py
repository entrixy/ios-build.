"""Release preparation boundaries, using synthetic identifiers and temp files only."""
from pathlib import Path
import tempfile
import unittest
from prepare_app_store_release import prepare


class ReleasePreparationTests(unittest.TestCase):
    def fixture(self):
        # Test values are not a claim about the user's Apple account.
        return dict(confirmed=True, team_id='TESTTEAM01', application_identifier_prefix='OLDPREFIX1',
                    bundle_id='test.entrixy.fixture', app_group='group.test.entrixy.fixture')

    def testLegacyPrefixIsPreservedSeparatelyFromTeamAndAppWidgetUseOneGroup(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)/'release'
            report = prepare(self.fixture(), output)
            self.assertEqual(report['widget_bundle_id'], 'test.entrixy.fixture.widget')
            self.assertIn('OLDPREFIX1.test.entrixy.fixture', (output/'apple-app-site-association').read_text())
            settings = (output/'Signing.xcconfig').read_text()
            self.assertIn('DEVELOPMENT_TEAM = TESTTEAM01', settings)
            self.assertIn('ENTRIXY_APP_GROUP = group.test.entrixy.fixture', settings)
            self.assertFalse(report['signed']); self.assertFalse(report['uploaded'])

    def testUnconfirmedMissingOrExtraCredentialFieldsCreateNothing(self):
        with tempfile.TemporaryDirectory() as temporary:
            for inputs in [dict(self.fixture(), confirmed=False), dict(self.fixture(), team_id=None),
                           dict(self.fixture(), private_key='do-not-copy')]:
                output = Path(temporary)/'release'
                with self.assertRaises(ValueError): prepare(inputs, output)
                self.assertFalse(output.exists())

    def testIdentifierCannotInjectBuildSettingsPathsOrOtherTargets(self):
        with tempfile.TemporaryDirectory() as temporary:
            for key, value in [('bundle_id', 'test.valid\nOTHER = injected'), ('team_id', '../secrets'),
                               ('app_group', 'group.'), ('app_group', 'group.test..invalid'),
                               ('bundle_id', '$(OTHER_SETTING)'), ('application_identifier_prefix', 'lowercase1')]:
                output = Path(temporary)/'release'
                with self.assertRaises(ValueError): prepare(dict(self.fixture(), **{key:value}), output)
                self.assertFalse(output.exists())

    def testExistingPreparedMaterialIsNeverOverwritten(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)/'release'; output.mkdir()
            marker = output/'Signing.xcconfig'; marker.write_text('keep-existing')
            with self.assertRaises(ValueError): prepare(self.fixture(), output)
            self.assertEqual(marker.read_text(), 'keep-existing')
            self.assertEqual(list(output.iterdir()), [marker])


if __name__ == '__main__': unittest.main()
