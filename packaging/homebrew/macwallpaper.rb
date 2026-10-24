cask "macwallpaper" do
  version "0.0.0-dev"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/OWNER/REPO/releases/download/v#{version}/MacWallpaper-#{version}.zip"
  name "MacWallpaper"
  desc "Plays Wallpaper Engine wallpapers on the desktop"
  homepage "https://github.com/OWNER/REPO"

  depends_on arch: :arm64
  depends_on macos: ">= :sonoma"

  app "MacWallpaper.app"

  zap trash: [
    "~/Library/Application Support/MacWallpaper",
    "~/Library/Caches/MacWallpaper",
    "~/Library/Preferences/dev.macwallpaper.app.plist",
  ]

  caveats <<~EOS
    MacWallpaper is ad-hoc signed and is not notarized.
    If macOS blocks opening it, allow this app in System Settings > Privacy & Security > Open Anyway.
  EOS
end
