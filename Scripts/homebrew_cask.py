#!/usr/bin/env python3
"""Generate the official cask only from a published stable release's checksums."""
import argparse
import json
from pathlib import Path
import re

REPOSITORY = 'alexiosus/WandelBar'


def make_cask(release, checksums):
    if release.get('draft') is not False or release.get('prerelease') is not False:
        raise ValueError('Homebrew requires a published stable release')
    tag = release.get('tag_name', '')
    if not re.fullmatch(r'v(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)', tag):
        raise ValueError('Expected a stable vMAJOR.MINOR.PATCH tag')
    version = tag[1:]
    if tuple(map(int, version.split('.'))) < (0, 2, 0):
        raise ValueError('Homebrew distribution starts with 0.2.0')
    filename = f'WandelBar-{version}-macOS-arm64.dmg'
    url = f'https://github.com/{REPOSITORY}/releases/download/{tag}/{filename}'
    matches = [a for a in release.get('assets', []) if a.get('name') == filename]
    if len(matches) != 1 or matches[0].get('browser_download_url') != url:
        raise ValueError('Missing official Apple silicon DMG')
    hashes = re.findall(r'^([0-9a-f]{64})  ' + re.escape(filename) + r'$', checksums, re.MULTILINE)
    if len(hashes) != 1:
        raise ValueError('Missing or ambiguous DMG SHA-256')
    digest = matches[0].get('digest')
    if digest and digest != 'sha256:' + hashes[0]:
        raise ValueError('GitHub asset digest does not match release checksums')
    return f'''cask "wandelbar" do
  version "{version}"
  sha256 "{hashes[0]}"

  url "https://github.com/{REPOSITORY}/releases/download/v#{{version}}/WandelBar-#{{version}}-macOS-arm64.dmg"
  name "WandelBar"
  desc "Customize the macOS menu bar with blur, color and textures"
  homepage "https://github.com/{REPOSITORY}"

  auto_updates true
  depends_on arch: :arm64
  depends_on macos: ">= :sonoma"

  app "WandelBar.app"
end
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('release', type=Path)
    parser.add_argument('checksums', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--readme', type=Path)
    args = parser.parse_args()
    cask = make_cask(json.loads(args.release.read_text()), args.checksums.read_text())
    if args.output.exists():
        old = re.search(r'^  version "([0-9.]+)"$', args.output.read_text(), re.MULTILINE)
        new = re.search(r'^  version "([0-9.]+)"$', cask, re.MULTILINE)
        if old and tuple(map(int, old[1].split('.'))) > tuple(map(int, new[1].split('.'))):
            raise ValueError('Refusing to downgrade the Homebrew cask')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(cask)
    if args.readme:
        args.readme.write_text(add_installation_instructions(args.readme.read_text()))


def add_installation_instructions(text):
    if '### Homebrew\n' in text:
        return text
    anchor = '## Build from source\n'
    if text.count(anchor) != 1:
        raise ValueError('Cannot find the README installation section')
    instructions = '''### Homebrew

Install from the official project tap:

```sh
brew tap alexiosus/wandelbar https://github.com/alexiosus/WandelBar
brew install --cask alexiosus/wandelbar/wandelbar
```

You can update from within WandelBar, or run
`brew upgrade --cask --greedy alexiosus/wandelbar/wandelbar`.

'''
    return text.replace(anchor, instructions + anchor)


if __name__ == '__main__':
    main()
