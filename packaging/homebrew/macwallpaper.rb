cask "macwallpaper" do
  version "0.1.0"
  sha256 "7d0f2128a92ccee5954faf0da9bb1e3b68e316d14b54dd06e44f15a6b14b48da"

  url "https://github.com/Strangelight-Merser/mac-wallpaper/releases/download/v#{version}/MacWallpaper-#{version}.zip"
  name "MacWallpaper"
  desc "Plays Wallpaper Engine wallpapers on the desktop"
  homepage "https://github.com/Strangelight-Merser/mac-wallpaper"

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
