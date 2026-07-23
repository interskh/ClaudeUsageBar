# Implement-loop handoff log — multi-provider UsageBar

Decisions made during implementation, and the alternatives rejected. Recorded so the
end-of-run whole-worktree review can check cross-task coherence, and so a later reader
knows which choices were deliberate rather than accidental.

Spec: `docs/superpowers/specs/2026-07-22-multi-provider-usage-bar-design.md`
Branch: `implement-loop/multi-provider`

---

## Task 1 — Keychain spike (`0783f59`)

**Decision: read credentials by shelling out to `/usr/bin/security`, not `SecItemCopyMatching`.**

Measured, not reasoned. A hardened-runtime `.app` stub was built and launched twice
through the GUI path with a byte-identical binary:

| Strategy | Run 1 | Run 2 | Result |
|---|---|---|---|
| `SecItemCopyMatching` | 9796 / 5875 ms | 9614 / 2240 ms | prompts every launch |
| `security` subprocess | 102 / 101 ms | 121 / 99 ms | silent every time |

**Rejected: the direct Security-framework API.** It works, but prompts on every launch
because this machine has **no valid Developer ID identity** — `security find-identity`
returns zero — so `build.sh` ad-hoc signs, and an ad-hoc designated requirement is a
`cdhash` pin that any rebuild invalidates. The subprocess strategy is immune because the
process the ACL evaluates is Apple-signed `/usr/bin/security`, whose identity does not
change when we rebuild.

**Consequence for later tasks:** the spec's advice to "keep the signing identity stable"
is not an available remedy here, which promotes task 12's loud signing fallback from
hygiene to a correctness requirement.

---

## Task 2 — Split the monolith (`2cb51e6`)

**Decision: pure mechanical split, zero behaviour change, cookie code left intact.**

Cookie auth, the donation button and the flat-key parser all survive verbatim even
though later tasks delete them. **Rejected: deleting them during the split**, which
would have merged a 1587-line file move with semantic changes into one unreviewable
diff. Verified byte-equivalence three ways; the only substantive delta across ~1600
lines is one forced visibility widening (`private` is file-scoped in Swift and two new
files touch that member).

**Decision: `set -euo pipefail` in `build.sh`.** Not cleanup. The script previously
printed "Build successful!", exited 0, and re-signed and launched the *previous* binary
whenever compilation failed. Since `build.sh` is the verification gate for tasks 3–12, a
later doer would have run a stale app, seen it work, and misattributed the regression to
this split.

**Decision: three declared directory sets** (`PURE_DIRS` / `APP_ONLY_DIRS` / `TEST_DIRS`)
rather than an opt-out `find` from the cwd. **Rejected: `find . -not -path ./Tests/*`**,
which is cwd-anchored and leaked a second `@main` into the app target when invoked from
the repo root.

---

## Task 3 — Model and provider protocol (`a699334`)

**Decision: `AccountRef` compares and hashes over durable identity ALONE.**
**Rejected: Swift's synthesized `Hashable`**, which covers `label` and `subtitle`, so
renaming a profile directory — or merely discovering an account's email after first
fetch — silently orphans its cached snapshot and threshold history. Tasks 8 and 10 will
both reach for `[AccountRef: …]` because it is the obvious key and it compiles.

**Decision: `Utilization` exposes no optional accessor, no `rawValue`, no `Comparable`,
no defaulting init.** Every consumer must `switch`. **Rejected: a convenience accessor**,
which puts `?? 0` one keystroke away; coercing unknown to zero manufactures headroom the
account may not have.

**Decision: composite identity keeps its components as a list, not a joined string**, and
the persistence key escapes the escape character *before* the separator. Fuzzed: 72
distinct identities → 72 distinct keys. A colon-only escaper — the plausible refactor —
collides 7 of them.

**Decision: `fetch` returns the raw response body on both the success and
malformed-response paths.** The spec requires retaining the most recent raw response per
account while forbidding providers from writing persisted state, so it must be returned.
Done now because the blast radius is zero; after tasks 6, 7 and 10 consume the signature
it would touch all three.

**Decision: `Snapshot` carries a warnings channel.** The observed Codex `account_id`
mismatch is the *normal* state on this machine, so modelling it as a `FetchError` would
render the only real Codex account as a hard failure.

**Deviation from the spec's literal code block:** `fetch` returns `FetchedSnapshot`
rather than bare `Snapshot`. Spec updated to match.

---

## Task 4 — Keychain reader and profile discovery

**Two spec errors found by implementing against it, both verified against the real
machine and both corrected in the spec.**

1. **The identity gate excluded the primary account.** §4.1 said a directory is an
   account iff `<dir>/.claude.json` holds an `oauthAccount`. On this machine
   `~/.claude/.claude.json` has **no** `oauthAccount` — the home-level `~/.claude.json`
   carries it — while every non-default profile carries it in-directory. Applied
   literally, the app shows fiona and ethan and silently omits `default`. Resolution: the
   default directory *only* falls back to the home-level file; no other profile may
   inherit it, or a signed-out sibling could borrow the default account's identity.

   The general shape: **the default profile is the odd one out in two independent
   places** — the credential namespace *and* the identity file location. The spec caught
   the first and did not generalise.

2. **The trailing-newline claim was wrong.** The spec (and the task brief) said the
   subprocess's trailing newline must be trimmed "or JSON decoding fails".
   `JSONSerialization` tolerates trailing ASCII whitespace — measured. The naive test
   guarded nothing and passed against a non-trimming implementation. The trim's real
   purpose is a reader-independent canonical byte form, which §6's credential-change
   detection compares; it also strips a trailing NUL, which `JSONSerialization` *does*
   reject.

**Decision: `failed` is distinct from `signedOut`.** A locked Keychain, an unlaunchable
subprocess and a corrupt payload previously all rendered as a confident "you are signed
out" — advice that is wrong and sends the user to re-authenticate a working session.
This matters disproportionately because `signedOut` is the terminus of several
independent wrong turns (hash-first namespace resolution, the literal identity gate, a
non-absolute config path), every one of them silent. Spec §3 and §4.1 updated.

**Decision: `build.sh` gained an `APP_ONLY_FILES` exclusion** so the impure Keychain
reader compiles into the app target but not the test target, preserving §9's layout.
**Rejected: moving the file to a new directory**, which would fork the spec's layout for
a build-system reason and force future `Credentials/` files to be classified by folder
rather than by what they do.

**Decision: an `oauthAccount` with no identifier field at all is excluded** — a slight
narrowing of "included iff present" — because §3 forbids location-derived identity and
there would be nothing durable left to key persisted state on.

**Stale spec comment corrected:** §3 still said one provider "derives it from the
configuration location", contradicting the same paragraph's rule that identity is never
location-derived. A leftover the spec loop's final round flagged but did not fully
propagate.

**Security finding: the credential blob contains unrelated third-party secrets.**
Inspecting a real entry showed that alongside `claudeAiOauth` it carries an `mcpOAuth`
section with **live client IDs and client secrets for unrelated MCP servers**. Two rules
follow, now in §6:

- §6's credential-change detection must compare a **digest**, never a retained copy of
  the blob. The obvious implementation — keep the last blob and diff it — would write
  other services' live secrets to disk, a worse exposure than the one the read-only rule
  was written to prevent.
- Parse **only** the `claudeAiOauth` subtree; never decode the whole document into a
  retained structure, and never quote any part of the blob in a log, an error, or a
  fixture.

Found the hard way: an ad-hoc inspection script used an allow-by-name redaction filter
(`accessToken`/`refreshToken`/`idToken`) rather than deny-by-default, and printed three
live Supabase client secrets. The affected credentials were reported for rotation. The
transferable rule is that any script touching a credential store must print an explicit
allowlist of fields, never "everything except the ones I thought of".

### Task 4 — fix round 1 (doer's record)

**Decision: duplicate identities are resolved by credential health, not scan order.**
Two directories can legitimately carry the same `accountUuid` (a copied configuration),
and each has its OWN credential entry because the service name is derived from the path.
First-scanned-wins let a stale copy shadow the directory holding the live credential —
the app reported a working login as signed out and never consulted the good entry. Rank:
`pending` < `expired` < `failed` < `signedOut`, scan order as tie-break (so `~/.claude`
still wins among equals). **Rejected: merging the two candidates' states**, which would
invent a state neither directory is in; and **rejected: keeping both as separate
accounts**, which would double-poll one credential and split its history in two.

**Decision: `ClaudeCredentialSource` returns a three-case `CredentialLookup`, not
`Data?`.** An optional cannot distinguish "no item" from "could not read". **Rejected:
`Result<Data, Error>`** — it makes absence an error, and absence is the normal case.

**Decision: `credentialDigest` is the public comparison value; `canonicalBlob` is
private and transient.** Per the security finding, the blob carries third-party
`mcpOAuth` secrets, so task 7 must hold a digest and never the bytes.

**Decision: path normalisation is hand-rolled and lexical.** Foundation's
`standardizingPath` expands `~` against the PROCESS's home (bypassing the injected one —
the file header's isolation claim was false) and consults the real filesystem
(`/private/tmp/x` → `/tmp/x`). Since the service name is the digest of this string, the
second silently produces a name the CLI never wrote. Relative paths are REJECTED, not
resolved: there is no defensible base for a window-server-launched app.

**Decision: `build.sh` greps the collected TEST sources for impure dependencies**
(`usr/bin/security|SecItem|import Security|URLSession|import SwiftUI|import
AppKit|NSHomeDirectory|ProcessInfo|Process\(`) and fails loud. The `APP_ONLY_FILES` list
is hand-maintained and will rot as tasks 5-6 add files; the grep does not. Consequence
for later tasks: a new pure file must not name those symbols even in a comment.

**Assumption:** `security` exits 44 for errSecItemNotFound (unchanged); a non-zero exit
that is not 44 is a fault, not an absence. Check by running the tool against a
nonexistent service.

**Deferred:** §10's row "two accounts resolving to one credential share a single request
budget" is **unreachable on the Anthropic path as written** — one credential entry
belongs to exactly one directory (service name = digest of path), and two directories
sharing an account now collapse to one account. Codex is single-account. Recommendation
for task 7: key the request budget on the **service name** carried by
`ResolvedClaudeProfile`, which is correct regardless, rather than writing a test for a
scenario that cannot occur.

> **Corrected in task 7 — the recommendation named the wrong identifier.** The service
> name is a digest of a configuration *path*; §6 scopes the budget to the *access token*,
> which is what upstream throttles. Two directories holding the same credential — a copied
> configuration, the scenario §6 names — resolve to two service names and would each be
> granted a full allowance: ten requests per 300s against the one limit that binds. Task 7
> keys the ledger on the **credential digest** §6 already compares for change detection,
> keeping the service name only as a namespaced fallback when there is no credential to
> digest. The digest rotates with the token, so a rotation *migrates* the ledger rather
> than reissuing it. The scenario is reachable and is now tested.

**Touches:** `Credentials/{KeychainStore,ClaudeProfileDiscovery,SystemProfileFileSystem}
.swift`, `Tests/ClaudeProfileDiscoveryTests.swift`, `Tests/Fixtures/anthropic/*`,
`build.sh` (shared surface: `APP_ONLY_FILES`, `IMPURE_PATTERNS`, `collect_swift`'s
`EXCLUDED`). `ResolvedClaudeProfile` is the surface tasks 5 and 7 consume.

---

## Task 5 — `AnthropicProvider`: OAuth fetch and `limits[]` parsing

**The governing rule, learned the hard way: a parser can be exhaustive at INGESTION and
lossy at PROJECTION.** Ingestion was correct from the first draft — no flat key is read
anywhere, and mutating in an allow-list of known `kind`s fails five tests. Every bug found
in two review rounds was downstream of it: an entry read successfully and then dropped,
merged, or misscaled. That reproduces the exact silent under-report this task exists to
kill, one layer lower, while every ingestion test stays green.

The rule now stated in the file: **nothing below ingestion may delete a window it managed
to read; the worst it may do is give it a degraded, distinct identity and say so.**

**Decision: an entry that cannot be identified is kept with a fallback identity, never
dropped.** The chain is resolved scope → `.feature(id: "group:<group>")` →
`.feature(id: "index:<n>")`, each branch namespaced so it cannot alias a scope dimension
or a `kind`. **Rejected: dropping the entry and warning**, which is what the first two
drafts did — measured, an unscoped 10% window plus an unidentifiable 95% window reported
`bindingUtilization = .known(10)`, an 85-point under-report with the true figure existing
nowhere but a warning string. §5.1 mandates a discriminator fallback chain; it never
sanctions deleting the window.

**This bug was fixed twice.** Round 1 fixed it on the `scope` path and wrote the invariant
into the file as a comment. The `kind` path nine lines away still returned `nil`, so the
identical 85-point under-report survived through the adjacent field — caught by the
verifier, not by review. **The transferable lesson: stating an invariant is not enforcing
it.** A sweep of all twelve early-return sites followed, which turned up a second silent
drop nobody had reported (a `spend` field present but not an object read as "no spending
at all"). Neither reviewer nor the verifier found that one; only the systematic pass did.

**Decision: position (`index:n`) is the last-resort identity, knowingly unstable.** Under
vendor reordering the `WindowID` changes, which resets §8 threshold state and re-fires the
whole [25,50,75,90] ladder. Accepted deliberately: under-reporting is the failure this
provider exists to prevent, a re-fired ladder is noise rather than a wrong number.
**Consequence for task 8 — this is the ONLY `WindowID` in the file that is not stable
across polls.** Anything persisting per-window state keyed on `WindowID` must treat this
case as intentionally volatile. Two `kind`-less entries sharing a `group` also still
collide; both windows survive, `collidingIdentities` fires, and `bindingUtilization`
iterates the full window list rather than a deduped map, so the worse figure is still
reported — degraded history, never a lost figure.

**Decision: a window's span comes from a duration, never a position.** An explicit numeric
duration field wins if one appears; otherwise the leading token of `kind` maps to seconds
through `WindowSpan(seconds:)`, the model's canonicalising factory, so this provider cannot
spell a span differently from §5.2's numeric path. **Rejected: guessing a duration for an
unrecognised class** (`monthly` → 30 days) — it merges an unknown class onto a canonical
span; the length of a month is not the vendor's to have left unstated.

**Decision: money keeps its scale even when partly qualified.** `{amount_minor: 1500,
exponent: 2}` with no currency renders `15.00`, not `1500`. **The original draft emitted
the minor-unit integer as a bare figure — a 100× over-report — and a test asserted that
was correct.** The test is now inverted with a comment recording why the bug survived its
own suite. `MonetaryAmount.unqualified(raw:)` means "the provider gave a bare figure";
here it gave a scaled one. **Rejected: `NSNumber.intValue` anywhere** — it wraps silently
(`99999999999999999999` → `7766279631452241919`, a fabricated figure presented as fact).
One round-trip-checked `exactInteger` now serves minor units, exponents and durations.
Negative amounts are **kept deliberately**: a refund or credit is legitimately negative.

**Decision: utilization is clamped in the provider, not the model.** `Utilization.percent
(_: Double)` guards only `isFinite` and then does `Int(value.rounded())`, which TRAPS —
`percent: 1e30` killed the process (exit 133). Clamping provider-side keeps the model's
contract honest; **rejected: widening the model's `Double` overload**, which would sanction
handing it unrepresentable figures from every future provider.

**Decision: `resets_at` is a three-case `Timestamp`** (`absent` / `parsed` / `unreadable`).
A single optional conflated four facts, and a 0%-utilization window whose reset time merely
failed to parse was dropped as "never started" with no warning. Only `.absent` may qualify
a window as dormant. **Measured: `ISO8601DateFormatter` parses fractional OR whole seconds,
never both** — the two option sets are disjoint, so both are tried; one formatter silently
loses every reset time the day the vendor drops microseconds.

**Decision: `FetchError` gained a terminal `.accountUnknown`.** "Account no longer present
in local discovery" previously mapped to `.transport`, which §6 retries forever.
**This modifies task 3's committed protocol file and is a deliberate source break** — any
`switch` written against the old five cases will fail to compile, so the terminal case
cannot be silently folded into the backoff path.

**Agent version resolves from the installed CLI with no PATH dependence** — ~8 absolute
candidate paths, `<path> --version`, 24h cache, compile-time floor on failure. Proven under
`env -i` with no `PATH` and no `HOME` (macOS resolves home from the user record). An
explicit minimal `Process.environment` is set so an npm-style `#!/usr/bin/env node`
launcher resolves its interpreter deterministically rather than from an inherited PATH;
on this machine the installed `claude` is a Mach-O binary with no shebang, so that path is
hardening, not a live fix.

### Carried forward — not fixable inside this task

- **`spend.percent` is a REGRESSION, not an omission.** It is present and non-null in the
  live payload and the shipped v1.3.2 app rendered its extra-usage bar from exactly that
  figure. Task 4's `Spend` shape has no field for it. Needs a model change or a UI
  derivation in tasks 10–11. Recorded so it is a decision rather than a silent loss.
- **Two key sets are GUESSES, not observations**, and are labelled as such in the source:
  the explicit-duration names (`limit_window_seconds` / `window_seconds` /
  `duration_seconds` — that field is Codex's, §5.2) and the account-identity names
  (`account_uuid` / `account_id` / `account.uuid` / `account.id`, none present in the live
  payload). The identity-mismatch path required by §3 is therefore exercised only against
  an invented fixture.
- `AgentVersion.current(now:)` is synchronous on an actor and can block a cooperative-pool
  thread up to 10s behind a hung CLI. Task 7 owns cadence.
- **`build.sh --test` never compiles `FoundationHTTPClient.swift` or
  `InstalledAgentVersionProbe.swift`.** The test gate alone cannot catch a break in the two
  `APP_ONLY_FILES`; `swiftc -typecheck` over all six directories is the check that does.

### Fixture provenance

`Tests/Fixtures/anthropic/usage-live.json` is a **sanitised recording** of one real
response. Altered: the model display name, one spend figure, and the disclaimer prose.
**Unaltered and therefore load-bearing as observed API shape:** the key names, the
null-vs-populated pattern (including the legacy flat keys being null while `limits[]`
carries the same figures, which is the regression this task exists to prove), the nesting,
the six-digit fractional timestamps, and the unusual codename keys. Every other
`usage-*.json` is synthetic. Never quote any part of a credential blob into a fixture.

**Touches:** new `Providers/{AnthropicProvider,HTTPRequesting,AgentVersion,
FoundationHTTPClient,InstalledAgentVersionProbe}.swift`,
`Tests/AnthropicProviderTests.swift`, `Tests/Fixtures/anthropic/usage-*.json` (24).
Modified: `Providers/UsageProvider.swift` (+8, the shared protocol — see above),
`Tests/main.swift`, `build.sh` (`APP_ONLY_FILES`). 259 checks.

---

## Task 6 — `CodexAuthReader` + `CodexProvider`

**The invariant was enforced better here and the bug moved upstream of the enforcement.**
Task 5 defended "never delete a window you read" with a comment, and the comment did not
stop a `guard … else { return nil }` nine lines away. Here `window(from:)` is
**non-optional by signature** — enforcement by type-checker, not by reviewer vigilance.
It worked. The worst defect of the task then landed one layer *up*, at ingestion, where
the invariant never runs: `flatten` tested `isTemporalWindow` on an object's children and
grandchildren but **never on the object it was handed**, so a bucket that *is* a window
disappeared. Measured, a 91% limit rendered as an idle account; in one shape the parser
returned one 5% window and `warnings=[]` while a 99% limit sat in a sibling group.

**The transferable question is therefore not "is my projection lossless" but "is there any
shape carrying a real figure that never becomes a window at all?"** A structural guarantee
is only as wide as the layer it is installed in.

**The dominant bug shape of this whole run: twinned branches where only one side was
fixed or covered.** Seven instances found across tasks 5 and 6 — `scope` fixed but `kind`
not; the group scan's object branch warning while its list branch stayed silent; depth-1
vs depth-2 `unreadableWindow`; `rescue()`'s recoverable-vs-unrecoverable paths; `spend()`'s
two credits guards; `genericGroup`'s object and list branches; and `spanLabel`'s ternary.
Where two code paths do the same job, fixing or testing one is not evidence about the
other. Several such pairs are now collapsed into single code paths so they *cannot*
disagree.

**Decision: a working token with no durable identifier is not `usable`.** Every credential
lacking both identifiers previously keyed to one shared namespace, so two unrelated
sign-ins inherited each other's cached usage and notification history — the exact
misattribution §4.2 exists to prevent, and a warning does not help because the app still
reads the wrong account's numbers. Now `.noDurableIdentity`, discovery reports `failed`,
and `fetch` returns `.accountUnknown` before any request. **Rejected: a credential-digest
identity** — the only remaining material rotates every 8 hours, so the key would churn on
every rotation. **Rejected: hiding the account** — a working login rendering as nothing at
all is worse than a named failure.

**Decision: composite arity is fixed at two slots, absent half spelled empty, and the
half-resolved case warns.** Fixed arity keeps `storageKey` stable when one half fails to
parse. **Rejected: making the account half authoritative when the user half fails to
*parse*** (as distinct from being absent) — it produces a key identical to the
genuinely-absent case, so it removes no re-keying while breaking the composite. The
residual cost is documented: a transient id_token problem re-keys the account and costs
its history. It no longer costs the account itself (see below).

**Decision: colliding `WindowID`s are made distinct, not merely announced.** Warning is
insufficient because downstream dictionaries and §8 persistence still merge or drop one.
Every member of a colliding group is re-keyed to `dup:<bucket-ordinal>.<path>:<scope>`;
`dup:` is a prefix no natural id can take. **All** members re-key — letting the first keep
the clean id would make its identity depend on another window's arrival order.
**Consequence for task 8: `dup:` keys, like Anthropic's `index:n`, are deliberately
volatile across polls.**

**Decision: credential-fault classification happens before the identity comparison.** The
order of two tests was the entire bug: the identity guard derived its reference from the
credential *read result*, so every non-usable read resolved to the shared sentinel and
returned `.accountUnknown` — which §6 treats as terminal and drops the account. **The CLI
rewrites `auth.json` on every token rotation, so a read landing mid-write is routine.**
The classification branches were provably unreachable: replacing both bodies with
`fatalError` left the suite fully green. A test suite cannot fail on code that never runs.

**Decision: `isActive` requires the window's own utilization to be `.known`.**
`limit_reached` is a *bucket* flag, so it marked null-utilization windows active, and
`bindingUtilization` returns `.unknown` if any active window is unknown — meaning the
account that was *literally rate-limited* was the one whose figure disappeared.

**Decision: identity disagreement is judged per-identifier, not by total disjointness.**
The original `allSatisfy { !known.contains($0) }` required *complete* disjointness, so a
response matching one half while naming a **different user** on the other produced no
warning at all. The two-warning split is retained and correct: `ambiguousIdentifiers`
(response reuses one value for both fields — the observed normal state, fires every poll)
is deliberately distinct from `identityDisagreement`. Collapsing them would tell the user
their only real Codex account does not match itself, forever, training them to ignore the
accurate warnings.

**Measured facts that corrected the spec's assumptions:**
- **Reset times are Unix epoch integers (`reset_at`) plus a relative `reset_after_seconds`
  — not RFC3339.** None of the sibling's ISO8601 machinery applies. The relative countdown
  is preferred (no clock agreement needed), the epoch is the fallback, and both are read
  because a payload dropping either must not lose its reset time.
- **The third quota group is `code_review_rate_limit`, and it is `null` on this account.**
  A name-based special case would look correct today and omit a live limit the day it
  populates. It is reached only by the generic scan over every top-level value carrying
  the window shape.
- **The §5.2 fallback endpoint answers 403, not 404** (HTML body), so that path is
  unexercised in production and unit-tested only.
- Identity: `tokens.account_id == chatgpt_account_id` (UUID) while the response returns
  `account_id == user_id == user-…`. The §4.2 disagreement is real and is the normal state.

**A fix that compiled, read correctly, and did nothing.** `readFile` was first added as a
protocol **extension** member. Swift dispatches extension members statically, so calling
through an `any ProfileFileSystem` existential never reached the concrete filesystem's
override — the fix was inert and invisible to inspection. A newly written test failed and
exposed it; it is now a protocol **requirement** with a default, which puts it in the
witness table. Verified at runtime against a 0-permission file, not merely by compiling.

**On mutation survivors: distinguish a gap from an equivalent mutant.** `humanised`'s
`!first.isEmpty` guard survives mutation and should — `split(separator:)` defaults to
`omittingEmptySubsequences: true`, so the empty case is unreachable (measured across five
inputs). Writing a fixture for it would inflate the count while pinning nothing. Reporting
an unkillable mutant as unkillable is the honest answer.

**Kept deliberately:** `CodexUsageParser.WarningLog` duplicates the sibling's ~9 lines.
Both reviewers agreed to keep it; the honest argument is "below the threshold where
abstraction pays", not "sharing is dangerous". A missing `rate_limit` fails the whole
fetch (fail loud beats a reassuring partial read). `JSONSerialization` materialises the
whole credential document transiently — parity with `ClaudeCredential.decode`; §6's rule
is about *retention*, `root` is a local `let` that escapes no scope and is captured by no
closure, and `CodexCredential` now has a redacted `description` so a bearer token cannot
reach a log through a failed assertion's diagnostic.

### Carried forward

- **`ProfileFileSystem` gained a sixth member.** `readFile` + `FileReadResult` were added
  to task 4's `ClaudeProfileDiscovery.swift` with a default implementation, and
  `SystemProfileFileSystem.swift` gained the override. Verified additive — task 4's fake
  conformer does not implement it and still passes on the default.
- **`dup:` window identities are volatile across polls**, like Anthropic's `index:n`.
  Task 8 persists threshold state keyed on `WindowID` and must treat both as intentionally
  unstable.
- The `404` → alternate-endpoint fallback, a `limit_reached == true` state, and windows at
  both nesting depths in one bucket are **built and unit-tested but never observed live**;
  they cannot be produced without vendor behaviour changing or the account being exhausted.

**Touches:** new `Credentials/CodexAuthReader.swift`, `Providers/CodexProvider.swift`,
`Tests/CodexProviderTests.swift`, `Tests/Fixtures/codex/*` (58). Modified:
`Credentials/{ClaudeProfileDiscovery,SystemProfileFileSystem}.swift` (the shared
`ProfileFileSystem` surface — see above), `Tests/main.swift`. 484 checks.
`build.sh` untouched: both new files are pure.

---

## Task 7 — `UsageStore`: registry, adaptive polling, backoff, caching

The orchestration core, and the largest task in the run. The single owner that discovers
accounts, drives both providers, applies the rate-limit policy, caches, persists, and
projects the menu-bar figure. Two full review rounds (4 CRITICAL + 6 MAJOR reconciled
from a fresh reviewer and codex; then a verifier FAIL on an unbounded-growth path the
first fix round introduced). 484 → 800 checks.

**The dominant failure of this run recurred here for the third and fourth time: a
structural guarantee is only as wide as the layer it is installed in.** `Snapshot.binding
Utilization` guarantees that an unknown *active* window makes the aggregate unknown rather
than falling through to a lower known figure — the guardrail against manufactured
headroom. `contributingWindows` deleted over-horizon windows *before* the fold, so the
guarantee never saw them: the menu bar read a stale account at a green 10% while the same
account's own card read unknown, with the real 95% figure nowhere. Reachability was not
exotic — `CacheHorizon.sessionHorizon` and the interval ladder's top rung are the same
number (1800), so a throttled account sits past its session horizon for much of every
cycle. Fixed by folding the *projected* window list (suppressed windows → `.unknown`) and
using the non-suppressed set only to decide whether the account contributes at all.

**Decision: the pure engine lives in `Model/`, the impure shell in `Core/`.** `Core/` is
app-only and is compiled into *no* test target, so policy written there is untestable.
The interval ladder, per-credential request budget, cache horizon, backoff, and the whole
registry/lifecycle live in `Model/{UsagePolicy,UsageEngine,UsagePersistence}.swift` with
`now` injected everywhere; `Core/UsageStore.swift` is the transport shell (clock, two
timers, `UserDefaults`, concrete providers). This is the main architectural choice of the
task and it is what let the budget and state machine be mutation-tested at all.

**The measured `429` threshold (§6, recorded in the spec).** One real account, stopping
at the first refusal: requests 1–5 returned `200` over 10.7s; request 6 at t+13.3s
returned `429` with `Retry-After: 300`. Budget = **5 requests / 300s rolling, per
credential** — the measurement expressed directly. The sustained rate and recovery curve
were deliberately *not* characterised: every further request spends a real account's real
allowance, and the burst ceiling is what the budget needs. **Honest qualification the
verifier forced into the spec:** the `PollSchedule.manualFloor` (60s) *alone* caps a
single account at 5/300s, so the credential-scoped budget only does work at ≥2 accounts
sharing a credential (measured: 2 → 5 with / 10 without; 4 → 5 / 20). The budget is the
correct construct — and the `.retry` floor exemption means the floor is not a general
guarantee — but the floor, not the budget, holds the single-account case today.

**Decision: the request budget keys on the credential DIGEST, not the service name.**
Task 4's handoff recommended the service name; that recommendation named the wrong
identifier and is corrected inline above. The service name digests a configuration *path*;
§6 scopes the budget to the *access token*, which is what upstream throttles. Key is
`digest:<credentialDigest>` with `location:<service>` as a namespaced fallback. A rotation
*migrates* the ledger rather than reissuing it.

**Decision: a spend carries the account that made it, and `merge` is a multiset union.**
The fix round's first attempt at credential-scoped budgeting introduced an unbounded-growth
path: `rekeyBudget` merged the old ledger into the new key without clearing the old, and
`reclaimUnreferencedBudgets` retains an unreferenced-but-non-empty ledger — each correct
alone, but an identity flipping `P → Q → P` merged its spends into themselves, growing the
persisted `UserDefaults` payload Fibonacci-style to ~700 MB at a 5s flip cadence (the
verifier's suite *hung* reproducing it). **Rejected: a plain set union** — it collapses a
genuine repeat spend, and the floor-exempt auth re-read lets one account legitimately spend
twice at one instant; deduping those under-counts, which *admits an extra request*.
**Rejected: a timestamp-only key** — two accounts spending at one instant are two real
requests it would collapse into one. The account must be in the identity. **Rejected:
clearing `budgets[oldKey]` on migration** — it hands a fresh allowance to a sibling that
shares the credential but has not yet observed the rotation, reopening the hole
`rekeyBudget` exists to close. The multiset union keeping the max count per identity makes
merging a ledger into a copy of itself idempotent.

**Decision: fetch completions carry a monotonic engine-wide claim token.** A per-account
counter is provably insufficient — after drop-and-rediscovery under the same identity, the
reborn account's counter restarts and a stale completion looks current. `finish(task,…)`
rejects any completion whose token is not current, closing the ABA where a completion
arriving after the 180s expiry, after disablement, or after a re-identification overwrites
newer state.

**Decision: an authentication rejection is disambiguated before it can stop a timer.**
The token rotates ~8-hourly and is re-read every fetch, so a rejection is ambiguous. One
immediate re-read and retry follows — **exempt from the 60s manual floor** because §6
mandates it be immediate (a genuine manual refresh at the same instant is still floored).
Only a *second consecutive* rejection with a stored expiry that has genuinely passed stops
the timer; any non-auth outcome in between resets the counter, so a transient transport
failure cannot turn two non-consecutive rejections into a stop.

**Decision: a stopped account is revived by observing a credential-digest change**, which
costs no upstream request and so keeps running under the budget even for stopped accounts.
The first observation after a relaunch **arms without firing** — an earlier fix deleted the
`hasObservedCredential` gate to make a re-login visible and thereby regressed the stagger
(every new account's digest "changes" from nothing, so all armed at once); withholding
*arming* on a first observation while still clearing the stop satisfies both.

**Decision: `UsageEngine` is `@MainActor`.** §6's single-writer requirement is now
compiler-checked rather than asserted in a comment — the same class of gap task 6's
`readFile` lesson was about. Verified with `-strict-concurrency=complete`: zero diagnostics
in the four new files.

**Buildability was a hard gate.** `Core/UsageStore.swift` (the cookie-era `UsageManager`)
was renamed to `Core/LegacyUsageManager.swift` byte-for-byte so all five legacy call sites
(`AppDelegate`, `MenuBarController`, `PopoverView`, `Notifier`, `Settings`) keep compiling;
the new `UsageStore` type does not collide with the old `UsageManager` name. Every commit
in this run must leave a buildable app, and `build.sh --test` cannot catch a break in
`Core/` (app-only, uncompiled by the test target) — `swiftc -typecheck` over all six
directories is the gate that does.

### The surface tasks 8–13 consume

**`UsageStore` (`@MainActor`, `Core/UsageStore.swift`).**
- `@Published private(set) var accounts: [AccountPresentation]`, `var menuBar:
  [ProviderFigure]`, `var lastSuccessAt: Date?` — the only things §7 renders, all engine
  projections under one consistent view, never assembled by the UI.
- `AccountPresentation`: `ref`, `state: AccountState` (**already horizon-projected** —
  over-horizon windows read `.unknown`), `isEnabled`, `isPollingStopped`, `lastSuccessAt`,
  `degradationNote: String?` (e.g. "rate limited · checking every 20 min"),
  `nextPollAt: Date?`, `warnings: [String]`.
- `ProviderFigure`: `provider`, `utilization`, `accountLabel`, `windowLabel` (the last two
  are the tooltip source).
- Methods: `start()`, `stop()`, `popoverWillOpen()` (**throttled — 5s survey floor**),
  `refresh()`, `refresh(_ identity:)`, `setEnabled(_:for:)`, `isEnabled(_:)`,
  `retainedRawBody(for:)` (§5 diagnostic, deliberately NOT on `AccountPresentation` — no
  display path may read it), and `registeredLocations` get/set (§4.1 escape hatch, task 11
  owns the UI).

**Task 8 (notifier):** key threshold state on `AccountIdentity.storageKey` so the engine's
lifecycle reclaims it as a unit. Treat `index:n` (Anthropic) and `dup:<ordinal>` (Codex)
`WindowID`s as **intentionally volatile across polls** — persisting threshold state keyed
on them will re-fire the ladder on reorder; that is the accepted trade (an under-report is
the failure to prevent, a re-fired ladder is noise), but task 8 must not treat a volatile
id as stable identity.

**Version-2 payload contract:** `PersistedAccountState` (v2) and
`PersistedCredentialLedger` (v2) both go through `PersistedCodec`, which returns `nil` on a
version mismatch or corrupt bytes; `PersistedStore.load` partitions the keyspace and
returns `unreadable` keys for reclamation (closing the third orphan class — undecodable
keys that a live-account sweep structurally cannot reach). Ledgers live under a
`credential:` namespace, accounts under `usage.v2.account.`, index at `usage.v2.accounts`.
A version-1 payload from an earlier build is unreadable and reclaimed at load.

**`Core/LegacyUsageManager.swift` must be DELETED by task 11** with its last call site.
Task 9's first step is `@MainActor` on `AppDelegate` (or `MainActor.assumeIsolated` at the
call site), because `UsageStore` is `@MainActor`.

### Carried forward

- **`spend.percent` remains a v1.3.2 regression** (task 5's note stands): the extra-usage
  bar rendered from it has no home in the `Spend` shape. Tasks 10–11 decide model-change
  vs UI-derivation.
- **Write amplification for tasks 9–10 to watch:** `ingest` persists every account on every
  60s survey regardless of change; `publish` reassigns both `@Published` arrays every 15s
  with non-`Equatable` payloads, so SwiftUI invalidates unconditionally.
- One theoretical orphan class left open and recorded: an account whose provider left
  `providerOrder` would never be surveyed and so never reclaimed — unreachable while both
  providers always survey together.

**Touches:** new `Model/{UsagePolicy,UsageEngine,UsagePersistence}.swift`,
`Core/UsageStore.swift`, `Tests/UsageEngineTests.swift`. Renamed
`Core/UsageStore.swift` → `Core/LegacyUsageManager.swift` (byte-identical + header).
Modified: `Tests/main.swift`, spec §6 (measured threshold + the single-account
qualification), and the task 4 budget-key correction above. 800 checks.
`build.sh` untouched: the engine is pure, the shell is already app-only `Core/`.

---

## Task 8 — the notifier: per-`(account, window)` thresholds

**A correctness fix, not a feature — the spec says so, and it is the same silent-suppression
family as the flat-key under-report.** The cookie-era notifier kept one global
`lastNotifiedThreshold` compared against `max(session, weekly)`. With N accounts that slot
is a race: account A crossing 75% overwrites it and *suppresses* account B's 75% alert,
last poll wins, and the user is never told B is nearly exhausted. Nothing fails; the app
just alerts less than it should. Fixed by keying state per `(provider, account, window)` —
`AccountIdentity.storageKey` (durable identity, never label or location) as the outer
namespace, the full `WindowID` (temporal span × scope) as the inner. Two accounts, a
model-scoped short and long window, and a re-signed-in occupant at the same location are
all now distinct slots.

**Pure decision engine, impure delivery shell** — task 7's split repeated. `Model/
NotificationEngine.swift` holds the `[25,50,75,90]` ladder, hysteresis, per-window state,
reclamation, and the persisted shape; it is compiled into the test target and exhaustively
tested with no side effects. `Core/AccountNotifier.swift` is the `NSUserNotification`
delivery, the master toggle, and the `UserDefaults` blob. Both `@MainActor`, in task 7's
single-writer domain. The engine returns *what alerts to deliver*; the shell delivers them,
so a test asserts "these crossings → these alerts" without anything reaching the
notification centre.

**Decision: an alert carries its provider and derives its own title.** The delivery shell
originally hardcoded the title `"Claude Usage Alert"` for *every* alert, so a Codex alert
was branded as Claude — the task's own thesis (never assert a window the reading did not
come from) violated one layer out, in the shell no test compiles. `NotificationAlert` now
carries `provider` and computes `title` per-provider; the shell uses `alert.title` and
*cannot* mislabel. This was the reviewer/codex split made concrete: the decision engine was
clean and the violation lived in the impure layer the engine's discipline did not reach —
the same shape as task 6's `readFile` and task 7's `contributingWindows`.

**Decision: the full discovered set is an explicit `discovered roster` parameter, not an
inferred one.** Reclamation must key on which accounts *exist*, not on which happened to
produce a reading this cycle — otherwise a partial batch reads as deletions and re-fires
the whole ladder when the omitted accounts return. `evaluate(_ readings:, discovered
roster:)` reclaims on the roster; a reading absent from the roster **traps loudly**. This
was true "by construction" while `publish` was the only caller, but task 9 adds
`notifier.evaluate(store.accounts)`, so the property was one refactor from breaking
silently. **Rejected: an asserted precondition** — an assertion cannot detect a partial
call without an independent full-set reference, and the roster *is* that reference; making
it a parameter makes the property safe rather than lucky.

**Decision: reclamation keys on departure from discovery, not on a transient non-active
state.** The `AccountState.windows` bridge returns the projected windows only for
`active`/`stale`; a `.expired`/`.failed`/`.signedOut` account presents an empty window
list. Reclaiming on that emptiness meant recovery to `.active` replayed 25/50/75/90 for
*every* window — the avoidable twin of the re-fired-ladder noise the volatile-id trade
accepted deliberately (there the id genuinely changed; here only the ability to read the
window did, and task 7's auth-disambiguation makes `.expired` recoverable). Now such an
account is roster-only and **holds** its slots exactly as a `.stale` over-horizon account
does; only genuine absence from the roster reclaims. Composes with the roster parameter.

**Decision: a restored threshold outside `[25,50,75,90]` is treated as re-armed, not
trusted.** A valid-version blob carrying `99` would let no band `<= 99` count as a fresh
crossing, so 90% would never fire, and it would then normalise to 90 — the crossing lost
for good, silent suppression through the persistence door. `init(restoring:)` drops any
stored threshold not in `storableBands` and re-arms to 0.

**Volatile window identities (the crux carried from tasks 5–7).** `index:n` (Anthropic)
and `dup:<ordinal>` (Codex) `WindowID`s are deliberately unstable across polls. A reorder
reclaims the old slot and re-fires the ladder on the fresh id — the accepted trade. What is
pinned: a *stable* sibling window across the same reorder does **not** re-fire, the old
positional id is genuinely reclaimed (not merely superseded — tested against unbounded
growth), and misattribution is structurally impossible because `storageKey` is the outer
namespace. `.unknown` is neither a crossing nor a reset — every consumer `switch`es, no
`?? 0`, and an `.unknown` window is *present* (its slot survives) while only an *absent*
window is reclaimed.

**Persistence** is one versioned blob (`PersistedNotificationState` v1) through task 7's
`PersistedCodec`; undecodable or old-version → reclaimed, never resurrected. Deliberately
*not* mirroring task 7's keyspace partitioning: the blob is tiny and rewritten wholesale,
so there is no orphan-key class to sweep — the reviewer agreed.

### What tasks 9–11 must wire

- Task 9: call `notifier.evaluate(store.accounts)` after each `publish`. The `evaluate`
  entry point takes `[AccountPresentation]` and splits readings from roster internally.
- Task 11: repoint the master toggle and the test-notification button (`sendTestNotification`
  is preserved for exactly this), then **delete `Core/Notifier.swift`** along with
  `Core/LegacyUsageManager.swift` and the cookie call sites.

**Touches:** new `Model/NotificationEngine.swift`, `Core/AccountNotifier.swift`,
`Tests/NotificationEngineTests.swift`. Modified: `Tests/main.swift`. 863 checks.
`build.sh` untouched: the engine is pure, the shell is app-only `Core/`. No task 1–7 file
touched; the cookie `Notifier.swift` is left intact and compiling until task 11 removes it.

---

## Task 9 — the menu bar, and the first cutover of the real engine onto screen

The first task that puts the new `UsageStore` on screen with real credentials, replacing
the cookie `UsageManager` as the app's polling owner. It is a UI cutover, not pure logic —
`build.sh --test` compiles none of `App/`/`Core/`/`UI/`, so the gate is a **rendered
screenshot with a quality verdict** plus `swiftc -typecheck` over all six directories.

**The screenshot is the artifact, and it passed on quality, not just on rendering:** Claude
spark **amber** at 72% (70–89 band) beside Codex diamond **green** at 6% (<70) — two
providers in two different bands at once, which the old single-`max`-coloured icon
structurally could not show. That simultaneity is the point of §7.1's per-provider design.

**The critical constraint was exactly one polling loop.** The app previously started the
cookie manager's timer; `UsageStore` also polls, and task 7's request budget is per-engine,
so a second loop blows the measured 5-req/300s budget and throttles the user (who noticed a
stray second bar once this session). Resolution: `AppDelegate` starts `UsageStore` as the
sole poller, and the legacy manager is made **inert** — its `init` reads UserDefaults only,
and the two `nonisolated` shims are empty so even the `loadCachedUsage → updateStatusBar →
delegate.updateStatusIcon` path cannot fight the store for the status button. Verified at
runtime: only the store logged fetches.

**Decision: the worst-of stays single-sourced in the engine; the view only renders.** A
pure `MenuBarPresentation` (`Model/`, testable) maps `store.menuBar: [ProviderFigure]` to
band colour, glyph, value and tooltip in engine order — no re-derivation, no aggregation, no
`?? 0`. `.unknown` renders as "?" in its own band, an absent provider is omitted (never
"0%"), an empty `menuBar` is a neutral idle state. These paths could not be induced live
(both real accounts returned known figures), so they rest on the pure tests — pinned and
mutation-verified, band boundaries checked at 69/70/89/90.

**Decision: `AppDelegate` is class-level `@MainActor`, with `assumeIsolated` at three
hand-back sites.** The Carbon hotkey C callback (wrapped in `DispatchQueue.main.async`
first), the `$menuBar` Combine sink and the `$accounts` sink (both `.receive(on:
RunLoop.main)` first) — each provably on the main thread before `assumeIsolated`, none an
off-main path like a `URLSession` completion.

**The fix round caught a deferral that was a feature deletion.** The first pass left
`AccountNotifier` wired nowhere, on the reasoning that the `$menuBar` sink is the wrong place
(true — it is a coalesced worst-of subset, and task 8's roster parameter would trap on the
partial call). But that justified changing the sink, not skipping the wiring: task 8 built
`evaluate([AccountPresentation])` to take the **full roster** precisely so it hangs off
`store.$accounts`, which `publish` reassigns complete every cycle. Left unwired, the new app
was silent on every threshold crossing — except a stale one-shot at launch from the cookie
cache, i.e. the *only* alert it fired was the exact false "Claude Usage Alert" the rework
exists to kill. Now `notifier.evaluate(store.accounts)` is driven off the `$accounts` sink
in `AppDelegate` (not from inside `store.publish`, so task 7's single-writer core stays
untouched).

**Decision: the saved notification preference is honoured from now, not from task 11.**
`AccountNotifier` keys its master toggle on the same `notifications_enabled` UserDefaults key
the legacy manager used, so a v1.3.2 user who disabled notifications stays quiet — wiring it
default-on would have silently re-enabled them. Verified on this machine's real saved value
(`0`): threshold state still advances (`notify.v1.state` written) while delivery count is 0.
The contract is "advance regardless, gate only delivery"; task 11 repoints the settings
*control*, but the *state* lives in UserDefaults and is respected now.

**Two legacy paths neutered to hold the single-loop guarantee:** `scheduleTimer` is a no-op
(the one chokepoint every recurring-timer path routes through, so a click on the still-present
cookie Refresh button does one one-shot fetch and nothing recurs), and the legacy
`checkNotificationThresholds` is a no-op (so no stale cookie-cache alert fires at launch).
Both are documented no-ops with no unreachable-code warnings.

### What tasks 10–11 must wire

- Task 10 (popover cards): the popover still hosts the legacy `UsageView` on inert (zeroed)
  data, and `PopoverView.swift:217,263` still call `usageManager.fetchUsage()` from the old
  cookie Refresh buttons — sever those two call sites when the cards replace the view.
- Task 11 (settings): repoint the notification master toggle control to `AccountNotifier`'s
  `notifications_enabled` (the state is already honoured), then delete
  `Core/LegacyUsageManager.swift`, `Core/Notifier.swift`, the cookie UI and the coffee button
  with their last call sites.

**Touches:** new `Model/MenuBarPresentation.swift`, `Tests/MenuBarPresentationTests.swift`.
Modified: `App/AppDelegate.swift` (`@MainActor`, store ownership, `$menuBar`+`$accounts`
sinks, notifier), `UI/MenuBarController.swift` (per-provider render, diamond glyph, inert
shims), `Core/LegacyUsageManager.swift` (`scheduleTimer` inert), `Core/Notifier.swift`
(`checkNotificationThresholds` inert), `Tests/NotificationEngineTests.swift` (the
evaluate-on-publish seam test), `Tests/main.swift`. 891 checks. The real path launch → real
Keychain → real HTTPS → menu bar is now REAL and screenshot-verified; only the popover body
and settings remain on the old surface.

---

## Task 10 — the popover: per-account cards, and the §7.4 removals

Rewrote the popover from the cookie-era single-account `UsageView` into §7.2's
provider-grouped, per-account collapsed cards driven entirely by `UsageStore`, removed the
cookie/coffee UI, and resolved the long-carried `spend.percent` regression. The artifact is
a screenshot with a quality verdict, and it passed on quality: `default` 73% amber matching
the menu bar, expanded per-window rows (Session with a time reset, Weekly with a date
reset, a model-scoped Fable window from `windowLabel`), `work-ethan` rendering "Sign in via
Claude Code" as a non-error non-zero hint, and the Extra line showing Claude's qualified
`$0.00` beside Codex's unqualified `0 free` — the two money formats correctly distinct.

**Decision: the `spend.percent` regression is resolved by the redesign, not by restoring the
field.** Since task 5 the handoff carried `spend.percent` as a live regression — v1.3.2
rendered an extra-usage *percentage bar* from it, and the new `Spend` has no such field.
§7.2 replaced that bar with a *dollar line*: `Extra <used> · <balance> free`, built from
`Spend.used` (qualified minor units + currency + exponent) and the credits `balance`
(**unqualified** — no currency or scale inferred, per §5.2). The percentage was never needed
once the UI shows money; `spend.percent` is intentionally not surfaced, and no percent is
derived from `used/limit` (limit is often null).

**Decision: card expansion is store-owned per-account state, reclaimed by task 7's
lifecycle.** `AccountPresentation.isExpanded` + a `@MainActor UsageStore.setExpanded(_:for:)`,
persisted in the existing version-2 `PersistedAccountState` as an **additive optional field**
`expanded: Bool?`. **Rejected: a parallel `UserDefaults` map in the UI** keyed by label —
it would re-introduce the orphan-key growth task 7 eliminated and could misattribute one
account's expansion to another. Keying on `AccountIdentity.storageKey` and riding task 7's
roster reclamation means expansion drops with the account and a returning identity does not
inherit a stale flag — no parallel keyspace, no resurrection.

**The additive-optional persistence change was the make-or-break risk, and it holds.**
`expanded: Bool?` is `Optional`, so synthesized `Decodable` uses `decodeIfPresent`: a v2 blob
written before the field existed decodes the missing key to `nil` → a collapsed card, NOT a
decode failure. That distinction is load-bearing — task 7's codec returns `nil` on a genuine
decode failure and the engine then *reclaims* (wipes) the account, so had the field been made
required, every pre-existing account would be silently erased on the first launch after
upgrade. No version bump; the ledger namespace, ABA claim token, and horizon projection are
untouched. The restore default (`state.expanded ?? false`) is now pinned by a test that
restores a legacy blob through the engine and asserts the presented card is collapsed.

**Two review findings were this run's recurring failure families, in the new UI layer:**
- **A provider name hardcoded in user-facing text** (codex): a signed-out *Codex* account was
  told "Sign in via *Claude Code*", misdirecting a lapsed ChatGPT user to the wrong CLI —
  the same shape as task 8's hardcoded "Claude Usage Alert" title. Fixed with a pure,
  testable `ProviderKind.cliName`; the hint now derives from the account's provider.
- **An arithmetic trap on a provider-controlled, persisted value** (codex): the money
  formatter's `abs(minor)` traps on `Int.min` and `exponent + 1` overflows at `Int.max` —
  the same species as task 5's `Int(1e30)` crash. Fixed with `minor.magnitude` (which cannot
  trap) and an exponent bound (`0 < exponent <= 30`, else the raw figure); reproduced at
  SIGTRAP before, gone after.

**Decision: a rate-limited account's degradation is shown on the COLLAPSED row, not only
when expanded** (reviewer). `AccountPresentation.degradationNote`'s task-7 contract requires
the stretched cadence be visible in the account's own card and *never just appear fresh* —
but the collapsed row is the card's default, so rendering the note only inside the expanded
body left a throttled account looking fresh until the user expanded it.

**Confirmed single-sourced (not re-derived):** the card's per-account figure calls
`Snapshot.bindingUtilization(of: snapshot.windows)` on the engine's already-projected
snapshot; the menu bar applies the identical function to `project(snapshot, now).windows`.
Same function, same projected windows — they can differ only in *presence* (the menu bar
omits an over-horizon account, the card shows it as unknown), which is the §6/§7.1 intent,
never a numeric disagreement.

**§7.4 removals done here** (they lived in this view): the entire cookie input block,
`PasteableTextField`/`PasteableNSTextView`/`CustomTextField` (file `PasteableTextField.swift`
deleted), the Save/Clear Cookie buttons, the "Buy Dev a Coffee" Stripe button; both
`usageManager.fetchUsage()` sites severed (Refresh → `store.refresh()`). `import WebKit` and
the `-framework WebKit` flags were already absent (the only remaining `WebKit` string is a
browser User-Agent literal inside `LegacyUsageManager.swift`, task 11's file, not a
dependency).

### What task 11 must do

The settings gear is still wired to the inert legacy manager (Open-at-Login, notifications
toggle/test button, ⌘U shortcut) — a documented two-source interim. Task 11 builds the real
`SettingsView` (§7.3: per-account enable checkboxes, the §4.1 registered-locations
lifecycle), repoints the notification toggle control to `AccountNotifier` (the
`notifications_enabled` state is already honoured from task 9), then **deletes
`Core/LegacyUsageManager.swift` and `Core/Notifier.swift`** with their last call sites —
closing the final fake leg.

**A process note for the whole-worktree review:** during task 10's review a fresh reviewer's
mutation script used `git checkout` to revert mutations on this *uncommitted* work, resetting
`UsageModel/UsageEngine/UsagePersistence.swift` to HEAD; the reviewer reconstructed them from
captured content and disclosed it. Tree integrity was independently verified before commit
(diff shape 451/458 matched the doer's report, all reported defects physically present, 915
checks green, six-dir typecheck clean); residual risk is comment-byte cosmetics only. The
transferable rule: a mutation harness in a shared uncommitted worktree must snapshot bytes,
never `git checkout`.

**Touches:** `UI/PopoverView.swift` (full rewrite), `Model/UsageModel.swift`
(`MonetaryAmount.display`/`scaledString`, `Spend.extraLine`, `ProviderKind.cliName`),
`Model/UsageEngine.swift` (`isExpanded`/`setExpanded`/restore wiring),
`Model/UsagePersistence.swift` (additive `expanded: Bool?` — shared surface),
`Core/UsageStore.swift` (`setExpanded` shell), `App/AppDelegate.swift` (1 line),
`Tests/{UsageModelTests,UsageEngineTests,NotificationEngineTests}.swift`. Deleted
`UI/PasteableTextField.swift`. 915 checks. The popover path launch → real credentials → real
fetch → cards is now REAL; only the settings gear remains on the legacy surface.

---

## Task 11 — the real SettingsView, and the deletion that closes the fake-entrypoint leg

The final cutover. Built `SettingsView` (§7.3) on the new engine, moved app-level settings
to a new `AppSettings` owner, implemented the §4.1 registered-locations lifecycle, and
**deleted the entire legacy cookie subsystem** — `LegacyUsageManager.swift`, `Notifier.swift`,
`Settings.swift`, so the type `UsageManager` no longer exists anywhere. **The
fake-entrypoint leg every ledger carried since task 3 is now closed:** launch → real Keychain
→ real HTTPS → menu bar + popover + settings, all on the new engine, no cookie path to fall
back to. The proof a deletion task needs is the gate `build.sh --test` cannot give — a clean
`swiftc -typecheck` over all six directories, which is the only thing that catches a dangling
reference to a deleted type in `App/`/`Core/`/`UI/`.

**A deletion task's real risk is silent loss, so every legacy behaviour was enumerated to a
new home** (recorded in the untracked log): cookie poll/parse/backoff — dead since task 9;
`notifications_enabled` → `AccountNotifier` (the toggle now writes it); Open-at-Login +
`SMAppService.register()/unregister()` → `AppSettings`, reflecting real system status not a
stored bool; accessibility status + launch prompt → `AppSettings`; `shortcut_enabled` + the
⌘U Carbon hotkey enable/disable → `AppSettings` (pref) + `AppDelegate` (the hotkey ref);
`sendTestNotification` → `AccountNotifier`. Each was verified to *act*, not merely store the
preference — a setting that quietly stops registering the login item or toggling the hotkey
is exactly the regression this task must not ship.

**Decision: a new `@MainActor AppSettings` owns genuinely app-level settings** — not
per-account (`UsageStore`) and not notification (`AccountNotifier`). The Carbon hotkey ref
and register/unregister stay on `AppDelegate`; `AppSettings` only records the preference.

**§4.1 registered locations — add-time validation runs the SAME gate as the survey.**
`ClaudeProfileDiscovery.validateCandidate` applies normalize → not-home → is-directory →
identity-gate through the *same shared* methods the survey uses, so the two cannot drift (a
divergence would let a location validate but never appear, or be rejected though it would
appear). A gate failure is surfaced to the user and **not registered**; the persisted string
is the **normalized absolute path**, not the raw input. Credential health is deliberately
NOT checked at registration — the identity gate decides inclusion, the credential decides
state, so a signed-out-but-valid config is a legitimate account.

**Two review rounds' worth of findings, and a genuine two-reviewer severity split (Rule 7).**
Codex rated six issues CRITICAL/MAJOR; the fresh reviewer rated the same code all-clear. Both
were right about different *layers*: the reviewer verified the model layer correctly
*implements* each behaviour (it traced `register()`, the launch prompt, the single-homed
pref); codex found the *view* copies that authoritative state into local `@State` so the UI
can go stale, and — the one that mattered — a concurrency defect the reviewer's happy-path
trace missed.

**Decision (the codex CRITICAL, re-severed to MAJOR and fixed): a location change during an
in-flight survey was silently swallowed.** `survey()` opens `guard !isSurveying else
return`, so a removal's `survey()` — fired while the timer's survey was already running —
did nothing; the in-flight survey finished with the *stale* location set, the removed
account was never reclaimed, and the `removeLocation` comment *falsely claimed* it was. Fixed
with a `pendingResurvey` flag: a swallowed request is remembered and re-run once `isSurveying`
clears (serialisation guarantees it runs strictly after, with the *current* location set), so
a remove reclaims and a re-add re-discovers rather than waiting up to 60s. Re-severed from
CRITICAL because state is identity-keyed (a different account at a re-registered location
cannot inherit the old one's state) and it self-heals on the next tick — but the §6 contract
and the lying comment both had to be fixed. **This fix lives in `Core/` (task 7's app-only
shell), which the test target does not compile, so it is verified by typecheck + an
interleaving trace read at commit, not by a unit test — the same boundary every `UsageStore`
orchestration change has.**

**Decision: the registered-location invariant lives at the store, not the caller.**
`addLocation` now validates+normalizes internally and no-ops on rejection, so the store cannot
persist a path the survey won't honour even if a caller skips the UI — the same "invariant at
the owner" lesson as task 8's roster parameter.

**A test that passed for the wrong reason, overturned.** The doer had marked the
relative-path-rejection mutation an equivalent mutant ("caught downstream by is-directory").
The reviewer proved it unsound: the real `SystemProfileFileSystem.isDirectory` resolves a
relative path against the process CWD, so with the normalize guard removed a relative input
*would* pass in production — the test only survived because the *fake* filesystem's
dict-lookup never resolves CWD. Since a window-server-launched app has no defensible CWD,
relative-path rejection is a task-4 *security* property. The test now rigs the fake so the
relative path resolves to a valid directory and asserts it is still rejected; the mutation
that was SURVIVED is now KILLED.

**Freshness cluster (codex): the SettingsView re-reads authoritative state on `.onAppear`**
rather than trusting `@State` snapshots — `SMAppService` login status, `notifier.isEnabled`,
`store.registeredLocations` — so an external change (e.g. Open-at-Login toggled in System
Settings) is reflected. Per-account checkboxes already read `@Published store.accounts` live.
Chose onAppear re-read over making `AccountNotifier` observable — it is deliberately the
impure shell.

**Confirmed, not changed (reviewer over codex):** the launch-time accessibility prompt fires;
the settings "Grant Accessibility" button opens System Settings rather than firing
`AXIsProcessTrustedWithOptions`, which is correct — the with-options prompt is one-shot
(macOS suppresses it after the first denial), so opening System Settings is the reliable
recovery.

**Artifact honesty:** the settings *panel* could not be screenshotted — a transient NSPopover
of an accessory app is not drivable by synthesized System-Events clicks (it closes before
`screencapture`) and `cliclick` is not installed. The menu bar was captured live on the new
engine (Claude amber 75%, Codex green 6%, values moving across captures). Every SettingsView
binding bug codex found is the class a settings screenshot would have shown in seconds — with
the visual gate genuinely unavailable, the adversarial static review covered it. The settings
logic is pure-tested and mutation-verified; the orchestration is typecheck-clean and trace-read.

### For task 12

Now-dead cookie-era UserDefaults keys are **left in place** (not this task's scope):
`claude_session_cookie`, `has_cached_usage`, `cached_*`, `last_notified_threshold`,
`has_set_notifications`. Version is still `1.3.2`; `build.sh`/`Info.plist`/signing untouched.
Task 12 purges those keys, bumps to 2.0.0, and adds the loud signing fallback.

**Touches:** new `Core/AppSettings.swift`, `UI/SettingsView.swift`. Deleted
`Core/LegacyUsageManager.swift`, `Core/Notifier.swift`, `Core/Settings.swift`. Modified
`App/AppDelegate.swift`, `UI/PopoverView.swift`, `UI/MenuBarController.swift`,
`Core/UsageStore.swift` (registered-locations lifecycle + `pendingResurvey`),
`Core/AccountNotifier.swift` (comment), `Credentials/ClaudeProfileDiscovery.swift`
(`validateCandidate`), `Tests/ClaudeProfileDiscoveryTests.swift`. 924 checks. The app now runs
entirely on the new engine; no legacy or inert leg remains.
