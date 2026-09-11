import importlib.util
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('cask', ROOT / 'Scripts/homebrew_cask.py')
cask = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cask)


class HomebrewTests(unittest.TestCase):
    def test_instructions_are_added_once_only_after_a_cask_exists(self):
        text = '# WandelBar\n\n## Build from source\n'
        updated = cask.add_installation_instructions(text)
        self.assertIn('brew install --cask alexiosus/wandelbar/wandelbar', updated)
        self.assertEqual(updated, cask.add_installation_instructions(updated))
        with self.assertRaises(ValueError):
            cask.add_installation_instructions('# Unsupported README')

    def release(self):
        return dict(draft=False, prerelease=False, tag_name='v0.2.0', assets=[dict(
            name='WandelBar-0.2.0-macOS-arm64.dmg', digest='sha256:' + 'a'*64,
            browser_download_url='https://github.com/alexiosus/WandelBar/releases/download/v0.2.0/WandelBar-0.2.0-macOS-arm64.dmg')])

    def checksums(self):
        return 'a'*64 + '  WandelBar-0.2.0-macOS-arm64.dmg\n'

    def test_valid_cask_has_valid_ruby_and_exact_checksum(self):
        result = cask.make_cask(self.release(), self.checksums())
        self.assertIn('sha256 "' + 'a'*64 + '"', result)
        self.assertIn('auto_updates true', result)
        subprocess.run(['ruby', '-c'], input=result, text=True, check=True, capture_output=True)

    def test_drafts_prereleases_bad_tags_and_external_assets_are_rejected(self):
        for field, value in [('draft', True), ('prerelease', True), ('tag_name', 'v0.2.0-beta'),
                             ('tag_name', 'v0.1.0'), ('tag_name', 'v0.2.0";system("bad")')]:
            release = self.release()
            release[field] = value
            with self.assertRaises(ValueError):
                cask.make_cask(release, self.checksums())
        release = self.release()
        release['assets'][0]['browser_download_url'] = 'https://example.com/app.dmg'
        with self.assertRaises(ValueError):
            cask.make_cask(release, self.checksums())

    def test_mismatched_or_duplicate_checksums_are_rejected(self):
        for checksum in [self.checksums().replace('a', 'b'), self.checksums()*2, '']:
            with self.assertRaises(ValueError):
                cask.make_cask(self.release(), checksum)
