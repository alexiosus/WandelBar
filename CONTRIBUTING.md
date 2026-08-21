# Contributing to WandelBar

Thanks for your interest! WandelBar is a small, focused utility, so contributions of
all sizes are welcome.

## Getting started

```sh
git clone https://github.com/alexiosus/WandelBar.git
cd WandelBar
swift build            # debug build
swift test             # regression tests
./Scripts/package_app.sh   # build + package Build/WandelBar.app
```

Requires macOS 14+ and a recent Swift toolchain (Swift 6).

## Reporting bugs

Because WandelBar depends on undocumented macOS internals (the active Space via SkyLight
and the wallpaper store format), behavior can change between macOS releases. When
filing an issue, please include:

- Your **macOS version** and Mac model.
- Whether you use multiple displays and/or multiple Spaces.
- The wallpaper type (image file, dynamic, or a Photos asset).
- What you expected vs. what happened.

## Pull requests

- Keep the style consistent with the surrounding code (Swift, `@MainActor` UI, small
  focused types).
- Make sure `swift test` and `swift build -c release` succeed with no new warnings.
- Describe *why* the change is needed, not just what it does.
- One logical change per PR where possible.

## Project layout

```
Sources/WandelBar/
  main.swift                  App entry point (accessory app)
  AppDelegate.swift           Menu bar item + popover host
  MenuBarPopoverView.swift    SwiftUI popover + view model
  WallpaperController.swift    Enable/disable, apply, restore, per-Space settings
  WallpaperRenderer.swift      Core Image blur + tint + saturation pipeline
  WallpaperStoreResolver.swift Finds the real wallpaper source (SkyLight/QuickLook/Photos)
  FileCacheKey.swift          Collision-resistant cache identities
  WallpaperEffectSettings.swift Settings model + storage
  DesktopState.swift           Display/wallpaper snapshots
Tests/WandelBarTests/           Resolver, cache and settings regression tests
Scripts/package_app.sh        Builds and packages the .app bundle
```

By contributing you agree that your contributions are licensed under the
[GNU General Public License version 3](LICENSE) only (`GPL-3.0-only`). The project name, logo, and
app icon are covered separately by the [branding policy](BRANDING.md).
