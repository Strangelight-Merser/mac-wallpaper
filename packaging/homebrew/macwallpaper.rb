cask "macwallpaper" do
  version "0.1.0"
  sha256 "42736289806e8c5474030528f6ab99a78b8042e0b5d5b7ccc41cd72596ce59ea"

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
