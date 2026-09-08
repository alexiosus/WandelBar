#!/usr/bin/env python3
"""Trusted catalogue automation. No archive bytes or private keys are logged."""
import argparse
import base64
import hashlib
import io
import json
import math
import os
from pathlib import Path
import re
import stat
import ssl
import struct
import subprocess
import tempfile
import time
import urllib.parse
import urllib.request
import zipfile
import zlib

REPO = 'alexiosus/WandelBar'
REPO_ID = 1341390246
APPROVER_ID = 48015759
LABEL = 'community-approved'
CATEGORY = 'Preset Exchange'
MAX_PACKAGE = 32 * 1024 * 1024
MAX_EXPANDED = 200 * 1024 * 1024
ATTACHMENT = re.compile(r'https://github\.com/user-attachments/files/([1-9][0-9]{0,15})/([A-Za-z0-9][A-Za-z0-9._-]{0,127}\.(?:zip|wandelbar-presets))\Z')
DIGEST = re.compile(r'[a-f0-9]{64}\Z')
BUILT_INS = {'built-in.' + name for name in ('azure-reflection', 'embedded-slate', 'classic-blue', 'ocean-blue', 'royal-noir', 'classic-olive', 'silver-glass', 'graphite-glass', 'coastal-light', 'coastal-dark', 'striped-light', 'striped-dark')}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def decode_json(data):
    def pairs(values):
        result = {}
        for key, value in values:
            require(key not in result, 'Duplicate JSON key')
            result[key] = value
        return result
    def invalid(_):
        raise ValueError('Non-finite JSON number')
    return json.loads(data, object_pairs_hook=pairs, parse_constant=invalid)


def bounded_json(path, limit=700_000):
    with open(path, 'rb') as stream:
        data = stream.read(limit + 1)
    require(len(data) <= limit, 'Oversized JSON')
    return decode_json(data)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def clean_text(value, limit):
    require(isinstance(value, str) and 0 < len(value.strip()) <= limit and len(value.encode('utf-8')) <= 1024, 'Invalid text length')
    require(all(ord(c) >= 32 and not 127 <= ord(c) <= 159 and
                not 0x202a <= ord(c) <= 0x202e and not 0x2066 <= ord(c) <= 0x2069 for c in value), 'Unsafe text')
    return value


def attachment_from_body(body):
    # Exactly one distinct package link; never guess which of several files was approved.
    links = set(re.findall(r'https://github\.com/user-attachments/files/[^\s<>"\)]+', body))
    links = {url for url in links if ATTACHMENT.fullmatch(url)}
    require(len(links) == 1, 'Post must contain exactly one ZIP/package attachment link')
    return links.pop()


def allows_download(url, original):
    match = ATTACHMENT.fullmatch(original)
    if not match:
        return False
    if url == original:
        return True
    parts = urllib.parse.urlsplit(url)
    # Bind CDN redirects to both this repository and the approved attachment ID.
    return (parts.scheme == 'https' and parts.netloc == 'objects.githubusercontent.com' and
            parts.path == f'/github-production-repository-file-5c1aeb/{REPO_ID}/{match[1]}' and
            not parts.fragment and len(parts.query) <= 8192 and not any(ord(c) < 32 for c in url))


class AttachmentRedirects(urllib.request.HTTPRedirectHandler):
    def __init__(self, original):
        self.original = original
        self.count = 0

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        self.count += 1
        require(self.count <= 3 and allows_download(newurl, self.original), 'Rejected attachment redirect')
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def download(url):
    require(ATTACHMENT.fullmatch(url), 'Invalid attachment URL')
    # No GitHub token, cookies, proxy credentials or browser session on attachment requests.
    context = ssl.create_default_context()
    if ssl.get_default_verify_paths().cafile is None and Path('/etc/ssl/cert.pem').is_file():
        context.load_verify_locations('/etc/ssl/cert.pem')
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), urllib.request.HTTPSHandler(context=context), AttachmentRedirects(url))
    with opener.open(url, timeout=60) as response:
        require(response.status == 200 and allows_download(response.url, url), 'Unexpected attachment response')
        require(int(response.headers.get('Content-Length', '0')) <= MAX_PACKAGE, 'Attachment too large')
        data = response.read(MAX_PACKAGE + 1)
    require(0 < len(data) <= MAX_PACKAGE, 'Attachment too large or empty')
    return data


def archive_files(data, wrapper=False):
    require(0 < len(data) <= MAX_PACKAGE, 'ZIP exceeds download limit')
    result = {}
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        infos = archive.infolist()
        require(0 < len(infos) <= (1 if wrapper else 102), 'Invalid ZIP entry count')
        total = 0
        for info in infos:
            name = info.filename
            require(name == info.orig_filename and '\x00' not in name and name not in result, 'Duplicate/invalid ZIP path')
            allowed = (name == 'Presets.wandelbar-presets' if wrapper else
                       name in ('manifest.json', 'textures/') or re.fullmatch(r'textures/[a-f0-9]{64}\.png', name))
            require(allowed, 'Unexpected ZIP entry')
            kind = stat.S_IFMT(info.external_attr >> 16)
            require(kind in (0, stat.S_IFDIR if name == 'textures/' else stat.S_IFREG), 'ZIP link or special file')
            require(info.flag_bits & 0x41 == 0 and info.compress_type in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED), 'Unsupported ZIP encoding')
            cap = MAX_PACKAGE if wrapper else (1024 * 1024 if name == 'manifest.json' else MAX_EXPANDED)
            total += info.file_size
            require(0 <= info.file_size <= cap and total <= (MAX_PACKAGE if wrapper else MAX_EXPANDED), 'ZIP expansion limit')
            require(name != 'textures/' or info.file_size == 0, 'Nonempty directory')
            # ZipFile verifies local/central names, overlapping entries, decompression and CRC.
            with archive.open(info) as stream:
                content = stream.read(cap + 1)
            require(len(content) == info.file_size and len(content) <= cap, 'ZIP size mismatch')
            result[name] = content
    return result


def validate_png(data):
    require(data[:8] == b'\x89PNG\r\n\x1a\n' and len(data) >= 33, 'Invalid PNG')
    cursor = 8
    first = True
    ended = False
    compressed = bytearray()
    expected = 0
    row_bytes = 0
    while cursor < len(data):
        require(cursor + 12 <= len(data), 'Truncated PNG')
        length = int.from_bytes(data[cursor:cursor+4], 'big')
        end = cursor + 12 + length
        require(end <= len(data), 'Truncated PNG chunk')
        kind = data[cursor+4:cursor+8]
        content = data[cursor+8:end-4]
        require(zlib.crc32(kind + content) & 0xffffffff == int.from_bytes(data[end-4:end], 'big'), 'PNG checksum mismatch')
        require(first or kind != b'IHDR', 'Duplicate PNG header')
        require(kind in (b'IHDR', b'PLTE', b'IDAT', b'IEND') or kind[0] & 32 != 0, 'Unknown critical PNG chunk')
        if first:
            require(kind == b'IHDR' and length == 13, 'Missing PNG header')
            width, height = struct.unpack('>II', content[:8])
            require(0 < width <= 4096 and 0 < height <= 4096, 'PNG dimensions exceed normalized texture limit')
            require(content[8:] == bytes([8, 6, 0, 0, 0]), 'Texture must be normalized non-interlaced RGBA8 PNG')
            row_bytes = width * 4 + 1
            expected = row_bytes * height
            first = False
        require(kind not in (b'acTL', b'fcTL', b'fdAT'), 'Animated PNG unsupported')
        if kind == b'IDAT':
            compressed.extend(content)
        cursor = end
        if kind == b'IEND':
            require(length == 0 and cursor == len(data), 'Unexpected bytes after PNG end')
            ended = True
    require(ended, 'Missing PNG end')
    decoder = zlib.decompressobj()
    pixels = decoder.decompress(compressed, expected + 1)
    require(len(pixels) == expected and decoder.eof and not decoder.unconsumed_tail and not decoder.unused_data, 'Invalid or oversized PNG pixel stream')
    require(all(value <= 4 for value in pixels[::row_bytes]), 'Invalid PNG row filter')


def validate_package(data, url):
    if url.endswith('.zip'):
        data = archive_files(data, wrapper=True)['Presets.wandelbar-presets']
    files = archive_files(data)
    require('manifest.json' in files, 'Missing manifest')
    manifest = decode_json(files['manifest.json'])
    require(manifest.get('format') == 'com.alexeremeev.WandelBar.preset-package' and type(manifest.get('version')) is int and manifest['version'] == 1, 'Unsupported preset format')
    clean_text(manifest.get('createdBy'), 1024)
    presets = manifest.get('presets')
    require(isinstance(presets, list) and 0 < len(presets) <= 100, 'Invalid preset count')
    seen, textures, names = set(), set(), []
    for preset in presets:
        identity = clean_text(preset.get('sourceID'), 1024)
        require(identity not in seen, 'Duplicate preset ID')
        seen.add(identity)
        names.append(clean_text(preset.get('name'), 100))
        settings = preset.get('settings')
        require(isinstance(settings, dict), 'Missing settings')
        for field in ('blurRadiusPoints', 'blurLengthPoints', 'fadeLengthPoints', 'tintStrength', 'saturation'):
            require(type(settings.get(field)) in (float, int) and math.isfinite(settings[field]), 'Invalid numeric setting')
        for field in ('shadowStrength', 'shadowLengthPoints', 'textureStrength', 'textureVerticalPosition'):
            if field in settings:
                require(type(settings[field]) in (float, int) and math.isfinite(settings[field]), 'Invalid optional numeric setting')
        if 'shadowEnabled' in settings:
            require(type(settings['shadowEnabled']) is bool, 'Invalid legacy shadow setting')
        for field, values in [('textureBlendMode', {'normal', 'screen', 'multiply', 'softLight', 'overlay'}), ('textureLayoutMode', {'fitWidth', 'fillBand', 'stretchToBand'})]:
            if field in settings:
                require(isinstance(settings[field], str) and settings[field] in values, 'Unsupported texture mode')
        tint = settings.get('tintColor')
        require(isinstance(tint, dict) and all(type(tint.get(c)) in (float, int) and math.isfinite(tint[c]) for c in ('red', 'green', 'blue')), 'Invalid tint')
        require(type(settings.get('solidTint')) is bool, 'Invalid solid tint')
        texture = preset.get('texture')
        require((texture or {}).get('id') == settings.get('textureID'), 'Texture/settings mismatch')
        if not texture:
            continue
        if texture.get('kind') == 'builtIn':
            require(texture.get('id') in BUILT_INS and texture.get('path') is None and texture.get('sha256') is None, 'Invalid built-in texture')
        else:
            sha = texture.get('sha256', '')
            require(texture.get('kind') == 'embedded' and DIGEST.fullmatch(sha), 'Invalid embedded texture')
            name = 'textures/' + sha + '.png'
            require(texture.get('path') == name and texture.get('id') == 'custom.' + sha and name in files, 'Missing texture')
            require(digest(files[name]) == sha, 'Texture digest mismatch')
            if name not in textures:
                validate_png(files[name])
            textures.add(name)
    require(textures == {n for n in files if n.endswith('.png')}, 'Unreferenced texture')
    return names


def gh(path, payload=None, method=None, allow_missing_discussion=False):
    args = ['gh', 'api', path]
    if method:
        args += ['--method', method]
    if payload is not None:
        args += ['--input', '-']
    result = subprocess.run(args, input=json.dumps(payload) if payload is not None else None,
                            text=True, capture_output=True, check=False)
    # Error bodies can contain untrusted post text. Do not echo them into Actions commands/logs.
    parsed = decode_json(result.stdout) if result.stdout.strip() else None
    missing = (allow_missing_discussion and isinstance(parsed, dict) and parsed.get('errors') and
               all(e.get('type') == 'NOT_FOUND' and e.get('path') == ['repository', 'discussion'] for e in parsed['errors']) and
               (parsed.get('data') or {}).get('repository', {}).get('discussion', 'not-null') is None)
    require(result.returncode == 0 or missing, 'GitHub API request failed: ' + path.split('?')[0])
    return parsed


def discussion(number):
    require(type(number) is int and 0 < number < 10**16, 'Invalid discussion number')
    query = '''query($number:Int!) { repository(owner:"alexiosus",name:"WandelBar") {
      discussion(number:$number) { number title body url author { login } category { name }
        labels(first:100) { nodes { name } } } } }'''
    data = gh('graphql', {'query': query, 'variables': {'number': number}}, allow_missing_discussion=True)
    if data.get('errors'):
        require(all(e.get('type') == 'NOT_FOUND' and e.get('path') == ['repository', 'discussion'] for e in data['errors']), 'Cannot verify current discussion state')
    return data['data']['repository']['discussion']


def is_current(post, body_hash):
    return (post is not None and post['category']['name'] == CATEGORY and
            LABEL in [label['name'] for label in post['labels']['nodes']] and
            digest(post['body'].encode()) == body_hash)


def approval_request(event, event_name):
    if event_name != 'discussion' or event.get('action') != 'labeled' or event.get('label', {}).get('name') != LABEL:
        return None
    require(event.get('repository', {}).get('id') == REPO_ID and event['repository'].get('full_name') == REPO, 'Wrong repository')
    require(event.get('sender', {}).get('id') == APPROVER_ID, 'Only the configured maintainer can approve presets')
    post = event['discussion']
    return {'number': post['number'], 'bodyHash': digest(post['body'].encode()), 'packageURL': attachment_from_body(post['body'])}


def validate_event(event, event_name):
    request = approval_request(event, event_name)
    if request is None:
        return {'approval': None}
    current = discussion(request['number'])
    require(is_current(current, request['bodyHash']), 'Post changed or approval was removed; reapply the label after review')
    data = download(request['packageURL'])
    names = validate_package(data, request['packageURL'])
    # Titles/descriptions are generated by the signer from fresh metadata; the validator
    # delivers only bounded, typed evidence. It never sees a signing key.
    return {'approval': {**request, 'sha256': digest(data), 'byteCount': len(data), 'presetCount': len(names)}}


def build_payload(baseline, evidence, event, event_name, lookup, now, event_order=1):
    entries = {entry['sha256']: entry for entry in baseline['entries']}
    retained = []
    watermarks = dict(baseline.get('eventWatermarks', {}))
    require(type(event_order) is int and event_order > 0, 'Invalid workflow run number')
    effective_event = event
    revoked_number = None
    if event_name == 'discussion':
        require(event.get('repository', {}).get('id') == REPO_ID and event['repository'].get('full_name') == REPO, 'Wrong repository')
        number = event['discussion']['number']
        require(type(number) is int and number > 0, 'Invalid discussion number')
        relevant = event.get('action') not in ('labeled', 'unlabeled') or event.get('label', {}).get('name') == LABEL
        if relevant and event_order > watermarks.get(str(number), 0):
            watermarks[str(number)] = event_order
            if event.get('action') in ('unlabeled', 'edited', 'deleted', 'transferred', 'category_changed'):
                revoked_number = number
        else:
            effective_event = {}
    for approval in baseline.get('approvals', []):
        post = lookup(approval['number'])
        if (approval.get('approvedBy') == APPROVER_ID and is_current(post, approval['bodyHash']) and
                attachment_from_body(post['body']) == approval['packageURL']):
            if approval['number'] != revoked_number:
                retained.append(approval)
        else:
            identity = str(approval['number'])
            watermarks[identity] = max(watermarks.get(identity, 0), event_order)
    request = approval_request(effective_event, event_name)
    if request is not None:
        verified = evidence.get('approval')
        require(isinstance(verified, dict) and all(verified.get(k) == v for k, v in request.items()), 'Validation evidence does not match approval event')
        require(isinstance(verified.get('sha256'), str) and DIGEST.fullmatch(verified['sha256']) and
                type(verified.get('byteCount')) is int and 0 < verified['byteCount'] <= MAX_PACKAGE and
                type(verified.get('presetCount')) is int and 0 < verified['presetCount'] <= 100, 'Invalid validation evidence')
        post = lookup(request['number'])
        require(is_current(post, request['bodyHash']), 'Post changed during validation; reapply approval')
        require(attachment_from_body(post['body']) == request['packageURL'], 'Attachment changed')
        retained = [a for a in retained if a['number'] != request['number']]
        entry = {'id': verified['sha256'], 'sha256': verified['sha256'], 'byteCount': verified['byteCount'],
                 'packageURL': request['packageURL'], 'sourceURL': post['url'],
                 'title': clean_text(post['title'], 100), 'author': clean_text((post.get('author') or {}).get('login'), 100),
                 'summary': f"{verified['presetCount']} preset(s) shared in Preset Exchange.", 'tags': []}
        # An identical package is one catalogue entry, with its latest approved source.
        retained = [a for a in retained if a['sha256'] != verified['sha256']]
        entries[verified['sha256']] = entry
        retained.append({**request, 'sha256': verified['sha256'], 'approvedBy': APPROVER_ID})
    retained.sort(key=lambda a: a['number'])
    result = {**baseline, 'schemaVersion': 1, 'minimumClientVersion': 2, 'sequence': baseline['sequence'] + 1,
              'issuedAt': now, 'expiresAt': now + 7 * 86400, 'approvals': retained, 'eventWatermarks': watermarks,
              'entries': [entries[a['sha256']] for a in retained]}
    require(len(retained) <= 200 and len(watermarks) <= 10_000, 'Catalogue history is full')
    return result


def swift_tool(*args):
    subprocess.run(['swift', 'Scripts/catalog_sign.swift', *args], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def publish(evidence, event, event_name):
    # The signing environment passes the base64 key only to this step. Never place it
    # in argv, artifacts, GITHUB_OUTPUT or the checked-out working tree.
    secret = os.environ.pop('CATALOG_SIGNING_KEY', None)
    require(secret is not None, 'Signing secret is not configured')
    key = base64.b64decode(secret, validate=True)
    require(len(key) == 32, 'Signing key must contain 32 bytes')
    with tempfile.TemporaryDirectory(prefix='wandelbar-sign-') as folder:
        root = Path(folder)
        key_path = root / 'key'
        fd = os.open(key_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'wb') as stream:
            stream.write(key)
        for attempt in range(5):
            current = gh(f'repos/{REPO}/contents/Community/catalog.json?ref=master')
            envelope = base64.b64decode(current['content'], validate=False)
            require(len(envelope) <= 1_048_576, 'Oversized existing catalogue')
            (root / 'current.json').write_bytes(envelope)
            swift_tool('verify', '--allow-expired', '--config', 'Sources/WandelBar/Resources/Community/configuration.json', '--input', str(root / 'current.json'))
            baseline = decode_json(base64.b64decode(decode_json(envelope)['payload'], validate=True))
            payload = build_payload(baseline, evidence, event, event_name, discussion, int(time.time()), event_order=int(os.environ['GITHUB_RUN_NUMBER']))
            if payload['entries'] == baseline['entries'] and payload['approvals'] == baseline.get('approvals', []) and payload.get('eventWatermarks', {}) == baseline.get('eventWatermarks', {}) and baseline['expiresAt'] > time.time() + 3 * 86400:
                print('Catalogue unchanged; renewal not yet needed.')
                return
            (root / 'payload.json').write_text(json.dumps(payload, ensure_ascii=False), encoding='utf-8')
            swift_tool('sign', '--key', str(key_path), '--input', str(root / 'payload.json'), '--output', str(root / 'signed.json'))
            swift_tool('verify', '--config', 'Sources/WandelBar/Resources/Community/configuration.json', '--input', str(root / 'signed.json'))
            content = base64.b64encode((root / 'signed.json').read_bytes()).decode()
            try:
                gh(f'repos/{REPO}/contents/Community/catalog.json', {
                    'message': f"Update community catalogue (sequence {payload['sequence']})",
                    'content': content, 'sha': current['sha'], 'branch': 'master'}, 'PUT')
                print(f"Published catalogue sequence {payload['sequence']}; {len(payload['entries'])} entries.")
                return
            except ValueError:
                if attempt == 4:
                    raise
                # Compare-and-swap conflict: reverify latest signed state and reapply
                # this exact event. Concurrent approvals never overwrite each other.
                time.sleep(1)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('command', choices=['validate', 'publish', 'inspect'])
    parser.add_argument('--event', default=os.environ.get('GITHUB_EVENT_PATH'))
    parser.add_argument('--event-name', default=os.environ.get('GITHUB_EVENT_NAME', 'workflow_dispatch'))
    parser.add_argument('--evidence', default='validation.json')
    parser.add_argument('--url')
    args = parser.parse_args()
    if args.command == 'inspect':
        data = download(args.url)
        names = validate_package(data, args.url)
        print(json.dumps({'sha256': digest(data), 'byteCount': len(data), 'presetCount': len(names)}))
        return
    event = bounded_json(args.event, 1_048_576) if args.event else {}
    if args.command == 'validate':
        Path(args.evidence).write_text(json.dumps(validate_event(event, args.event_name)), encoding='utf-8')
        print('Validation finished. No package bytes retained.')
    else:
        publish(bounded_json(args.evidence, 4096), event, args.event_name)


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        # No raw network response, attachment contents, or secret-bearing exception.
        detail = str(error) if type(error) is ValueError else type(error).__name__
        print('Catalogue operation failed: ' + detail, file=__import__('sys').stderr)
        raise SystemExit(1)
