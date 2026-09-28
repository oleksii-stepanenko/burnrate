# Burnrate

A native macOS menu-bar app (SwiftUI + Swift Charts) that shows how fast you burn through
AI coding agents. It tracks token usage and cost across **Claude Code**, **pi** and **omp**
(oh-my-pi), per model and per day, and shows live plan limits: the Claude 5-hour and weekly
windows, GitHub Copilot premium requests, and OpenRouter credits.

## Install

```sh
brew install --cask oleksii-stepanenko/tap/burnrate
```

Burnrate is signed with a self-signed certificate and is **not notarized by Apple**, so the
first time you open it (and after each update) macOS blocks it:

1. Open **System Settings → Privacy & Security**
2. Scroll to **Security** and click **Open Anyway** next to Burnrate
3. Confirm with Touch ID or your password

Update with `brew upgrade --cask burnrate`. Uninstall with `brew uninstall --cask burnrate`;
add `--zap` to also delete the usage history.

## Build from source

```sh
./scripts/make-app.sh --release            # → build/Burnrate.app (ad-hoc signed)
./scripts/make-app.sh --release --install  # also copies it to /Applications
```

Requires macOS 14+ and Swift 5.10+ (Xcode command line tools). No dependencies.
Releases are built and signed by GitHub Actions; see [RELEASE.md](RELEASE.md).

## Open at login

The first time the app runs from `/Applications`, it registers a per-user launch agent
(`Contents/Library/LaunchAgents/io.stepanenko.Burnrate.agent.plist`, via `SMAppService`).
At login it starts in the menu bar only, with no window and no Dock icon. If it crashes,
launchd restarts it; after a normal Quit it stays closed until the next login. You can
toggle this in the menu bar panel or on the Help page. It also appears under
System Settings › General › Login Items. `./scripts/make-app.sh --install` restarts the running
login instance so it picks up the new build.

The Dock icon is shown only while the dashboard window is open.

## What it shows

- **Menu bar**: the Claude 5-hour session percentage, plus a panel with every quota
  (Claude, GitHub Copilot, OpenRouter), today's tokens and cost, and active sessions.
- **Overview**: a quota card per provider, KPI tiles, usage per day/hour stacked by model
  (all tokens / input+output / output / est. cost), model share, per-agent split (click
  one to filter), weekday × hour heatmap, top projects (click one to see its sessions),
  and top tools.
- **Models**: per-model table. Select a row to see that model's own day-by-day history.
- **Sessions**: every session, searchable and sortable, with a live "active" dot. Select
  one to open an inspector with per-model tokens and cost, tools used, and
  main/sub-agent/advisor call counts.
- **Projects**: usage per working directory.
- **Limits**: all quota cards plus their history over time (hover for values).
- **Help**: data sources, the refresh schedule with last-run times, database stats,
  "Show in Finder", and CSV export.

Every chart has hover details. Filters: agent (all / one tool) and time range
(Today, 7D, 30D, 90D, All).

## Where the data comes from

| Source | Location | Notes |
|---|---|---|
| Claude Code | `~/.claude/projects/**/*.jsonl` (incl. `subagents/`) | `message.usage` per API response. Each response is logged once per content block, so copies are merged by `message.id` + `requestId`. Advisor sub-calls (`usage.iterations[type=advisor_message]`) aren't included in the top-level totals, so they're recorded as their own rows on the advisor model. |
| Claude Code archive | `~/.claude/stats-cache.json` | Per-day, per-model totals for days whose transcripts Claude Code has already deleted. Imported as input/output only (no cache split), and never for days that have real transcript data. |
| pi | `~/.pi/agent/sessions/**/*.jsonl` | pi-ai format: `usage {input, output, cacheRead, cacheWrite, cost.total}` |
| omp | `~/.omp/agent/sessions/**/*.jsonl` | Same format; sub-agent transcripts are attributed to the parent session |
| Claude limits | `GET api.anthropic.com/api/oauth/usage` | Uses Claude Code's OAuth token from the Keychain (`Claude Code-credentials`), falling back to `~/.claude/.credentials.json`. The rate limit is shared with other tools that poll this endpoint (e.g. the oh-my-claudecode HUD). On a 429, a recent reading from that HUD's cache is used. |
| GitHub Copilot | `GET api.github.com/copilot_internal/user` | Monthly premium-request quota. Uses the GitHub token omp (or pi) stores. |
| OpenRouter | `GET openrouter.ai/api/v1/credits` and `/key` | Account balance, key spend limit, free-model daily requests, daily/weekly/monthly spend. Uses the key omp (or pi) stores. |

Credentials are only read, never stored in the app's database and never refreshed.
Refreshing would rotate the token and sign the other tool out.

## Refresh schedule

| What | Every |
|---|---|
| Session logs | 10 s (only new bytes are read) |
| Claude limits | 2 min |
| Copilot quota | 5 min |
| OpenRouter | 5 min |

⌘R refreshes everything, but hits a quota endpoint at most once every 30 s. After errors,
each provider backs off exponentially, up to 30 minutes.

## What is stored

`~/Library/Application Support/Burnrate/usage.sqlite` holds:

- per model response: time, agent, session, project folder, provider, model, input,
  output, cache read/write (5m/1h), reasoning tokens, cost
- session titles and tool names
- every quota reading, written on change or every 15 minutes

It does **not** hold prompts, replies, file contents or credentials.

Rows are never deleted. Claude Code prunes transcripts after about 30 days, so this
database keeps your history after the source files are gone. Setting `cleanupPeriodDays`
in `~/.claude/settings.json` also keeps the transcripts themselves for longer.

**Cost**: pi and omp costs are what those tools report. Claude Code doesn't log cost, so
its cost is an *API-equivalent estimate* at list prices, with 5-minute and 1-hour cache
writes priced separately and fast mode at 2×. That's a yardstick, not a bill. Prices are
in `Sources/Burnrate/Core/Models.swift` (`Pricing.table`) and are re-applied to all
history on each launch.

## CLI

```sh
.build/release/Burnrate --dump [--db /path/to.sqlite]   # ingest + print totals per agent/model + limits
```

Dev flags for the app: `--page overview|models|sessions|projects|limits|help`, `--appearance dark|light`, `--scroll-bottom`.
