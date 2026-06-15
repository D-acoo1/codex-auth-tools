import AppKit
import Foundation

struct CodexUsageSummary: Sendable {
    var title: String
    var email: String
    var alias: String?
    var accountID: String?
    var plan: String
    var allowed: Bool
    var limitReached: Bool
    var primaryUsed: Int?
    var primaryWindowSeconds: Int?
    var primaryResetAfterSeconds: Int?
    var primaryResetAt: TimeInterval?
    var secondaryUsed: Int?
    var secondaryWindowSeconds: Int?
    var secondaryResetAfterSeconds: Int?
    var secondaryResetAt: TimeInterval?
    var creditsBalance: String?
    var creditsUnlimited: Bool
    var resetCreditsAvailable: Int?
    var sparkPrimaryUsed: Int?
    var sparkSecondaryUsed: Int?
    var fetchedAt: Date
    var kind: String = "chatgpt"
    var baseURL: String? = nil

    var isAPIAccount: Bool { kind == "api" }

    var primaryRemaining: Int? { primaryUsed.map { max(0, 100 - $0) } }
    var secondaryRemaining: Int? { secondaryUsed.map { max(0, 100 - $0) } }
    var sparkPrimaryRemaining: Int? { sparkPrimaryUsed.map { max(0, 100 - $0) } }
    var sparkSecondaryRemaining: Int? { sparkSecondaryUsed.map { max(0, 100 - $0) } }

    func asDictionary() -> [String: Any] {
        var d: [String: Any] = [
            "ok": true,
            "title": title,
            "email": email,
            "plan": plan,
            "allowed": allowed,
            "limit_reached": limitReached,
            "fetched_at": ISO8601DateFormatter().string(from: fetchedAt),
            "kind": kind
        ]
        if let v = baseURL { d["base_url"] = v }
        if let v = alias { d["alias"] = v }
        if let v = accountID { d["account_id"] = v }
        if let v = primaryUsed { d["primary_used_percent"] = v }
        if let v = primaryRemaining { d["primary_remaining_percent"] = v }
        if let v = primaryResetAfterSeconds { d["primary_reset_after_seconds"] = v }
        if let v = primaryResetAt { d["primary_reset_at"] = Int(v) }
        if let v = secondaryUsed { d["secondary_used_percent"] = v }
        if let v = secondaryRemaining { d["secondary_remaining_percent"] = v }
        if let v = secondaryResetAfterSeconds { d["secondary_reset_after_seconds"] = v }
        if let v = secondaryResetAt { d["secondary_reset_at"] = Int(v) }
        if let v = creditsBalance { d["credits_balance"] = v }
        d["credits_unlimited"] = creditsUnlimited
        if let v = resetCreditsAvailable { d["rate_limit_reset_credits_available"] = v }
        if let v = sparkPrimaryUsed { d["spark_primary_used_percent"] = v }
        if let v = sparkPrimaryRemaining { d["spark_primary_remaining_percent"] = v }
        if let v = sparkSecondaryUsed { d["spark_secondary_used_percent"] = v }
        if let v = sparkSecondaryRemaining { d["spark_secondary_remaining_percent"] = v }
        return d
    }
}

enum UsageError: Error, CustomStringConvertible, Sendable {
    case missingRegistry(String)
    case missingActiveAccount
    case missingAuthFile(String)
    case missingToken
    case badHTTP(Int, String)
    case badJSON
    case network(String)

    var description: String {
        switch self {
        case .missingRegistry(let p): return "找不到 Codex 账号注册表：\(p)"
        case .missingActiveAccount: return "Codex 没有当前登录账号"
        case .missingAuthFile(let p): return "找不到当前账号登录文件：\(p)"
        case .missingToken: return "当前账号没有可用登录令牌"
        case .badHTTP(let code, let body): return "接口返回 \(code)：\(body.prefix(180))"
        case .badJSON: return "接口返回的数据格式不符合预期"
        case .network(let msg): return msg
        }
    }
}

private struct CodexAuthContext: Sendable {
    let kind: String
    let accessToken: String?
    let alias: String?
    let accountID: String?
    let baseURL: String?

    var isAPIAccount: Bool { kind == "api" }
}


final class CodexUsageFetcher: @unchecked Sendable {
    private let home = FileManager.default.homeDirectoryForCurrentUser
    private let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    private let environment = ProcessInfo.processInfo.environment

    private var codexHome: URL {
        if let value = environment["CODEX_HOME"], !value.isEmpty {
            return URL(fileURLWithPath: (value as NSString).expandingTildeInPath, isDirectory: true)
        }
        return home.appendingPathComponent(".codex", isDirectory: true)
    }

    private var acHome: URL {
        if let value = environment["CODEX_AC_HOME"], !value.isEmpty {
            return URL(fileURLWithPath: (value as NSString).expandingTildeInPath, isDirectory: true)
        }
        return home.appendingPathComponent(".codex-ac", isDirectory: true)
    }

    private var stateDir: URL {
        if let value = environment["CODEX_BALANCE_STATE_DIR"], !value.isEmpty {
            return URL(fileURLWithPath: (value as NSString).expandingTildeInPath, isDirectory: true)
        }
        return home.appendingPathComponent("Library/Application Support/CodexBalance", isDirectory: true)
    }
    var stateFile: URL { stateDir.appendingPathComponent("last-status.json") }

    func fetch(completion: @escaping @Sendable (Result<CodexUsageSummary, UsageError>) -> Void) {
        do {
            let auth = try loadAuthContext()
            if auth.isAPIAccount {
                let summary = apiSummary(auth: auth)
                writeState(summary.asDictionary())
                completion(.success(summary))
                return
            }
            guard let accessToken = auth.accessToken, !accessToken.isEmpty else {
                throw UsageError.missingToken
            }
            var request = URLRequest(url: usageURL)
            request.httpMethod = "GET"
            request.timeoutInterval = 25
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("codex-balance-menubar/1.0", forHTTPHeaderField: "User-Agent")

            URLSession.shared.dataTask(with: request) { data, response, error in
                if let error = error {
                    completion(.failure(.network(error.localizedDescription)))
                    return
                }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                guard (200..<300).contains(status) else {
                    completion(.failure(.badHTTP(status, body)))
                    return
                }
                do {
                    let summary = try self.parseUsage(data ?? Data(), auth: auth)
                    self.writeState(summary.asDictionary())
                    completion(.success(summary))
                } catch {
                    completion(.failure(.badJSON))
                }
            }.resume()
        } catch let error as UsageError {
            completion(.failure(error))
        } catch {
            completion(.failure(.network(error.localizedDescription)))
        }
    }

    func fetchSync(timeout: TimeInterval = 30) -> Result<CodexUsageSummary, UsageError> {
        final class Box: @unchecked Sendable {
            var result: Result<CodexUsageSummary, UsageError>?
        }
        let semaphore = DispatchSemaphore(value: 0)
        let box = Box()
        fetch { res in
            box.result = res
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            return .failure(.network("请求超时"))
        }
        return box.result ?? .failure(.network("请求失败"))
    }

    private func loadAuthContext() throws -> CodexAuthContext {
        // API/relay profiles selected by `ca s <alias>` are represented in config.toml.
        // Detect them before reading ChatGPT OAuth tokens so Codex Balance follows ca.
        if let api = readAPIContextFromConfig() {
            return api
        }

        // `ca current` switches ChatGPT accounts by replacing ~/.codex/auth.json.
        // Read that file first so the menu bar always follows the account selected by ca.
        let currentAuthURL = codexHome.appendingPathComponent("auth.json")
        if let context = try? readAuthContext(from: currentAuthURL) {
            return context
        }

        let registryURL = codexHome.appendingPathComponent("accounts/registry.json")
        guard FileManager.default.fileExists(atPath: registryURL.path) else {
            throw UsageError.missingRegistry(registryURL.path)
        }
        let registryData = try Data(contentsOf: registryURL)
        guard let registry = try JSONSerialization.jsonObject(with: registryData) as? [String: Any],
              let activeKey = registry["active_account_key"] as? String,
              !activeKey.isEmpty else {
            throw UsageError.missingActiveAccount
        }
        let encoded = base64URL(activeKey)
        let authURL = codexHome.appendingPathComponent("accounts/\(encoded).auth.json")
        guard FileManager.default.fileExists(atPath: authURL.path) else {
            throw UsageError.missingAuthFile(authURL.path)
        }
        return try readAuthContext(from: authURL)
    }

    private func readAuthContext(from url: URL) throws -> CodexAuthContext {
        let authData = try Data(contentsOf: url)
        guard let auth = try JSONSerialization.jsonObject(with: authData) as? [String: Any],
              let tokens = auth["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String,
              !accessToken.isEmpty else {
            throw UsageError.missingToken
        }
        let accountID = tokens["account_id"] as? String
        return CodexAuthContext(
            kind: "chatgpt",
            accessToken: accessToken,
            alias: accountAlias(for: accountID),
            accountID: accountID,
            baseURL: nil
        )
    }

    private func readAPIContextFromConfig() -> CodexAuthContext? {
        let provider = currentModelProvider()
        let providerBaseURL = provider.flatMap { baseURLForProvider($0) }
        let topLevelBaseURL = currentOpenAIBaseURL()
        let authMode = currentAuthMode()
        let baseURL = providerBaseURL ?? topLevelBaseURL
        let match = apiAccountFromRegistry(provider: provider, baseURL: baseURL)

        if match != nil || authMode == "apikey" || providerBaseURL != nil || topLevelBaseURL != nil {
            return CodexAuthContext(
                kind: "api",
                accessToken: nil,
                alias: match?.alias,
                accountID: nil,
                baseURL: match?.baseURL ?? baseURL
            )
        }
        return nil
    }

    private func currentModelProvider() -> String? {
        let config = codexHome.appendingPathComponent("config.toml")
        guard let lines = try? String(contentsOf: config, encoding: .utf8).components(separatedBy: .newlines) else { return nil }
        var inTable = false
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("[") { inTable = true }
            if inTable { continue }
            if let value = tomlStringValue(line, key: "model_provider") { return value }
        }
        return nil
    }

    private func currentOpenAIBaseURL() -> String? {
        let config = codexHome.appendingPathComponent("config.toml")
        guard let lines = try? String(contentsOf: config, encoding: .utf8).components(separatedBy: .newlines) else { return nil }
        var inTable = false
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("[") { inTable = true }
            if inTable { continue }
            if let value = tomlStringValue(line, key: "openai_base_url") { return normalizeBaseURL(value) }
        }
        return nil
    }

    private func baseURLForProvider(_ provider: String) -> String? {
        let config = codexHome.appendingPathComponent("config.toml")
        guard let lines = try? String(contentsOf: config, encoding: .utf8).components(separatedBy: .newlines) else { return nil }
        var inTarget = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                let table = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                inTarget = table == "model_providers.\(provider)"
                continue
            }
            if inTarget, let value = tomlStringValue(line, key: "base_url") {
                return normalizeBaseURL(value)
            }
        }
        return nil
    }

    private func currentAuthMode() -> String? {
        let authURL = codexHome.appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: authURL),
              let auth = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return auth["auth_mode"] as? String
    }

    private struct APIAccountMatch {
        let alias: String?
        let baseURL: String?
    }

    private func apiAccountFromRegistry(provider: String?, baseURL: String?) -> APIAccountMatch? {
        let registryURL = acHome.appendingPathComponent("registry.json")
        guard let data = try? Data(contentsOf: registryURL),
              let registry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accounts = registry["accounts"] as? [String: Any] else { return nil }
        let activeAlias = registry["active_alias"] as? String
        if let activeAlias,
           let rec = accounts[activeAlias] as? [String: Any],
           isAPIRecord(rec),
           apiRecord(rec, matchesProvider: provider, baseURL: baseURL) {
            return APIAccountMatch(alias: activeAlias, baseURL: normalizeBaseURL(rec["base_url"] as? String) ?? baseURL)
        }
        for (alias, raw) in accounts {
            guard let rec = raw as? [String: Any], isAPIRecord(rec) else { continue }
            if apiRecord(rec, matchesProvider: provider, baseURL: baseURL) {
                return APIAccountMatch(alias: alias, baseURL: normalizeBaseURL(rec["base_url"] as? String) ?? baseURL)
            }
        }
        return nil
    }

    private func isAPIRecord(_ rec: [String: Any]) -> Bool {
        return rec["kind"] as? String == "api"
    }

    private func apiRecord(_ rec: [String: Any], matchesProvider provider: String?, baseURL: String?) -> Bool {
        if let provider {
            var ids: [String] = []
            if let id = rec["provider_id"] as? String { ids.append(id) }
            if let legacy = rec["legacy_provider_ids"] as? [String] { ids.append(contentsOf: legacy) }
            if ids.contains(provider) { return true }
        }
        if let baseURL, let recBase = normalizeBaseURL(rec["base_url"] as? String), recBase == normalizeBaseURL(baseURL) {
            return true
        }
        return false
    }

    private func tomlStringValue(_ line: String, key: String) -> String? {
        let pattern = #"^\s*"# + NSRegularExpression.escapedPattern(for: key) + #"\s*=\s*[\"']([^\"']+)[\"']"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line) else { return nil }
        return String(line[range])
    }

    private func normalizeBaseURL(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return String(value.drop { $0 == " " || $0 == "\t" }).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func apiDisplayName(from baseURL: String?) -> String {
        guard let baseURL, !baseURL.isEmpty else { return "API/中转" }
        var display = baseURL
        for prefix in ["https://", "http://"] {
            if display.hasPrefix(prefix) { display.removeFirst(prefix.count) }
        }
        return "api:" + display
    }

    private func apiSummary(auth: CodexAuthContext) -> CodexUsageSummary {
        return CodexUsageSummary(
            title: "API / -",
            email: apiDisplayName(from: auth.baseURL),
            alias: auth.alias,
            accountID: nil,
            plan: "API",
            allowed: true,
            limitReached: false,
            primaryUsed: nil,
            primaryWindowSeconds: nil,
            primaryResetAfterSeconds: nil,
            primaryResetAt: nil,
            secondaryUsed: nil,
            secondaryWindowSeconds: nil,
            secondaryResetAfterSeconds: nil,
            secondaryResetAt: nil,
            creditsBalance: nil,
            creditsUnlimited: false,
            resetCreditsAvailable: nil,
            sparkPrimaryUsed: nil,
            sparkSecondaryUsed: nil,
            fetchedAt: Date(),
            kind: "api",
            baseURL: auth.baseURL
        )
    }

    private func accountAlias(for accountID: String?) -> String? {
        guard let accountID else { return nil }
        let registryURL = codexHome.appendingPathComponent("accounts/registry.json")
        guard let data = try? Data(contentsOf: registryURL),
              let registry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accounts = registry["accounts"] as? [[String: Any]] else {
            return nil
        }
        return accounts.first { ($0["chatgpt_account_id"] as? String) == accountID }?["alias"] as? String
    }

    private func base64URL(_ text: String) -> String {
        let b64 = Data(text.utf8).base64EncodedString()
        return b64.replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func parseUsage(_ data: Data, auth: CodexAuthContext) throws -> CodexUsageSummary {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.badJSON
        }
        let email = root["email"] as? String ?? "unknown"
        let plan = root["plan_type"] as? String ?? "unknown"
        let rateLimit = root["rate_limit"] as? [String: Any] ?? [:]
        let allowed = bool(rateLimit["allowed"]) ?? false
        let limitReached = bool(rateLimit["limit_reached"]) ?? false
        let primary = rateLimit["primary_window"] as? [String: Any]
        let secondary = rateLimit["secondary_window"] as? [String: Any]
        let pUsed = int(primary?["used_percent"])
        let sUsed = int(secondary?["used_percent"])
        let pRemain = pUsed.map { max(0, 100 - $0) }
        let sRemain = sUsed.map { max(0, 100 - $0) }
        let title: String
        if limitReached {
            title = "5h 0% / 7d 0%"
        } else if let pRemain, let sRemain {
            title = "5h \(pRemain)% / 7d \(sRemain)%"
        } else if let pRemain {
            title = "5h \(pRemain)%"
        } else {
            title = "5h ? / 7d ?"
        }

        let credits = root["credits"] as? [String: Any] ?? [:]
        let resetCredits = root["rate_limit_reset_credits"] as? [String: Any] ?? [:]
        let additional = root["additional_rate_limits"] as? [[String: Any]] ?? []
        let spark = additional.first { (($0["limit_name"] as? String) ?? "").localizedCaseInsensitiveContains("Spark") }
        let sparkRate = spark?["rate_limit"] as? [String: Any]
        let sparkPrimary = sparkRate?["primary_window"] as? [String: Any]
        let sparkSecondary = sparkRate?["secondary_window"] as? [String: Any]

        return CodexUsageSummary(
            title: title,
            email: email,
            alias: auth.alias,
            accountID: auth.accountID,
            plan: plan,
            allowed: allowed,
            limitReached: limitReached,
            primaryUsed: pUsed,
            primaryWindowSeconds: int(primary?["limit_window_seconds"]),
            primaryResetAfterSeconds: int(primary?["reset_after_seconds"]),
            primaryResetAt: double(primary?["reset_at"]),
            secondaryUsed: sUsed,
            secondaryWindowSeconds: int(secondary?["limit_window_seconds"]),
            secondaryResetAfterSeconds: int(secondary?["reset_after_seconds"]),
            secondaryResetAt: double(secondary?["reset_at"]),
            creditsBalance: credits["balance"] as? String,
            creditsUnlimited: bool(credits["unlimited"]) ?? false,
            resetCreditsAvailable: int(resetCredits["available_count"]),
            sparkPrimaryUsed: int(sparkPrimary?["used_percent"]),
            sparkSecondaryUsed: int(sparkSecondary?["used_percent"]),
            fetchedAt: Date(),
            kind: "chatgpt",
            baseURL: nil
        )
    }

    private func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private func double(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private func bool(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String { return ["true", "1", "yes"].contains(value.lowercased()) }
        return nil
    }

    private func writeState(_ dictionary: [String: Any]) {
        do {
            try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: dictionary, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: stateFile, options: .atomic)
        } catch {
            // 状态文件只用于本机验收，失败不影响菜单栏显示。
        }
    }
}

final class UsageCardView: NSView {
    private let summary: CodexUsageSummary
    private let errorText: String?

    init(summary: CodexUsageSummary, errorText: String?) {
        self.summary = summary
        self.errorText = errorText
        super.init(frame: NSRect(x: 0, y: 0, width: 410, height: 162))
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let card = bounds.insetBy(dx: 10, dy: 10)
        let path = NSBezierPath(roundedRect: card, xRadius: 18, yRadius: 18)
        NSColor(calibratedRed: 0.06, green: 0.43, blue: 0.18, alpha: 1.0).setFill()
        path.fill()

        drawText("Codex 额度", x: 24, y: 124, width: 120, height: 18, font: .systemFont(ofSize: 12, weight: .semibold), color: NSColor(white: 1, alpha: 0.72))
        drawText(summary.plan.uppercased(), x: 338, y: 124, width: 52, height: 18, font: .systemFont(ofSize: 11, weight: .medium), color: NSColor(white: 1, alpha: 0.55), alignment: .right)

        drawDivider(x: 138)
        drawDivider(x: 270)

        drawColumn(icon: .timer, label: summary.isAPIAccount ? "API" : "剩余", value: summary.isAPIAccount ? "API" : percent(summary.primaryRemaining), x: 24, valueColor: NSColor(calibratedRed: 0.20, green: 0.92, blue: 0.44, alpha: 1))
        drawColumn(icon: .week, label: summary.isAPIAccount ? "中转" : "剩余", value: summary.isAPIAccount ? "—" : percent(summary.secondaryRemaining), x: 156, valueColor: NSColor(calibratedRed: 0.76, green: 0.48, blue: 1.0, alpha: 1))
        let credits = summary.isAPIAccount ? "—" : (summary.creditsUnlimited ? "∞" : (summary.creditsBalance ?? "0"))
        drawColumn(icon: .none, label: "Credits", value: credits, x: 288, valueColor: NSColor(calibratedRed: 0.46, green: 0.94, blue: 0.72, alpha: 1))

        if summary.isAPIAccount {
            drawText("无订阅额度", x: 24, y: 32, width: 116, height: 15, font: .systemFont(ofSize: 10.5, weight: .regular), color: NSColor(white: 1, alpha: 0.56))
            drawText("由 API 计费", x: 156, y: 32, width: 116, height: 15, font: .systemFont(ofSize: 10.5, weight: .regular), color: NSColor(white: 1, alpha: 0.56))
        } else {
            if let pReset = summary.primaryResetAfterSeconds {
                drawResetBlock(seconds: pReset, timestamp: summary.primaryResetAt, x: 24)
            }
            if let sReset = summary.secondaryResetAfterSeconds {
                drawResetBlock(seconds: sReset, timestamp: summary.secondaryResetAt, x: 156)
            }
        }
        let update = "更新 " + timeString(summary.fetchedAt)
        if let errorText {
            drawText(errorText, x: 288, y: 32, width: 96, height: 16, font: .systemFont(ofSize: 10, weight: .regular), color: NSColor(calibratedRed: 1, green: 0.72, blue: 0.52, alpha: 1), alignment: .right)
        } else {
            drawText(update, x: 288, y: 32, width: 96, height: 16, font: .systemFont(ofSize: 10.5, weight: .regular), color: NSColor(white: 1, alpha: 0.56), alignment: .right)
        }
    }

    private enum ColumnIcon {
        case timer
        case week
        case none
    }

    private func drawColumn(icon: ColumnIcon, label: String, value: String, x: CGFloat, valueColor: NSColor) {
        let labelColor = NSColor(white: 1, alpha: 0.62)
        if icon != .none {
            drawIcon(icon, in: NSRect(x: x, y: 92, width: 14, height: 14), color: labelColor)
            drawText(label, x: x + 18, y: 90, width: 87, height: 16, font: .systemFont(ofSize: 11, weight: .medium), color: labelColor)
        } else {
            drawText(label, x: x, y: 90, width: 105, height: 16, font: .systemFont(ofSize: 11, weight: .medium), color: labelColor)
        }
        drawText(value, x: x, y: 62, width: 112, height: 28, font: .monospacedDigitSystemFont(ofSize: 24, weight: .bold), color: valueColor)
    }

    private func drawIcon(_ icon: ColumnIcon, in rect: NSRect, color: NSColor) {
        switch icon {
        case .timer:
            drawTimerIcon(in: rect, color: color)
        case .week:
            drawWeekIcon(in: rect, color: color)
        case .none:
            return
        }
    }

    private func drawTimerIcon(in rect: NSRect, color: NSColor) {
        color.setStroke()
        color.setFill()
        let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2))
        circle.lineWidth = 1.4
        circle.stroke()
        let knob = NSBezierPath(roundedRect: NSRect(x: rect.midX - 2, y: rect.maxY - 2.5, width: 4, height: 2), xRadius: 1, yRadius: 1)
        knob.fill()
        let hand = NSBezierPath()
        hand.lineWidth = 1.3
        hand.move(to: NSPoint(x: rect.midX, y: rect.midY))
        hand.line(to: NSPoint(x: rect.midX, y: rect.midY + 3.2))
        hand.move(to: NSPoint(x: rect.midX, y: rect.midY))
        hand.line(to: NSPoint(x: rect.midX + 2.5, y: rect.midY - 1.4))
        hand.stroke()
    }

    private func drawWeekIcon(in rect: NSRect, color: NSColor) {
        color.setStroke()
        let body = NSBezierPath(roundedRect: rect.insetBy(dx: 1.2, dy: 1.2), xRadius: 2.2, yRadius: 2.2)
        body.lineWidth = 1.2
        body.stroke()
        color.withAlphaComponent(0.32).setFill()
        NSBezierPath(roundedRect: NSRect(x: rect.minX + 1.2, y: rect.maxY - 5, width: rect.width - 2.4, height: 3.4), xRadius: 1.4, yRadius: 1.4).fill()
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        ("7" as NSString).draw(in: NSRect(x: rect.minX, y: rect.minY + 1.0, width: rect.width, height: rect.height - 3.5), withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .bold),
            .foregroundColor: color,
            .paragraphStyle: style
        ])
    }

    private func drawDivider(x: CGFloat) {
        NSColor(white: 1, alpha: 0.18).setStroke()
        let path = NSBezierPath()
        path.move(to: NSPoint(x: x, y: 54))
        path.line(to: NSPoint(x: x, y: 106))
        path.lineWidth = 1
        path.stroke()
    }

    private func drawResetBlock(seconds: Int, timestamp: TimeInterval?, x: CGFloat) {
        let color = NSColor(white: 1, alpha: 0.56)
        drawText(duration(seconds), x: x, y: 32, width: 116, height: 15, font: .systemFont(ofSize: 10.5, weight: .regular), color: color)
        let point = resetPoint(timestamp) ?? "时间未知"
        drawText(point, x: x, y: 18, width: 116, height: 15, font: .systemFont(ofSize: 10.5, weight: .regular), color: color)
    }


    private func percent(_ value: Int?) -> String {
        value.map { "\($0)%" } ?? "?"
    }

    private func drawText(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, font: NSFont, color: NSColor, alignment: NSTextAlignment = .left) {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        (text as NSString).draw(in: NSRect(x: x, y: y, width: width, height: height), withAttributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: style
        ])
    }

    private func duration(_ seconds: Int) -> String {
        if seconds <= 0 { return "现在" }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return "\(days)天\(hours)小时" }
        if hours > 0 { return "\(hours)小时\(minutes)分" }
        return "\(max(1, minutes))分"
    }

    private func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    private func resetTimeSuffix(_ timestamp: TimeInterval?) -> String {
        resetPoint(timestamp).map { " · " + $0 } ?? ""
    }

    private func resetPoint(_ timestamp: TimeInterval?) -> String? {
        guard let timestamp else { return nil }
        let date = Date(timeIntervalSince1970: timestamp)
        let formatter = DateFormatter()
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            formatter.dateFormat = "今天 HH:mm"
        } else if calendar.isDateInTomorrow(date) {
            formatter.dateFormat = "明天 HH:mm"
        } else {
            formatter.dateFormat = "M/d HH:mm"
        }
        return formatter.string(from: date)
    }
}

final class CodexPanelViewController: NSViewController {
    init(summary: CodexUsageSummary?, errorText: String?, target: AnyObject, refreshAction: Selector, openAction: Selector, quitAction: Selector) {
        super.init(nibName: nil, bundle: nil)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 410, height: 372))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.clear.cgColor

        if let summary {
            let card = UsageCardView(summary: summary, errorText: errorText)
            card.frame = NSRect(x: 0, y: 200, width: 410, height: 162)
            root.addSubview(card)

            let accountText = "账号 " + [summary.alias, summary.email].compactMap { $0 }.joined(separator: " · ")
            root.addSubview(label(accountText, x: 22, y: 176, width: 360, height: 18, size: 12, weight: .semibold, color: .labelColor))
            root.addSubview(label("状态 \(statusText(summary)) · 套餐 \(summary.plan.uppercased())", x: 22, y: 154, width: 360, height: 16, size: 11, color: .secondaryLabelColor))

            if summary.isAPIAccount {
                addInfoRow(root, y: 124, title: "5 小时", value: "不适用", detail: "API/中转不提供 Codex 额度")
                addInfoRow(root, y: 94, title: "周额度", value: "不适用", detail: "按 API 服务商计费")
                addInfoRow(root, y: 64, title: "Credits", value: "不适用", detail: "无订阅重置券")
            } else {
                addInfoRow(root, y: 124, title: "5 小时", value: usageLine(used: summary.primaryUsed, remaining: summary.primaryRemaining), detail: resetLine(after: summary.primaryResetAfterSeconds, at: summary.primaryResetAt))
                addInfoRow(root, y: 94, title: "周额度", value: usageLine(used: summary.secondaryUsed, remaining: summary.secondaryRemaining), detail: resetLine(after: summary.secondaryResetAfterSeconds, at: summary.secondaryResetAt))
                let credits = summary.creditsUnlimited ? "无限" : (summary.creditsBalance ?? "未知")
                let resetCredits = summary.resetCreditsAvailable.map { "重置券 \($0)" } ?? "重置券未知"
                addInfoRow(root, y: 64, title: "Credits", value: credits, detail: resetCredits)

                if summary.sparkPrimaryUsed != nil || summary.sparkSecondaryUsed != nil {
                    let spark = "剩余 5h \(summary.sparkPrimaryRemaining.map { "\($0)%" } ?? "?") · 周 \(summary.sparkSecondaryRemaining.map { "\($0)%" } ?? "?")"
                    root.addSubview(label("Spark " + spark, x: 22, y: 44, width: 360, height: 14, size: 10.5, color: .tertiaryLabelColor))
                }
            }
        } else {
            let loading = NSTextField(labelWithString: "正在读取 Codex 额度…")
            loading.frame = NSRect(x: 22, y: 250, width: 260, height: 22)
            loading.font = .systemFont(ofSize: 14, weight: .medium)
            root.addSubview(loading)
        }

        if let errorText {
            let error = NSTextField(labelWithString: errorText)
            error.frame = NSRect(x: 22, y: 44, width: 360, height: 16)
            error.font = .systemFont(ofSize: 11, weight: .regular)
            error.textColor = .systemOrange
            root.addSubview(error)
        }

        let refresh = NSButton(title: "刷新", target: target, action: refreshAction)
        refresh.frame = NSRect(x: 22, y: 14, width: 82, height: 28)
        refresh.bezelStyle = .rounded
        root.addSubview(refresh)

        let open = NSButton(title: "用量页面", target: target, action: openAction)
        open.frame = NSRect(x: 116, y: 14, width: 96, height: 28)
        open.bezelStyle = .rounded
        root.addSubview(open)

        let quit = NSButton(title: "退出", target: target, action: quitAction)
        quit.frame = NSRect(x: 308, y: 14, width: 76, height: 28)
        quit.bezelStyle = .rounded
        root.addSubview(quit)

        self.view = root
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func addInfoRow(_ root: NSView, y: CGFloat, title: String, value: String, detail: String) {
        root.addSubview(label(title, x: 22, y: y, width: 70, height: 16, size: 11, weight: .semibold, color: .secondaryLabelColor))
        root.addSubview(label(value, x: 96, y: y, width: 118, height: 16, size: 11, weight: .medium, color: .labelColor))
        root.addSubview(label(detail, x: 216, y: y, width: 172, height: 16, size: 10.5, color: .secondaryLabelColor, alignment: .right))
    }

    private func label(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor, alignment: NSTextAlignment = .left) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.frame = NSRect(x: x, y: y, width: width, height: height)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.alignment = alignment
        field.lineBreakMode = .byTruncatingMiddle
        return field
    }

    private func statusText(_ summary: CodexUsageSummary) -> String {
        if summary.isAPIAccount { return "API/中转" }
        return summary.allowed && !summary.limitReached ? "可用" : "已到上限"
    }

    private func usageLine(used: Int?, remaining: Int?) -> String {
        let usedText = used.map { "已用 \($0)%" } ?? "已用 ?"
        let remainingText = remaining.map { "剩余 \($0)%" } ?? "剩余 ?"
        return "\(remainingText) · \(usedText)"
    }

    private func resetLine(after seconds: Int?, at timestamp: TimeInterval?) -> String {
        guard let seconds else { return "重置未知" }
        if let point = resetPoint(timestamp) {
            return "重置 " + point + " · " + duration(seconds)
        }
        return "重置 " + duration(seconds)
    }

    private func duration(_ seconds: Int) -> String {
        if seconds <= 0 { return "现在" }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return "\(days)天\(hours)小时" }
        if hours > 0 { return "\(hours)小时\(minutes)分" }
        return "\(max(1, minutes))分"
    }

    private func resetPoint(_ timestamp: TimeInterval?) -> String? {
        guard let timestamp else { return nil }
        let date = Date(timeIntervalSince1970: timestamp)
        let formatter = DateFormatter()
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            formatter.dateFormat = "今天 HH:mm"
        } else if calendar.isDateInTomorrow(date) {
            formatter.dateFormat = "明天 HH:mm"
        } else {
            formatter.dateFormat = "M/d HH:mm"
        }
        return formatter.string(from: date)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let menu = NSMenu()
    private let fetcher = CodexUsageFetcher()
    private var timer: Timer?
    private var outsideClickMonitor: Any?
    private var lastSummary: CodexUsageSummary?
    private var lastError: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        updateStatusButton(title: "5h … / 7d …")
        statusItem.button?.toolTip = "Codex 额度"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover(_:))
        popover.behavior = .transient
        popover.delegate = self
        updatePopoverContent()
        refresh(nil)
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh(nil)
            }
        }
    }

    @objc private func refresh(_ sender: Any?) {
        updateStatusButton(title: lastSummary?.title ?? "5h … / 7d …")
        fetcher.fetch { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let summary):
                    self?.lastSummary = summary
                    self?.lastError = nil
                    self?.updateStatusButton(title: summary.title)
                    self?.statusItem.button?.toolTip = self?.tooltip(for: summary)
                case .failure(let error):
                    self?.lastError = error.description
                    self?.updateStatusButton(title: self?.lastSummary?.title ?? "5h ? / 7d ?")
                    self?.statusItem.button?.toolTip = "Codex 额度读取失败：\(error.description)"
                }
                if self?.popover.isShown == true {
                    self?.updatePopoverContent()
                }
            }
        }
    }


    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            closePopover(sender)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        updatePopoverContent()
        refresh(nil)
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        installOutsideClickMonitor()
    }

    private func closePopover(_ sender: Any?) {
        popover.performClose(sender)
        removeOutsideClickMonitor()
    }

    func popoverDidClose(_ notification: Notification) {
        removeOutsideClickMonitor()
    }

    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.popover.isShown else { return }
                self.closePopover(nil)
            }
        }
    }

    private func removeOutsideClickMonitor() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
    }

    private func updatePopoverContent() {
        popover.contentViewController = CodexPanelViewController(
            summary: lastSummary,
            errorText: lastError,
            target: self,
            refreshAction: #selector(refreshFromPopover(_:)),
            openAction: #selector(openUsagePageFromPopover(_:)),
            quitAction: #selector(quit)
        )
        popover.contentSize = NSSize(width: 410, height: 372)
    }

    @objc private func refreshFromPopover(_ sender: Any?) {
        refresh(nil)
    }

    @objc private func openUsagePageFromPopover(_ sender: Any?) {
        openUsagePage()
    }


    private func updateStatusButton(title: String) {
        guard let button = statusItem.button else { return }
        button.image = nil
        button.attributedTitle = statusAttributedTitle(from: title)
    }

    private func statusAttributedTitle(from title: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let bodyFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [.font: bodyFont, .foregroundColor: NSColor.labelColor]

        let parsed = parseStatusTitle(title)
        appendSymbol("timer", to: result)
        result.append(NSAttributedString(string: " \(parsed.primary) / ", attributes: attrs))
        appendSymbol("week", to: result)
        result.append(NSAttributedString(string: " \(parsed.secondary)", attributes: attrs))
        return result
    }

    private func parseStatusTitle(_ title: String) -> (primary: String, secondary: String) {
        let stripped = title
            .replacingOccurrences(of: "5h ", with: "")
            .replacingOccurrences(of: "7d ", with: "")
        let parts = stripped.components(separatedBy: " / ")
        if parts.count >= 2 { return (parts[0], parts[1]) }
        if parts.count == 1 { return (parts[0], "?") }
        return ("?", "?")
    }

    private func appendSymbol(_ name: String, to result: NSMutableAttributedString) {
        let image: NSImage?
        if name == "week" {
            image = statusWeekIcon()
        } else if let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
            symbol.isTemplate = true
            symbol.size = NSSize(width: 13, height: 13)
            image = symbol
        } else {
            image = nil
        }

        if let image {
            let attachment = NSTextAttachment()
            attachment.image = image
            attachment.bounds = NSRect(x: 0, y: -2, width: 13, height: 13)
            result.append(NSAttributedString(attachment: attachment))
        } else {
            result.append(NSAttributedString(string: name == "timer" ? "⏱" : "7"))
        }
    }

    private func statusWeekIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 13, height: 13))
        image.lockFocus()
        let rect = NSRect(x: 0.5, y: 0.5, width: 12, height: 12)
        let color = NSColor.labelColor.withAlphaComponent(0.82)
        color.setStroke()
        let body = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 2, yRadius: 2)
        body.lineWidth = 1.1
        body.stroke()
        color.withAlphaComponent(0.28).setFill()
        NSBezierPath(roundedRect: NSRect(x: rect.minX + 1, y: rect.maxY - 4.2, width: rect.width - 2, height: 3), xRadius: 1.2, yRadius: 1.2).fill()
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        ("7" as NSString).draw(in: NSRect(x: 0, y: 1.3, width: 13, height: 10), withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .bold),
            .foregroundColor: color,
            .paragraphStyle: style
        ])
        image.unlockFocus()
        return image
    }

    private func codexIcon() -> NSImage? {
        let candidates = [
            Bundle.main.url(forResource: "codexTemplate", withExtension: "png"),
            URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codexTemplate.png")
        ].compactMap { $0 }
        for url in candidates {
            if let image = NSImage(contentsOf: url) {
                image.size = NSSize(width: 16, height: 16)
                image.isTemplate = true
                return image
            }
        }
        return nil
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        if let summary = lastSummary {
            let card = NSMenuItem()
            card.view = UsageCardView(summary: summary, errorText: lastError == nil ? nil : "读取失败")
            menu.addItem(card)
            menu.addItem(.separator())
            menu.addItem(disabled("账号：\(summary.email)"))
            menu.addItem(disabled("套餐：\(summary.plan)"))
            menu.addItem(disabled(summary.allowed && !summary.limitReached ? "状态：可用" : "状态：已到上限"))
            menu.addItem(.separator())
            menu.addItem(disabled("5 小时：\(windowLine(used: summary.primaryUsed, remaining: summary.primaryRemaining, resetAfter: summary.primaryResetAfterSeconds, resetAt: summary.primaryResetAt))"))
            if summary.secondaryUsed != nil {
                menu.addItem(disabled("7 天：\(windowLine(used: summary.secondaryUsed, remaining: summary.secondaryRemaining, resetAfter: summary.secondaryResetAfterSeconds, resetAt: summary.secondaryResetAt))"))
            }
            if let sp = summary.sparkPrimaryRemaining, let ss = summary.sparkSecondaryRemaining {
                menu.addItem(disabled("Spark：剩余 5h \(sp)% / 周 \(ss)%"))
            }
            let credits = summary.creditsUnlimited ? "无限" : (summary.creditsBalance ?? "未知")
            menu.addItem(disabled("Credits：\(credits)"))
            if let count = summary.resetCreditsAvailable {
                menu.addItem(disabled("重置券：\(count)"))
            }
            menu.addItem(disabled("刷新：\(timeString(summary.fetchedAt))"))
        } else {
            menu.addItem(disabled("正在读取 Codex 额度"))
        }
        if let lastError = lastError {
            menu.addItem(.separator())
            menu.addItem(disabled("错误：\(lastError)"))
        }
        menu.addItem(.separator())
        let refreshItem = NSMenuItem(title: "立即刷新", action: #selector(refresh(_:)), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)
        let openItem = NSMenuItem(title: "打开 Codex 用量页面", action: #selector(openUsagePage), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func windowLine(used: Int?, remaining: Int?, resetAfter: Int?, resetAt: TimeInterval?) -> String {
        let usedText = used.map { "已用 \($0)%" } ?? "已用未知"
        let remainText = remaining.map { "剩余 \($0)%" } ?? "剩余未知"
        let resetText = resetAfter.map { "，\(duration($0)) 后重置\(resetPoint(resetAt).map { "（\($0)）" } ?? "")" } ?? ""
        return "\(remainText)（\(usedText)）\(resetText)"
    }

    private func duration(_ seconds: Int) -> String {
        if seconds <= 0 { return "现在" }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return "\(days)天\(hours)小时" }
        if hours > 0 { return "\(hours)小时\(minutes)分" }
        return "\(max(1, minutes))分"
    }

    private func resetPoint(_ timestamp: TimeInterval?) -> String? {
        guard let timestamp else { return nil }
        let date = Date(timeIntervalSince1970: timestamp)
        let formatter = DateFormatter()
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            formatter.dateFormat = "今天 HH:mm"
        } else if calendar.isDateInTomorrow(date) {
            formatter.dateFormat = "明天 HH:mm"
        } else {
            formatter.dateFormat = "M/d HH:mm"
        }
        return formatter.string(from: date)
    }

    private func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    private func tooltip(for summary: CodexUsageSummary) -> String {
        if summary.isAPIAccount {
            return ["Codex 额度", "API/中转账号", summary.alias, summary.baseURL].compactMap { $0 }.joined(separator: "\n")
        }
        var lines = ["Codex 额度", summary.email]
        if let p = summary.primaryRemaining { lines.append("5 小时剩余：\(p)%") }
        if let s = summary.secondaryRemaining { lines.append("7 天剩余：\(s)%") }
        return lines.joined(separator: "\n")
    }

    @objc private func openUsagePage() {
        if let url = URL(string: "https://chatgpt.com/codex/settings/usage") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

func printJSON(_ object: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
       let text = String(data: data, encoding: .utf8) {
        print(text)
    }
}

if CommandLine.arguments.contains("--once") {
    let fetcher = CodexUsageFetcher()
    switch fetcher.fetchSync() {
    case .success(let summary):
        printJSON(summary.asDictionary())
        exit(0)
    case .failure(let error):
        printJSON(["ok": false, "error": error.description])
        exit(1)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
