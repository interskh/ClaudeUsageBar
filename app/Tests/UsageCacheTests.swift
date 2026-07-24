import Foundation

enum UsageCacheTests {
    static func run() {
        documentUsesLatestFetchTime()
        jsonContractIsStable()
        writerReplacesTheFile()
    }

    private static func documentUsesLatestFetchTime() {
        let earlier = Date(timeIntervalSince1970: 1_700_000_000)
        let later = earlier.addingTimeInterval(60)
        let account = AccountRef(
            id: AccountIdentity(provider: .anthropic, "account-1"),
            label: "Work",
            subtitle: "work@example.com"
        )
        let window = UsageWindow(
            id: WindowID(span: .session, scope: .account),
            label: "Session",
            utilization: .known(42),
            resetsAt: later.addingTimeInterval(3_600),
            isActive: true
        )
        let document = UsageCacheDocument(snapshots: [
            Snapshot(account: account, windows: [window], fetchedAt: earlier),
            Snapshot(
                account: AccountRef(
                    id: AccountIdentity(provider: .codex, "account-2"),
                    label: "Codex"
                ),
                windows: [],
                fetchedAt: later
            ),
        ])

        TestHarness.expect("the cache schema is versioned", document.schemaVersion, 1)
        TestHarness.expect("last_updated is the newest successful pull",
                           document.lastUpdated, later)
        TestHarness.expect("all cached accounts are exported", document.accounts.count, 2)
        TestHarness.expect("the provider is explicit",
                           document.accounts.first?.provider, "anthropic")
        TestHarness.expect("the stable account identity is exported",
                           document.accounts.first?.id, account.id.storageKey)
        TestHarness.expect("the account fetch time is retained",
                           document.accounts.first?.fetchedAt, earlier)
        TestHarness.expect("known utilization remains numeric",
                           document.accounts.first?.windows.first?.utilizationPercent, 42)
        if let data = try? document.encoded(),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            TestHarness.expect("last_updated is an ISO 8601 string",
                               object["last_updated"] as? String, "2023-11-14T22:14:20Z")
            let accounts = object["accounts"] as? [[String: Any]]
            let windows = accounts?.first?["windows"] as? [[String: Any]]
            TestHarness.expect("nested JSON keys are snake_case",
                               windows?.first?["utilization_percent"] as? Int, 42)
        } else {
            TestHarness.check("a populated cache encodes as JSON", false)
        }
    }

    private static func jsonContractIsStable() {
        let document = UsageCacheDocument(snapshots: [])
        guard let data = try? document.encoded(),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            TestHarness.check("the cache encodes as JSON", false)
            return
        }

        TestHarness.expect("the JSON uses snake_case keys", object["schema_version"] as? Int, 1)
        TestHarness.check("last_updated is present even before the first pull",
                          object.keys.contains("last_updated"))
        TestHarness.check("last_updated is null before the first pull",
                          object["last_updated"] is NSNull)
        TestHarness.expect("an empty cache has an accounts array",
                           (object["accounts"] as? [Any])?.count, 0)
    }

    private static func writerReplacesTheFile() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeUsageBar-\(UUID().uuidString)", isDirectory: true)
        let file = directory.appendingPathComponent("usage.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = UsageCacheDocument(snapshots: [])
        let writer = UsageCacheWriter(fileURL: file)
        do {
            try writer.write(first)
            let expected = try first.encoded()
            TestHarness.expect("the writer creates the requested cache file",
                               try Data(contentsOf: file), expected)
            let second = UsageCacheDocument(snapshots: [
                Snapshot(
                    account: AccountRef(
                        id: AccountIdentity(provider: .codex, "replacement"),
                        label: "Codex"
                    ),
                    windows: [],
                    fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
                ),
            ])
            try writer.write(second)
            TestHarness.expect("the writer replaces stale cache contents",
                               try Data(contentsOf: file), try second.encoded())
        } catch {
            TestHarness.check("the writer creates the requested cache file: \(error)", false)
        }
    }
}
