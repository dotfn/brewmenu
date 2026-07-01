cask "brewmenu" do
  version "VERSION_PLACEHOLDER"
  sha256 "SHA256_PLACEHOLDER"

  url "https://github.com/dotfn/brewmenu/releases/download/v#{version}/BrewMenu-#{version}.zip"
  name "BrewMenu"
  desc "Homebrew health monitor for macOS menu bar"
  homepage "https://github.com/dotfn/brewmenu"

  depends_on macos: :sonoma

  app "BrewMenu.app"

  zap trash: [
    "~/Library/Application Support/BrewMenu",
    "~/Library/Preferences/com.brewmenu.app.plist",
  ]

  caveats <<~EOS
    BrewMenu is not notarized by Apple. If macOS blocks the app on first launch:

      System Settings → Privacy & Security → "Open Anyway"

    Or via Terminal:
      sudo xattr -rd com.apple.quarantine /Applications/BrewMenu.app
  EOS
end
