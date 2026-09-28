#!/usr/bin/env bash
# add-cask-to-tap.sh — add (or update) Casks/burnrate.rb in the tap for a
# release that already exists. Used once for the first release; after that the
# release workflow bumps the cask itself (when TAP_GITHUB_TOKEN is set).
#
#   ./scripts/add-cask-to-tap.sh 1.0.0
#
# Downloads that release's DMG, computes its sha256, writes the cask from
# packaging/homebrew/burnrate.rb, and pushes it to the tap.

set -euo pipefail

VERSION="${1:?usage: add-cask-to-tap.sh <version, e.g. 1.0.0>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="oleksii-stepanenko/burnrate"
TAP="oleksii-stepanenko/homebrew-tap"
URL="https://github.com/${REPO}/releases/download/v${VERSION}/Burnrate.dmg"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Fetching ${URL}"
curl -fsSL -o "$TMP/Burnrate.dmg" "$URL"
SHA="$(shasum -a 256 "$TMP/Burnrate.dmg" | awk '{print $1}')"
echo "sha256 = ${SHA}"

git clone -q "https://github.com/${TAP}.git" "$TMP/tap"
mkdir -p "$TMP/tap/Casks"
CASK="$TMP/tap/Casks/burnrate.rb"
cp "$ROOT/packaging/homebrew/burnrate.rb" "$CASK"
sed -i '' -E "s/^  version \".*\"/  version \"${VERSION}\"/" "$CASK"
sed -i '' -E "s/^  sha256 \".*\"/  sha256 \"${SHA}\"/" "$CASK"

cd "$TMP/tap"
if git diff --quiet && git ls-files --error-unmatch Casks/burnrate.rb >/dev/null 2>&1; then
  echo "Cask already at ${VERSION} — nothing to do."
  exit 0
fi
git add Casks/burnrate.rb
git commit -qm "burnrate ${VERSION}"
git push -q
echo "Pushed Casks/burnrate.rb (${VERSION}) to ${TAP}."
