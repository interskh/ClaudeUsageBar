## Task 1 — Muse Keychain gate (read only on user Refresh)

**Decisions**
- `MuseKeychainGate` (pure, app/Credentials): token cache + one-shot arm; lock held across the inner read; caches only `access_token`, serves a synthesized `{access_token}` blob.
- Not-connected = gate returns `.failed(MuseAuthReader.connectInstruction)`; reader maps that exact fault to new `MuseAuthRead.notConnected` (state `.failed(msg)`, fetch `.transport(msg)`); other faults get `"; " + connectInstruction`.
- `arm()` is a no-op (returns false) while a token is cached, so a stale arm cannot let a later background poll prompt after invalidation.
- Engine only polls `.pending` accounts (`credentialUsable`), so a not-connected account cannot be fetched by a manual refresh. Wiring: `armMuseConnect()` arms + runs a survey (discovery does the one read); the survey's completion requests a manual refresh for Muse observations once `!gate.isArmed` (`museConnectPending` flag). [SUPERSEDED by the review fix round: the flag and `!gate.isArmed` test were replaced by arm tickets.]
- 401/403 on Muse: `invalidate()` + `survey()` so discoveryState flips to the connect failure (outranks cached reading).
- Inline-first: `MuseAuthReader.credentialMaterial()` / `hasInlineToken` (pure); `museCredentialFact` uses it.
- [SUPERSEDED by the fix round: the connect state now keys on the auth file's email] Connect-state ref is the shared "unresolved" sentinel; after connecting, the real-email identity is a new engine key (staggered-first-poll avoided by the manual refresh above).

**Rejected**
- Distinct sentinel type/new lookup case on `CredentialLookup`: touches shared Claude/Codex code; string-constant match is local.
- Making the engine poll failed accounts on manual refresh: changes shared engine semantics.
- Having fetch() return `.accountUnknown`/`.authenticationRejected` for not-connected: drop wipes state / triggers invalidate loop.

**Assumptions**
- Muse's blob has top-level `access_token` (matches fixture + prior reader). UsageStore wiring is untested (app-only); only typechecked via swiftc -typecheck of all sources.
- After 401 the engine's immediate retry fetch yields "network: Click Refresh…" briefly until the survey lands.

**Deferred**: README text (task 2). No engine unit test for the survey->refresh hop (UsageStore is app-only).

**Touches**: Credentials/MuseKeychainGate.swift (new), Credentials/MuseAuthReader.swift (new enum case, `keychainGrantHint` -> `connectInstruction`), Providers/MuseProvider.swift, Core/UsageStore.swift, Tests/MuseProviderTests.swift. Any README referencing `keychainGrantHint`/partition grant is stale.

## Task 1 — review fix round

**Decisions**
- Arm lifetime: `arm()` returns an `ArmTicket`; `UsageStore` hands it to the next survey that starts, and that survey calls `endSurvey(ticket)` at its end (withdraws the arm unless a newer click re-armed). Arm only when an enabled Muse account is currently in the connect state (so never for absent/inline/connected/disabled).
- Locks: `state` (short, flags + cache + generation) vs `reads` (serialises real reads). arm/endSurvey/isArmed/invalidate take `state` only; invalidate bumps `generation` so a mid-read result is not cached.
- Identity: not-connected / keychain-failed reads use the auth file's email identity (`authIdentityEmail`, `reference(for:tokenlessEmail:)`); sentinel kept for no-email/other states. Engine still blocks the failed-state account (`credentialUnusable`), so the post-survey manual-refresh request is kept (now keyed to the same identity).
- `KeychainStore.timeoutSeconds` is per-instance (default 5); Muse gate inner uses 120s. Reads run in survey (detached) / fetch (nonisolated async), not on the main actor.
- One `parseAuthFile()` backs `read`, `credentialMaterial`, `authIdentityEmail`; `hasInlineToken` removed.

**Rejected**: disarm-by-timer (non-deterministic); ticket held inside the gate (the survey, not the gate, knows when it ends).

**Deferred**: refresh() runs an unthrottled survey when it arms (bounded: only while the Muse card is in the connect state); post-401 retry yields a transport failure (accepted).

**Assumptions**: wiring in UsageStore is typechecked only (app-only), not exercised.

**Touches**: + Credentials/KeychainStore.swift (init param `timeoutSeconds`; static default unchanged).
- Re-arm predicate is `MuseAuthReader.isWaitingToConnect` (suffix match) so a denied/timed-out card (`fault; instruction`) still arms on Refresh.
- `.noAccessToken` (armed read -> item absent) keeps the sentinel identity (signed out); deliberate, since signed-out has no state worth keeping. Same-session churn email->sentinel->email is possible there; rare.
- Assumption: the engine's second-rejection `credentialProbe` -> `museCredentialFact` runs on the main actor and could wait on `reads`. Believed unreachable while a read is in flight: after the first 401 `invalidate()` makes the retry a transport failure, resetting `authRejections`, so two consecutive rejections cannot occur with an uncached gate.

## Task 2 — README docs (orchestrator entry)

**Decisions**: Replaced the one-time partition-list grant in both READMEs: Muse rewrites its Keychain item on launch/refresh and the rewrite resets the partition list (observed 2026-10-17: grant applied, undone by Muse's next write). Documented click-to-connect (commit 044fc15) and the file backend (`TBH_CREDENTIAL_BACKEND=file` in `~/.zshenv`, then `muse logout && muse login`) as the zero-prompt path, verified on the target machine: `auth.json` gained an inline token and lost `storage: keychain`.
**Rejected**: Keeping the grant as a documented workaround — it does not survive the next Muse launch.
**Assumptions**: `TBH_CREDENTIAL_BACKEND` is internal and undocumented; the docs say so.
**Deferred**: none.
**Touches**: README.md, app/README.md.

## Task 1 — whole-run gate fix round

**Decisions**
- Account binding: the gate caches `(token, email)`; `lookupCredential(service:boundTo:)` (protocol `AccountBoundCredentialSource`) misses and drops the cache for another/nil email. `MuseAuthReader` passes the auth file's email and calls `invalidate()` on fileMissing / unsupportedMechanism / inline token. Plain `lookupCredential(service:)` binds to nil (never a hit).
- Arm activation: `arm()` records a pending ticket only; `beginSurvey(ticket)` (called by `survey()` as it starts) activates it; lookups consume only an activated arm; `endSurvey` clears pending and active. A survey that did not start with the ticket can never spend it.
- `UsageStore` invalidates on a Muse 401/403 only when `engine.finish` accepted the result.
- Docs: no per-card Refresh exists (only the popover-wide button, PopoverView); both READMEs now say so, describe the real token lifetime (quit, rejection, sign-out, account change) and that a Keychain-backed Muse needs a Refresh click to reconnect while the file backend resumes alone.

**Accepted trade-off**: an armed read can keep the survey busy for up to 120s while the dialog is open, so Claude/Codex discovery and location add/remove wait (they queue via `pendingResurvey`).

**Rejected**
- Inline-token 401 entering the connect state: no Keychain involved; the engine's existing rejection handling applies, as for Codex.
- Dropping the token on an HTTP usage-request timeout: the contract's "timeout" is the Keychain read timeout.
- Setting the expected email on the gate before each lookup (stateful, racy) in favour of passing it per call.

**Touches**: Credentials/MuseKeychainGate.swift, MuseAuthReader.swift, Core/UsageStore.swift, Tests/MuseProviderTests.swift, README.md, app/README.md.
- `.noAccessToken` has no cache drop on purpose: the gate returns `.absent` only with an empty cache (a matching email is a hit, a mismatch drops before reading).
- Assumption: plain `lookupCredential(service:)` binds to nil and so DROPS the cache; no app caller uses it (the reader casts to `AccountBoundCredentialSource`, Claude discovery uses a raw `KeychainStore`). A footgun for a future caller.
- `refresh(_ identity:)` (and its Muse arming) is unreachable from the UI today: only `store.refresh()` is called, from the popover button.

## Whole-run gate, fix round 2 (orchestrator)

**Decisions**: `read()` and `credentialMaterial()` now check for an email BEFORE the token source. An email-less oauth login can never be cached (the token is account-bound), so spending the user's one armed read on it was a prompt for nothing; the arm now survives for a keyable login. The email-less path also drops any cached token, like the other login-changed paths.
**Rejected**: none.
**Assumptions**: none new.
**Deferred**: none.
**Touches**: app/Credentials/MuseAuthReader.swift, app/Tests/MuseProviderTests.swift (one assertion in `cachedTokenIsBoundToItsAccount` now expects `.noDurableIdentity` for the email-less file, since that file no longer reaches the gate).
