from pathlib import Path
import json
import plistlib
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]


class UpdateConfigurationTests(unittest.TestCase):
    def test_updater_pins_key_and_requires_signed_feeds_and_archives(self):
        import base64
        with (ROOT / 'Resources/Info.plist').open('rb') as f:
            plist = plistlib.load(f)
        self.assertEqual(len(base64.b64decode(plist['SUPublicEDKey'], validate=True)), 32)
        self.assertTrue(plist['SURequireSignedFeed'])
        self.assertTrue(plist['SUVerifyUpdateBeforeExtraction'])
        self.assertFalse(plist['SUEnableAutomaticChecks'])
        self.assertFalse(plist['SUAutomaticallyUpdate'])
        self.assertEqual(plist['SUFeedURL'], 'https://github.com/alexiosus/WandelBar/releases/latest/download/appcast.xml')

    def test_homebrew_reads_stable_releases_without_signing_secrets(self):
        workflow = json.loads(subprocess.check_output([
            'ruby', '-ryaml', '-rjson', '-e', 'puts JSON.generate(YAML.load_file(ARGV[0]))',
            str(ROOT / '.github/workflows/homebrew.yml')], text=True))
        self.assertNotIn('secrets.', str(workflow))
        job = workflow['jobs']['update']
        self.assertIn('!github.event.release.prerelease', job['if'])
        self.assertIn('releases/latest', str(job))
        self.assertEqual(job['steps'][0]['with']['ref'], 'master')
        self.assertFalse(job['steps'][0]['with']['persist-credentials'])
