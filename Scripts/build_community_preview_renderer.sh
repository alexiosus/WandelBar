#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p Build
swiftc -O -swift-version 6 -parse-as-library \
  Sources/WandelBar/WallpaperIdentity.swift \
  Sources/WandelBar/DesktopState.swift \
  Sources/WandelBar/FileCacheKey.swift \
  Sources/WandelBar/WallpaperEffectSettings.swift \
  Sources/WandelBar/WallpaperRenderer.swift \
  Sources/WandelBar/TextureAsset.swift \
  Sources/WandelBar/PresetPackageManifest.swift \
  Sources/WandelBar/PresetPreviewContext.swift \
  Sources/WandelBar/SharePreviewRenderer.swift \
  Scripts/community_preview_renderer.swift \
  -o Build/CommunityPreviewRenderer
