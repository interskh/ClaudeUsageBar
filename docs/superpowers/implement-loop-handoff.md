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
