# JSON Cache

ClaudeUsageBar exports its latest normalized usage readings for other local tools at:

```text
~/Library/Application Support/ClaudeUsageBar/usage.json
```

The file is created after the app publishes its first account state. It is refreshed
when pulled data or discovered accounts change.

## Why this location

`Application Support` is the standard macOS location for durable, app-managed data.
Unlike `~/Library/Caches`, macOS does not treat it as disposable. A non-sandboxed local
app or command-line tool can read the file directly.

The export deliberately does not use `~/.claude-usage-bar/`. ClaudeUsageBar scans
`~/.claude-*` directories for Claude Code profiles, so that name would overlap with
profile discovery. A hidden home-directory location would also be less conventional for
a macOS application.

Sandboxed applications cannot freely read either location. A sandboxed consumer must
obtain user-granted access to the file, or both applications must be changed to use a
shared App Group container.

## Update behavior

Writes are atomic: the app writes a complete replacement and then swaps it into place.
A reader sees either the previous complete document or the new complete document, not a
partially written file.

The app skips repeated writes while the exported payload is unchanged.

- `last_updated` is the newest successful provider pull represented in the file.
- `fetched_at` is the successful pull time for one account.
- A failed pull does not advance either timestamp or erase the last successful reading.
- An account removed from discovery is removed from `accounts`.
- Before any successful pull, `last_updated` is `null` and `accounts` may be empty.

All timestamps use ISO 8601 in UTC.

## Schema version 1

```json
{
  "accounts": [
    {
      "fetched_at": "2026-07-24T08:15:00Z",
      "id": "anthropic:account-id",
      "label": "Work",
      "plan": "Max 20x",
      "provider": "anthropic",
      "subtitle": "user@example.com",
      "warnings": [],
      "windows": [
        {
          "is_active": true,
          "label": "Session",
          "resets_at": "2026-07-24T12:00:00Z",
          "scope": "account",
          "span": "session",
          "utilization_percent": 42
        }
      ]
    }
  ],
  "last_updated": "2026-07-24T08:15:00Z",
  "schema_version": 1
}
```

Top-level fields:

| Field | Type | Meaning |
| --- | --- | --- |
| `schema_version` | integer | Cache contract version. Currently `1`. |
| `last_updated` | string or null | Newest `fetched_at` represented in the document. |
| `accounts` | array | Latest successful normalized snapshot for each discovered account. |

Account fields:

| Field | Type | Meaning |
| --- | --- | --- |
| `provider` | string | `anthropic` or `codex`. |
| `id` | string | Stable, provider-namespaced account identity. |
| `label` | string | Current display label. |
| `subtitle` | string | Optional account subtitle, usually an email address. |
| `plan` | string | Optional provider plan label. |
| `fetched_at` | string | Time this account snapshot was pulled. |
| `windows` | array | Normalized quota windows. |
| `spend` | object | Optional extra-usage and credit amounts. |
| `warnings` | array | Non-fatal warnings attached to the snapshot. |

Window fields:

| Field | Type | Meaning |
| --- | --- | --- |
| `span` | string | `session`, `weekly`, or `other`. |
| `duration_seconds` | integer | Present when `span` is `other`. |
| `scope` | string | `account`, `model`, or `feature`. |
| `scope_id` | string | Present for model- or feature-scoped windows. |
| `label` | string | Provider-facing display label. |
| `utilization_percent` | integer | Whole percentage from 0 through 100; omitted when unknown. |
| `resets_at` | string | Reset time; omitted when the window has not started. |
| `is_active` | boolean | Whether the provider marks this as the binding window. |

`spend` may contain `used`, `limit`, and `balance`. Qualified amounts contain
`kind: "qualified"`, `minor_units`, `currency`, and `exponent`. Provider values without
currency metadata contain `kind: "unqualified"` and `raw`.

Optional fields are omitted when unavailable, except top-level `last_updated`, which is
always present.

## Reading the cache

Read the full document:

```bash
jq . "$HOME/Library/Application Support/ClaudeUsageBar/usage.json"
```

Check freshness:

```bash
jq -r '.last_updated' "$HOME/Library/Application Support/ClaudeUsageBar/usage.json"
```

List each account and its known usage percentages:

```bash
jq -r '.accounts[] | [.provider, .label, (.windows | map(.utilization_percent // "unknown") | join(","))] | @tsv' \
  "$HOME/Library/Application Support/ClaudeUsageBar/usage.json"
```

Consumers should check `schema_version` before parsing and treat unknown fields as
additive for forward compatibility.

## Privacy

The cache contains no OAuth credentials and no raw provider responses. It can contain
account identifiers, email addresses, plan names, usage percentages, and spend or credit
figures, so consumers should still treat it as private local data.
