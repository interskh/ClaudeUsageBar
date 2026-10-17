# ClaudeUsageBar

> Track your Claude, Codex, and Muse usage right from your Mac menu bar!

A lightweight macOS menu bar app that displays the session and weekly usage limits of each Claude account on your Mac, plus your OpenAI Codex and Meta Muse accounts, with real-time updates and notifications.

This is a fork of [Artzainnn/ClaudeUsageBar](https://github.com/Artzainnn/ClaudeUsageBar) with **OAuth authentication, multi-profile support, Codex support, and Muse support** — no browser-session credential to paste, and nothing to configure.

## ✨ Features

- 👥 **Multi-Account**: Tracks the Claude profiles in the usual locations, plus any you register
- ◆ **Codex Support**: Tracks your ChatGPT/Codex subscription usage alongside Claude
- ● **Muse Support**: Tracks your Muse Code subscription usage (5-hour and weekly windows) alongside Claude
- 🔑 **Zero Setup**: Reads the OAuth credentials Claude Code, the Codex CLI, and Muse already store
- 🔒 **Read-Only Credentials**: Never writes, refreshes, or rotates a token
- 🟢 **Real-time Usage Tracking**: Session (5-hour) and weekly (7-day) usage per account
- 🎨 **Color-Coded Menu Bar**: One figure per provider, coloured by level (green/yellow/red)
- 🔔 **Smart Notifications**: Per-account alerts at 25%, 50%, 75%, and 90% thresholds
- ⚡ **Auto-Refresh**: Updates roughly every 5 minutes, backing off when rate limited
- ⌨️ **Keyboard Shortcut**: Toggle popup with Cmd+U from anywhere
- 📊 **Model-Scoped Limits**: Per-model weekly bars appear automatically, as your plan reports them
- 💳 **Extra Usage & Credits**: Pay-as-you-go spend and remaining free credits
- 🔗 **JSON Cache**: Latest normalized readings for other local tools, with timestamps
- 🎯 **Menu Bar Only**: No Dock icon, stays out of your way

## 🖼️ Screenshots

**Menu Bar Display:**
- One percentage per provider, each color-coded (green < 70%, yellow 70-90%, red ≥ 90%)
- Example: `⚡ 78%   ◆ 31%   ● 12%` — `⚡` is the worst of your Claude profiles, `◆` is Codex, `●` is Muse

**Popup Interface:**
- One card per account, grouped under CLAUDE, CODEX, and MUSE headings; accounts with data expand to show their windows
- Session (5-hour) usage with progress bar and reset time
- Weekly (7-day) usage with progress bar and reset date
- Any model-scoped weekly limits your plan reports, with their reset times
- Extra usage spend and remaining free credits
- Signed-out or expired accounts shown inline with a sign-in hint
- Settings for per-account tracking, notifications and keyboard shortcuts

## 📋 Requirements

- macOS 12.0 (Monterey) or later
- Apple Silicon (M1/M2/M3) or Intel Mac
- [Claude Code](https://claude.com/claude-code), the [Codex CLI](https://developers.openai.com/codex/cli), and/or Muse (`muse`), signed in on this Mac

## 🚀 Installation

There are no pre-built releases for this fork yet, so build it from source:

```bash
git clone https://github.com/interskh/ClaudeUsageBar.git
cd ClaudeUsageBar/app
chmod +x build.sh
./build.sh
```

The universal binary will be in `build/ClaudeUsageBar.app` — drag it to Applications and
launch it. `./create_dmg.sh` packages the same build as a DMG if you want an installer.

The [original project](https://github.com/Artzainnn/ClaudeUsageBar) publishes DMG and ZIP
downloads, but they contain the original single-account app rather than this fork.

## 🔧 First-Time Setup

There isn't one. Sign in to Claude Code (`claude`), the Codex CLI (`codex`), and/or Muse (`muse`) as you
normally would, then launch ClaudeUsageBar — it finds those credentials itself and starts
tracking. Nothing to paste, no key to enter.

### What Gets Discovered

- **Claude**: any configuration directory with an account recorded in it — `~/.claude`,
  any `~/.claude-*` directory, and the configuration directory your environment
  designates. A directory is listed because it holds an account; whether that account is
  currently signed in only changes what its card shows (*Signed out* and *Expired* are
  states, not reasons to hide it).
- **Codex**: the account the Codex CLI is signed in to, from `$CODEX_HOME` when that is
  set, otherwise `~/.codex`.
- **Muse**: the account Muse is signed in to, from `~/.config/muse/auth.json`
  (or `$MUSE_AUTH_PATH`) plus the device token the CLI keeps in your Keychain. Muse
  publishes no GET usage endpoint, so the app makes the same startup key call the CLI
  makes and reads the subscription block from its response; the minted key in that
  response is discarded, never stored.
- Directories that hold no account at all (backups, scratch dirs) are ignored entirely.

Discovery re-runs while the app is open, so a profile you sign into — or out of — is
picked up without a restart.

A profile outside those locations is invisible until you register it: **Settings → add
configuration location**. You can list and remove registered locations there too.

## ⚙️ Settings

Access settings by clicking the gear icon in the popup:

### Accounts
- Enable or disable each discovered account individually
- A disabled account disappears from the popup and the menu bar, and is no longer polled
- Add, list, and remove configuration directories outside the standard locations

### Notifications
- Enable/disable usage alerts
- Get notifications at 25%, 50%, 75%, 90% thresholds
- Click "Test Notification" to verify it works

### Keyboard Shortcut (Cmd+U)
- Toggle popup from anywhere on your Mac
- Requires Accessibility permission
- Click "Enable Keyboard Shortcut" to grant permission

### Launch at Login
- Start ClaudeUsageBar automatically when you log in

## 🔒 Read-Only Credentials

**The app never writes, refreshes, or rotates a credential.** No code path writes to the
Keychain, to `.credentials.json`, or to `auth.json`.

This is the central design decision, not a detail. Both providers pair a short-lived
access token with a long-lived refresh token that *rotates*: refreshing spends the old
one and issues a replacement. A second program doing that leaves the CLI holding a dead
token and logs you out of the account you actually work in. So this app reads, and only
reads — the CLIs stay the sole owners of their tokens.

What follows from that:

- The app can never repair a credential, so an expired one is shown as **expired** with a
  hint to sign in again via the CLI. It is a display state, never an error.
- Once you do sign in again, the app notices the stored credential changed and resumes on
  its own — no restart, no manual refresh.
- Because refreshing is off the table as a way to get a fresh rate-limit window, polling
  backs off instead when a provider rate-limits an account.

## 🔐 Privacy & Security

- ✅ **No analytics, no telemetry, no third-party services** - the only network calls the
  app makes are authenticated requests to `api.anthropic.com`, `chatgpt.com`, and `api.meta.ai`, the
  providers' own usage endpoints
- ✅ **Credentials are read, never written** - the access token only ever goes to the
  provider that issued it
- ✅ **What's stored locally** - your settings, the last good reading per account, and the
  normalized JSON cache described below. The most recent raw usage response per account
  is retained only in memory for diagnostics and discarded when the app exits
- ✅ **No hardcoded credentials** - accounts are discovered from what's already on disk
- ✅ **Open source** - review the code yourself

## 🎯 How It Works

1. Discovers your Claude profiles — the usual locations plus any you registered — plus
   the Codex and Muse accounts, from the credentials the CLIs already store
2. Reads (never writes) each account's OAuth access token at fetch time
3. Fetches usage from each provider's usage endpoint, per account
4. Displays the worst-case figure per provider in your menu bar, with a card per account
5. Sends per-account notifications when you cross a usage threshold

## JSON Cache

ClaudeUsageBar atomically maintains:

```text
~/Library/Application Support/ClaudeUsageBar/usage.json
```

The file is safe for another local tool to read while the app is updating it. Its
top-level fields are:

- `schema_version`: currently `1`
- `last_updated`: ISO 8601 time of the newest successful pull, or `null` before any pull
- `accounts`: latest normalized reading per discovered account

Each account includes `provider`, stable `id`, display metadata, `fetched_at`, usage
`windows`, optional spend data, and warnings. Each window includes its span, scope,
percentage when known, reset time, and whether the provider marks it active. The cache
contains no credentials or raw provider response. See
[the full cache contract](../docs/json-cache.md) for the complete schema, location
rationale, sandbox limitations, and reader examples.

## 🔨 Building & Distribution

### Build the App
```bash
./build.sh
```

### Create DMG Installer
```bash
./create_dmg.sh
```

### Clean Build
```bash
rm -rf build
./build.sh
```

## 🐛 Troubleshooting

### No accounts showing
- Make sure Claude Code, the Codex CLI, or Muse is signed in on this Mac (`claude`, `codex`, `muse`)
- If the profile lives outside `~/.claude` / `~/.claude-*` / your designated config
  directory, register its directory in Settings — it is not found otherwise
- Discovery re-runs periodically and when you open the popup

### An account shows "Signed out" or "Expired"
- Sign in again with that CLI; the app can't renew a credential itself
- It picks the new credential up automatically once the CLI has written it

### Notifications not working
- Click "Test Notification" in Settings
- Notifications work without permission prompts
- Check macOS Focus mode isn't blocking them

### Cmd+U shortcut not working
- Click "Enable Keyboard Shortcut" in Settings
- Grant Accessibility permission in System Settings
- Restart the app after granting permission

### Usage not updating
- App auto-refreshes roughly every 5 minutes, per account
- Click the refresh button to update manually
- An account that says "rate limited" is checking on a longer interval until the provider
  lets it back in
- A card labelled "as of HH:mm" is showing the last good reading while fetches fail

## 📦 Build Output

- **build/ClaudeUsageBar.app** - The universal binary produced by `./build.sh`
- **ClaudeUsageBar-Installer.dmg** - Optional installer produced by `./create_dmg.sh`

## 🤝 Contributing

Bugs, feature requests and pull requests for this fork go to
[interskh/ClaudeUsageBar](https://github.com/interskh/ClaudeUsageBar/issues). Forking it
and customizing it for your own needs is welcome too.

## 📄 License

MIT License - see [LICENSE](LICENSE) file for details.

Forked from [Artzainnn/ClaudeUsageBar](https://github.com/Artzainnn/ClaudeUsageBar) (MIT); the upstream copyright line is retained.

## ⚠️ Disclaimer

This app reads Anthropic's, OpenAI's, and Meta's internal usage endpoints, which may change without notice. It is not affiliated with or endorsed by Anthropic, OpenAI, or Meta. Use at your own risk.

## 🙏 Acknowledgments

Forked from [Artzainnn/ClaudeUsageBar](https://github.com/Artzainnn/ClaudeUsageBar).

Built with:
- SwiftUI for the interface
- AppKit for menu bar integration
- Carbon for global keyboard shortcuts
- NSUserNotification for alerts

---

**Made with ❤️ for the Claude community**
