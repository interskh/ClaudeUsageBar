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
- Multiple Codex accounts. The environment-designated Codex configuration location is
  honoured, but only ever to locate the **single** active account — no enumeration.
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
shape, so **the UI renders usage without branching on provider**. Where presentation
must differ per provider (section grouping, menu-bar glyph, ordering), that identity is
supplied *by the provider* as data rather than discovered by the UI through a type
switch — so adding a third provider touches no view code.

```swift
enum ProviderKind { case anthropic, codex }

struct AccountRef: Hashable {
    let provider: ProviderKind
    // Identity is resolved BEFORE any request, from credential-side material only, so
    // persisted state can be keyed without a network round-trip. Each provider defines
    // its own canonical rule (§4): a durable account identifier where one is published,
    // otherwise a composite of the identifier fields available. It is never derived
    // from a response, never from a user-visible label, and never from the location the
    // credential happens to live in — locations and labels both change while the
    // account stays the same.
    let id: AccountIdentity
    let label: String     // presentation only — renaming it must not orphan history
    let subtitle: String? // email address, when known
}

// Temporal class and scope are INDEPENDENT dimensions. Collapsing them into one
// axis cannot represent a model-scoped limit that has both a short and a long
// window, and it collides the keys such a pair would need.
enum WindowSpan: Hashable {
    case session              // short rolling window
    case weekly               // long rolling window
    case other(seconds: Int)  // spans the providers have not standardised
}

// Scope identity uses the provider's STABLE discriminator, never its display text.
// Labels are renamed and reused by providers; keying on them would split one history
// in two on a rename, or merge two histories on a collision.
enum WindowScope: Hashable {
    case account                  // applies to the account as a whole
    case model(id: String)        // stable model discriminator
    case feature(id: String)      // stable metered-feature discriminator
}

struct WindowID: Hashable {
    let span: WindowSpan
    let scope: WindowScope
}

// Absent, unknown, and zero are three different facts and must stay distinguishable.
// Coercing an unknown utilization to zero manufactures headroom that may not exist.
enum Utilization {
    case known(Int)
    case unknown              // provider returned null, or omitted the figure
}

struct UsageWindow {
    let id: WindowID          // stable; drives persistence and keying
    let label: String         // presentation only; may change without changing identity
    let utilization: Utilization
    let resetsAt: Date?       // nil => window has never started
    let isActive: Bool        // provider marks this the currently binding limit
}

// Monetary metadata is NOT uniformly available. One provider supplies fully-qualified
// minor units with currency and exponent; the other exposes a bare balance with no
// currency and no scale. Requiring the full set would force fabricating a currency and
// an exponent that the payload never stated — presenting a guess as a fact. Amounts
// therefore carry their own qualification, and an unqualified amount is displayed as
// the provider stated it, without a currency symbol implying precision that is absent.
enum MonetaryAmount {
    case qualified(minor: Int, currency: String, exponent: Int)
    case unqualified(raw: String)   // provider gave a bare figure; never inferred
}

struct Spend {
    let used: MonetaryAmount?
    let limit: MonetaryAmount?
    let balance: MonetaryAmount?    // remaining prepaid / free credits
}

struct Snapshot {
    let account: AccountRef
    let planLabel: String?   // "Max 20x", "pro"
    let windows: [UsageWindow]
    let spend: Spend?
    let fetchedAt: Date
}

enum AccountState {
    // Credential is usable but no telemetry has been retrieved yet. Discovery resolves
    // to this, NOT to `active` — an account is authenticated well before it has a
    // reading, and collapsing the two would force discovery to either fabricate a
    // snapshot or misreport a healthy account as unauthenticated.
    case pending
    case active(Snapshot)
    case stale(Snapshot, since: Date)  // last good data; fetches currently failing
    case signedOut                     // no credential, or credential unusable
    case expired(Date)                 // access token past its own expiry; use the CLI
    case failed(String)
}

// Identity is opaque and provider-defined, but always derived from credential-side
// material that is stable across sign-ins. One provider derives it from the
// configuration location; the other from a composite of its ambiguous identifier
// fields (§4). Consumers only ever compare it — they never parse it.
struct AccountIdentity: Hashable { /* provider-defined, opaque to consumers */ }

// Discovery yields an account TOGETHER with its resolved state. Returning bare
// references could not express a signed-out or expired account, which the inclusion/
// state gate split (§4.1) explicitly requires be present rather than filtered away.
struct DiscoveredAccount {
    let ref: AccountRef
    let state: AccountState   // `.pending` when the credential is usable but unfetched
}

protocol UsageProvider {
    var kind: ProviderKind { get }
    var presentation: ProviderPresentation { get }  // glyph, section title, sort order
    func discoverAccounts() -> [DiscoveredAccount]
    func fetch(_ account: AccountRef) async -> Result<Snapshot, FetchError>
}
```

**Credential freshness is an invariant of `fetch`, not of `discoverAccounts`.** A
provider re-reads the credential from its store on **every** fetch and never caches an
access token in memory across polls. This is mandatory rather than an optimisation:
Claude Code rotates the access token roughly every 8 hours, so a token captured at
discovery is guaranteed to go stale while the on-disk credential remains healthy. A
design that caches it would permanently park a live account as expired (§6).

`signedOut` and `expired` are **display states, not errors** — read-only means every
failure is cosmetic, never destructive.

**Unknown utilization propagates as unknown.** It is never rendered as a zeroed bar,
never substituted with a prior reading, and never contributes to any aggregate — a
window of unknown utilization cannot be selected as a provider's worst-of, and cannot
arm or clear a notification threshold. Every consumer of a window must handle the
unknown case explicitly rather than defaulting it. The failure this prevents is the
only one that actively misleads: a bar reading zero because the provider declined to
say, presented identically to a bar reading zero because nothing has been used.

---

## 4. Credential discovery

### 4.1 Anthropic (multi-profile)

Discovery is **directory-driven**, never credential-store-driven. The store is keyed by
a one-way digest of the configuration path, so a credential entry cannot name the
profile it belongs to: enumerating the store yields opaque entries that cannot be
resolved back to an identity, including orphans belonging to directories that no longer
exist (five exist on the target machine). Directories, by contrast, carry the identity.

The consequence is that the conventional scan alone under-covers: a profile rooted at an
arbitrary path is invisible to it and, because the digest cannot be inverted, is
equally invisible to store enumeration. The candidate set is therefore the **union** of
three sources, so that convention is a convenience rather than the limit of what can be
tracked:

- the conventional home-directory locations (`~/.claude`, `~/.claude-*`);
- the configuration directory designated by the environment, when one is set;
- directories the user has explicitly registered.

Explicit registration is the escape hatch that makes arbitrary-location profiles
reachable; without it the design would silently cap the feature at one naming
convention.

For each candidate, resolve the Keychain **service name**:

- **Default dir (`~/.claude`): the unsuffixed `Claude Code-credentials` entry is
  authoritative.** This is mandatory, not an optimisation. On the target machine the
  derived name `sha256("/Users/kyle/.claude")[0..8] = 6a445fbb` **exists but is empty**
  (`expiresAt: 0`, no `refreshToken`, no `subscriptionType`); binding it would report
  the primary account as signed out. The derived location is **not consulted at all**
  for the default profile: the authoritative namespace is the only one, so when it is
  absent the account resolves to `signedOut`. Retaining a derived fallback would risk
  binding anomalous material — the empty entry on the target machine proves such
  material exists — to the primary identity, and no fallback can distinguish an
  anomaly from a legitimate credential.
- **Any other dir:** `"Claude Code-credentials-" + sha256(absolutePath)[0..8]`, where
  the path has **no trailing slash**. Verified: `~/.claude-work-fiona` → `6c3a8789`,
  `~/.claude-work-ethan` → `de838ebc`.

Two gates apply, and **they answer different questions**. Conflating them is what makes
a signed-out account unrepresentable — it would be filtered out before it could be
displayed as signed out.

- **Identity gate — decides inclusion.** The candidate must carry account identity
  (`<dir>/.claude.json` containing an `oauthAccount` object). A directory without it is
  not an account and never appears in any state. This is what excludes
  `~/.claude-backups` and `~/.claude-koop-llm-stub`.
- **Credential gate — decides state, never inclusion.** An included account is resolved
  to `pending`, `signedOut`, or `expired` by inspecting its credential alone. A usable
  credential yields `pending` — authenticated, not yet fetched; a missing or unusable
  one yields `signedOut`; a present but lapsed one yields `expired`. `work-ethan` is
  included and rendered `signedOut`.

The credential gate tests **only what the app actually consumes**: presence of an access
token and its recorded expiry. It must **not** require renewal material. Read-only
operation never uses a refresh token, so treating its absence as disqualifying would
mark an account unusable on the basis of a capability the app deliberately declines to
exercise — an otherwise valid credential stays `active` until its own expiry passes.

**Identity is the account, not the location.** The configuration directory is how an
account is *found*; it is not what the account *is*. The identity metadata already
present alongside the credential carries a durable account identifier, and that is what
keys persisted state. Keying on the location instead would mean signing a different
account into the same directory silently inherits the previous occupant's cached
readings and notification history — precisely the misattribution the identity rules
exist to prevent. A location whose account identifier changes is treated as a different
account, and the prior account's state is reclaimed under §6.

Label = directory basename with a leading `.claude-` stripped, or `"default"` for
`~/.claude`. Labels and locations may both change without changing identity.
Subtitle = `oauthAccount.emailAddress`. Plan label derives from
`claudeAiOauth.subscriptionType` + `rateLimitTier`, replaced by live response data
when available.

Credential blob fields: `accessToken`, `refreshToken`, `expiresAt` (Unix **ms**),
`refreshTokenExpiresAt` (Unix ms), `scopes`, `subscriptionType`, `rateLimitTier`.

### 4.2 Codex (single account)

`$CODEX_HOME/auth.json`, else `~/.codex/auth.json`. Require `auth_mode == "chatgpt"`
and a non-empty `tokens.access_token`.

**Identity is composite, with an explicit collision policy.** This provider's identity
fields are ambiguous: the identifier sent with the request and the ones returned in the
response have been observed to disagree, with the response's account identifier equal to
its user identifier. No single field is trustworthy as the identity, so the account is
keyed on a **composite** of the account and user identifiers. When they collide or
disagree, the case is handled explicitly and surfaced rather than silently resolved to
one of them. Getting this wrong misattributes persisted state — notification history and
cached readings — from one signed-in account to the next.

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

**Retain the most recent raw response per account alongside the projected model.**
Because both vendors add and retire fields without announcement, and because a
schema drift here fails silently rather than loudly, the raw payload is the only
way to answer "was this field ever present, and when did it change shape?" without
shipping a new build to find out. Retention is bounded — latest response per
account, not a history — and it is diagnostic-only: no display path may read it,
so it can never become a shadow parser. Because these payloads contain account
identifiers and plan details, retained bodies are treated as sensitive: stored
under the app's own container with the same care as a credential, never logged
wholesale, and discarded when an account is removed.

### 5.1 Anthropic

```http
GET https://api.anthropic.com/api/oauth/usage
Authorization: Bearer <claudeAiOauth.accessToken>
anthropic-beta: oauth-2025-04-20
User-Agent: claude-code/<resolved version — see below; value shown is illustrative>
Content-Type: application/json
```

Both the `anthropic-beta` header and a plausible CLI `User-Agent` are load-bearing.

**The advertised version is derived from the locally installed CLI, not pinned at
compile time.** A hardcoded constant rots: the value above was already ~150 releases
behind the installed CLI on the day this spec was written, and the endpoint is
documented to care about agent plausibility. The version is therefore resolved from the
installed CLI, **cached and re-resolved at most once daily**, with a compile-time
constant retained only as a floor when resolution fails.

Two constraints make this architectural rather than incidental:

- **Resolution must not depend on the inherited environment.** A menu-bar app launched
  by the window server or as a login item does not inherit the user's shell PATH, so a
  bare command lookup succeeds in development and fails silently in the shipped bundle.
  Resolution probes known install locations directly and treats "not found" as a normal
  outcome, falling back to the floor constant.
- **The version source must be the executable itself.** Version-like fields recorded in
  the CLI's own config are onboarding artefacts, not the running version, and were
  observed to be many releases stale on the target machine.

Resolution failure is never fatal and never blocks a fetch; the floor constant ships a
working request.

Parse **`limits[]`**, not the flat `five_hour` / `seven_day` / `seven_day_sonnet` keys.
The `seven_day_<model>` keys are legacy mirrors that now return `null` even while the
corresponding entry in `limits[]` is live and non-zero.

Each `limits[]` entry:

| Field | Maps to |
|---|---|
| `kind` — `session` \| `weekly_all` \| `weekly_scoped` | `WindowID.span` (+ `.scope` below) |
| `percent` (Int **or** Double, **nullable**) | `Utilization` — `null`/absent ⇒ `.unknown` |
| `resets_at` (RFC3339, **nullable**) | `UsageWindow.resetsAt` |
| `is_active` | `UsageWindow.isActive` |
| `scope.model` | `WindowScope.model(id:)` — see the discriminator rule below |
| absence of a scope | `WindowScope.account` |

Rules:

- **Render a scoped bar on presence of a reset time, not on a non-zero utilization.**
  Unused models always report zero; a freshly-reset but genuinely active window also
  reports zero. Utilization cannot distinguish them — the reset time can.
- **Scope discriminator, with an acknowledged shortfall.** §3 requires scope identity to
  come from a stable discriminator rather than display text. This provider exposes both
  a model identifier and a display name, but the identifier has been **observed null**
  while the display name was populated. Identity therefore prefers the stable
  identifier and falls back to the display name only when it is absent. The fallback is
  a known, accepted weakness — a provider-side rename of a model whose identifier is
  null will split that window's history — and it is recorded here rather than hidden,
  because silently keying everything on display text would make the same breakage
  invisible. The display name is never used as identity when an identifier exists.
- New models appear automatically with a usable label — **no client-side label map.**
  No model display name is hardcoded anywhere in the new code.
- `limits` is a JSON **array** at top level and `spend` is an object of a different
  shape; a parser that assumes every top-level value is a quota object must skip
  non-conforming keys per-key, not fail the decode.
- Ignore experimental codename keys (`tangelo`, `iguana_necktie`, `omelette_promotional`,
  `nimbus_quill`, `cinder_cove`, `amber_ladder`, …). They are almost always `null`.
- **`null` ≠ 0.** `null` means "not applicable to this plan".

`spend` → `Spend`. This provider publishes fully-qualified money, so `used`, `limit`,
and `balance` each become a **qualified** amount from `amount_minor` + `exponent` +
`currency`. **Money is never parsed as a Double.** Field presence does not
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

Normalisation is a **flattening, not a one-to-one mapping**. The account-level bucket,
every named feature bucket, **and any separately-named quota class the payload carries
outside those two groups** each hold their *own* set of temporal windows, so a single
bucket can contribute more than one window. Emit one `UsageWindow` per `(scope, span)`
pair actually present, taking the scope from the bucket and the span from each window
inside it. Mapping one bucket to one window silently discards every additional temporal
window a bucket holds — the same self-describing-bucket blindness the flat-key trap
causes on the other provider.

**Ingestion is exhaustive over quota-bearing groups, not a fixed list of two.** This
provider carries at least one further named quota class alongside the account-level and
feature-list groups; modelling only the groups enumerated here would silently omit a
live limit. Any top-level object that carries the same window shape is ingested as a
scoped bucket, and an unrecognised quota-bearing group is surfaced rather than dropped.

Scope identity comes from the bucket's **stable feature discriminator**; its display
name supplies the label only (§3).

Rules:

- **Classify a window by `limit_window_seconds` (18000 = session, 604800 = weekly),
  never by `primary`/`secondary` position.** On an observed Pro account
  `primary_window` held the **weekly** window and `secondary_window` was `null`.
- **A `null` window means "no data", not "0% used"** — omit it, never render an empty
  bar. A window does not begin until a real generation request is made, so a dormant
  window is absent rather than zeroed. The app must never issue a generation request
  to start one; that would spend real quota.
- **`credits.balance` is a String** (`"0"`) in observed payloads. Accept String or
  Number, and carry it as an **unqualified** amount — this provider states no currency
  and no scale, so neither may be inferred (§3).
- `plan_type` supplies `planLabel`.
- Identity fields are ambiguous: the response's `account_id` has been observed equal
  to `user_id` (`user-…`) while the request sends a different UUID. Resolve identity by
  the composite rule in §4.2 rather than trusting any single field, and treat a
  disagreement between the credential's identifier and the response's as a condition to
  surface, not to silently reconcile.

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
- **Recovery is hysteretic, never a snap back to base.** A single success must not
  restore the most aggressive cadence: the condition that caused throttling is a
  sustained request rate, so immediately resuming that rate reproduces it, yielding a
  throttle–recover–throttle oscillation that is worse than a steady slower cadence.
  Recovery steps back toward base gradually and only after sustained success, and the
  account additionally honours a **sustained request budget** over a rolling span, so
  that no combination of scheduled polls, manual refreshes, discovery-triggered fetches,
  and retries can exceed the rate the endpoint tolerates. The budget is the binding
  constraint; the interval is merely how it is normally spent.
- **The budget is scoped to the credential, not to the logical account.** Throttling is
  enforced upstream per access token, so two accounts that happen to resolve to the same
  credential — a copied or shared configuration — would each be granted a full budget
  and jointly exceed the one limit that actually binds. Accounts sharing a credential
  therefore share a single budget.
- Honour `Retry-After` (seconds **or** HTTP-date) with a 60s floor.
- Backoff, cooldown, and interval state are **per account** — one rate-limited
  account must never stall the others.
- The actual `429` threshold will be **measured during implementation** and the
  starting interval revised if 5 min proves untenable; the measured figure is recorded
  in this spec so the chosen cadence stays traceable to evidence.

Caching: last good `Snapshot` persisted per account. On failure, present
`.stale(snapshot, since:)` with an "as of HH:mm" label rather than blanking. A
`lastFetchAttempt` timestamp persists across restarts so cooldown survives relaunch.

**Cached data has a validity horizon.** Beyond it, a cached figure is suppressed rather
than displayed — a quota reading hours or days old is not merely imprecise, it is
misleading in the one direction that matters, implying headroom the user may not have.
Past the horizon the account renders as unknown with its last-seen time, and it never
contributes to the menu-bar worst-of. The horizon is defined per window class, since a
session window ages far faster than a weekly one.

Manual **Refresh** bypasses the interval but keeps a 60s floor. Disabled accounts are
never polled.

**Authentication failures re-read before concluding.** Because the access token is
re-read from its store on every fetch (§3) and rotates roughly 8-hourly, an
authentication rejection is ambiguous: it may mean the credential is genuinely dead, or
merely that it rotated between read and request. A rejection therefore triggers one
immediate re-read and retry; only a second consecutive rejection with a credential
whose stored expiry has genuinely passed marks the account `expired` and stops its
timer. Treating the first rejection as terminal would permanently park healthy accounts.
An authorization failure that is not an expiry — a revoked or scope-reduced credential —
is distinguished from transient upstream blocking, which backs off and retries rather
than stopping.

**A stopped account must have a defined path back to life.** Because the app cannot
renew a credential itself, recovery depends entirely on an external writer — the
provider's own CLI — updating the store at an unpredictable time. Stopping the timer
without a wake-up contract would therefore make expiry effectively permanent: the user
signs in again and the app never notices. An account whose polling has stopped is
revived by **observing that its stored credential has changed**, in addition to manual
refresh and the periodic re-discovery above. Credential observation is cheap and local,
so it continues on a slow cadence even for accounts whose polling has stopped; it costs
no upstream requests, which is what makes it safe to keep running under a rate-limit
budget.

**Account discovery re-runs on a schedule, not only at launch.** Profiles are created,
signed into, and signed out of while the app is running; a launch-only scan would leave
a newly added account invisible until relaunch and a signed-out one displayed
indefinitely. Discovery is cheap and local, so it re-runs periodically and on popover
open, adding and removing accounts without disturbing existing accounts' polling state.

**Persisted per-account state has an explicit lifecycle.** Threshold bookkeeping,
cached snapshots, retained raw bodies, and card expansion are all keyed by account, and
accounts churn — this machine already carries five credential entries belonging to
directories that no longer exist. Without a lifecycle, that keyspace grows without
bound and stale entries silently resurrect when an identifier is reused. Therefore:
state for an account absent from discovery is reclaimed rather than left in place, and
per-account state is namespaced so a whole account's state can be dropped as a unit.
The same applies within an account, where model-scoped windows appear and disappear as
providers introduce and retire models.

Account identity is the durable account identifier (§4), not the label and not the
location, so neither relabeling a profile nor moving it orphans its history — the
account is recognised as the same account wherever it is found. Identity changes only
when the account itself changes: a different account signing into the same location is
a different account, and the previous occupant's state is reclaimed as above rather
than inherited. Losing threshold history is acceptable; silent misattribution of one
account's usage to another is not.

**State ownership is single-writer.** Accounts poll concurrently and independently, but
all mutation of the shared account registry, the menu-bar projection, and persisted
state is serialised onto one owner. Providers are pure with respect to that state:
they return a snapshot and never mutate the registry. This keeps concurrent fetches
from interleaving partial updates into a menu-bar figure that belongs to no single
consistent reading.

---

## 7. UI

### 7.1 Menu bar

```
⚡ 78%   ◆ 31%
```

One figure per **provider**, each independently coloured (green <70, amber <90,
red ≥90). `⚡` = worst across all enabled Claude profiles; `◆` = Codex.

**Worst-of selection prefers the provider-marked binding window**, falling back to the
highest known utilization when nothing is flagged. (Providers mark the binding limit
precisely so a single-number UI needs no heuristics.)

**An unknown binding window makes the aggregate unknown — it does not fall through.**
If the window the provider marks as binding has unknown utilization, the provider's
menu-bar figure renders as unknown rather than reporting the next-highest *known*
window. Falling through would present a lower number sourced from a non-binding window
as though it were the constraint, which is precisely the manufactured-headroom failure
the unknown-utilization invariant exists to prevent (§3).

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
- `pending` rows show the account with a loading indicator in place of a bar — never a
  zeroed bar, which would be indistinguishable from genuine zero usage. A pending
  account contributes nothing to the menu-bar figure until it has a reading.
- `stale` rows show "as of HH:mm"; rate-limited rows show the degraded interval.
- Provider section headers are omitted when that provider has no accounts.

### 7.3 Settings

Adds **per-account enable checkboxes** (all discovered accounts on by default).
Retains the existing notifications toggle, Open-at-Login, and ⌘U shortcut toggle
with its Accessibility permission prompt.

**Settings owns the full lifecycle of manually registered locations** (§4.1) — adding
one, listing what has been added, and removing one. Without this the escape hatch for
arbitrary configuration locations would be unreachable, and the design would silently
degrade to convention-only discovery. Registered locations are user-owned state and
persist across launches. A registered location that fails the identity gate is reported
as such at the moment of registration rather than being accepted and silently ignored,
and removing a registration reclaims that account's persisted state on the same terms
as any other account that leaves discovery (§6).

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
by provider, account, and the window's full identity — **both** its temporal span and
its scope, since a model-scoped short window and a model-scoped long window are distinct
alerts. Alert text names the source:
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
| An account whose credential is missing/unusable is **present** in the result, in the signed-out state | Conflating the inclusion gate with the state gate, which makes signed-out unrepresentable |
| A credential with a usable, unexpired access token but **no renewal material** resolves `pending`, and reaches `active` only after a successful fetch | Disqualifying an account over a capability the app never exercises; and collapsing authenticated-but-unfetched into active |
| Codex fixture where `primary_window` is **weekly** (604800) and `secondary_window` is `null` | Classifying by position instead of duration |
| `credits.balance` as `"0"` and as `0` both parse | Naive numeric binding failing on the real payload |
| Scoped window with zero utilization but a non-nil reset time renders; zero with a null reset time does not | Hiding a genuinely active freshly-reset window |
| A null/absent utilization yields `unknown`, renders as unknown, and is excluded from worst-of and from threshold arming | Coercing unknown to zero, manufacturing headroom the account may not have |
| Worst-of picks the `isActive` window over a higher-utilization inactive one | Reintroducing max-only heuristics |
| Two accounts both crossing 75% each produce a notification | Cross-account threshold suppression |
| Windows sharing a scope but differing in temporal span keep distinct threshold state | Collapsing span and scope into one key, so one window's alert suppresses the other's |
| An authentication rejection re-reads the credential and retries before any account is marked expired | Parking a healthy account permanently when its token rotated mid-request |
| After throttling, a single success does not restore base cadence | Throttle–recover–throttle oscillation |
| Composite identity distinguishes two credentials that share one identifier but differ in the other | Misattributing one account's history to another after a sign-in switch |
| Money parsed from `amount_minor` + `exponent` | Floating-point currency |
| A bare balance with no currency/scale stays unqualified and renders without a currency symbol | Fabricating a currency and precision the provider never stated |
| A quota-bearing group outside the two enumerated ones is still ingested | Silently omitting a live limit that sits outside the modelled groups |
| Two accounts resolving to one credential share a single request budget | Jointly exceeding the one upstream limit that actually binds |
| Signing a different account into one location does not inherit the previous occupant's history | Location-keyed identity misattributing usage across sign-ins |

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
2. Launching the built app with no configuration discovers `default`, `work-fiona`, and
   Codex as `pending`, each reaching `active` after its first successful fetch, and
   `work-ethan` as `signedOut`.
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
10. A credential whose own expiry has genuinely lapsed renders `expired` with a
    sign-in hint and stops that account's timer, while other accounts keep updating.
    A rejection that is *not* an expiry is retried after a credential re-read and, if
    it persists, is distinguished from expiry rather than collapsed into it (§6).
11. An account whose timer has stopped resumes automatically once its stored credential
    changes on disk, without a manual refresh or an app restart.
12. A configuration directory outside the naming convention can be registered, appears
    as an account, and can be removed again — with its persisted state reclaimed.
13. An account is never displayed with a zeroed bar sourced from an unknown
    utilization; unknown renders as unknown and is excluded from the menu-bar figure.
14. `grep -ri 'cookie\|sessionKey\|donate.stripe\|producthunt' app/ website/ README.md`
    returns no functional hits.
15. The test target compiles and passes, exiting non-zero on failure.
16. **No code path writes to the Keychain, `.credentials.json`, or `auth.json`.**
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
11. `SettingsView`: per-account toggles; add/list/remove manually registered
    configuration locations; delete cookie UI and coffee button.
12. Migration: purge old UserDefaults keys; version bump; loud signing fallback.
13. Docs: `README.md`, `app/README.md`, `website/index.html`.
