#!/usr/bin/env bash
# setup-release.sh — one-time setup so `git tag` publishes a release and
# updates the Homebrew cask automatically.
#
# Run it once. It is idempotent: re-running skips anything already done.
#
#   ./scripts/setup-release.sh
#
# It does three things:
#   1. copies the cask into your homebrew-tap (the release only *updates* it)
#   2. uploads the signing certificate (the shared ~/.showpoint-signing one) as secrets
#   3. asks for a token so releases can bump the tap
#
# Nothing here touches the burnrate repo's code or history.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GH_USER="oleksii-stepanenko"
APP_REPO="$GH_USER/burnrate"
TAP_REPO="$GH_USER/homebrew-tap"
CASK_SRC="$ROOT/packaging/homebrew/burnrate.rb"
CERT_DIR="$HOME/.showpoint-signing"

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# ── Preflight ────────────────────────────────────────────────────────────────
step "Checking prerequisites"

command -v gh >/dev/null || { echo "gh CLI not found: brew install gh"; exit 1; }
command -v openssl >/dev/null || { echo "openssl not found"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "Not logged in: gh auth login"; exit 1; }
ok "gh CLI authenticated as $(gh api user --jq .login)"

[[ -f "$CASK_SRC" ]] || { echo "Missing $CASK_SRC"; exit 1; }
ok "cask template found"

# ── 1. Cask into the tap ─────────────────────────────────────────────────────
step "1. Homebrew cask"

if gh api "repos/$TAP_REPO/contents/Casks/burnrate.rb" >/dev/null 2>&1; then
  ok "Casks/burnrate.rb already exists in $TAP_REPO"
else
  warn "Casks/burnrate.rb is missing from $TAP_REPO"
  echo "     The release workflow only *updates* the cask — it cannot create it."
  echo "     Add it once, AFTER the first release exists, with the real sha256:"
  echo "       ./scripts/add-cask-to-tap.sh <version>"
fi

# ── 2. Signing certificate ───────────────────────────────────────────────────
step "2. Code-signing certificate"

if gh secret list --repo "$APP_REPO" 2>/dev/null | grep -q SIGNING_CERTIFICATE_P12; then
  ok "SIGNING_CERTIFICATE_P12 already set — leaving it alone"
  echo "     (Replacing it would make the next update look like a different app to macOS.)"
else
  # A code-signing certificate is not tied to a bundle id. The designated requirement
  # pins the identifier *and* the certificate, so apps sharing one certificate stay
  # separate as far as macOS permissions are concerned.
  P12="$CERT_DIR/showpoint-signing.p12"
  PWD_FILE="$(ls "$CERT_DIR"/*password*.txt 2>/dev/null | head -1 || true)"
  if [[ -f "$P12" && -n "$PWD_FILE" ]]; then
    subject="$(openssl pkcs12 -in "$P12" -nokeys -passin "file:$PWD_FILE" -legacy 2>/dev/null \
               | openssl x509 -noout -subject 2>/dev/null | sed 's/^subject=//')"
    echo "     Reusing the certificate your other apps are signed with:"
    echo "       $P12"
    echo "       $subject"
    base64 -i "$P12" | gh secret set SIGNING_CERTIFICATE_P12 --repo "$APP_REPO"
    tr -d '\n' < "$PWD_FILE" | gh secret set SIGNING_CERTIFICATE_PASSWORD --repo "$APP_REPO"
    ok "uploaded to $APP_REPO"
  else
    warn "no certificate found in $CERT_DIR — releases will be ad-hoc signed"
  fi
fi

# ── 3. Tap token ─────────────────────────────────────────────────────────────
step "3. Token for updating the tap"

if gh secret list --repo "$APP_REPO" 2>/dev/null | grep -q TAP_GITHUB_TOKEN; then
  ok "TAP_GITHUB_TOKEN already set"
else
  echo "     Releases live in $APP_REPO but the cask lives in $TAP_REPO."
  echo "     A workflow's built-in token only reaches its own repo, so bumping"
  echo "     the cask needs a personal access token with write access to the tap."
  echo
  echo "     Create one here (Contents: Read and write, on homebrew-tap):"
  echo "       https://github.com/settings/personal-access-tokens/new"
  echo
  read -r -s -p "     Paste the token (input hidden, blank to skip): " TOKEN || TOKEN=""
  echo
  if [[ -n "$TOKEN" ]]; then
    printf '%s' "$TOKEN" | gh secret set TAP_GITHUB_TOKEN --repo "$APP_REPO"
    ok "TAP_GITHUB_TOKEN set"
  else
    warn "skipped — the cask will not auto-update on release"
  fi
fi

step "Current state"
gh secret list --repo "$APP_REPO" 2>/dev/null | sed 's/^/  /' || echo "  (none)"

step "Next"
cat <<'NEXT'
  See RELEASE.md: dry run, tag, then add the cask to the tap once.
NEXT
