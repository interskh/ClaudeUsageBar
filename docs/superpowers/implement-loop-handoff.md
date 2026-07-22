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
