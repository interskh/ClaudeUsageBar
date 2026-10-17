## Task 1 — Muse Keychain gate (read only on user Refresh)

**Decisions**
- `MuseKeychainGate` (pure, app/Credentials): token cache + one-shot arm; lock held across the inner read; caches only `access_token`, serves a synthesized `{access_token}` blob.
- Not-connected = gate returns `.failed(MuseAuthReader.connectInstruction)`; reader maps that exact fault to new `MuseAuthRead.notConnected` (state `.failed(msg)`, fetch `.transport(msg)`); other faults get `"; " + connectInstruction`.
- `arm()` is a no-op (returns false) while a token is cached, so a stale arm cannot let a later background poll prompt after invalidation.
- Engine only polls `.pending` accounts (`credentialUsable`), so a not-connected account cannot be fetched by a manual refresh. Wiring: `armMuseConnect()` arms + runs a survey (discovery does the one read); the survey's completion requests a manual refresh for Muse observations once `!gate.isArmed` (`museConnectPending` flag).
- 401/403 on Muse: `invalidate()` + `survey()` so discoveryState flips to the connect failure (outranks cached reading).
- Inline-first: `MuseAuthReader.credentialMaterial()` / `hasInlineToken` (pure); `museCredentialFact` uses it.
- Connect-state ref is the shared "unresolved" sentinel; after connecting, the real-email identity is a new engine key (staggered-first-poll avoided by the manual refresh above).

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
