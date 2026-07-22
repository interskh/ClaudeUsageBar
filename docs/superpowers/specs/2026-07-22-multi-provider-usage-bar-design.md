# Multi-Provider, Multi-Account UsageBar — Design

> Date: 2026-07-22
> Status: Approved for implementation
> Supersedes: the cookie-based single-account design in `app/ClaudeUsageBar.swift` (v1.3.2)
> Target version: **2.0.0** (breaking: authentication method changes)

## Summary

ClaudeUsageBar today tracks **one** Claude account, authenticated by a browser session
cookie the user pastes in by hand. This design replaces that with **OAuth access tokens
already on disk**, adds **multiple Claude profiles**, adds **OpenAI Codex** as a second
provider, reworks the UI to present N accounts across 2 providers, and re-frames the
README as a fork.

The app becomes **strictly read-only with respect to credentials**. It never writes,
refreshes, or rotates a token.

## Goals

1. Authenticate via OAuth credentials written by Claude Code / Codex CLI, not cookies.
2. Track every signed-in Claude profile on the machine, not just one.
3. Track OpenAI Codex (ChatGPT subscription) usage alongside Claude.
4. Present multiple accounts and providers legibly in a menu bar and popover.
5. Re-frame the project as a fork and remove inherited funding/promo assets.

## Non-Goals (explicit YAGNI)

- Token refresh, rotation, or **any** credential write. See "Why read-only".
- Multiple Codex accounts / `$CODEX_HOME` profile enumeration.
- Providers beyond Anthropic and Codex.
- Renaming the app, bundle ID (`com.claude.usagebar`), or icon.
- Displaying raw input/output token counts. Usage stays expressed as % of limits.
- Cookie-based auth as a fallback. It is removed outright.

---

## 1. Why read-only

Anthropic and OpenAI both issue a short-lived **access token** plus a long-lived
**refresh token**. The refresh token **rotates**: refreshing spends the old one and
returns a new one with a fresh window. Observed on the target machine (2026-07-22):

| Profile | access token TTL | refresh token expiry | Keychain item age |
|---|---|---|---|
| default (`~/.claude`) | ~8h | 2026-08-20 (~29d) | created 2026-02-08, written continuously |
| `work-fiona` | ~8h | 2026-08-18 (~27d) | created 2026-01-22, written continuously |

Two conclusions drove the decision:

1. **Refresh already works.** Both live profiles have been maintained in place for five
   to six months. The refresh chain is not what causes re-logins; chain *breakage* is
   (evidenced by three orphan Keychain items created 2026-06-11 alongside a manual
   login backup, and `work-ethan`'s refresh token vanishing 2026-07-21).
2. **There is no safe partial refresh.** Because rotation is single-use, "refresh in
   memory without persisting" is the *worst* option: it spends the stored refresh token
   and leaves Claude Code holding a dead one. Any refresh obliges a correct write-back.

Adding a second writer to a chain that has been unbroken since February is pure
downside risk, on work accounts. Therefore: **the app never writes credentials.**

**Consequence to respect throughout:** the documented mitigation for a `429` on
Anthropic's usage endpoint is to refresh for a fresh rate-limit window. Read-only
forfeits that, so polling cadence and backoff must absorb rate limiting instead
(§6).

---

## 2. RISK: Keychain access from a signed GUI app — spike before building

**No `.credentials.json` exists on any profile on the target machine.** The macOS
Keychain is the *only* Anthropic credential source; there is no file fallback.

Keychain ACLs are per-application. Items written by Claude Code may prompt
(*"ClaudeUsageBar wants to use your confidential information"*) when read by a
different binary. Reads performed from an interactive shell during design prove
nothing — `/usr/bin/security` was already trusted there.

Two candidate strategies:

- **A — Direct API:** `SecItemCopyMatching` against `kSecClassGenericPassword`.
  Cleaner, no subprocess, but most likely to trigger an ACL prompt.
- **B — Subprocess:** `/usr/bin/security find-generic-password -s <service> -a $USER -w`.
  If Claude Code wrote these items via the `security` CLI, the ACL names
  `/usr/bin/security` and this path inherits access silently. This is the approach
  onWatch uses in production.

**Task 1 is a throwaway spike** that builds a signed stub, runs it as a real `.app`,
and records for each strategy: does it read, does it prompt, does "Always Allow"
persist across relaunch. Outcomes:

| Result | Action |
|---|---|
| Silent read | Adopt that strategy. |
| Prompts once, "Always Allow" persists | Acceptable. Onboarding must explain it, and **code-signing identity must stay stable** — an identity change invalidates the ACL and re-prompts. |
| Prompts every launch / denied on both | **Stop and report.** The design as specified is not viable; do not proceed to Task 4+. |

`build.sh` currently signs with `Developer ID Application: Linkko Technology Pte Ltd
(Q467HQ5432)` and silently falls back to ad-hoc. That fallback must be made **loud**,
because a silent switch to ad-hoc changes the signing identity and re-triggers prompts.

---

## 3. Data model

The single abstraction the whole design rests on: both providers normalise to one
shape, so **UI code never learns which provider it is rendering**.

```swift
enum ProviderKind { case anthropic, codex }

struct AccountRef: Hashable {
    let provider: ProviderKind
    let id: String        // anthropic: absolute config-dir path; codex: tokens.account_id
    let label: String     // "default", "work-fiona", "Codex"
    let subtitle: String? // email address, when known
}

enum WindowKind: Hashable {
    case session          // ~5h
    case weekly           // ~7d, account-wide
    case scoped(String)   // 7d, model-scoped; payload-supplied display name
}

struct UsageWindow {
    let kind: WindowKind
    let label: String     // "Session 5h", "Weekly 7d", "Fable 7d"
    let percent: Int
    let resetsAt: Date?   // nil => window has never started
    let isActive: Bool    // provider marks this the currently binding limit
}

struct Spend {
    let usedMinor: Int
    let limitMinor: Int?
    let balanceMinor: Int?   // remaining prepaid / free credits
    let currency: String
    let exponent: Int        // money is minor-units + exponent, never a Double
}

struct Snapshot {
    let account: AccountRef
    let planLabel: String?   // "Max 20x", "pro"
    let windows: [UsageWindow]
    let spend: Spend?
    let fetchedAt: Date
}

enum AccountState {
    case active(Snapshot)
    case stale(Snapshot, since: Date)  // last good data; fetches currently failing
    case signedOut                     // no credential, or credential lacks refresh token
    case expired(Date)                 // access token past expiry; user must use the CLI
    case failed(String)
}

protocol UsageProvider {
    var kind: ProviderKind { get }
    func discoverAccounts() -> [AccountRef]
    func fetch(_ account: AccountRef) async -> Result<Snapshot, FetchError>
}
```

`signedOut` and `expired` are **display states, not errors** — read-only means every
failure is cosmetic, never destructive.

---

## 4. Credential discovery

### 4.1 Anthropic (multi-profile)

Discovery is **directory-driven**, never Keychain-driven. Enumerating the Keychain
surfaces orphan items belonging to deleted config dirs (five exist on the target
machine); enumerating directories does not.

Candidates: `~/.claude` and every `~/.claude-*` directory.

For each candidate, resolve the Keychain **service name**:

- **Default dir (`~/.claude`): try the unsuffixed `Claude Code-credentials` FIRST,
  then the hashed name.** This is mandatory, not an optimisation. On the target
  machine `sha256("/Users/kyle/.claude")[0..8] = 6a445fbb` **exists but is empty**
  (`expiresAt: 0`, no `refreshToken`, no `subscriptionType`). Hash-first reports the
  primary account as signed out.
- **Any other dir:** `"Claude Code-credentials-" + sha256(absolutePath)[0..8]`, where
  the path has **no trailing slash**. Verified: `~/.claude-work-fiona` → `6c3a8789`,
  `~/.claude-work-ethan` → `de838ebc`.

Account is included only if **both** gates pass:

- **Validity gate** — blob `claudeAiOauth` has a non-empty `accessToken`, a non-empty
  `refreshToken`, and `expiresAt > 0`. `work-ethan` fails this → `signedOut`.
- **Identity gate** — `<dir>/.claude.json` contains an `oauthAccount` object. This is
  what excludes `~/.claude-backups` and `~/.claude-koop-llm-stub`, which are not
  accounts.

Label = directory basename with a leading `.claude-` stripped, or `"default"` for
`~/.claude`. Subtitle = `oauthAccount.emailAddress`. Plan label derives from
`claudeAiOauth.subscriptionType` + `rateLimitTier`, replaced by live response data
when available.

Credential blob fields: `accessToken`, `refreshToken`, `expiresAt` (Unix **ms**),
`refreshTokenExpiresAt` (Unix ms), `scopes`, `subscriptionType`, `rateLimitTier`.

### 4.2 Codex (single account)

`$CODEX_HOME/auth.json`, else `~/.codex/auth.json`. Require `auth_mode == "chatgpt"`
and a non-empty `tokens.access_token`. Identity: `tokens.account_id`.

`auth.json` may also carry an `OPENAI_API_KEY` — **ignore it**; it is unrelated to
subscription quota.

**Plan type must come from the live usage response, never from `tokens.id_token`.**
The JWT's subscription claims are a cache stamped at
`chatgpt_subscription_last_checked` and have been observed a month stale on an
active account.

---

## 5. Fetching and parsing

Both payloads migrated from flat named keys to **arrays of self-describing bucket
objects**. A client written against the flat keys still returns `200 OK` and still
parses cleanly while silently under-reporting. **Nothing fails loudly** — which is
exactly why §8 tests pin this.

Decode **permissively and per-key**: one unreadable companion object must never
discard the whole payload. Both vendors add top-level fields without notice.

### 5.1 Anthropic

```http
GET https://api.anthropic.com/api/oauth/usage
Authorization: Bearer <claudeAiOauth.accessToken>
anthropic-beta: oauth-2025-04-20
User-Agent: claude-code/2.1.69
Content-Type: application/json
```

Both the `anthropic-beta` header and a plausible CLI `User-Agent` are load-bearing.
The version string is a single named constant, so it can be bumped in one place if
the endpoint starts rejecting stale agents.

Parse **`limits[]`**, not the flat `five_hour` / `seven_day` / `seven_day_sonnet` keys.
The `seven_day_<model>` keys are legacy mirrors that now return `null` even while the
corresponding entry in `limits[]` is live and non-zero.

Each `limits[]` entry:

| Field | Maps to |
|---|---|
| `kind` — `session` \| `weekly_all` \| `weekly_scoped` | `WindowKind` |
| `percent` (Int **or** Double) | `UsageWindow.percent` |
| `resets_at` (RFC3339, **nullable**) | `UsageWindow.resetsAt` |
| `is_active` | `UsageWindow.isActive` |
| `scope.model.display_name` | `.scoped(name)` label, presentation-ready |

Rules:

- **Render a scoped bar when `resets_at != nil`, not when `percent > 0`.** Unused
  models always appear with `percent: 0`; a freshly-reset but genuinely active window
  also reads 0%. Presence of a reset time is the real signal.
- New models appear automatically with a usable label — **no client-side label map.**
  There is no hardcoded `"Fable"` string anywhere in the new code.
- `limits` is a JSON **array** at top level and `spend` is an object of a different
  shape; a parser that assumes every top-level value is a quota object must skip
  non-conforming keys per-key, not fail the decode.
- Ignore experimental codename keys (`tangelo`, `iguana_necktie`, `omelette_promotional`,
  `nimbus_quill`, `cinder_cove`, `amber_ladder`, …). They are almost always `null`.
- **`null` ≠ 0.** `null` means "not applicable to this plan".

`spend` → `Spend`: `used.amount_minor` + `used.exponent` + `used.currency`,
`limit`, `balance`. **Money is never parsed as a Double.** Field presence does not
prove the feature is live — on plans with `can_purchase_credits: false` the object is
present but zeroed.

### 5.2 Codex

```http
GET https://chatgpt.com/backend-api/wham/usage
Authorization: Bearer <tokens.access_token>
Accept: application/json
X-Account-Id: <tokens.account_id>
```

On `404`, retry `https://chatgpt.com/api/codex/usage` and cache whichever answered —
the path has moved before.

Map `rate_limit.primary_window`, `rate_limit.secondary_window`, and every
`additional_rate_limits[]` entry (`limit_name` → scoped label) to `UsageWindow`.

Rules:

- **Classify a window by `limit_window_seconds` (18000 = session, 604800 = weekly),
  never by `primary`/`secondary` position.** On an observed Pro account
  `primary_window` held the **weekly** window and `secondary_window` was `null`.
- **A `null` window means "no data", not "0% used"** — omit it, never render an empty
  bar. A window does not begin until a real generation request is made, so a dormant
  window is absent rather than zeroed. The app must never issue a generation request
  to start one; that would spend real quota.
- **`credits.balance` is a String** (`"0"`) in observed payloads. Accept String or
  Number.
- `plan_type` supplies `planLabel`.
- Identity fields are ambiguous: the response's `account_id` has been observed equal
  to `user_id` (`user-…`) while the request sends a different UUID. Key the account on
  the **credential's** `tokens.account_id`, not the response.

Useful fields worth surfacing: `rate_limit.allowed` / `limit_reached` (direct throttle
state) and `reset_after_seconds` (relative countdown, avoids clock-skew maths).

---

## 6. Polling, rate limits, caching

**Base interval: 5 minutes per account**, jittered, and **staggered** so N accounts
never fire simultaneously.

Anthropic's usage endpoint tolerates only a few requests per access token before
returning `429` for several minutes, and read-only forfeits the refresh mitigation
(§1). Therefore the interval is **adaptive**:

- Start at 5 min.
- On repeated `429` for an account, **lengthen that account's own interval**
  (5 → 10 → 20 → 30 min cap) and surface the degradation in that account's card
  (e.g. "rate limited · checking every 20 min"). It must never silently appear fresh.
- Recovery: a successful fetch resets the interval to 5 min.
- Honour `Retry-After` (seconds **or** HTTP-date) with a 60s floor.
- Backoff, cooldown, and interval state are **per account** — one rate-limited
  account must never stall the others.
- The actual `429` threshold will be **measured during implementation** and the
  starting interval revised if 5 min proves untenable; the measurement is recorded in
  the PR description.

Caching: last good `Snapshot` persisted per account. On failure, present
`.stale(snapshot, since:)` with an "as of HH:mm" label rather than blanking. A
`lastFetchAttempt` timestamp persists across restarts so cooldown survives relaunch.

Manual **Refresh** bypasses the interval but keeps a 60s floor. Disabled accounts are
never polled.

`401` / `403` mark the account `expired` and **stop** its timer — polling with a dead
token is pure waste. It resumes on manual refresh or credential change.

---

## 7. UI

### 7.1 Menu bar

```
⚡ 78%   ◆ 31%
```

One figure per **provider**, each independently coloured (green <70, amber <90,
red ≥90). `⚡` = worst across all enabled Claude profiles; `◆` = Codex.

**Worst-of selection prefers `isActive`**, falling back to max-percent when nothing is
flagged. (`is_active` exists precisely so a single-number UI needs no heuristics.)

A provider with no enabled/valid account is omitted entirely rather than showing 0%.
Tooltip names the source account and window.

### 7.2 Popover — collapsed cards

```
┌──────────────────────────────┐
│ CLAUDE                       │
│ ▸ default        ▓▓▓▓▓░ 62%  │
│ ▾ work-fiona     ▓▓▓▓▓▓ 78%  │
│     Session 5h   ▓▓░░░░ 20%  │
│       resets 11:04 PM        │
│     Weekly 7d    ▓▓▓▓▓▓ 78%  │
│       resets Fri 24 Jul      │
│     Extra  $0.00 · $15 free  │
│ ▸ work-ethan     Signed out  │
│                              │
│ CODEX                        │
│ ▸ pro             ▓▓░░░░ 31% │
│                              │
│ Updated 21:58 · Refresh      │
└──────────────────────────────┘
```

- One row per account: label, worst-of bar, percentage. Click to expand.
- **Expansion state persists** across popover opens and app restarts.
- `signedOut` / `expired` rows show an inline hint — *"Sign in via Claude Code"* — and
  are not expandable. They are never rendered as errors.
- `stale` rows show "as of HH:mm"; rate-limited rows show the degraded interval.
- Provider section headers are omitted when that provider has no accounts.

### 7.3 Settings

Adds **per-account enable checkboxes** (all discovered accounts on by default).
Retains the existing notifications toggle, Open-at-Login, and ⌘U shortcut toggle
with its Accessibility permission prompt.

### 7.4 Removed

- The entire cookie input block: instructions, `PasteableTextField`,
  `PasteableNSTextView`, `CustomTextField`, Save/Clear Cookie buttons.
- The "☕ Buy Dev a Coffee" Stripe button.
- Unused `import WebKit` and the `-framework WebKit` build flags.

---

## 8. Notifications

Thresholds stay `[25, 50, 75, 90]`.

Today a single global `lastNotifiedThreshold` key is compared against
`max(session, weekly)`. With N accounts that one slot is a race: one account crossing
75% suppresses another's alert, and whichever polls last wins. **This is a correctness
fix, not a feature.**

State becomes one entry **per `(account, window)`**, keyed
`notif.<provider>.<accountId>.<windowKind>`. Alert text names the source:
*"work-fiona · weekly hit 75%"*. Every enabled account notifies independently.

Hysteresis is retained: when usage drops below the recorded threshold, the stored
threshold is lowered to the highest band still met, so a reset re-arms the alerts.

---

## 9. File layout

`build.sh` invokes `swiftc` with a source list, so splitting costs one glob change.
`UsageManager` currently owns auth + fetch + parse + cache + notify + settings +
status bar in 1587 lines; it cannot absorb 2 providers × N accounts. This split is the
minimum that makes the feature tractable — not opportunistic refactoring.

```
app/
  Model/UsageModel.swift                    # AccountRef, UsageWindow, Snapshot, AccountState
  Providers/UsageProvider.swift             # protocol + FetchError
  Providers/AnthropicProvider.swift
  Providers/CodexProvider.swift
  Credentials/KeychainStore.swift           # strategy chosen by the Task 1 spike
  Credentials/ClaudeProfileDiscovery.swift  # dir scan, service-name resolution, gates
  Credentials/CodexAuthReader.swift
  Core/UsageStore.swift                     # accounts, per-account polling/backoff/cache
  Core/Notifier.swift
  Core/Settings.swift
  UI/MenuBarController.swift
  UI/PopoverView.swift
  UI/AccountCardView.swift
  UI/SettingsView.swift
  App/AppDelegate.swift
```

Both `swiftc` invocations (arm64 + x86_64) and the `lipo` universal-binary step are
preserved.

---

## 10. Testing

There is no test target today. Add a second `swiftc` target compiling the **pure**
logic — parsing, discovery, window classification, worst-of selection, threshold
bookkeeping — against **sanitised recorded fixtures** committed under
`app/Tests/Fixtures/`. Networking, Keychain, and SwiftUI stay out of the test target;
discovery takes an injectable filesystem/credential reader.

Each test encodes **why** the behaviour matters:

| Test | Regression it prevents |
|---|---|
| Fixture has `seven_day_sonnet: null` while `limits[]` carries a live scoped entry; parser reports the scoped usage | Reverting to flat-key parsing, which stays `200 OK` and silently under-reports |
| Default profile resolves to the unsuffixed item when a **present-but-empty** hashed item also exists | Reporting the primary account signed out (the real bug on the target machine) |
| `~/.claude-backups` and a dir with no `oauthAccount` are excluded | Non-accounts rendering as broken entries |
| A credential with no `refreshToken` yields `signedOut`, not `failed` | Logged-out profiles surfacing as errors |
| Codex fixture where `primary_window` is **weekly** (604800) and `secondary_window` is `null` | Classifying by position instead of duration |
| `credits.balance` as `"0"` and as `0` both parse | Naive numeric binding failing on the real payload |
| Scoped window with `percent: 0` but non-nil `resets_at` renders; `percent: 0` with `null` resets_at does not | Hiding a genuinely active freshly-reset window |
| Worst-of picks the `isActive` window over a higher-percent inactive one | Reintroducing max-only heuristics |
| Two accounts both crossing 75% each produce a notification | Cross-account threshold suppression |
| Money parsed from `amount_minor` + `exponent` | Floating-point currency |

`build.sh` gains a `--test` mode (or a sibling `test.sh`) that compiles and runs this
target; it must exit non-zero on failure.

---

## 11. Migration and cleanup

- Remove the `claude_session_cookie` UserDefaults key on first run of 2.0.0, along
  with the now-orphaned `cached_*` single-account keys and `last_notified_threshold`.
- No user action is required to upgrade: credentials are auto-discovered. If no
  account is found, the popover explains that Claude Code or Codex CLI must be signed
  in — it does **not** ask for a cookie.
- Bump `CFBundleShortVersionString` to `2.0.0` and increment `CFBundleVersion`.
- Make `build.sh`'s ad-hoc signing fallback **loud** (§2).

## 12. Documentation

Three files document the cookie flow and all need the same treatment:

- `README.md` — add fork framing ("a fork of
  [Artzainnn/ClaudeUsageBar](https://github.com/Artzainnn/ClaudeUsageBar) with OAuth
  auth, multi-profile and Codex support"); replace the 6-step cookie setup with
  "sign in to Claude Code / Codex CLI; the app finds it"; document multi-account and
  Codex; state the read-only credential guarantee. **Remove** the Product Hunt badge
  and any sponsor/donation section.
- `app/README.md` — same, for the feature list.
- `website/index.html` — same, for the setup copy and feature list.

The app name, bundle ID, and icon are unchanged.

Upstream is MIT-licensed; `LICENSE` and its copyright line are retained, with the
fork's attribution added rather than substituted.

---

## 13. Acceptance criteria

Verified against a **real run of the built `.app`**, not unit tests alone. UI claims
require a screenshot of the rendered popover and menu bar.

1. Spike (Task 1) has produced a recorded result naming the chosen Keychain strategy
   and whether a prompt occurs.
2. Launching the built app with no configuration discovers `default` and `work-fiona`
   as active accounts, `work-ethan` as `signedOut`, and Codex as active.
3. `~/.claude-backups`, `~/.claude-koop-llm-stub`, and all five orphan Keychain items
   appear nowhere in the UI.
4. The menu bar shows two independently-coloured figures, one per provider.
5. Expanding an account card shows its session, weekly, and any model-scoped windows
   with reset times; collapse state survives an app restart.
6. Model-scoped bars render from `limits[]` with payload-supplied labels — verified by
   confirming no model display name is hardcoded in the source.
7. Extra usage / free credits render for an account that has them, in minor units.
8. Two accounts crossing a threshold each produce a distinct, account-named
   notification.
9. Disabling an account in Settings removes it from the popover, the menu bar
   worst-of, and the polling schedule.
10. A forced failure (invalid token) renders `expired` with a sign-in hint and stops
    that account's timer, while other accounts keep updating.
11. `grep -ri 'cookie\|sessionKey\|donate.stripe\|producthunt' app/ website/ README.md`
    returns no functional hits.
12. The test target compiles and passes, exiting non-zero on failure.
13. **No code path writes to the Keychain, `.credentials.json`, or `auth.json`.**
    Verified by grepping for `SecItemAdd`, `SecItemUpdate`,
    `add-generic-password`, `delete-generic-password`, and any write to those paths.

## 14. Implementation order

1. **Spike:** Keychain read from a signed GUI app; decide strategy. *Blocking.*
2. Split the single file into §9 layout with **no behaviour change**; update
   `build.sh` glob; scaffold the test target.
3. `Model/` + `UsageProvider` protocol.
4. `KeychainStore` + `ClaudeProfileDiscovery` + tests.
5. `AnthropicProvider` fetch + `limits[]`/`spend` parsing + tests.
6. `CodexAuthReader` + `CodexProvider` + tests.
7. `UsageStore`: account registry, per-account adaptive polling, backoff, cache + tests.
8. `Notifier`: per-`(account, window)` thresholds + tests.
9. `MenuBarController`: per-provider worst-of.
10. `PopoverView` + `AccountCardView`: collapsed cards.
11. `SettingsView`: per-account toggles; delete cookie UI and coffee button.
12. Migration: purge old UserDefaults keys; version bump; loud signing fallback.
13. Docs: `README.md`, `app/README.md`, `website/index.html`.
