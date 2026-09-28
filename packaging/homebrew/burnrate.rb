cask "burnrate" do
  version "1.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/oleksii-stepanenko/burnrate/releases/download/v#{version}/Burnrate.dmg"
  name "Burnrate"
  desc "Menu-bar dashboard for Claude Code, pi and omp token usage and plan limits"
  homepage "https://github.com/oleksii-stepanenko/burnrate"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :sonoma

  app "Burnrate.app"

  # Burnrate runs from a login item that launchd restarts after a crash; quitting
  # it normally (exit 0) keeps launchd from relaunching it mid-upgrade.
  uninstall launchctl: "io.stepanenko.Burnrate.agent",
            quit:      "io.stepanenko.Burnrate"

  zap trash: [
    "~/Library/Application Support/Burnrate",
    "~/Library/Preferences/io.stepanenko.Burnrate.plist",
    "~/Library/Saved Application State/io.stepanenko.Burnrate.savedState",
  ]

  caveats <<~EOS
    Burnrate is signed with a self-signed certificate (it is not notarized by
    Apple), so the first time you launch it macOS says it "cannot be opened
    because Apple cannot check it for malicious software". To allow it:

      1. Open  System Settings -> Privacy & Security
      2. Scroll to Security and click "Open Anyway" next to Burnrate
      3. Confirm with Touch ID or your password

    This step reappears after each update: open Burnrate once after upgrading
    so its login item starts the new version.

    Burnrate starts at login (menu bar only). Turn that off from its menu bar
    panel or under System Settings -> General -> Login Items.

    It reads the session logs Claude Code, pi and omp write in your home
    folder, and reuses their stored logins read-only (Claude Code's Keychain
    token; omp/pi's GitHub Copilot and OpenRouter credentials) to show plan
    limits. Nothing leaves your Mac except those limit requests to Anthropic,
    GitHub and OpenRouter. Its history lives in
    ~/Library/Application Support/Burnrate (removed by `brew uninstall --zap`).
  EOS
end
