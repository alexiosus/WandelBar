# Community catalogue maintenance

Packages stay in GitHub Discussions attachments. The signed index is served from
`https://raw.githubusercontent.com/alexiosus/WandelBar/master/Community/catalog.json`.
The default branch is **master**, not main. This client supports protocol capability
2, including attachment ZIP unwrapping. Builds made before this change need an app
update; adding subsequent presets does not require another app release.

## Approve and remove presets

1. Open a post in **Preset Exchange** with exactly one ZIP/package attachment link.
   The app's sharing output works: `Presets.zip` contains one root file named
   `Presets.wandelbar-presets`.
2. Check redistribution permission and review the package in WandelBar's import preview.
3. Apply **community-approved**. Only the configured maintainer account (GitHub
   numeric ID `48015759`, currently `alexiosus`) can authorize an addition.
4. Check **Actions → Community catalogue**. After success, refresh Community Presets.

Removing the label removes the entry on the next successful workflow run. Editing
any part of the post invalidates its recorded approval. Review it again, remove the
label and add it again. A remaining label does not approve replacement bytes.
Deleted/transferred posts and posts outside Preset Exchange are also excluded.
A pack can contain several presets and occupies one gallery card.

## Trust and automation

The read-only validation job checks the event, numeric approver ID, live post body,
attachment URL, ZIP structure, size limits, CRCs, manifest, texture digests and bounded
normalized PNG pixel streams. It has **no signing secret**. The separate signing job
receives only a small JSON record, rechecks the approval and current post, verifies
the previous signed catalogue, then signs and updates JSON only. Archive contents
are never executed. Discussion text is never interpolated into shell code.
GitHub Actions dependencies are pinned to full commit hashes.

Downloads and the inner package are limited to 32 MiB, with at most 100 presets,
100 textures and 200 MiB expanded package contents. The app independently checks
signed size and SHA-256 before unpacking, then runs its normal import validation and
confirmation. Catalogue inclusion does not bypass user confirmation.
CDN redirects must match the official repository ID and approved attachment ID.
Index requests cannot redirect to attachments. The app needs no GitHub token/login.

The signed envelope contains base64 `payload` and `signature`. The payload records
schema 1, client capability 2, a monotonically increasing sequence, Unix timestamps,
entries, and signed approval records (discussion number, body hash, attachment URL,
file hash and approver). Signed per-discussion workflow-run watermarks retain revocation history, so rerunning an old approval cannot restore a removed preset. Concurrent updates use file-SHA compare-and-swap and retries.

Newly published catalogues last **7 days**. A daily workflow renews them when fewer
than 3 days remain, retaining approved hashes and never silently approving new files.
GitHub schedules may be delayed or disabled; use **Run workflow** to retry/renew.
Offline clients may retain a removed preset until their signed catalogue expires.
An inaccessible API fails the update rather than trusting uncertain approval state.

## Signing key

The **community-catalog** GitHub environment permits only the `master` branch.
Its **CATALOG_SIGNING_KEY** secret contains the base64-encoded 32-byte Ed25519 key.
Only the signing step receives it. It is decoded into a temporary owner-only file
outside the checkout and removed on exit. It never belongs in logs, artifacts,
workflow outputs, the app or the repository. Repository administrators and changes
to trusted workflow code remain part of the trust boundary.

The local original is `~/.config/wandelbar/catalog-signing.key` with mode 0600.
Keep an encrypted backup. Do not regenerate it to add presets. It is independent
of Developer ID, app signing and notarization.

Check the key without printing it:

```sh
swift Scripts/catalog_sign.swift check-key \
  --key "$HOME/.config/wandelbar/catalog-signing.key" \
  --config Sources/WandelBar/Resources/Community/configuration.json
```

Never paste the key into a discussion, issue or chat. To replace the environment
secret from the local original, pass base64 bytes directly to `gh secret set` through
stdin, without shell tracing or a secret value in command-line arguments. Suspected
compromise requires rotation and an app release pinning the new public key.
Removing the environment secret stops automated signing.

## Verification

```sh
python3 -m unittest discover -s Tests/CommunityAutomation -v
swift test
swift Scripts/catalog_sign.swift verify \
  --config Sources/WandelBar/Resources/Community/configuration.json \
  --input Community/catalog.json
```

`--allow-expired` on **verify** authenticates old state for renewal; signing still
rejects expired payloads. `inspect --url` on the Python tool validates an attachment
without approving, retaining, signing or publishing it. App releases should bundle
a current verified copy of the signed index in `Resources/Community/catalog.json`.
