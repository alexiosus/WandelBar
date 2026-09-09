import copy
import importlib.util
import io
import json
from pathlib import Path
import stat
import unittest
from unittest.mock import patch
import zipfile

spec = importlib.util.spec_from_file_location('catalogue', Path(__file__).resolve().parents[2] / 'Scripts/community_catalog.py')
c = importlib.util.module_from_spec(spec)
spec.loader.exec_module(c)
URL = 'https://github.com/user-attachments/files/31951170/Presets.zip'


def zipped(files):
    output = io.BytesIO()
    with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED) as archive:
        for name, data in files:
            archive.writestr(name, data)
    return output.getvalue()


def package():
    manifest = {'format': 'com.alexeremeev.WandelBar.preset-package', 'version': 1, 'createdBy': 'WandelBar',
                'presets': [{'name': 'Example', 'sourceID': 'user.1', 'settings': {
                    'blurRadiusPoints': 12, 'blurLengthPoints': 24, 'fadeLengthPoints': 30,
                    'tintStrength': 0.5, 'saturation': 0.3, 'solidTint': False,
                    'tintColor': {'red': 0, 'green': 0, 'blue': 0}}}]}
    return zipped([('manifest.json', json.dumps(manifest))])


def post():
    return {'number': 4, 'title': 'Example', 'body': '[Download](' + URL + ')',
            'url': 'https://github.com/alexiosus/WandelBar/discussions/4', 'author': {'login': 'alexiosus'},
            'category': {'name': c.CATEGORY}, 'labels': {'nodes': [{'name': c.LABEL}]}}


def event():
    return {'action': 'labeled', 'label': {'name': c.LABEL}, 'repository': {'id': c.REPO_ID, 'full_name': c.REPO},
            'sender': {'id': c.APPROVER_ID}, 'discussion': post()}


def baseline():
    return {'schemaVersion': 1, 'minimumClientVersion': 1, 'sequence': 1, 'issuedAt': 1, 'expiresAt': 2, 'entries': []}


def evidence():
    return {'approval': {**c.approval_request(event(), 'discussion'), 'sha256': 'a' * 64, 'byteCount': 100, 'presetCount': 1}}


class CatalogueTests(unittest.TestCase):
    def test_valid_wrapper(self):
        self.assertEqual(c.validate_package(zipped([('Presets.wandelbar-presets', package())]), URL), ['Example'])

    def test_ambiguous_attachments(self):
        with self.assertRaises(ValueError):
            c.attachment_from_body(URL + ' https://github.com/user-attachments/files/12/Other.zip')

    def test_rejects_traversal_links_duplicates_and_bombs(self):
        for files in [[('../Presets.wandelbar-presets', package())], [('Presets.wandelbar-presets', package()), ('extra', b'x')],
                      [('Presets.wandelbar-presets', b'x'), ('Presets.wandelbar-presets', b'x')]]:
            with self.assertRaises(ValueError):
                c.archive_files(zipped(files), wrapper=True)
        link = zipfile.ZipInfo('Presets.wandelbar-presets')
        link.create_system = 3
        link.external_attr = (stat.S_IFLNK | 0o777) << 16
        with self.assertRaises(ValueError):
            c.archive_files(zipped([(link, b'target')]), wrapper=True)
        with patch.object(c, 'MAX_PACKAGE', 1000):
            with self.assertRaises(ValueError):
                c.archive_files(zipped([('Presets.wandelbar-presets', b'x' * 1001)]), wrapper=True)

    def test_source_link_and_cdn_are_bound(self):
        self.assertTrue(c.allows_download(URL, URL))
        good = 'https://objects.githubusercontent.com/github-production-repository-file-5c1aeb/1341390246/31951170?X-Amz-Signature=test'
        self.assertTrue(c.allows_download(good, URL))
        for bad in [good.replace('31951170', '12'), good.replace('1341390246', '1'), good.replace('https:', 'http:'),
                    good.replace('objects.githubusercontent.com', 'objects.githubusercontent.com.evil.test'),
                    good.replace('objects.githubusercontent.com', 'user@objects.githubusercontent.com'), URL + '?token=x']:
            self.assertFalse(c.allows_download(bad, URL))

    def test_numeric_approver_not_login(self):
        bad = event()
        bad['sender'] = {'id': 1, 'login': 'alexiosus'}
        with self.assertRaises(ValueError):
            c.approval_request(bad, 'discussion')

    def test_approve_then_renew_preserves_hash(self):
        first = c.build_payload(baseline(), evidence(), event(), 'discussion', lambda _: post(), 10)
        renewed = c.build_payload(first, {'approval': None}, {}, 'schedule', lambda _: post(), 20)
        self.assertEqual(first['entries'], renewed['entries'])
        self.assertEqual(renewed['sequence'], 3)
        self.assertEqual(renewed['expiresAt'], 20 + 7 * 86400)

    def test_renewal_never_adds_existing_label(self):
        self.assertEqual(c.build_payload(baseline(), {'approval': None}, {}, 'schedule', lambda _: post(), 10)['entries'], [])

    def test_edit_delete_and_label_removal_revoke(self):
        first = c.build_payload(baseline(), evidence(), event(), 'discussion', lambda _: post(), 10)
        changed = post()
        changed['body'] += ' edited'
        unlabelled = post()
        unlabelled['labels']['nodes'] = []
        for current in [changed, unlabelled, None]:
            result = c.build_payload(first, {'approval': None}, {}, 'schedule', lambda _: current, 20)
            self.assertEqual(result['entries'], [])

    def test_race_and_forged_evidence_rejected(self):
        changed = post()
        changed['body'] += ' changed while downloading'
        with self.assertRaises(ValueError):
            c.build_payload(baseline(), evidence(), event(), 'discussion', lambda _: changed, 10)
        bad = evidence()
        bad['approval']['packageURL'] = 'https://evil.test/evil.zip'
        with self.assertRaises(ValueError):
            c.build_payload(baseline(), bad, event(), 'discussion', lambda _: post(), 10)

    def test_metadata_is_data_not_shell(self):
        current = post()
        current['title'] = '$(touch /tmp/should-not-exist)'
        result = c.build_payload(baseline(), evidence(), event(), 'discussion', lambda _: current, 10)
        self.assertEqual(result['entries'][0]['title'], current['title'])

    def test_json_and_text_reject_ambiguity(self):
        for text in ['{"x":1,"x":2}', '{"x": NaN}']:
            with self.assertRaises(ValueError):
                c.decode_json(text)
        with self.assertRaises(ValueError):
            c.clean_text('name\u202eexe', 100)

class ReviewRegressionTests(unittest.TestCase):
    def test_delayed_revocation_and_old_rerun(self):
        first = c.build_payload(baseline(), evidence(), event(), 'discussion', lambda _: post(), 10, event_order=10)
        removed = event()
        removed['action'] = 'unlabeled'
        revoked = c.build_payload(first, {'approval': None}, removed, 'discussion', lambda _: post(), 20, event_order=11)
        self.assertEqual(revoked['entries'], [])
        replay = c.build_payload(revoked, evidence(), event(), 'discussion', lambda _: post(), 30, event_order=10)
        self.assertEqual(replay['entries'], [])
        fresh = c.build_payload(revoked, evidence(), event(), 'discussion', lambda _: post(), 40, event_order=12)
        self.assertEqual(len(fresh['entries']), 1)
        old_remove = c.build_payload(fresh, {'approval': None}, removed, 'discussion', lambda _: post(), 50, event_order=11)
        self.assertEqual(len(old_remove['entries']), 1)

    def test_schedule_revocation_prevents_delayed_approval(self):
        first = c.build_payload(baseline(), evidence(), event(), 'discussion', lambda _: post(), 10, event_order=10)
        revoked = c.build_payload(first, {'approval': None}, {}, 'schedule', lambda _: None, 20, event_order=12)
        replay = c.build_payload(revoked, evidence(), event(), 'discussion', lambda _: post(), 30, event_order=11)
        self.assertEqual(replay['entries'], [])

    def test_not_found_is_deleted_but_permission_error_is_fatal(self):
        import subprocess
        missing = {'data': {'repository': {'discussion': None}}, 'errors': [{'type': 'NOT_FOUND', 'path': ['repository', 'discussion']}]}
        with patch.object(c.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1, json.dumps(missing), '')):
            self.assertIsNone(c.discussion(999999))
        missing['errors'][0]['type'] = 'FORBIDDEN'
        with patch.object(c.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1, json.dumps(missing), '')):
            with self.assertRaises(ValueError):
                c.discussion(999999)

    def test_invalid_optional_setting_and_builtin(self):
        manifest = c.decode_json(c.archive_files(package())['manifest.json'])
        for mutate in [lambda m: m.update(version=True),
                       lambda m: m['presets'][0]['settings'].update(shadowStrength='bad'),
                       lambda m: m.update(createdBy='я' * 600)]:
            bad = copy.deepcopy(manifest)
            mutate(bad)
            with self.assertRaises(ValueError):
                c.validate_package(zipped([('manifest.json', json.dumps(bad))]), URL.replace('.zip', '.wandelbar-presets'))
        bad = copy.deepcopy(manifest)
        bad['presets'][0]['settings']['textureID'] = 'nonexistent'
        bad['presets'][0]['texture'] = {'id': 'nonexistent', 'kind': 'builtIn'}
        with self.assertRaises(ValueError):
            c.validate_package(zipped([('manifest.json', json.dumps(bad))]), URL.replace('.zip', '.wandelbar-presets'))

class PreviewTests(unittest.TestCase):
    def metadata(self):
        sha = 'c' * 64
        return {'url': c.PREVIEW_ROOT + sha + '.png', 'sha256': sha, 'byteCount': 100, 'width': 2160, 'height': 696}

    def test_preview_metadata_is_bounded_and_pinned(self):
        value = self.metadata()
        self.assertEqual(c.preview_metadata(value), value)
        for key, bad in [('url', 'https://evil.test/x.png'), ('byteCount', c.MAX_PREVIEW + 1), ('width', 2161), ('height', 4097), ('sha256', '../x')]:
            changed = {**value, key: bad}
            with self.assertRaises(ValueError): c.preview_metadata(changed)

    def test_backfill_keeps_package_approval_and_revocation_drops_preview(self):
        first = c.build_payload(baseline(), evidence(), event(), 'discussion', lambda _: post(), 10, event_order=10)
        supplied = {'approval': None, 'previews': {'a' * 64: self.metadata()}}
        result = c.build_payload(first, supplied, {}, 'workflow_dispatch', lambda _: post(), 20, event_order=11)
        self.assertEqual(result['entries'][0]['preview'], self.metadata())
        self.assertEqual(result['entries'][0]['sha256'], first['entries'][0]['sha256'])
        self.assertEqual(result['approvals'], first['approvals'])
        revoked = c.build_payload(first, supplied, {}, 'schedule', lambda _: None, 30, event_order=12)
        self.assertEqual(revoked['entries'], [])

    def test_mismatched_preview_artifact_never_uploads(self):
        import tempfile
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / ('c' * 64 + '.png')
            path.write_bytes(b'x' * 100)
            with patch.object(c, 'gh') as api:
                with self.assertRaises(ValueError):
                    c.upload_previews({'previews': {'a' * 64: self.metadata()}}, folder)
                api.assert_not_called()
