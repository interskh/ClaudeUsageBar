import Foundation

struct UsageCacheDocument: Encodable, Equatable {
    let schemaVersion = 1
    let lastUpdated: Date?
    let accounts: [UsageCacheAccount]

    init(snapshots: [Snapshot]) {
        lastUpdated = snapshots.map(\.fetchedAt).max()
        accounts = snapshots.map(UsageCacheAccount.init)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case lastUpdated = "last_updated"
        case accounts
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        if let lastUpdated {
            try container.encode(lastUpdated, forKey: .lastUpdated)
        } else {
            try container.encodeNil(forKey: .lastUpdated)
        }
        try container.encode(accounts, forKey: .accounts)
    }
}

struct UsageCacheAccount: Encodable, Equatable {
    let provider: String
    let id: String
    let label: String
    let subtitle: String?
    let plan: String?
    let fetchedAt: Date
    let windows: [UsageCacheWindow]
    let spend: UsageCacheSpend?
    let warnings: [String]

    init(_ snapshot: Snapshot) {
        provider = snapshot.account.provider.rawValue
        id = snapshot.account.id.storageKey
        label = snapshot.account.label
        subtitle = snapshot.account.subtitle
        plan = snapshot.planLabel
        fetchedAt = snapshot.fetchedAt
        windows = snapshot.windows.map(UsageCacheWindow.init)
        spend = snapshot.spend.map(UsageCacheSpend.init)
        warnings = snapshot.warnings
    }
}

struct UsageCacheWindow: Encodable, Equatable {
    let span: String
    let durationSeconds: Int?
    let scope: String
    let scopeId: String?
    let label: String
    let utilizationPercent: Int?
    let resetsAt: Date?
    let isActive: Bool

    init(_ window: UsageWindow) {
        switch window.id.span {
        case .session:
            span = "session"
            durationSeconds = nil
        case .weekly:
            span = "weekly"
            durationSeconds = nil
        case .other(let seconds):
            span = "other"
            durationSeconds = seconds
        }

        switch window.id.scope {
        case .account:
            scope = "account"
            scopeId = nil
        case .model(let id):
            scope = "model"
            scopeId = id
        case .feature(let id):
            scope = "feature"
            scopeId = id
        }

        label = window.label
        if case .known(let percent) = window.utilization {
            utilizationPercent = percent
        } else {
            utilizationPercent = nil
        }
        resetsAt = window.resetsAt
        isActive = window.isActive
    }
}

struct UsageCacheSpend: Encodable, Equatable {
    let used: UsageCacheAmount?
    let limit: UsageCacheAmount?
    let balance: UsageCacheAmount?

    init(_ spend: Spend) {
        used = spend.used.map(UsageCacheAmount.init)
        limit = spend.limit.map(UsageCacheAmount.init)
        balance = spend.balance.map(UsageCacheAmount.init)
    }
}

struct UsageCacheAmount: Encodable, Equatable {
    let kind: String
    let minorUnits: Int?
    let currency: String?
    let exponent: Int?
    let raw: String?

    init(_ amount: MonetaryAmount) {
        switch amount {
        case .qualified(let minor, let currency, let exponent):
            kind = "qualified"
            minorUnits = minor
            self.currency = currency
            self.exponent = exponent
            raw = nil
        case .unqualified(let raw):
            kind = "unqualified"
            minorUnits = nil
            currency = nil
            exponent = nil
            self.raw = raw
        }
    }
}

final class UsageCacheWriter {
    static let defaultFileURL: URL = {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport
            .appendingPathComponent("ClaudeUsageBar", isDirectory: true)
            .appendingPathComponent("usage.json")
    }()

    let fileURL: URL
    private var lastPayload: Data?

    init(fileURL: URL = UsageCacheWriter.defaultFileURL) {
        self.fileURL = fileURL
    }

    func write(_ document: UsageCacheDocument) throws {
        let payload = try document.encoded()
        guard payload != lastPayload else { return }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try payload.write(to: fileURL, options: .atomic)
        lastPayload = payload
    }
}
