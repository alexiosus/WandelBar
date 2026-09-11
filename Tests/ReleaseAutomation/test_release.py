import importlib.util
from pathlib import Path
import subprocess
import unittest
import json
import os
import tempfile

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('release_notes', ROOT / 'Scripts/release_notes.py')
notes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(notes)


class ReleaseTests(unittest.TestCase):
    def test_untrusted_tag_fails_before_reading_version(self):
        workflow = json.loads(subprocess.check_output([
            'ruby', '-ryaml', '-rjson', '-e', 'puts JSON.generate(YAML.load_file(ARGV[0]))',
            str(ROOT / '.github/workflows/release.yml')], text=True))
        gate = next(s['run'] for s in workflow['jobs']['validate']['steps']
                    if s.get('name') == 'Require a trusted release source')
        with tempfile.TemporaryDirectory() as directory:
            git = Path(directory) / 'git'
            git.write_text('#!/bin/sh\nexit 1\n')
            git.chmod(0o755)
            env = dict(os.environ, PATH=directory + ':' + os.environ['PATH'],
                       RELEASE_EVENT='push', RELEASE_REF='refs/tags/v0.2.0', RELEASE_NAME='v0.2.0')
            result = subprocess.run(['/bin/zsh', '-c', gate], cwd=ROOT, env=env,
                                    capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)

    def test_notes_only_include_requested_version(self):
        text = '# Changes\n## 0.2.0 — Unreleased\n\n### New\n- New thing\n\n## 0.1.0 — 2026-08-21\n- Old thing\n'
        self.assertEqual(notes.release_notes('0.2.0', text), '### New\n- New thing\n')
        with self.assertRaises(ValueError):
            notes.release_notes('0.3.0', text)

    def test_secret_job_is_separate_from_validation_and_publication(self):
        workflow = json.loads(subprocess.check_output([
            'ruby', '-ryaml', '-rjson', '-e', 'puts JSON.generate(YAML.load_file(ARGV[0]))',
            str(ROOT / '.github/workflows/release.yml')], text=True))
        jobs = workflow['jobs']
        self.assertEqual(jobs['sign']['needs'], 'validate')
        self.assertEqual(jobs['sign']['environment'], 'release-signing')
        self.assertEqual(jobs['publish']['needs'], 'sign')
        self.assertEqual(workflow['permissions'], {'contents': 'read'})
        for job in ('validate', 'publish'):
            self.assertNotIn('secrets.', str(jobs[job]))
            self.assertNotIn('environment', jobs[job])
        secret_steps = [s for s in jobs['sign']['steps'] if 'secrets.' in str(s)]
        self.assertEqual(len(secret_steps), 1)
        self.assertEqual(secret_steps[0]['run'], './Scripts/ci_signed_release.sh')
        self.assertTrue(any(s.get('if') == 'always()' for s in jobs['sign']['steps']))
        for job in jobs.values():
            for step in job['steps']:
                if 'uses' in step:
                    self.assertRegex(step['uses'], r'@[a-f0-9]{40}$')

    def test_missing_credentials_fail_before_creating_keychain(self):
        result = subprocess.run(['/bin/zsh', str(ROOT / 'Scripts/ci_signed_release.sh')],
                                env={'PATH': '/usr/bin:/bin'}, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Only run on the release runner', result.stderr)


if __name__ == '__main__':
    unittest.main()
