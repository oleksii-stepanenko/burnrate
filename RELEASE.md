# Releasing Burnrate

Exact commands, in order. Run them from the repo root.

---

## One time only

```sh
./scripts/setup-release.sh
```

That script:

1. uploads the shared signing certificate from `~/.showpoint-signing` as
   `SIGNING_CERTIFICATE_P12` / `SIGNING_CERTIFICATE_PASSWORD` (the same one
   Showpoint, Disk Spacer and Piège Lock use)
2. asks for a personal access token and uploads it as `TAP_GITHUB_TOKEN`
3. tells you whether the cask is in the tap yet

It is safe to re-run. It never replaces an existing signing certificate,
because that would make the next update look like a different app to macOS.

Create the token at **https://github.com/settings/personal-access-tokens/new**
with **Contents: Read and write** on `homebrew-tap` only.

---

## Before a first tag: dry run

```sh
gh workflow run "Build & Release" --ref main
gh run watch "$(gh run list --workflow='Build & Release' --limit 1 --json databaseId --jq '.[0].databaseId')"
```

A manual run resolves the version to `0.0.0`, and both "Attach to Release" and
"Bump Homebrew cask" only run on a tag, so nothing public is created. You still
get a downloadable `Burnrate.dmg` artifact to check.

---

## Publish a release

```sh
git tag v1.0.0
git push origin v1.0.0
```

The workflow builds the app, signs it, packages `Burnrate.dmg`, attaches it to a
GitHub Release, and bumps the cask in the tap.

**First release only:** the cask doesn't exist in the tap yet, so add it once,
after the release is published, so it gets the real checksum:

```sh
./scripts/add-cask-to-tap.sh 1.0.0
```

---

## Check it worked

```sh
gh release view v1.0.0
brew update
brew install --cask oleksii-stepanenko/tap/burnrate
```

---

## Later releases

Just tag again:

```sh
git tag v1.0.1
git push origin v1.0.1
```

---

## If something breaks

**Cask bump fails with "not found in the tap"**
`Casks/burnrate.rb` is missing. Run `./scripts/add-cask-to-tap.sh <version>`.

**Cask bump is skipped with a notice**
`TAP_GITHUB_TOKEN` is not set, or it expired. Re-run the setup script, or bump
by hand with `./scripts/add-cask-to-tap.sh <version>`.

**`brew install` fails with a checksum mismatch**
The cask points at a different build than the release. Re-run
`./scripts/add-cask-to-tap.sh <version>`.

**Build fails with "Designated requirement is cdhash-based"**
The certificate did not get applied. The signing secrets are wrong or missing.
Re-run the setup script.

---

## Names that must stay in sync

| Thing | Value | Set in |
|---|---|---|
| DMG filename | `Burnrate.dmg` | `release.yml` and the cask `url` |
| App bundle name | `Burnrate.app` | `make-app.sh` and the cask `app` stanza |
| Bundle identifier | `io.stepanenko.Burnrate` | `make-app.sh`, the cask `zap`/`uninstall` |
| Login agent label | `io.stepanenko.Burnrate.agent` | `make-app.sh`, `LoginItem.swift`, the cask `uninstall` |
| Cask filename | `Casks/burnrate.rb` | the tap, and the bump step in `release.yml` |
