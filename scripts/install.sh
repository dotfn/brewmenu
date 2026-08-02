#!/bin/bash
# Unattended installer: installs Homebrew if missing, then installs BrewMenu.
# Usage: curl -fsSL https://raw.githubusercontent.com/dotfn/brewmenu/main/scripts/install.sh | bash
set -euo pipefail

if ! command -v brew >/dev/null 2>&1; then
    echo "→ Homebrew not found, installing…"
    NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

    if [[ -x /opt/homebrew/bin/brew ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [[ -x /usr/local/bin/brew ]]; then
        eval "$(/usr/local/bin/brew shellenv)"
    fi
fi

echo "→ Installing BrewMenu…"
brew install --cask dotfn/tap/brewmenu

echo "✓ BrewMenu installed. Launch it from /Applications or Spotlight."
