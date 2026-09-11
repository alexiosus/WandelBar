cask "wandelbar" do
  version "0.2.0"
  sha256 "7fbb12edc635998320aa43bccdb7efd85b12ec5a0b8878a9dcd6173fb931c523"

  url "https://github.com/alexiosus/WandelBar/releases/download/v#{version}/WandelBar-#{version}-macOS-arm64.dmg"
  name "WandelBar"
  desc "Customize the macOS menu bar with blur, color and textures"
  homepage "https://github.com/alexiosus/WandelBar"

  auto_updates true
  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "WandelBar.app"
end
