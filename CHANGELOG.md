# Changelog

## 0.2.0

### New

- **Community Gallery:** browse approved preset packages with expandable previews, directly
  from the preset catalog. Previously loaded previews are available offline.
- **Share to Discussions:** prepare a post, a preset package and a sharp preview using the sample
  or current wallpaper. Drag all attachments into GitHub together and publish when ready.
- **Preset organization:** search names and tags, filter favorites, and undo the last preset application.
- **First-launch guidance:** a one-time reminder helps you disable the macOS menu bar background.
- **About and maintenance:** official links, copyright, Ko-fi support, third-party notices and
  tools for removing unused textures and optionally cleaning the macOS wallpaper cache.
- **Installation and updates:** signed and notarized releases, Homebrew support, and in-app
  update checks with optional automatic downloads and installation.

### Improvements and fixes

- Preset import and export run in the background and can be cancelled. Import lets you select
  presets, preserves existing names and rejects damaged or unsafe packages.
- Imported presets now show the correct wallpaper in the catalog, with more reliable preview refreshes.
- Fixed texture scaling in preset previews so fade transitions match the desktop treatment.
- Utility windows are easier to find in the Dock and bring back to the foreground.
- Fixed the missing Applications folder icon in the DMG installer on macOS Tahoe.
- Improved cleanup of unused wallpapers. System cache cleanup is off by default, avoiding its
  unsolicited cross-app access prompt on launch.

## 0.1.0

- Initial public release with editable menu bar treatments, built-in presets, custom textures,
  per-Space settings and wallpaper restoration.
