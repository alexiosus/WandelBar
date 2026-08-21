<p align="center">
  <img src="docs/icon.png" width="136" alt="WandelBar app icon">
</p>

<h1 align="center">WandelBar</h1>

<p align="center">
  <strong>Build your own background for the macOS menu bar.</strong><br>
  Restore contrast, soften a busy wallpaper, or give the bar a completely different character.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14%2B-2f81f7" alt="macOS 14 or later">
  <img src="https://img.shields.io/badge/Apple%20Silicon-arm64-7c5cff" alt="Apple Silicon">
  <img src="https://img.shields.io/badge/Swift-6.0-f05138" alt="Swift 6.0">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL--3.0--only-3da639" alt="GNU GPL version 3"></a>
</p>

<p align="center">
  <img src="docs/comparison.png" width="620" alt="One wallpaper with several WandelBar menu bar treatments">
</p>

WandelBar is a native macOS utility that turns the strip behind the menu bar into a customizable
part of the desktop. It works with your current wallpaper and lets you add blur, tint, shadow,
texture, and other treatments without replacing the menu bar itself.

## Why it exists

macOS Tahoe hides the menu bar background by default. The cleaner appearance works on some
wallpapers, but on bright or detailed images it can make menu bar icons and text difficult to read.

There is currently a system setting that brings the background back, but it offers one fixed result
and may change along with future versions of macOS. WandelBar started as a way to restore contrast
without depending on that single system treatment. It soon became something broader: a way to make
the bar fit the wallpaper, recreate an older desktop style, or design an entirely personal surface.

The name is a bilingual wordplay: the German adjective *wandelbar* means “changeable,” while the
app makes the menu bar itself changeable.

> [!NOTE]
> WandelBar is designed primarily for macOS Tahoe. It can run on macOS 14 Sonoma and later, but on
> releases before Tahoe the system menu bar background cannot be disabled. It therefore covers most
> of WandelBar's treatment, leaving little practical reason to use the app there.

## What you can customize

- **Surface:** blur radius, band height, edge fade, shadow strength, and shadow length.
- **Color:** solid or gradient tint, custom tint color, opacity, and saturation.
- **Texture:** bundled or imported PNG, JPEG, and HEIC images with blend, layout, position, and
  strength controls.
- **Scope:** use one design as the default or create an explicit override for the current desktop
  Space.
- **System behavior:** launch at login, keep the original wallpaper on the lock screen, and enable or
  disable the effect at any time.

Changes are rendered as you make them. WandelBar follows wallpaper, display, and Space changes, and
restores the original wallpaper when the effect is turned off.

## Preset catalog

### See the [complete preset catalog](docs/PRESETS.md).

The visual catalog previews every preset on the current wallpaper, so you can compare treatments
before applying one.

The app includes **26 built-in presets** across four collections:

| Collection | Style |
| --- | --- |
| **Basic** | Flexible starting points from a subtle wash to clear blur |
| **Color & Tone** | Dark glass, solid bars, monochrome, vivid color, and tinted treatments |
| **Cupertino** | Striped surfaces, metallic glass, and coastal translucent treatments |
| **Redmond** | Glossy blue, olive, slate, and noir treatments with a retro PC character |

Every preset remains fully editable after it is applied. Use the **Save Current** card to capture
your changes as a personal preset. Presets in **My Presets** can be renamed or deleted directly from
their cards.

### Share complete preset packages

Personal presets can be exported as a single `.wandelbar-presets` file. A package contains the
complete effect settings and embeds any custom textures used by the selected presets, making it easy
to share a finished collection without sending separate image files.

Importing first shows a preview of what will be added. Existing presets are not overwritten:
conflicting names receive an `(Imported)` suffix, and imported presets are not applied automatically.
Import and export controls are available in the preset catalog.

Discover community-made presets in the
[Preset Exchange](https://github.com/alexiosus/WandelBar/discussions/categories/preset-exchange). To
publish your own collection, follow the
[preset sharing guide](https://github.com/alexiosus/WandelBar/discussions/1).

## Getting started

1. Open WandelBar and click its icon in the menu bar.
2. Turn the app on. WandelBar saves the original wallpaper before applying its first effect.
3. Open **Preset** and choose a starting point, or adjust the controls manually.
4. Use **Default** for the shared design, or **This Space** for the current desktop Space.
5. Optionally enable **Launch at Login** or **Don't Apply on Lock Screen**.

> [!NOTE]
> If the wallpaper is stored in a protected folder such as Downloads or Pictures, macOS may ask
> WandelBar for access to that folder. This is expected: the permission lets the app read the
> wallpaper file so it can generate previews and apply treatments. WandelBar does not use it to
> browse unrelated files.

Opening `WandelBar.app` again while the app is already running brings the existing settings popover
forward.

<p align="center">
  <img src="docs/panel.png" width="620" alt="Main settings panel and presets catalog">
</p>

## Download and install

Download the latest DMG from [GitHub Releases](https://github.com/alexiosus/WandelBar/releases).

1. Open the downloaded `.dmg` file.
2. Drag **WandelBar** to **Applications**.
3. Try to open **WandelBar** once. When macOS displays the security warning, click **Done**.
4. Open **System Settings → Privacy & Security**, scroll to **Security**, and click
   **Open Anyway** next to the WandelBar message.
5. Confirm with **Open** and authenticate if macOS asks you to.

> [!IMPORTANT]
> The current preview releases are not signed with an Apple Developer ID or notarized by Apple, so
> macOS blocks the normal first launch. **Open Anyway** appears only after an attempted launch and
> remains available for about an hour. Once approved, WandelBar opens normally on subsequent
> launches. Download releases only from this repository. See
> [Apple's instructions for opening an app from an unknown developer](https://support.apple.com/guide/mac-help/-mh40616/mac).

Current release builds support Apple silicon Macs (`arm64`). macOS Tahoe still supports a small
number of Intel Macs, but an Intel release is not currently provided.

## Build from source

To build and package WandelBar locally:

```sh
git clone https://github.com/alexiosus/WandelBar.git
cd WandelBar
./Scripts/package_app.sh
open Build/WandelBar.app
```

The script creates an ad-hoc signed application at `Build/WandelBar.app`. To create the same DMG used
for GitHub releases:

```sh
./Scripts/create_dmg.sh
```

### Requirements

- An Apple silicon Mac for prebuilt releases
- macOS 14 Sonoma or later; macOS Tahoe is strongly recommended
- A still-image wallpaper or a Photos wallpaper that can be exported locally
- Swift 6 when building from source

## How it works

WandelBar finds the wallpaper assigned to each active display and Space, renders a screen-sized copy
with a Core Image treatment across the top, and asks macOS to use the generated image as the desktop
wallpaper. The app modifies a copy; it never edits the source image.

Saved originals, generated wallpapers, and textures live under
`~/Library/Application Support/WandelBar`; settings and presets are stored in the app's local
preferences. Rendering happens locally and off the main thread.

## Privacy

WandelBar has no accounts, analytics, or network service. Wallpapers, textures, presets, packages,
and generated files remain on the Mac. Photos access is requested only when it is needed to export a
wallpaper from the Photos library; macOS may first download that asset from iCloud.

## Limitations

- WandelBar uses undocumented SkyLight APIs and macOS wallpaper-store data to identify active Spaces
  and their wallpaper sources. These internals can change in a macOS update.
- Full-screen Spaces are left untouched because the public desktop API cannot address them
  independently.
- Video and animated wallpapers, including Aerials and the animated Macintosh wallpaper, are not
  supported. WandelBar detects them and leaves the desktop unchanged instead of replacing the moving
  wallpaper with a still frame.
- Photos shuffle and live-provider configurations cannot be reconstructed through the public desktop
  API. While WandelBar is active, the currently visible Photos asset is treated as a still image.
- macOS chooses light or dark menu bar content based on wallpaper brightness. An unusually bright
  treatment can therefore change the system icon appearance.

## Development

```sh
swift build
swift test
./Scripts/package_app.sh
```

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for the project layout and
bug-reporting checklist.

## Trademark notice

WandelBar is an independent project and is not affiliated with, sponsored by, or endorsed by
Apple Inc. macOS is a trademark of Apple Inc., registered in the U.S. and other countries and
regions. The WandelBar name, logo, and app icon are reserved for official builds; forks and modified
distributions should use different branding. See the [branding policy](BRANDING.md) for details.

## License

WandelBar's source code and documentation are free software licensed under the
[GNU General Public License version 3](LICENSE) only (`GPL-3.0-only`), except where otherwise noted.
Copyright © 2026 Alexey Eremeev.
