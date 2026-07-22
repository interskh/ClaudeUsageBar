import SwiftUI
import AppKit

// THE COOKIE-ERA STORE, kept verbatim and kept COMPILING (§14 order). `UsageStore.swift`
// is now the multi-account store of §6; this file holds what it replaces, unchanged,
// because `AppDelegate`, `MenuBarController` and `PopoverView` still compile against it
// and those are tasks 9-11. Deleting it here would leave three commits in the run with
// an app target that does not build — and `build.sh --test` would not catch it, since
// the test target compiles no file in `App/`, `Core/` or `UI/`.
//
// Tasks 9-11 move each call site onto `UsageStore` and this file goes with the last one.
class UsageManager: ObservableObject {
    @Published var sessionUsage: Int = 0
    @Published var sessionLimit: Int = 100
    @Published var weeklyUsage: Int = 0
    @Published var weeklyLimit: Int = 100
    @Published var weeklySonnetUsage: Int = 0
    @Published var weeklySonnetLimit: Int = 100
    @Published var weeklyFableUsage: Int = 0
    @Published var weeklyFableLimit: Int = 100
    // Extra usage spend (from /overage_spend_limit). Shown only when there's spend.
    @Published var extraSpentMinor: Int = 0
    @Published var extraLimitMinor: Int = 0
    @Published var extraResetsAt: Date?
    @Published var freeCreditsMinor: Int = 0   // remaining free/promo credits (/prepaid/credits)
    @Published var creditCurrency: String = "USD"
    @Published var hasCreditUsage: Bool = false
    @Published var sessionResetsAt: Date?
    @Published var weeklyResetsAt: Date?
    @Published var weeklySonnetResetsAt: Date?
    @Published var weeklyFableResetsAt: Date?
    @Published var lastUpdated: Date = Date()
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var notificationsEnabled: Bool = true
    @Published var openAtLogin: Bool = false
    @Published var hasWeeklySonnet: Bool = false
    @Published var hasWeeklyFable: Bool = false
    @Published var hasFetchedData: Bool = false
    @Published var isAccessibilityEnabled: Bool = false
    @Published var shortcutEnabled: Bool = true

    private var statusItem: NSStatusItem?
    private var sessionCookie: String = ""
    private weak var delegate: AppDelegate?
    var lastNotifiedThreshold: Int = 0

    // Rate limiting / backoff state
    private var refreshTimer: Timer?
    private var consecutiveFailures: Int = 0
    private let baseInterval: TimeInterval = 300 // 5 minutes
    private let maxInterval: TimeInterval = 1800 // 30 minutes cap
    private var retryAfterDate: Date?
    private var lastFetchAttempt: Date?
    private let fetchCooldown: TimeInterval = 60 // Don't hit API more than once per minute

    init(statusItem: NSStatusItem?, delegate: AppDelegate? = nil) {
        self.statusItem = statusItem
        self.delegate = delegate
        loadSessionCookie()
        loadSettings()
        loadCachedUsage()
        checkAccessibilityStatus()
    }

    func loadSessionCookie() {
        if let savedCookie = UserDefaults.standard.string(forKey: "claude_session_cookie") {
            sessionCookie = savedCookie
        }
    }

    func saveSessionCookie(_ cookie: String) {
        NSLog("ClaudeUsage: Saving cookie, length: \(cookie.count)")
        sessionCookie = cookie
        UserDefaults.standard.set(cookie, forKey: "claude_session_cookie")
        UserDefaults.standard.synchronize()
        NSLog("ClaudeUsage: Cookie saved successfully")
    }

    func clearSessionCookie() {
        NSLog("ClaudeUsage: Clearing cookie")
        sessionCookie = ""
        UserDefaults.standard.removeObject(forKey: "claude_session_cookie")
        UserDefaults.standard.synchronize()

        // Reset all data
        sessionUsage = 0
        weeklyUsage = 0
        weeklySonnetUsage = 0
        weeklyFableUsage = 0
        sessionResetsAt = nil
        weeklyResetsAt = nil
        weeklySonnetResetsAt = nil
        weeklyFableResetsAt = nil
        extraSpentMinor = 0
        extraLimitMinor = 0
        extraResetsAt = nil
        freeCreditsMinor = 0
        hasCreditUsage = false
        hasFetchedData = false
        hasWeeklySonnet = false
        hasWeeklyFable = false
        errorMessage = nil
        lastNotifiedThreshold = 0
        UserDefaults.standard.set(0, forKey: "last_notified_threshold")

        // Reset rate limiting state
        consecutiveFailures = 0
        retryAfterDate = nil
        lastFetchAttempt = nil
        refreshTimer?.invalidate()

        // Update status bar to show 0%
        delegate?.updateStatusIcon(percentage: 0)

        NSLog("ClaudeUsage: Cookie cleared, data reset")
    }

    // MARK: - Usage Cache (survives app restarts)

    private func loadCachedUsage() {
        let defaults = UserDefaults.standard

        // Always restore last fetch timestamp (even without cached data)
        // so cooldown works across restarts
        if let ts = defaults.object(forKey: "cached_last_fetch_attempt") as? Date {
            lastFetchAttempt = ts
            NSLog("⏱️ Last fetch attempt was \(Int(Date().timeIntervalSince(ts)))s ago")
        }

        guard defaults.bool(forKey: "has_cached_usage") else { return }

        sessionUsage = defaults.integer(forKey: "cached_session_usage")
        weeklyUsage = defaults.integer(forKey: "cached_weekly_usage")
        weeklySonnetUsage = defaults.integer(forKey: "cached_weekly_sonnet_usage")
        hasWeeklySonnet = defaults.bool(forKey: "cached_has_weekly_sonnet")
        hasFetchedData = true

        if let ts = defaults.object(forKey: "cached_last_updated") as? Date {
            lastUpdated = ts
        }

        NSLog("📦 Loaded cached usage: session \(sessionUsage)%, weekly \(weeklyUsage)%")
        updateStatusBar()
    }

    private func saveCacheToDefaults() {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: "has_cached_usage")
        defaults.set(sessionUsage, forKey: "cached_session_usage")
        defaults.set(weeklyUsage, forKey: "cached_weekly_usage")
        defaults.set(weeklySonnetUsage, forKey: "cached_weekly_sonnet_usage")
        defaults.set(hasWeeklySonnet, forKey: "cached_has_weekly_sonnet")
        defaults.set(lastUpdated, forKey: "cached_last_updated")
    }

    // MARK: - Timer & Backoff Management

    func startRefreshTimer() {
        scheduleTimer(interval: baseInterval)
    }

    private func scheduleTimer(interval: TimeInterval) {
        let schedule = { [weak self] in
            self?.refreshTimer?.invalidate()
            self?.refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
                self?.fetchUsage()
            }
            NSLog("⏱️ Next fetch in \(Int(interval))s")
        }
        if Thread.isMainThread {
            schedule()
        } else {
            DispatchQueue.main.async(execute: schedule)
        }
    }

    private func currentBackoffInterval() -> TimeInterval {
        guard consecutiveFailures > 0 else { return baseInterval }
        // Cap exponent to prevent overflow (2^10 = 1024x, way past maxInterval)
        let clampedFailures = min(consecutiveFailures, 10)
        let backoff = baseInterval * pow(2.0, Double(clampedFailures - 1))
        return min(backoff, maxInterval)
    }

    private func handleSuccess() {
        consecutiveFailures = 0
        retryAfterDate = nil
        scheduleTimer(interval: baseInterval)
    }

    private func handleFailure(retryAfterSeconds: TimeInterval? = nil) {
        consecutiveFailures += 1
        let minInterval: TimeInterval = 60 // Never retry faster than 1 minute

        let interval: TimeInterval
        if let retryAfter = retryAfterSeconds, retryAfter >= minInterval {
            // Server told us exactly how long to wait (and it's reasonable)
            interval = retryAfter
            retryAfterDate = Date().addingTimeInterval(retryAfter)
            NSLog("⏳ Rate limited, server says retry after \(Int(retryAfter))s")
        } else {
            // Use exponential backoff (also covers Retry-After: 0 or missing header)
            interval = max(currentBackoffInterval(), minInterval)
            NSLog("⏳ Failure #\(consecutiveFailures), backing off to \(Int(interval))s")
        }

        scheduleTimer(interval: interval)
    }

    func fetchOrganizationId(completion: @escaping (String?) -> Void) {
        // Get org ID from the lastActiveOrg cookie value
        let cookieParts = sessionCookie.components(separatedBy: ";")
        for part in cookieParts {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("lastActiveOrg=") {
                let orgId = trimmed.replacingOccurrences(of: "lastActiveOrg=", with: "")
                NSLog("📋 Found org ID in cookie: \(orgId)")
                completion(orgId)
                return
            }
        }

        // If not in cookie, fetch from bootstrap
        guard let url = URL(string: "https://claude.ai/api/bootstrap") else {
            completion(nil)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("sessionKey=\(sessionCookie)", forHTTPHeaderField: "Cookie")

        NSLog("📡 Fetching bootstrap to get org ID...")

        URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let account = json["account"] as? [String: Any],
                  let lastActiveOrgId = account["lastActiveOrgId"] as? String else {
                NSLog("❌ Could not parse org ID from bootstrap")
                completion(nil)
                return
            }
            NSLog("✅ Got org ID from bootstrap: \(lastActiveOrgId)")
            completion(lastActiveOrgId)
        }.resume()
    }

    func fetchUsage() {
        guard !sessionCookie.isEmpty else {
            DispatchQueue.main.async {
                self.errorMessage = "Session cookie not set"
                self.updateStatusBar()
            }
            return
        }

        // Prevent concurrent requests
        guard !isLoading else {
            NSLog("⚠️ Fetch already in progress, skipping")
            return
        }

        // Respect server-requested backoff (from 429 Retry-After)
        if let retryDate = retryAfterDate, Date() < retryDate {
            let wait = Int(retryDate.timeIntervalSinceNow)
            NSLog("🚫 Server backoff active, skipping fetch (\(wait)s remaining)")
            return
        }

        // Cooldown: don't hit API if we just tried recently
        let now = Date()
        if let lastAttempt = lastFetchAttempt,
           now.timeIntervalSince(lastAttempt) < fetchCooldown {
            let wait = Int(fetchCooldown - now.timeIntervalSince(lastAttempt))
            NSLog("⏳ Cooldown active, skipping fetch (\(wait)s remaining)")
            return
        }

        isLoading = true
        errorMessage = nil
        lastFetchAttempt = Date()
        UserDefaults.standard.set(Date(), forKey: "cached_last_fetch_attempt")

        // Extract org ID from cookie
        fetchOrganizationId { [weak self] orgId in
            guard let self = self, let orgId = orgId else {
                DispatchQueue.main.async {
                    self?.errorMessage = "Could not get org ID from cookie"
                    self?.isLoading = false
                    self?.handleFailure()
                }
                return
            }

            self.fetchUsageWithOrgId(orgId)
            self.fetchExtraUsage(orgId)
            self.fetchFreeCredits(orgId)
        }
    }

    // Remaining free/promo credits (balance) from /prepaid/credits.
    func fetchFreeCredits(_ orgId: String) {
        guard let url = URL(string: "https://claude.ai/api/organizations/\(orgId)/prepaid/credits") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(sessionCookie, forHTTPHeaderField: "Cookie")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://claude.ai", forHTTPHeaderField: "Origin")
        request.setValue("https://claude.ai", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("claude.ai", forHTTPHeaderField: "authority")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            DispatchQueue.main.async {
                guard let self = self,
                      let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                // `amount` is the current balance; fall back to summing remaining tranches.
                if let amount = json["amount"] as? Int {
                    self.freeCreditsMinor = amount
                } else {
                    var remaining = 0
                    for key in ["tranches", "promo_tranches"] {
                        if let arr = json[key] as? [[String: Any]] {
                            for t in arr { remaining += (t["remaining_amount_minor_units"] as? Int) ?? 0 }
                        }
                    }
                    self.freeCreditsMinor = remaining
                }
                if let cur = json["currency"] as? String { self.creditCurrency = cur }
                NSLog("🎁 Free credits left: \(self.freeCreditsMinor) \(self.creditCurrency)")
            }
        }.resume()
    }

    // Extra usage spend + monthly limit live on a separate endpoint (not /usage).
    func fetchExtraUsage(_ orgId: String) {
        guard let url = URL(string: "https://claude.ai/api/organizations/\(orgId)/overage_spend_limit") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(sessionCookie, forHTTPHeaderField: "Cookie")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://claude.ai", forHTTPHeaderField: "Origin")
        request.setValue("https://claude.ai", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("claude.ai", forHTTPHeaderField: "authority")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            DispatchQueue.main.async {
                guard let self = self,
                      let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

                let spent = (json["used_credits"] as? Int) ?? 0
                let limit = (json["monthly_credit_limit"] as? Int) ?? 0
                self.extraSpentMinor = spent
                self.extraLimitMinor = limit
                self.creditCurrency = (json["currency"] as? String) ?? "USD"
                if let resetStr = json["disabled_until"] as? String {
                    let f = ISO8601DateFormatter()
                    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    self.extraResetsAt = f.date(from: resetStr) ?? ISO8601DateFormatter().date(from: resetStr)
                }
                self.hasCreditUsage = spent > 0
                NSLog("💳 Extra usage: \(spent)/\(limit) \(self.creditCurrency)")
            }
        }.resume()
    }

    func fetchUsageWithOrgId(_ orgId: String) {
        let urlString = "https://claude.ai/api/organizations/\(orgId)/usage"

        guard let url = URL(string: urlString) else {
            DispatchQueue.main.async {
                self.errorMessage = "Invalid URL"
                self.isLoading = false
                self.handleFailure()
            }
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15

        // Use the full cookie string (user provides all cookies, not just sessionKey)
        request.setValue(sessionCookie, forHTTPHeaderField: "Cookie")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://claude.ai", forHTTPHeaderField: "Origin")
        request.setValue("https://claude.ai", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("claude.ai", forHTTPHeaderField: "authority")

        NSLog("🔍 Fetching from: \(urlString)")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                self?.isLoading = false

                if let error = error {
                    NSLog("❌ Error: \(error.localizedDescription)")
                    self?.errorMessage = "Network error"
                    self?.handleFailure()
                    self?.updateStatusBar()
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    self?.errorMessage = "Invalid response"
                    self?.handleFailure()
                    self?.updateStatusBar()
                    return
                }

                NSLog("📡 Status: \(httpResponse.statusCode)")

                if httpResponse.statusCode != 200, let data = data, let responseString = String(data: data, encoding: .utf8) {
                    let truncated = String(responseString.prefix(200))
                    NSLog("📦 Error response: \(truncated)")
                }

                switch httpResponse.statusCode {
                case 200:
                    if let data = data, self?.parseUsageData(data) == true {
                        self?.saveCacheToDefaults()
                        self?.handleSuccess()
                    } else {
                        self?.handleFailure()
                    }

                case 401:
                    // Auth failure — stop polling, don't waste requests with a bad cookie
                    self?.errorMessage = "Session expired"
                    self?.refreshTimer?.invalidate()
                    NSLog("🔒 Auth failed, stopping timer")

                case 403:
                    // Likely Cloudflare challenge — transient, backoff and retry
                    self?.errorMessage = "Blocked (Cloudflare) – retrying"
                    self?.handleFailure()

                case 429:
                    // Parse Retry-After header (seconds or HTTP-date)
                    var retryAfter: TimeInterval? = nil
                    if let retryHeader = httpResponse.value(forHTTPHeaderField: "Retry-After") {
                        if let seconds = TimeInterval(retryHeader) {
                            retryAfter = seconds
                        } else {
                            // Try parsing as HTTP-date
                            let formatter = DateFormatter()
                            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
                            formatter.locale = Locale(identifier: "en_US_POSIX")
                            if let date = formatter.date(from: retryHeader) {
                                retryAfter = max(date.timeIntervalSinceNow, 60)
                            }
                        }
                    }
                    self?.errorMessage = "Rate limited – backing off"
                    self?.handleFailure(retryAfterSeconds: retryAfter)

                default:
                    self?.errorMessage = "HTTP \(httpResponse.statusCode)"
                    self?.handleFailure()
                }

                self?.updateStatusBar()
            }
        }.resume()
    }

    @discardableResult
    func parseUsageData(_ data: Data) -> Bool {
        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                errorMessage = "Invalid JSON"
                return false
            }

            NSLog("📊 Parsing usage data...")

            let iso8601Formatter = ISO8601DateFormatter()
            iso8601Formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            // Parse the actual claude.ai response format
            if let fiveHour = json["five_hour"] as? [String: Any] {
                if let sessionUtil = fiveHour["utilization"] as? Double {
                    sessionUsage = Int(sessionUtil)
                    sessionLimit = 100
                }
                if let resetsAtString = fiveHour["resets_at"] as? String {
                    NSLog("🕐 Session resets_at string: \(resetsAtString)")
                    if let resetsAt = iso8601Formatter.date(from: resetsAtString) {
                        sessionResetsAt = resetsAt
                        NSLog("✅ Parsed session reset time: \(resetsAt)")
                    } else {
                        NSLog("❌ Failed to parse session reset time")
                    }
                }
            }

            if let sevenDay = json["seven_day"] as? [String: Any] {
                if let weeklyUtil = sevenDay["utilization"] as? Double {
                    weeklyUsage = Int(weeklyUtil)
                    weeklyLimit = 100
                }
                if let resetsAtString = sevenDay["resets_at"] as? String {
                    NSLog("🕐 Weekly resets_at string: \(resetsAtString)")
                    if let resetsAt = iso8601Formatter.date(from: resetsAtString) {
                        weeklyResetsAt = resetsAt
                        NSLog("✅ Parsed weekly reset time: \(resetsAt)")
                    } else {
                        NSLog("❌ Failed to parse weekly reset time")
                    }
                }
            }

            // Check for seven_day_sonnet (Pro plan feature)
            if let sevenDaySonnet = json["seven_day_sonnet"] as? [String: Any] {
                hasWeeklySonnet = true
                if let sonnetUtil = sevenDaySonnet["utilization"] as? Double {
                    weeklySonnetUsage = Int(sonnetUtil)
                    weeklySonnetLimit = 100
                }
                if let resetsAtString = sevenDaySonnet["resets_at"] as? String {
                    NSLog("🕐 Weekly Sonnet resets_at string: \(resetsAtString)")
                    if let resetsAt = iso8601Formatter.date(from: resetsAtString) {
                        weeklySonnetResetsAt = resetsAt
                        NSLog("✅ Parsed weekly Sonnet reset time: \(resetsAt)")
                    } else {
                        NSLog("❌ Failed to parse weekly Sonnet reset time")
                    }
                }
            } else {
                hasWeeklySonnet = false
            }

            // Fable is a new, separately-counted model. It isn't a top-level
            // key like seven_day_sonnet — it lives in the `limits` array as a
            // model-scoped weekly limit (scope.model.display_name == "Fable").
            // The bar is only surfaced in the UI when usage is above 1%.
            hasWeeklyFable = false
            if let limits = json["limits"] as? [[String: Any]] {
                let fableLimit = limits.first { entry in
                    let scope = entry["scope"] as? [String: Any]
                    let model = scope?["model"] as? [String: Any]
                    return (model?["display_name"] as? String) == "Fable"
                }
                if let fable = fableLimit {
                    hasWeeklyFable = true
                    // `percent` may decode as Int or Double depending on payload.
                    if let p = fable["percent"] as? Int {
                        weeklyFableUsage = p
                    } else if let p = fable["percent"] as? Double {
                        weeklyFableUsage = Int(p)
                    }
                    weeklyFableLimit = 100
                    if let resetsAtString = fable["resets_at"] as? String {
                        NSLog("🕐 Weekly Fable resets_at string: \(resetsAtString)")
                        if let resetsAt = iso8601Formatter.date(from: resetsAtString) {
                            weeklyFableResetsAt = resetsAt
                            NSLog("✅ Parsed weekly Fable reset time: \(resetsAt)")
                        } else {
                            NSLog("❌ Failed to parse weekly Fable reset time")
                        }
                    }
                }
            }

            // (Prepaid usage credits are fetched separately from /prepaid/credits.)

            // Log what we found
            NSLog("✅ Parsed: Session \(sessionUsage)%, Weekly \(weeklyUsage)%\(hasWeeklySonnet ? ", Weekly Sonnet \(weeklySonnetUsage)%" : "")\(hasWeeklyFable ? ", Weekly Fable \(weeklyFableUsage)%" : "")")

            lastUpdated = Date()
            errorMessage = nil
            hasFetchedData = true

            // Update percentage values for progress bars
            updatePercentages()
            return true
        } catch {
            NSLog("❌ Parse error: \(error.localizedDescription)")
            errorMessage = "Parse error"
            return false
        }
    }

    func updateStatusBar() {
        let sessionPercent = Int((Double(sessionUsage) / Double(sessionLimit)) * 100)
        let weeklyPercent = Int((Double(weeklyUsage) / Double(weeklyLimit)) * 100)

        delegate?.updateStatusIcon(sessionPercentage: sessionPercent, weeklyPercentage: weeklyPercent)

        checkNotificationThresholds(percentage: max(sessionPercent, weeklyPercent))
    }

    @Published var sessionPercentage: Double = 0.0
    @Published var weeklyPercentage: Double = 0.0
    @Published var weeklySonnetPercentage: Double = 0.0
    @Published var weeklyFablePercentage: Double = 0.0

    func updatePercentages() {
        sessionPercentage = Double(sessionUsage) / Double(sessionLimit)
        weeklyPercentage = Double(weeklyUsage) / Double(weeklyLimit)
        weeklySonnetPercentage = Double(weeklySonnetUsage) / Double(weeklySonnetLimit)
        weeklyFablePercentage = Double(weeklyFableUsage) / Double(weeklyFableLimit)
    }
}
