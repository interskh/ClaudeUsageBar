# ClaudeUsageBar

> Track your Claude and Codex usage right from your Mac menu bar!

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![macOS](https://img.shields.io/badge/macOS-12.0+-blue.svg)](https://www.apple.com/macos/)

A lightweight, open-source macOS menu bar application that displays your Claude and OpenAI Codex usage limits — for **every** account you are signed in to — with real-time updates and notifications.

This is a fork of [Artzainnn/ClaudeUsageBar](https://github.com/Artzainnn/ClaudeUsageBar) with **OAuth authentication, multi-profile support and Codex support**. The old browser-session setup is gone: the app reads the OAuth credentials Claude Code and the Codex CLI already keep on your Mac.

## 📥 Install

**There are no pre-built releases for this fork yet — build it from source** (about a minute):

```bash
git clone https://github.com/interskh/ClaudeUsageBar.git
cd ClaudeUsageBar/app
./build.sh
```

The universal binary lands in `app/build/ClaudeUsageBar.app`; drag it to Applications. macOS 12+ and the Xcode Command Line Tools are all you need.

> The [original project](https://github.com/Artzainnn/ClaudeUsageBar) does publish DMG installers, but those ship the **original single-account app**, which authenticates the old way. Its downloads will not behave as described below.

## 📦 Set Up (nothing to configure)

1. Sign in to **Claude Code** (`claude`) and/or the **Codex CLI** (`codex`), the way you normally would.
2. Launch ClaudeUsageBar.

That's it. The app finds the credentials those CLIs already stored, picks up your Claude profiles in the usual locations plus your Codex account, and starts tracking them. There is nothing to paste and no key to enter.

Claude profiles are discovered in `~/.claude`, any `~/.claude-*` directory, and whatever configuration directory your environment designates; a profile kept anywhere else is added by registering its directory in Settings. Codex honours `$CODEX_HOME`, falling back to `~/.codex`.

If no account is found, the popover tells you to sign in with Claude Code or the Codex CLI — it never asks you to paste a credential.

## 🔒 Read-only, always

**ClaudeUsageBar never writes, refreshes, or rotates any credential.** It only ever reads.

Claude Code and the Codex CLI own their tokens: refreshing one spends it and issues a
replacement, so a second program doing it would break the sign-in you rely on for real
work. This app therefore stays strictly out of that loop — it does not write to the
Keychain, to `.credentials.json`, or to `auth.json`, ever.

The consequence is deliberate: when a credential expires, the app shows the account as
expired and asks you to sign in again with the CLI. That is a display state, not an
error, and it can never damage your session.

## ✨ Features

- 👥 **Every account at once** - Tracks your Claude profiles, not just one, plus any you register by hand
- ◆ **Codex support** - Your ChatGPT/Codex subscription usage alongside Claude
- 🟢 **Real-time usage tracking** - Session (5-hour) and weekly (7-day) limits per account
- 🎨 **Color-coded menu bar** - One figure per provider, coloured green/yellow/red
- 🔔 **Smart notifications** - Per-account alerts at 25%, 50%, 75%, 90% thresholds
- ⌨️ **Keyboard shortcut** - Toggle popup with Cmd+U from anywhere
- ⚡ **Auto-refresh** - Updates roughly every 5 minutes, backing off if rate limited
- 🔒 **Read-only credentials** - Never writes, refreshes, or rotates a token
- 📊 **Model-scoped limits** - Per-model weekly bars appear automatically, as your plan reports them
- 💳 **Extra usage & credits** - Pay-as-you-go spend and remaining free credits
- 🎯 **Menu bar only** - No Dock icon, stays out of your way

[See full feature list →](app/README.md)

## 🚀 Quick Start

1. **Sign in** with Claude Code and/or the Codex CLI (if you haven't already)
2. **Build** it: `cd app && ./build.sh`
3. **Drag** `app/build/ClaudeUsageBar.app` to your Applications folder
4. **Launch** ClaudeUsageBar from Applications
5. **Done!** Your accounts appear in the menu bar

## 📸 Screenshots

**Menu Bar Display:**
```
⚡ 78%   ◆ 31%
```
One figure per provider — `⚡` is the worst of your Claude profiles, `◆` is Codex.

**Popup Interface:**
- One card per account, grouped by provider; active accounts expand to show their windows
- Session (5-hour) and weekly (7-day) usage with progress bars and reset times
- Any model-scoped weekly limits your plan reports
- Extra usage spend and remaining free credits
- Signed-out or expired accounts shown with a "sign in via the CLI" hint
- Settings for per-account tracking, notifications and shortcuts

## 📁 Repository Structure

```
app/        - macOS menu bar application (Swift/SwiftUI)
website/    - Landing page (HTML/CSS)
```

## 🛠️ Build from Source

**Requirements:**
- macOS 12.0 (Monterey) or later
- Xcode Command Line Tools

**Build the app:**
```bash
cd app
chmod +x build.sh
./build.sh
```

**Create DMG installer:**
```bash
./create_dmg.sh
```

The built app will be in `app/build/ClaudeUsageBar.app`

## 🔧 Development

### Project Structure

- `app/Model/` - Accounts, usage windows, snapshots
- `app/Providers/` - Anthropic and Codex usage providers
- `app/Credentials/` - Keychain reads, Claude profile discovery, Codex auth reader
- `app/Core/` - Account store, polling, notifications, settings
- `app/UI/` - Menu bar, popover, account cards, settings
- `app/build.sh` - Build script
- `app/create_dmg.sh` - DMG installer creation
- `website/index.html` - Landing page

### Key Technologies

- **SwiftUI** - Modern macOS UI framework
- **AppKit** - Menu bar integration
- **Carbon** - Global keyboard shortcuts
- **NSUserNotification** - System notifications (no permissions needed)

## 🤝 Contributing

Bugs and pull requests for this fork belong on
[interskh/ClaudeUsageBar](https://github.com/interskh/ClaudeUsageBar/issues). The
[original project](https://github.com/Artzainnn/ClaudeUsageBar) has its own issues page,
but it tracks the original app, not this one.

## 📄 License

MIT License - see [LICENSE](LICENSE) for details.

This project is a fork of [Artzainnn/ClaudeUsageBar](https://github.com/Artzainnn/ClaudeUsageBar), which is MIT-licensed; the upstream copyright line in [LICENSE](LICENSE) is retained as-is.

## ⚠️ Disclaimer

This app reads Anthropic's and OpenAI's internal usage endpoints, which may change without notice. It is not affiliated with or endorsed by Anthropic or OpenAI. Use at your own risk.

## 🔗 Links

- **This fork:** [interskh/ClaudeUsageBar](https://github.com/interskh/ClaudeUsageBar) — no releases published yet, so build from source as above
- **Original project:** [Artzainnn/ClaudeUsageBar](https://github.com/Artzainnn/ClaudeUsageBar) — its releases and its site, [claudeusagebar.com](https://claudeusagebar.com), are for the original single-account app

---

**Made with ❤️ for the Claude community**
