cask "brewmenu" do
  version "VERSION_PLACEHOLDER"
  sha256 "SHA256_PLACEHOLDER"

  url "https://github.com/dotfn/brewmenu/releases/download/v#{version}/BrewMenu-#{version}.zip"
  name "BrewMenu"
  desc "Homebrew health monitor for macOS menu bar"
  homepage "https://github.com/dotfn/brewmenu"

  depends_on macos: :sequoia

  app "BrewMenu.app"

  # `postflight` (block form) is deprecated by Homebrew as of 7.0 — hard error on
  # 2027-12-11. `postflight_steps`' `run` step is the declarative replacement;
  # `{{appdir}}` is its install-time token for the same path `#{appdir}` gave above.
  postflight_steps do
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{appdir}}/BrewMenu.app"]
  end

  zap trash: [
    "~/Library/Application Support/BrewMenu",
    "~/Library/Preferences/com.brewmenu.app.plist",
  ]
end
