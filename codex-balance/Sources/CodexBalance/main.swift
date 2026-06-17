import AppKit
import Foundation
import QuartzCore

struct APIUsageSummary: Sendable {
    var mode: String? = nil
    var status: String? = nil
    var valid: Bool? = nil
    var unit: String? = nil
    var remaining: Double? = nil
    var balance: Double? = nil
    var quotaLimit: Double? = nil
    var quotaUsed: Double? = nil
    var quotaRemaining: Double? = nil
    var todayCost: Double? = nil
    var todayActualCost: Double? = nil
    var totalCost: Double? = nil
    var totalActualCost: Double? = nil
    var todayTokens: Int64? = nil
    var totalTokens: Int64? = nil
    var todayInputTokens: Int64? = nil
    var todayOutputTokens: Int64? = nil
    var totalInputTokens: Int64? = nil
    var totalOutputTokens: Int64? = nil
    var todayRequests: Int64? = nil
    var totalRequests: Int64? = nil
    var rpm: Int64? = nil
    var tpm: Int64? = nil
    var error: String? = nil

    var displayRemaining: Double? {
        quotaRemaining ?? remaining ?? balance
    }

    var displayTodayCost: Double? {
        todayActualCost ?? todayCost
    }

    var displayTotalCost: Double? {
        totalActualCost ?? totalCost
    }
}

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
    var apiUsage: APIUsageSummary? = nil

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
        if let usage = apiUsage {
            if let v = usage.mode { d["api_mode"] = v }
            if let v = usage.status { d["api_status"] = v }
            if let v = usage.valid { d["api_valid"] = v }
            if let v = usage.unit { d["api_unit"] = v }
            if let v = usage.displayRemaining { d["api_remaining"] = v }
            if let v = usage.balance { d["api_balance"] = v }
            if let v = usage.quotaLimit { d["api_quota_limit"] = v }
            if let v = usage.quotaUsed { d["api_quota_used"] = v }
            if let v = usage.quotaRemaining { d["api_quota_remaining"] = v }
            if let v = usage.todayActualCost { d["api_today_actual_cost"] = v }
            if let v = usage.totalActualCost { d["api_total_actual_cost"] = v }
            if let v = usage.todayCost { d["api_today_cost"] = v }
            if let v = usage.totalCost { d["api_total_cost"] = v }
            if let v = usage.todayTokens { d["api_today_tokens"] = v }
            if let v = usage.totalTokens { d["api_total_tokens"] = v }
            if let v = usage.todayInputTokens { d["api_today_input_tokens"] = v }
            if let v = usage.todayOutputTokens { d["api_today_output_tokens"] = v }
            if let v = usage.totalInputTokens { d["api_total_input_tokens"] = v }
            if let v = usage.totalOutputTokens { d["api_total_output_tokens"] = v }
            if let v = usage.todayRequests { d["api_today_requests"] = v }
            if let v = usage.totalRequests { d["api_total_requests"] = v }
            if let v = usage.rpm { d["api_rpm"] = v }
            if let v = usage.tpm { d["api_tpm"] = v }
            if let v = usage.error { d["api_usage_error"] = v }
        }
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
        let l = L10n.shared
        switch self {
        case .missingRegistry(let p): return l.template("missingRegistry", ["path": p])
        case .missingActiveAccount: return l.t("missingActiveAccount")
        case .missingAuthFile(let p): return l.template("missingAuthFile", ["path": p])
        case .missingToken: return l.t("missingToken")
        case .badHTTP(let code, let body): return l.template("badHTTP", ["code": "\(code)", "body": String(body.prefix(180))])
        case .badJSON: return l.t("badJSON")
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
    let keyHelper: String?
    let usageURL: URL?

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
                fetchAPIUsage(auth: auth, completion: completion)
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
            return .failure(.network(L10n.shared.t("requestTimeout")))
        }
        return box.result ?? .failure(.network(L10n.shared.t("requestFailed")))
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
            baseURL: nil,
            keyHelper: nil,
            usageURL: nil
        )
    }

    private func readAPIContextFromConfig() -> CodexAuthContext? {
        let provider = currentModelProvider()
        let providerBaseURL = provider.flatMap { baseURLForProvider($0) }
        let providerKeyHelper = provider.flatMap { authCommandForProvider($0) }
        let topLevelBaseURL = currentOpenAIBaseURL()
        let authMode = currentAuthMode()
        let baseURL = providerBaseURL ?? topLevelBaseURL
        let match = apiAccountFromRegistry(provider: provider, baseURL: baseURL)
        let usageURL = match?.usageURL ?? defaultAPIUsageURL(from: match?.baseURL ?? baseURL)

        if match != nil || authMode == "apikey" || providerBaseURL != nil || topLevelBaseURL != nil {
            return CodexAuthContext(
                kind: "api",
                accessToken: nil,
                alias: match?.alias,
                accountID: nil,
                baseURL: match?.baseURL ?? baseURL,
                keyHelper: match?.keyHelper ?? providerKeyHelper,
                usageURL: usageURL
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

    private func authCommandForProvider(_ provider: String) -> String? {
        let config = codexHome.appendingPathComponent("config.toml")
        guard let lines = try? String(contentsOf: config, encoding: .utf8).components(separatedBy: .newlines) else { return nil }
        var inTarget = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                let table = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                inTarget = table == "model_providers.\(provider).auth"
                continue
            }
            if inTarget, let value = tomlStringValue(line, key: "command") {
                return value
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
        let keyHelper: String?
        let usageURL: URL?
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
            let recBaseURL = normalizeBaseURL(rec["base_url"] as? String) ?? baseURL
            return APIAccountMatch(alias: activeAlias, baseURL: recBaseURL, keyHelper: rec["key_helper"] as? String, usageURL: usageURL(from: rec, baseURL: recBaseURL))
        }
        for (alias, raw) in accounts {
            guard let rec = raw as? [String: Any], isAPIRecord(rec) else { continue }
            if apiRecord(rec, matchesProvider: provider, baseURL: baseURL) {
                let recBaseURL = normalizeBaseURL(rec["base_url"] as? String) ?? baseURL
                return APIAccountMatch(alias: alias, baseURL: recBaseURL, keyHelper: rec["key_helper"] as? String, usageURL: usageURL(from: rec, baseURL: recBaseURL))
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

    private func usageURL(from rec: [String: Any], baseURL: String?) -> URL? {
        if let raw = rec["usage_url"] as? String,
           let url = URL(string: raw),
           let scheme = url.scheme?.lowercased(),
           ["http", "https"].contains(scheme) {
            return url
        }
        return defaultAPIUsageURL(from: baseURL)
    }

    private func defaultAPIUsageURL(from baseURL: String?) -> URL? {
        guard let baseURL = normalizeBaseURL(baseURL) else { return nil }
        return URL(string: baseURL + "/usage")
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
        guard let baseURL, !baseURL.isEmpty else { return L10n.shared.t("apiRelay") }
        var display = baseURL
        for prefix in ["https://", "http://"] {
            if display.hasPrefix(prefix) { display.removeFirst(prefix.count) }
        }
        return "api:" + display
    }

    private func fetchAPIUsage(auth: CodexAuthContext, completion: @escaping @Sendable (Result<CodexUsageSummary, UsageError>) -> Void) {
        guard let usageURL = auth.usageURL, let keyHelper = auth.keyHelper, !keyHelper.isEmpty else {
            let usage = APIUsageSummary(error: L10n.shared.t("relayMissingConfig"))
            let summary = apiSummary(auth: auth, apiUsage: usage)
            writeState(summary.asDictionary())
            completion(.success(summary))
            return
        }

        let apiKey: String
        do {
            apiKey = try readAPIKey(command: keyHelper)
        } catch {
            let usage = APIUsageSummary(error: L10n.shared.t("apiKeyUnreadable"))
            let summary = apiSummary(auth: auth, apiUsage: usage)
            writeState(summary.asDictionary())
            completion(.success(summary))
            return
        }

        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("codex-balance-menubar/1.0", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { data, response, error in
            let usage: APIUsageSummary
            if let error = error {
                usage = APIUsageSummary(error: error.localizedDescription)
            } else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                if (200..<300).contains(status) {
                    usage = (try? self.parseAPIUsage(data ?? Data())) ?? APIUsageSummary(error: L10n.shared.t("relayBadFormat"))
                } else {
                    usage = APIUsageSummary(error: L10n.shared.template("badHTTP", ["code": "\(status)", "body": String(body.prefix(80))]))
                }
            }
            let summary = self.apiSummary(auth: auth, apiUsage: usage)
            self.writeState(summary.asDictionary())
            completion(.success(summary))
        }.resume()
    }

    private func readAPIKey(command: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            process.waitUntilExit()
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + 5) == .timedOut {
            process.terminate()
            throw UsageError.network(L10n.shared.t("requestTimeout"))
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0,
              let key = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else {
            throw UsageError.missingToken
        }
        return key
    }

    private func apiSummary(auth: CodexAuthContext, apiUsage: APIUsageSummary?) -> CodexUsageSummary {
        let title: String
        if let apiUsage, apiUsage.error == nil {
            let balance = formatAPIAmount(apiUsage.displayRemaining, unit: apiUsage.unit)
            let tokens = compactNumber(apiUsage.todayTokens ?? apiUsage.totalTokens)
            title = "API \(balance) / \(tokens)"
        } else {
            title = "API / -"
        }
        return CodexUsageSummary(
            title: title,
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
            baseURL: auth.baseURL,
            apiUsage: apiUsage
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

    private func parseAPIUsage(_ data: Data) throws -> APIUsageSummary {
        guard let rawRoot = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.badJSON
        }
        let root = (rawRoot["data"] as? [String: Any]) ?? rawRoot
        let quota = root["quota"] as? [String: Any]
        let usage = root["usage"] as? [String: Any]
        let today = usage?["today"] as? [String: Any]
        let total = usage?["total"] as? [String: Any]

        return APIUsageSummary(
            mode: root["mode"] as? String,
            status: root["status"] as? String,
            valid: bool(root["isValid"]) ?? bool(root["is_valid"]),
            unit: (quota?["unit"] as? String) ?? (root["unit"] as? String),
            remaining: double(root["remaining"]),
            balance: double(root["balance"]),
            quotaLimit: double(quota?["limit"]),
            quotaUsed: double(quota?["used"]),
            quotaRemaining: double(quota?["remaining"]),
            todayCost: double(today?["cost"]),
            todayActualCost: double(today?["actual_cost"]) ?? double(root["today_actual_cost"]),
            totalCost: double(total?["cost"]),
            totalActualCost: double(total?["actual_cost"]) ?? double(root["total_actual_cost"]),
            todayTokens: int64(today?["total_tokens"]) ?? int64(root["today_tokens"]),
            totalTokens: int64(total?["total_tokens"]) ?? int64(root["total_tokens"]),
            todayInputTokens: int64(today?["input_tokens"]),
            todayOutputTokens: int64(today?["output_tokens"]),
            totalInputTokens: int64(total?["input_tokens"]),
            totalOutputTokens: int64(total?["output_tokens"]),
            todayRequests: int64(today?["requests"]) ?? int64(root["today_requests"]),
            totalRequests: int64(total?["requests"]) ?? int64(root["total_requests"]),
            rpm: int64(usage?["rpm"]) ?? int64(root["rpm"]),
            tpm: int64(usage?["tpm"]) ?? int64(root["tpm"]),
            error: nil
        )
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
        if let pRemain, let sRemain {
            title = "5h \(pRemain)% / 7d \(sRemain)%"
        } else if let pRemain {
            title = "5h \(pRemain)%"
        } else if let sRemain {
            title = "5h ? / 7d \(sRemain)%"
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

    private func int64(_ value: Any?) -> Int64? {
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        if let value = value as? NSNumber { return value.int64Value }
        if let value = value as? String { return Int64(value) }
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

    private func formatAPIAmount(_ value: Double?, unit: String?) -> String {
        guard let value else { return "—" }
        if value < 0 { return L10n.shared.t("unlimited") }
        let absValue = abs(value)
        let decimals = absValue >= 100 ? 1 : (absValue >= 1 ? 2 : 4)
        let number = String(format: "%.\(decimals)f", value)
        switch (unit ?? "").uppercased() {
        case "USD", "$":
            return "$" + number
        case "CNY", "RMB", "¥":
            return "¥" + number
        case "":
            return number
        default:
            return number + " " + (unit ?? "")
        }
    }

    private func compactNumber(_ value: Int64?) -> String {
        guard let value else { return "—" }
        let number = Double(value)
        if value >= 1_000_000_000 {
            return String(format: "%.1fB", number / 1_000_000_000)
        }
        if value >= 1_000_000 {
            return String(format: "%.1fM", number / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fK", number / 1_000)
        }
        return "\(value)"
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
    enum TrainKind {
        case steam
        case bullet
        case metro
        case freight
    }

    struct TrainStyle {
        let kind: TrainKind
        let locomotiveBody: NSColor
        let locomotiveCab: NSColor
        let carA: NSColor
        let carB: NSColor
        let window: NSColor
        let headlight: NSColor
        let outline: NSColor
        let groove: NSColor
        let coupler: NSColor
        let accent: NSColor
    }

    static let trainStyles: [TrainStyle] = [
        TrainStyle(
            kind: .steam,
            locomotiveBody: NSColor(calibratedRed: 0.07, green: 0.10, blue: 0.09, alpha: 0.98),
            locomotiveCab: NSColor(calibratedRed: 0.17, green: 0.23, blue: 0.19, alpha: 0.98),
            carA: NSColor(calibratedRed: 0.76, green: 0.66, blue: 0.43, alpha: 0.96),
            carB: NSColor(calibratedRed: 0.45, green: 0.34, blue: 0.22, alpha: 0.96),
            window: NSColor(calibratedRed: 0.96, green: 0.90, blue: 0.72, alpha: 0.82),
            headlight: NSColor(calibratedRed: 0.93, green: 0.72, blue: 0.34, alpha: 0.95),
            outline: NSColor(white: 0, alpha: 0.30),
            groove: NSColor(white: 0, alpha: 0.18),
            coupler: NSColor(calibratedRed: 0.86, green: 0.77, blue: 0.58, alpha: 0.55),
            accent: NSColor(calibratedRed: 0.73, green: 0.55, blue: 0.25, alpha: 0.92)
        ),
        TrainStyle(
            kind: .bullet,
            locomotiveBody: NSColor(calibratedRed: 0.91, green: 0.95, blue: 0.90, alpha: 0.98),
            locomotiveCab: NSColor(calibratedRed: 0.80, green: 0.87, blue: 0.82, alpha: 0.98),
            carA: NSColor(calibratedRed: 0.88, green: 0.93, blue: 0.89, alpha: 0.96),
            carB: NSColor(calibratedRed: 0.77, green: 0.84, blue: 0.79, alpha: 0.96),
            window: NSColor(calibratedRed: 0.06, green: 0.19, blue: 0.17, alpha: 0.82),
            headlight: NSColor(calibratedRed: 0.96, green: 0.84, blue: 0.48, alpha: 0.88),
            outline: NSColor(white: 1, alpha: 0.28),
            groove: NSColor(calibratedRed: 0.25, green: 0.52, blue: 0.40, alpha: 0.26),
            coupler: NSColor(white: 1, alpha: 0.40),
            accent: NSColor(calibratedRed: 0.46, green: 0.73, blue: 0.56, alpha: 0.96)
        ),
        TrainStyle(
            kind: .metro,
            locomotiveBody: NSColor(calibratedRed: 0.72, green: 0.78, blue: 0.75, alpha: 0.97),
            locomotiveCab: NSColor(calibratedRed: 0.18, green: 0.34, blue: 0.33, alpha: 0.96),
            carA: NSColor(calibratedRed: 0.70, green: 0.77, blue: 0.74, alpha: 0.96),
            carB: NSColor(calibratedRed: 0.50, green: 0.60, blue: 0.56, alpha: 0.96),
            window: NSColor(calibratedRed: 0.04, green: 0.19, blue: 0.19, alpha: 0.78),
            headlight: NSColor(calibratedRed: 0.78, green: 0.95, blue: 0.84, alpha: 0.82),
            outline: NSColor(white: 0, alpha: 0.18),
            groove: NSColor(white: 0, alpha: 0.13),
            coupler: NSColor(white: 1, alpha: 0.42),
            accent: NSColor(calibratedRed: 0.35, green: 0.71, blue: 0.62, alpha: 0.92)
        ),
        TrainStyle(
            kind: .freight,
            locomotiveBody: NSColor(calibratedRed: 0.36, green: 0.29, blue: 0.22, alpha: 0.98),
            locomotiveCab: NSColor(calibratedRed: 0.63, green: 0.37, blue: 0.23, alpha: 0.96),
            carA: NSColor(calibratedRed: 0.60, green: 0.36, blue: 0.24, alpha: 0.96),
            carB: NSColor(calibratedRed: 0.39, green: 0.46, blue: 0.32, alpha: 0.96),
            window: NSColor(calibratedRed: 0.95, green: 0.83, blue: 0.60, alpha: 0.72),
            headlight: NSColor(calibratedRed: 0.95, green: 0.74, blue: 0.39, alpha: 0.88),
            outline: NSColor(white: 0, alpha: 0.22),
            groove: NSColor(white: 0, alpha: 0.17),
            coupler: NSColor(calibratedRed: 0.88, green: 0.72, blue: 0.52, alpha: 0.48),
            accent: NSColor(calibratedRed: 0.84, green: 0.64, blue: 0.36, alpha: 0.88)
        )
    ]

    static var styleCount: Int { trainStyles.count }

    private enum TrainSegment: Hashable {
        case locomotive
        case carA
        case carB
    }

    private let summary: CodexUsageSummary
    private let errorText: String?
    private let trainStyleIndex: Int
    private let trainStartTime: TimeInterval
    private let onTrainClick: () -> Void
    private let fastestTrainPeriod: TimeInterval = 4.5
    private let slowestTrainPeriod: TimeInterval = 24.0
    private var trainLayer: CALayer?
    private var staticCardImage: NSImage?
    private var trainSegmentImageCache: [TrainSegment: NSImage] = [:]
    private let trainSegmentSize = NSSize(width: 38, height: 34)
    private let trainTrackInset: CGFloat = 0
    private let trainTrackRadius: CGFloat = 18

    private var trainStyle: TrainStyle {
        Self.trainStyles[trainStyleIndex % Self.trainStyles.count]
    }

    init(summary: CodexUsageSummary, errorText: String?, trainStyleIndex: Int, trainStartTime: TimeInterval, onTrainClick: @escaping () -> Void) {
        self.summary = summary
        self.errorText = errorText
        self.trainStyleIndex = trainStyleIndex
        self.trainStartTime = trainStartTime
        self.onTrainClick = onTrainClick
        super.init(frame: NSRect(x: 0, y: 0, width: 410, height: 162))
        wantsLayer = true
        layer?.masksToBounds = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopTrainAnimation()
        } else {
            startTrainAnimation()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        staticCardSnapshot().draw(in: bounds)
    }

    private func staticCardSnapshot() -> NSImage {
        if let staticCardImage {
            return staticCardImage
        }
        let image = NSImage(size: bounds.size)
        image.lockFocus()
        drawStaticCard()
        image.unlockFocus()
        staticCardImage = image
        return image
    }

    private func drawStaticCard() {
        let card = bounds.insetBy(dx: 10, dy: 10)
        let path = NSBezierPath(roundedRect: card, xRadius: 18, yRadius: 18)
        let ceramicTop = NSColor(calibratedRed: 0.965, green: 0.943, blue: 0.900, alpha: 1.0)
        let ceramicBottom = NSColor(calibratedRed: 0.900, green: 0.862, blue: 0.805, alpha: 1.0)
        NSGradient(colors: [ceramicTop, ceramicBottom])?.draw(in: path, angle: -92)
        NSColor(calibratedWhite: 1.0, alpha: 0.42).setStroke()
        let highlight = NSBezierPath(roundedRect: card.insetBy(dx: 1.0, dy: 1.0), xRadius: 17, yRadius: 17)
        highlight.lineWidth = 1
        highlight.stroke()
        NSColor(calibratedRed: 0.36, green: 0.32, blue: 0.27, alpha: 0.16).setStroke()
        path.lineWidth = 1
        path.stroke()

        let titleColor = NSColor(calibratedRed: 0.17, green: 0.16, blue: 0.14, alpha: 0.82)
        let mutedTextColor = NSColor(calibratedRed: 0.20, green: 0.18, blue: 0.16, alpha: 0.56)
        let primaryValueColor = NSColor(calibratedRed: 0.18, green: 0.43, blue: 0.32, alpha: 1.0)
        let secondaryValueColor = NSColor(calibratedRed: 0.46, green: 0.32, blue: 0.52, alpha: 1.0)
        let tertiaryValueColor = NSColor(calibratedRed: 0.25, green: 0.47, blue: 0.43, alpha: 1.0)

        drawText(L10n.shared.t("title"), x: 24, y: 124, width: 120, height: 18, font: .systemFont(ofSize: 12, weight: .semibold), color: titleColor)
        drawText(summary.plan.uppercased(), x: 338, y: 124, width: 52, height: 18, font: .systemFont(ofSize: 11, weight: .medium), color: mutedTextColor, alignment: .right)

        drawDivider(x: 138)
        drawDivider(x: 270)

        if summary.isAPIAccount {
            let api = summary.apiUsage
            drawColumn(icon: .none, label: "Bal", value: apiAmount(api?.displayRemaining, unit: api?.unit), x: 24, valueColor: primaryValueColor)
            drawColumn(icon: .none, label: "Cost", value: apiAmount(api?.displayTodayCost, unit: api?.unit), x: 156, valueColor: secondaryValueColor)
            drawColumn(icon: .none, label: "Tok", value: compactNumber(api?.todayTokens ?? api?.totalTokens), x: 288, valueColor: tertiaryValueColor)
            drawText(L10n.shared.t("total") + " " + apiAmount(api?.displayTotalCost, unit: api?.unit), x: 24, y: 32, width: 116, height: 15, font: .systemFont(ofSize: 10.5, weight: .regular), color: mutedTextColor)
            drawText(L10n.shared.t("total") + " " + compactNumber(api?.totalTokens), x: 156, y: 32, width: 116, height: 15, font: .systemFont(ofSize: 10.5, weight: .regular), color: mutedTextColor)
        } else {
            drawColumn(icon: .timer, label: "5h", value: percent(summary.primaryRemaining), x: 24, valueColor: primaryValueColor)
            drawColumn(icon: .week, label: "7d", value: percent(summary.secondaryRemaining), x: 156, valueColor: secondaryValueColor)
            let credits = summary.creditsUnlimited ? "∞" : (summary.creditsBalance ?? "0")
            drawColumn(icon: .none, label: L10n.shared.t("credits"), value: credits, x: 288, valueColor: tertiaryValueColor)
            if let pReset = summary.primaryResetAfterSeconds {
                drawResetBlock(seconds: pReset, timestamp: summary.primaryResetAt, x: 24)
            }
            if let sReset = summary.secondaryResetAfterSeconds {
                drawResetBlock(seconds: sReset, timestamp: summary.secondaryResetAt, x: 156)
            }
        }
        let update = timeString(summary.fetchedAt)
        if let errorText {
            drawText(errorText, x: 288, y: 32, width: 96, height: 16, font: .systemFont(ofSize: 10, weight: .regular), color: NSColor(calibratedRed: 0.62, green: 0.30, blue: 0.22, alpha: 1.0), alignment: .right)
        } else {
            drawText(update, x: 288, y: 32, width: 96, height: 16, font: .systemFont(ofSize: 10.5, weight: .regular), color: mutedTextColor, alignment: .right)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let card = bounds.insetBy(dx: 10, dy: 10)
        if isPointOnTrain(point, in: card) {
            onTrainClick()
            return
        }
        super.mouseDown(with: event)
    }

    private func startTrainAnimation() {
        guard trainLayer == nil, let hostLayer = layer else { return }
        let card = bounds.insetBy(dx: 10, dy: 10)
        let track = trainTrackRect(in: card)

        let containerLayer = CALayer()
        containerLayer.name = "train"
        containerLayer.frame = bounds
        containerLayer.masksToBounds = false
        hostLayer.addSublayer(containerLayer)
        trainLayer = containerLayer

        let segments: [(segment: TrainSegment, offset: CGFloat)] = [
            (.carA, 32),
            (.carB, 17),
            (.locomotive, 0)
        ]

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for item in segments {
            let segmentLayer = makeTrainSegmentLayer(item.segment)
            let pose = currentTrainPose(in: card, distanceOffset: item.offset)
            segmentLayer.position = pose.point
            segmentLayer.transform = CATransform3DMakeRotation(pose.angle, 0, 0, 1)
            containerLayer.addSublayer(segmentLayer)
            if !isTrainBrokenDown {
                addTrainLoopAnimation(to: segmentLayer, on: track, distanceOffset: item.offset)
            }
        }
        CATransaction.commit()
    }

    private func stopTrainAnimation() {
        trainLayer?.removeAllAnimations()
        trainLayer?.removeFromSuperlayer()
        trainLayer = nil
    }

    private func makeTrainSegmentLayer(_ segment: TrainSegment) -> CALayer {
        let image = trainSegmentImage(segment)
        let segmentLayer = CALayer()
        segmentLayer.name = "trainSegment"
        segmentLayer.bounds = NSRect(origin: .zero, size: image.size)
        segmentLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        segmentLayer.contentsGravity = .resizeAspect
        segmentLayer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        segmentLayer.shouldRasterize = true
        segmentLayer.rasterizationScale = segmentLayer.contentsScale
        segmentLayer.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        return segmentLayer
    }

    private func addTrainLoopAnimation(to layer: CALayer, on track: NSRect, distanceOffset: CGFloat) {
        let period = currentTrainPeriod
        let keyframes = trainLoopKeyframes(on: track, distanceOffset: distanceOffset)
        let linearTiming = CAMediaTimingFunction(name: .linear)

        let position = CAKeyframeAnimation(keyPath: "position")
        position.values = keyframes.points
        position.keyTimes = keyframes.times
        position.calculationMode = .linear
        position.timingFunction = linearTiming
        position.duration = period

        let rotation = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        rotation.values = keyframes.angles
        rotation.keyTimes = keyframes.times
        rotation.calculationMode = .linear
        rotation.timingFunction = linearTiming
        rotation.duration = period

        let group = CAAnimationGroup()
        group.animations = [position, rotation]
        group.duration = period
        group.repeatCount = .infinity
        group.timingFunction = linearTiming
        group.isRemovedOnCompletion = false
        group.fillMode = .forwards

        let elapsed = max(0, Date.timeIntervalSinceReferenceDate - trainStartTime)
        let phase = elapsed.truncatingRemainder(dividingBy: period)
        group.beginTime = CACurrentMediaTime() - phase
        layer.add(group, forKey: "trainLoop")
    }

    private func trainLoopKeyframes(on track: NSRect, distanceOffset: CGFloat) -> (points: [NSValue], angles: [NSNumber], times: [NSNumber]) {
        let radius = trainTrackRadius
        let perimeter = roundedRectPerimeter(track, radius: radius)
        let sampleCount = 240
        var points: [NSValue] = []
        var angles: [NSNumber] = []
        var times: [NSNumber] = []
        points.reserveCapacity(sampleCount + 1)
        angles.reserveCapacity(sampleCount + 1)
        times.reserveCapacity(sampleCount + 1)

        var previousAngle: CGFloat?
        for index in 0...sampleCount {
            let progress = CGFloat(index) / CGFloat(sampleCount)
            let pose = trainPose(on: track, radius: radius, distance: progress * perimeter - distanceOffset)
            var angle = pose.angle
            if let previousAngle {
                while angle - previousAngle > CGFloat.pi {
                    angle -= 2 * CGFloat.pi
                }
                while angle - previousAngle < -CGFloat.pi {
                    angle += 2 * CGFloat.pi
                }
            }
            points.append(NSValue(point: pose.point))
            angles.append(NSNumber(value: Double(angle)))
            times.append(NSNumber(value: Double(progress)))
            previousAngle = angle
        }

        return (points, angles, times)
    }

    private func trainSegmentImage(_ segment: TrainSegment) -> NSImage {
        if let cached = trainSegmentImageCache[segment] {
            return cached
        }

        let image = NSImage(size: trainSegmentSize)
        image.lockFocus()
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: trainSegmentSize.width / 2, yBy: trainSegmentSize.height / 2)
        transform.concat()
        switch segment {
        case .locomotive:
            drawElectricMouseEngine()
            if isTrainBrokenDown {
                drawBreakdownSmoke(near: NSPoint(x: 0, y: 0))
            }
        case .carA:
            drawSeedCreatureCar()
        case .carB:
            drawWaterTurtleCar()
        }
        NSGraphicsContext.restoreGraphicsState()
        image.unlockFocus()
        trainSegmentImageCache[segment] = image
        return image
    }

    private func drawElectricMouseEngine() {
        let outline = NSColor(white: 0.06, alpha: 0.36)
        let yellow = NSColor(calibratedRed: 0.98, green: 0.78, blue: 0.24, alpha: 0.98)
        let warmYellow = NSColor(calibratedRed: 1.0, green: 0.88, blue: 0.42, alpha: 0.95)
        let cheek = NSColor(calibratedRed: 0.92, green: 0.24, blue: 0.20, alpha: 0.92)
        let dark = NSColor(calibratedRed: 0.13, green: 0.12, blue: 0.10, alpha: 0.92)
        let spark = NSColor(calibratedRed: 1.0, green: 0.91, blue: 0.36, alpha: 0.94)

        yellow.setFill()
        let body = NSBezierPath(roundedRect: NSRect(x: -8.2, y: -5.4, width: 16.4, height: 10.8), xRadius: 5.0, yRadius: 5.0)
        body.fill()
        outline.setStroke()
        body.lineWidth = 0.7
        body.stroke()

        drawTriangle(points: [NSPoint(x: -6.0, y: 4.5), NSPoint(x: -3.2, y: 12.4), NSPoint(x: -1.2, y: 4.0)], fill: yellow, stroke: outline, lineWidth: 0.65)
        drawTriangle(points: [NSPoint(x: 0.6, y: 4.2), NSPoint(x: 3.8, y: 12.0), NSPoint(x: 5.4, y: 3.8)], fill: yellow, stroke: outline, lineWidth: 0.65)
        drawTriangle(points: [NSPoint(x: -3.9, y: 9.0), NSPoint(x: -3.2, y: 12.4), NSPoint(x: -2.2, y: 8.7)], fill: dark)
        drawTriangle(points: [NSPoint(x: 2.6, y: 8.5), NSPoint(x: 3.8, y: 12.0), NSPoint(x: 4.4, y: 8.3)], fill: dark)

        warmYellow.setFill()
        NSBezierPath(roundedRect: NSRect(x: -5.8, y: -2.7, width: 9.0, height: 5.4), xRadius: 2.6, yRadius: 2.6).fill()
        dark.setFill()
        NSBezierPath(ovalIn: NSRect(x: -3.8, y: 0.3, width: 1.7, height: 1.9)).fill()
        NSBezierPath(ovalIn: NSRect(x: 2.4, y: 0.3, width: 1.7, height: 1.9)).fill()
        cheek.setFill()
        NSBezierPath(ovalIn: NSRect(x: -6.8, y: -2.2, width: 2.7, height: 2.7)).fill()
        NSBezierPath(ovalIn: NSRect(x: 5.0, y: -2.2, width: 2.7, height: 2.7)).fill()

        spark.setFill()
        let bolt = NSBezierPath()
        bolt.move(to: NSPoint(x: -10.4, y: 0.8))
        bolt.line(to: NSPoint(x: -14.0, y: 3.2))
        bolt.line(to: NSPoint(x: -12.2, y: 0.2))
        bolt.line(to: NSPoint(x: -15.4, y: -2.7))
        bolt.line(to: NSPoint(x: -10.6, y: -1.0))
        bolt.close()
        bolt.fill()
        outline.setStroke()
        bolt.lineWidth = 0.55
        bolt.stroke()

        drawCornerLight(x: 8.2, y: -3.8)
    }

    private func drawWaterTurtleCar() {
        let outline = NSColor(white: 0.05, alpha: 0.28)
        let shell = NSColor(calibratedRed: 0.22, green: 0.52, blue: 0.82, alpha: 0.96)
        let shellDark = NSColor(calibratedRed: 0.10, green: 0.32, blue: 0.58, alpha: 0.88)
        let skin = NSColor(calibratedRed: 0.46, green: 0.79, blue: 0.95, alpha: 0.96)
        let belly = NSColor(calibratedRed: 0.98, green: 0.84, blue: 0.52, alpha: 0.92)
        let dark = NSColor(calibratedRed: 0.07, green: 0.12, blue: 0.18, alpha: 0.90)
        let water = NSColor(calibratedRed: 0.56, green: 0.92, blue: 1.0, alpha: 0.82)

        shell.setFill()
        let body = NSBezierPath(roundedRect: NSRect(x: -8.4, y: -5.4, width: 16.2, height: 10.8), xRadius: 5.2, yRadius: 5.2)
        body.fill()
        outline.setStroke()
        body.lineWidth = 0.7
        body.stroke()

        shellDark.setFill()
        NSBezierPath(roundedRect: NSRect(x: -6.5, y: 1.0, width: 8.8, height: 2.2), xRadius: 1.0, yRadius: 1.0).fill()
        belly.setFill()
        NSBezierPath(roundedRect: NSRect(x: -5.5, y: -4.2, width: 8.0, height: 4.2), xRadius: 2.0, yRadius: 2.0).fill()

        skin.setFill()
        NSBezierPath(ovalIn: NSRect(x: 4.6, y: -3.7, width: 7.2, height: 7.4)).fill()
        NSBezierPath(ovalIn: NSRect(x: -10.5, y: -4.2, width: 4.0, height: 4.0)).fill()
        NSBezierPath(ovalIn: NSRect(x: -10.3, y: 0.4, width: 4.0, height: 4.0)).fill()
        outline.setStroke()
        NSBezierPath(ovalIn: NSRect(x: 4.6, y: -3.7, width: 7.2, height: 7.4)).stroke()

        dark.setFill()
        NSBezierPath(ovalIn: NSRect(x: 8.0, y: 0.7, width: 1.5, height: 1.8)).fill()
        NSBezierPath(ovalIn: NSRect(x: 8.0, y: -2.4, width: 1.5, height: 1.8)).fill()

        water.setStroke()
        let wave = NSBezierPath()
        wave.lineWidth = 0.9
        wave.move(to: NSPoint(x: -4.8, y: -7.0))
        wave.curve(to: NSPoint(x: 0.0, y: -7.0), controlPoint1: NSPoint(x: -3.2, y: -5.7), controlPoint2: NSPoint(x: -1.6, y: -8.3))
        wave.curve(to: NSPoint(x: 4.8, y: -7.0), controlPoint1: NSPoint(x: 1.6, y: -5.7), controlPoint2: NSPoint(x: 3.2, y: -8.3))
        wave.stroke()
    }

    private func drawSeedCreatureCar() {
        let outline = NSColor(white: 0.05, alpha: 0.28)
        let bodyGreen = NSColor(calibratedRed: 0.42, green: 0.74, blue: 0.48, alpha: 0.96)
        let belly = NSColor(calibratedRed: 0.62, green: 0.88, blue: 0.58, alpha: 0.92)
        let spot = NSColor(calibratedRed: 0.18, green: 0.48, blue: 0.32, alpha: 0.52)
        let bulb = NSColor(calibratedRed: 0.32, green: 0.64, blue: 0.42, alpha: 0.96)
        let bulbDark = NSColor(calibratedRed: 0.16, green: 0.42, blue: 0.30, alpha: 0.78)
        let dark = NSColor(calibratedRed: 0.06, green: 0.13, blue: 0.09, alpha: 0.88)

        bodyGreen.setFill()
        let body = NSBezierPath(roundedRect: NSRect(x: -8.6, y: -5.0, width: 16.4, height: 10.0), xRadius: 4.8, yRadius: 4.8)
        body.fill()
        outline.setStroke()
        body.lineWidth = 0.7
        body.stroke()

        belly.setFill()
        NSBezierPath(roundedRect: NSRect(x: -5.2, y: -3.6, width: 8.2, height: 4.6), xRadius: 2.1, yRadius: 2.1).fill()
        spot.setFill()
        NSBezierPath(ovalIn: NSRect(x: -6.5, y: 1.4, width: 2.4, height: 1.7)).fill()
        NSBezierPath(ovalIn: NSRect(x: 0.4, y: 2.0, width: 2.8, height: 1.8)).fill()

        bulb.setFill()
        let seed = NSBezierPath()
        seed.move(to: NSPoint(x: -3.8, y: 5.2))
        seed.curve(to: NSPoint(x: 0.4, y: 11.5), controlPoint1: NSPoint(x: -3.2, y: 8.4), controlPoint2: NSPoint(x: -1.2, y: 10.8))
        seed.curve(to: NSPoint(x: 5.1, y: 5.0), controlPoint1: NSPoint(x: 2.4, y: 10.2), controlPoint2: NSPoint(x: 4.6, y: 8.2))
        seed.curve(to: NSPoint(x: -3.8, y: 5.2), controlPoint1: NSPoint(x: 2.4, y: 6.2), controlPoint2: NSPoint(x: -0.5, y: 6.1))
        seed.close()
        seed.fill()
        outline.setStroke()
        seed.lineWidth = 0.65
        seed.stroke()

        bulbDark.setStroke()
        let vein = NSBezierPath()
        vein.lineWidth = 0.6
        vein.move(to: NSPoint(x: 0.3, y: 5.6))
        vein.line(to: NSPoint(x: 0.5, y: 10.5))
        vein.move(to: NSPoint(x: -0.2, y: 7.4))
        vein.line(to: NSPoint(x: -2.2, y: 8.9))
        vein.move(to: NSPoint(x: 1.0, y: 7.3))
        vein.line(to: NSPoint(x: 3.1, y: 8.8))
        vein.stroke()

        dark.setFill()
        NSBezierPath(ovalIn: NSRect(x: 4.6, y: 0.9, width: 1.5, height: 1.8)).fill()
        NSBezierPath(ovalIn: NSRect(x: 4.6, y: -2.2, width: 1.5, height: 1.8)).fill()
        drawCornerLight(x: -8.4, y: -5.0)
    }

    private func currentTrainPoses(in card: NSRect) -> [(point: NSPoint, angle: CGFloat)] {
        let offsets: [CGFloat] = [0, 17, 32]
        return offsets.map { currentTrainPose(in: card, distanceOffset: $0) }
    }

    private func currentTrainPose(in card: NSRect, distanceOffset: CGFloat) -> (point: NSPoint, angle: CGFloat) {
        let track = trainTrackRect(in: card)
        let elapsed = Date.timeIntervalSinceReferenceDate - trainStartTime
        let period = currentTrainPeriod
        let progress: CGFloat
        if isTrainBrokenDown {
            progress = 0
        } else {
            progress = CGFloat((elapsed.truncatingRemainder(dividingBy: period)) / period)
        }
        let radius = trainTrackRadius
        let perimeter = roundedRectPerimeter(track, radius: radius)
        let headDistance = progress * perimeter
        return trainPose(on: track, radius: radius, distance: headDistance - distanceOffset)
    }

    private var weeklyRemainingForSpeed: CGFloat {
        CGFloat(max(0, min(100, summary.secondaryRemaining ?? 100)))
    }

    private var isTrainBrokenDown: Bool {
        weeklyRemainingForSpeed <= 0
    }

    private var currentTrainPeriod: TimeInterval {
        let ratio = TimeInterval(weeklyRemainingForSpeed / 100)
        return slowestTrainPeriod - (slowestTrainPeriod - fastestTrainPeriod) * ratio
    }

    private func isPointOnTrain(_ point: NSPoint, in card: NSRect) -> Bool {
        currentTrainPoses(in: card).contains { pose in
            let dx = point.x - pose.point.x
            let dy = point.y - pose.point.y
            return sqrt(dx * dx + dy * dy) <= 14
        }
    }

    private func trainTrackRect(in card: NSRect) -> NSRect {
        card.insetBy(dx: trainTrackInset, dy: trainTrackInset)
    }

    private func roundedRectPerimeter(_ rect: NSRect, radius: CGFloat) -> CGFloat {
        let r = min(radius, rect.width / 2, rect.height / 2)
        return max(0, 2 * (rect.width + rect.height - 4 * r) + 2 * CGFloat.pi * r)
    }

    private func trainPose(on rect: NSRect, radius: CGFloat, distance: CGFloat) -> (point: NSPoint, angle: CGFloat) {
        let r = min(radius, rect.width / 2, rect.height / 2)
        let top = rect.width - 2 * r
        let side = rect.height - 2 * r
        let arc = CGFloat.pi * r / 2
        let perimeter = roundedRectPerimeter(rect, radius: r)
        var d = distance.truncatingRemainder(dividingBy: perimeter)
        if d < 0 { d += perimeter }

        if d <= top {
            return (NSPoint(x: rect.minX + r + d, y: rect.maxY), 0)
        }
        d -= top
        if d <= arc {
            return cornerPose(center: NSPoint(x: rect.maxX - r, y: rect.maxY - r), radius: r, startAngle: CGFloat.pi / 2, clockwiseDistance: d)
        }
        d -= arc
        if d <= side {
            return (NSPoint(x: rect.maxX, y: rect.maxY - r - d), -CGFloat.pi / 2)
        }
        d -= side
        if d <= arc {
            return cornerPose(center: NSPoint(x: rect.maxX - r, y: rect.minY + r), radius: r, startAngle: 0, clockwiseDistance: d)
        }
        d -= arc
        if d <= top {
            return (NSPoint(x: rect.maxX - r - d, y: rect.minY), CGFloat.pi)
        }
        d -= top
        if d <= arc {
            return cornerPose(center: NSPoint(x: rect.minX + r, y: rect.minY + r), radius: r, startAngle: -CGFloat.pi / 2, clockwiseDistance: d)
        }
        d -= arc
        if d <= side {
            return (NSPoint(x: rect.minX, y: rect.minY + r + d), CGFloat.pi / 2)
        }
        d -= side
        return cornerPose(center: NSPoint(x: rect.minX + r, y: rect.maxY - r), radius: r, startAngle: CGFloat.pi, clockwiseDistance: d)
    }

    private func cornerPose(center: NSPoint, radius: CGFloat, startAngle: CGFloat, clockwiseDistance: CGFloat) -> (point: NSPoint, angle: CGFloat) {
        let theta = startAngle - clockwiseDistance / radius
        let point = NSPoint(x: center.x + radius * cos(theta), y: center.y + radius * sin(theta))
        return (point, theta - CGFloat.pi / 2)
    }

    private func drawTrainCar(at point: NSPoint, angle: CGFloat, color: NSColor) {
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: point.x, yBy: point.y)
        transform.rotate(byRadians: angle)
        transform.concat()

        switch trainStyle.kind {
        case .steam:
            drawSteamCar(color: color)
        case .bullet:
            drawBulletCar(color: color)
        case .metro:
            drawMetroCar(color: color)
        case .freight:
            drawFreightCar(color: color)
        }

        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawLocomotive(at point: NSPoint, angle: CGFloat) {
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: point.x, yBy: point.y)
        transform.rotate(byRadians: angle)
        transform.concat()

        switch trainStyle.kind {
        case .steam:
            drawSteamLocomotive()
        case .bullet:
            drawBulletLocomotive()
        case .metro:
            drawMetroLocomotive()
        case .freight:
            drawFreightLocomotive()
        }

        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawSteamCar(color: NSColor) {
        color.setFill()
        let body = NSBezierPath(roundedRect: NSRect(x: -6.1, y: -4.0, width: 12.2, height: 8.0), xRadius: 1.7, yRadius: 1.7)
        body.fill()
        trainStyle.accent.setFill()
        NSBezierPath(roundedRect: NSRect(x: -5.0, y: -2.6, width: 10.0, height: 1.4), xRadius: 0.7, yRadius: 0.7).fill()
        trainStyle.window.setFill()
        NSBezierPath(roundedRect: NSRect(x: -3.9, y: 0.2, width: 2.4, height: 1.9), xRadius: 0.6, yRadius: 0.6).fill()
        NSBezierPath(roundedRect: NSRect(x: 1.4, y: 0.2, width: 2.4, height: 1.9), xRadius: 0.6, yRadius: 0.6).fill()
        strokeRounded(NSRect(x: -6.1, y: -4.0, width: 12.2, height: 8.0), radius: 1.7, width: 0.75)
    }

    private func drawBulletCar(color: NSColor) {
        color.setFill()
        let body = NSBezierPath(roundedRect: NSRect(x: -6.3, y: -3.7, width: 12.6, height: 7.4), xRadius: 3.3, yRadius: 3.3)
        body.fill()
        trainStyle.window.setFill()
        NSBezierPath(roundedRect: NSRect(x: -4.5, y: 0.2, width: 9.0, height: 1.8), xRadius: 0.9, yRadius: 0.9).fill()
        trainStyle.accent.setFill()
        NSBezierPath(roundedRect: NSRect(x: -4.8, y: -2.3, width: 9.6, height: 1.0), xRadius: 0.5, yRadius: 0.5).fill()
        strokeRounded(NSRect(x: -6.3, y: -3.7, width: 12.6, height: 7.4), radius: 3.3, width: 0.65)
    }

    private func drawMetroCar(color: NSColor) {
        color.setFill()
        NSBezierPath(roundedRect: NSRect(x: -6.0, y: -4.0, width: 12.0, height: 8.0), xRadius: 2.2, yRadius: 2.2).fill()
        trainStyle.accent.setFill()
        NSBezierPath(roundedRect: NSRect(x: -5.0, y: -3.0, width: 10.0, height: 1.1), xRadius: 0.5, yRadius: 0.5).fill()
        trainStyle.window.setFill()
        for x in stride(from: -4.2, through: 2.2, by: 3.2) {
            NSBezierPath(roundedRect: NSRect(x: x, y: 0.1, width: 2.0, height: 2.0), xRadius: 0.5, yRadius: 0.5).fill()
        }
        strokeRounded(NSRect(x: -6.0, y: -4.0, width: 12.0, height: 8.0), radius: 2.2, width: 0.7)
    }

    private func drawFreightCar(color: NSColor) {
        color.setFill()
        NSBezierPath(roundedRect: NSRect(x: -6.0, y: -4.0, width: 12.0, height: 8.0), xRadius: 1.2, yRadius: 1.2).fill()
        drawRoofGrooves(in: NSRect(x: -5.2, y: -3.0, width: 10.4, height: 6.0), spacing: 3.0)
        trainStyle.accent.setFill()
        NSBezierPath(roundedRect: NSRect(x: -3.0, y: -1.1, width: 6.0, height: 2.2), xRadius: 0.8, yRadius: 0.8).fill()
        strokeRounded(NSRect(x: -6.0, y: -4.0, width: 12.0, height: 8.0), radius: 1.2, width: 0.75)
    }

    private func drawSteamLocomotive() {
        trainStyle.locomotiveBody.setFill()
        NSBezierPath(roundedRect: NSRect(x: -7.0, y: -4.2, width: 13.4, height: 8.4), xRadius: 2.6, yRadius: 2.6).fill()
        trainStyle.locomotiveCab.setFill()
        NSBezierPath(roundedRect: NSRect(x: -5.1, y: -3.0, width: 5.6, height: 6.0), xRadius: 1.5, yRadius: 1.5).fill()
        trainStyle.accent.setFill()
        NSBezierPath(roundedRect: NSRect(x: 1.0, y: -2.0, width: 3.0, height: 4.0), xRadius: 1.3, yRadius: 1.3).fill()
        trainStyle.window.setFill()
        NSBezierPath(roundedRect: NSRect(x: -3.9, y: -1.4, width: 2.6, height: 2.8), xRadius: 0.7, yRadius: 0.7).fill()
        trainStyle.headlight.setFill()
        NSBezierPath(ovalIn: NSRect(x: 5.5, y: -1.7, width: 3.4, height: 3.4)).fill()
        trainStyle.outline.setFill()
        NSBezierPath(roundedRect: NSRect(x: 3.7, y: -3.2, width: 2.0, height: 6.4), xRadius: 0.8, yRadius: 0.8).fill()
        strokeRounded(NSRect(x: -7.0, y: -4.2, width: 13.4, height: 8.4), radius: 2.6, width: 0.8)
    }

    private func drawBulletLocomotive() {
        let body = NSBezierPath()
        body.move(to: NSPoint(x: -7.1, y: -3.9))
        body.line(to: NSPoint(x: 2.5, y: -3.9))
        body.curve(to: NSPoint(x: 8.1, y: 0), controlPoint1: NSPoint(x: 5.2, y: -3.7), controlPoint2: NSPoint(x: 7.2, y: -1.6))
        body.curve(to: NSPoint(x: 2.5, y: 3.9), controlPoint1: NSPoint(x: 7.2, y: 1.6), controlPoint2: NSPoint(x: 5.2, y: 3.7))
        body.line(to: NSPoint(x: -7.1, y: 3.9))
        body.curve(to: NSPoint(x: -7.1, y: -3.9), controlPoint1: NSPoint(x: -8.0, y: 2.5), controlPoint2: NSPoint(x: -8.0, y: -2.5))
        body.close()
        trainStyle.locomotiveBody.setFill()
        body.fill()
        trainStyle.outline.setStroke()
        body.lineWidth = 0.7
        body.stroke()
        trainStyle.window.setFill()
        NSBezierPath(roundedRect: NSRect(x: -4.4, y: 0.3, width: 7.2, height: 1.8), xRadius: 0.9, yRadius: 0.9).fill()
        trainStyle.accent.setFill()
        NSBezierPath(roundedRect: NSRect(x: -5.4, y: -2.4, width: 8.6, height: 1.0), xRadius: 0.5, yRadius: 0.5).fill()
        trainStyle.headlight.setFill()
        NSBezierPath(ovalIn: NSRect(x: 5.5, y: -0.9, width: 1.8, height: 1.8)).fill()
    }

    private func drawMetroLocomotive() {
        trainStyle.locomotiveBody.setFill()
        NSBezierPath(roundedRect: NSRect(x: -6.8, y: -4.2, width: 13.2, height: 8.4), xRadius: 2.0, yRadius: 2.0).fill()
        trainStyle.locomotiveCab.setFill()
        NSBezierPath(roundedRect: NSRect(x: 1.5, y: -3.0, width: 4.6, height: 6.0), xRadius: 1.4, yRadius: 1.4).fill()
        trainStyle.window.setFill()
        NSBezierPath(roundedRect: NSRect(x: 2.4, y: -1.7, width: 2.7, height: 3.4), xRadius: 0.8, yRadius: 0.8).fill()
        trainStyle.accent.setFill()
        NSBezierPath(roundedRect: NSRect(x: -5.5, y: -3.0, width: 7.0, height: 1.1), xRadius: 0.5, yRadius: 0.5).fill()
        trainStyle.headlight.setFill()
        NSBezierPath(ovalIn: NSRect(x: 5.3, y: -2.6, width: 1.4, height: 1.4)).fill()
        NSBezierPath(ovalIn: NSRect(x: 5.3, y: 1.2, width: 1.4, height: 1.4)).fill()
        strokeRounded(NSRect(x: -6.8, y: -4.2, width: 13.2, height: 8.4), radius: 2.0, width: 0.75)
    }

    private func drawFreightLocomotive() {
        trainStyle.locomotiveBody.setFill()
        NSBezierPath(roundedRect: NSRect(x: -7.0, y: -4.1, width: 13.6, height: 8.2), xRadius: 1.4, yRadius: 1.4).fill()
        trainStyle.locomotiveCab.setFill()
        NSBezierPath(roundedRect: NSRect(x: -4.8, y: -3.0, width: 4.9, height: 6.0), xRadius: 1.1, yRadius: 1.1).fill()
        trainStyle.window.setFill()
        NSBezierPath(roundedRect: NSRect(x: -3.8, y: -1.5, width: 2.4, height: 3.0), xRadius: 0.6, yRadius: 0.6).fill()
        trainStyle.accent.setFill()
        NSBezierPath(roundedRect: NSRect(x: 1.0, y: -1.3, width: 4.2, height: 2.6), xRadius: 0.9, yRadius: 0.9).fill()
        trainStyle.headlight.setFill()
        NSBezierPath(ovalIn: NSRect(x: 5.5, y: -1.4, width: 2.8, height: 2.8)).fill()
        drawRoofGrooves(in: NSRect(x: -6.0, y: -3.2, width: 11.0, height: 6.4), spacing: 3.0)
        strokeRounded(NSRect(x: -7.0, y: -4.1, width: 13.6, height: 8.2), radius: 1.4, width: 0.8)
    }

    private func drawTriangle(points: [NSPoint], fill: NSColor, stroke: NSColor? = nil, lineWidth: CGFloat = 0.6) {
        guard points.count >= 3 else { return }
        let path = NSBezierPath()
        path.move(to: points[0])
        for point in points.dropFirst() {
            path.line(to: point)
        }
        path.close()
        fill.setFill()
        path.fill()
        if let stroke {
            stroke.setStroke()
            path.lineWidth = lineWidth
            path.stroke()
        }
    }

    private func drawBreakdownSmoke(near point: NSPoint) {
        NSGraphicsContext.saveGraphicsState()
        NSColor(white: 1, alpha: 0.78).setFill()
        NSBezierPath(ovalIn: NSRect(x: point.x + 10, y: point.y + 2, width: 4.8, height: 4.8)).fill()
        NSColor(white: 1, alpha: 0.52).setFill()
        NSBezierPath(ovalIn: NSRect(x: point.x + 15, y: point.y + 8, width: 3.8, height: 3.8)).fill()
        NSColor(calibratedRed: 1.0, green: 0.72, blue: 0.28, alpha: 0.88).setFill()
        let spark = NSBezierPath()
        spark.move(to: NSPoint(x: point.x + 10, y: point.y - 9))
        spark.line(to: NSPoint(x: point.x + 14, y: point.y - 4))
        spark.line(to: NSPoint(x: point.x + 11.5, y: point.y - 4.2))
        spark.line(to: NSPoint(x: point.x + 15, y: point.y + 1))
        spark.line(to: NSPoint(x: point.x + 9.5, y: point.y - 5.2))
        spark.line(to: NSPoint(x: point.x + 12, y: point.y - 5.0))
        spark.close()
        spark.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawCoupler(from start: NSPoint, to end: NSPoint) {
        trainStyle.coupler.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        path.move(to: start)
        path.line(to: end)
        path.stroke()
    }

    private func drawRoofGrooves(in rect: NSRect, spacing: CGFloat = 2.4) {
        trainStyle.groove.setStroke()
        for offset in stride(from: rect.minX + spacing, through: rect.maxX - spacing, by: spacing) {
            let path = NSBezierPath()
            path.lineWidth = 0.45
            path.move(to: NSPoint(x: offset, y: rect.minY + 1.5))
            path.line(to: NSPoint(x: offset, y: rect.maxY - 1.5))
            path.stroke()
        }
    }

    private func drawCornerLight(x: CGFloat, y: CGFloat) {
        trainStyle.headlight.setFill()
        NSBezierPath(ovalIn: NSRect(x: x - 0.75, y: y - 0.75, width: 1.5, height: 1.5)).fill()
    }

    private func strokeRounded(_ rect: NSRect, radius: CGFloat, width: CGFloat) {
        trainStyle.outline.setStroke()
        let outline = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        outline.lineWidth = width
        outline.stroke()
    }

    private enum ColumnIcon {
        case timer
        case week
        case none
    }

    private func drawColumn(icon: ColumnIcon, label: String, value: String, x: CGFloat, valueColor: NSColor) {
        let labelColor = NSColor(calibratedRed: 0.20, green: 0.18, blue: 0.16, alpha: 0.58)
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
        NSColor(calibratedRed: 0.30, green: 0.26, blue: 0.22, alpha: 0.14).setStroke()
        let path = NSBezierPath()
        path.move(to: NSPoint(x: x, y: 54))
        path.line(to: NSPoint(x: x, y: 106))
        path.lineWidth = 1
        path.stroke()
    }

    private func drawResetBlock(seconds: Int, timestamp: TimeInterval?, x: CGFloat) {
        let color = NSColor(calibratedRed: 0.20, green: 0.18, blue: 0.16, alpha: 0.52)
        drawText(duration(seconds), x: x, y: 32, width: 116, height: 15, font: .systemFont(ofSize: 10.5, weight: .regular), color: color)
        let point = resetPoint(timestamp) ?? L10n.shared.t("unknown")
        drawText(point, x: x, y: 18, width: 116, height: 15, font: .systemFont(ofSize: 10.5, weight: .regular), color: color)
    }


    private func percent(_ value: Int?) -> String {
        value.map { "\($0)%" } ?? "?"
    }

    private func apiAmount(_ value: Double?, unit: String?) -> String {
        guard let value else { return "—" }
        if value < 0 { return L10n.shared.t("unlimited") }
        let absValue = abs(value)
        let decimals = absValue >= 100 ? 1 : (absValue >= 1 ? 2 : 4)
        let number = String(format: "%.\(decimals)f", value)
        switch (unit ?? "").uppercased() {
        case "USD", "$":
            return "$" + number
        case "CNY", "RMB", "¥":
            return "¥" + number
        case "":
            return number
        default:
            return number + " " + (unit ?? "")
        }
    }

    private func compactNumber(_ value: Int64?) -> String {
        guard let value else { return "—" }
        let number = Double(value)
        if value >= 1_000_000_000 { return String(format: "%.1fB", number / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.1fM", number / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", number / 1_000) }
        return "\(value)"
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
        L10n.shared.duration(seconds)
    }

    private func timeString(_ date: Date) -> String {
        L10n.shared.timeString(date)
    }

    private func resetTimeSuffix(_ timestamp: TimeInterval?) -> String {
        resetPoint(timestamp).map { " · " + $0 } ?? ""
    }

    private func resetPoint(_ timestamp: TimeInterval?) -> String? {
        L10n.shared.resetPoint(timestamp)
    }
}

final class CodexPanelViewController: NSViewController {
    init(
        summary: CodexUsageSummary?,
        errorText: String?,
        target: AnyObject,
        refreshAction: Selector,
        openAction: Selector,
        quitAction: Selector,
        languageAction: Selector,
        trainStyleIndex: Int,
        trainStartTime: TimeInterval,
        trainClickAction: @escaping () -> Void
    ) {
        super.init(nibName: nil, bundle: nil)
        let l = L10n.shared
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 410, height: 372))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.clear.cgColor

        if let summary {
            let card = UsageCardView(summary: summary, errorText: errorText, trainStyleIndex: trainStyleIndex, trainStartTime: trainStartTime, onTrainClick: trainClickAction)
            card.frame = NSRect(x: 0, y: 200, width: 410, height: 162)
            root.addSubview(card)

            let accountText = l.t("account") + " " + [summary.alias, summary.email].compactMap { $0 }.joined(separator: " · ")
            root.addSubview(label(accountText, x: 22, y: 176, width: 360, height: 18, size: 12, weight: .semibold, color: .labelColor))
            let statusPlan = l.t("status") + " " + statusText(summary) + " · " + l.t("plan") + " " + summary.plan.uppercased()
            root.addSubview(label(statusPlan, x: 22, y: 154, width: 360, height: 16, size: 11, color: .secondaryLabelColor))

            if summary.isAPIAccount {
                let api = summary.apiUsage
                addInfoRow(root, y: 124, title: l.t("balance"), value: apiAmount(api?.displayRemaining, unit: api?.unit), detail: quotaDetail(api))
                addInfoRow(root, y: 94, title: l.t("cost"), value: l.t("todayPrefix") + " " + apiAmount(api?.displayTodayCost, unit: api?.unit), detail: l.t("totalPrefix") + " " + apiAmount(api?.displayTotalCost, unit: api?.unit))
                addInfoRow(root, y: 64, title: l.t("tokens"), value: l.t("todayPrefix") + " " + compactNumber(api?.todayTokens), detail: l.t("totalPrefix") + " " + compactNumber(api?.totalTokens))
                let detail = apiDetailLine(api)
                root.addSubview(label(detail, x: 22, y: 44, width: 360, height: 14, size: 10.5, color: api?.error == nil ? .tertiaryLabelColor : .systemOrange))
            } else {
                addInfoRow(root, y: 124, title: l.t("fiveHours"), value: remainingLine(summary.primaryRemaining), detail: resetLine(after: summary.primaryResetAfterSeconds, at: summary.primaryResetAt))
                addInfoRow(root, y: 94, title: l.t("weeklyQuota"), value: remainingLine(summary.secondaryRemaining), detail: resetLine(after: summary.secondaryResetAfterSeconds, at: summary.secondaryResetAt))
                let credits = summary.creditsUnlimited ? l.t("unlimited") : (summary.creditsBalance ?? l.t("unknown"))
                let resetCredits = summary.resetCreditsAvailable.map { l.t("resetCredits") + " \($0)" } ?? (l.t("resetCredits") + " " + l.t("unknown"))
                addInfoRow(root, y: 64, title: l.t("credits"), value: credits, detail: resetCredits)

                if summary.sparkPrimaryUsed != nil || summary.sparkSecondaryUsed != nil {
                    let spark = "5h " + remainingLine(summary.sparkPrimaryRemaining) + " · 7d " + remainingLine(summary.sparkSecondaryRemaining)
                    root.addSubview(label("Spark " + spark, x: 22, y: 44, width: 360, height: 14, size: 10.5, color: .tertiaryLabelColor))
                }
            }
        } else {
            let loading = NSTextField(labelWithString: l.t("loading"))
            loading.frame = NSRect(x: 22, y: 250, width: 300, height: 22)
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

        let refresh = NSButton(title: l.t("refresh"), target: target, action: refreshAction)
        refresh.frame = NSRect(x: 22, y: 14, width: 78, height: 28)
        refresh.bezelStyle = .rounded
        root.addSubview(refresh)

        let open = NSButton(title: l.t("usagePage"), target: target, action: openAction)
        open.frame = NSRect(x: 108, y: 14, width: 90, height: 28)
        open.bezelStyle = .rounded
        root.addSubview(open)

        let language = NSPopUpButton(frame: NSRect(x: 208, y: 14, width: 92, height: 28), pullsDown: false)
        language.bezelStyle = .rounded
        for option in l.languageMenuOptions() {
            language.addItem(withTitle: l.displayLanguageTitle(option))
            language.lastItem?.representedObject = option.code
        }
        if let index = language.itemArray.firstIndex(where: { ($0.representedObject as? String) == l.selectedOptionCode }) {
            language.selectItem(at: index)
        }
        language.setTitle(l.languageButtonTitle())
        language.target = target
        language.action = languageAction
        root.addSubview(language)

        let quit = NSButton(title: l.t("quit"), target: target, action: quitAction)
        quit.frame = NSRect(x: 308, y: 14, width: 76, height: 28)
        quit.bezelStyle = .rounded
        root.addSubview(quit)

        self.view = root
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func addInfoRow(_ root: NSView, y: CGFloat, title: String, value: String, detail: String) {
        root.addSubview(label(title, x: 22, y: y, width: 78, height: 16, size: 11, weight: .semibold, color: .secondaryLabelColor))
        root.addSubview(label(value, x: 104, y: y, width: 128, height: 16, size: 11, weight: .medium, color: .labelColor))
        root.addSubview(label(detail, x: 232, y: y, width: 156, height: 16, size: 10.5, color: .secondaryLabelColor, alignment: .right))
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
        if summary.isAPIAccount { return L10n.shared.t("apiRelay") }
        return summary.allowed && !summary.limitReached ? L10n.shared.t("available") : L10n.shared.t("limitReached")
    }

    private func apiAmount(_ value: Double?, unit: String?) -> String {
        guard let value else { return "—" }
        if value < 0 { return L10n.shared.t("unlimited") }
        let absValue = abs(value)
        let decimals = absValue >= 100 ? 1 : (absValue >= 1 ? 2 : 4)
        let number = String(format: "%.\(decimals)f", value)
        switch (unit ?? "").uppercased() {
        case "USD", "$":
            return "$" + number
        case "CNY", "RMB", "¥":
            return "¥" + number
        case "":
            return number
        default:
            return number + " " + (unit ?? "")
        }
    }

    private func compactNumber(_ value: Int64?) -> String {
        guard let value else { return "—" }
        let number = Double(value)
        if value >= 1_000_000_000 { return String(format: "%.1fB", number / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.1fM", number / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", number / 1_000) }
        return "\(value)"
    }

    private func quotaDetail(_ api: APIUsageSummary?) -> String {
        let l = L10n.shared
        guard let api else { return l.t("relayUsageUnknown") }
        if let limit = api.quotaLimit {
            return l.t("quotaLimit") + " " + apiAmount(limit, unit: api.unit) + " · " + l.t("used") + " " + apiAmount(api.quotaUsed, unit: api.unit)
        }
        if api.balance != nil { return l.t("walletBalance") }
        return api.mode ?? l.t("relayUsageUnknown")
    }

    private func apiDetailLine(_ api: APIUsageSummary?) -> String {
        let l = L10n.shared
        if let error = api?.error { return l.t("relayUsageFailed") + ": " + error }
        let todayIO = l.t("input") + " " + compactNumber(api?.todayInputTokens) + " · " + l.t("output") + " " + compactNumber(api?.todayOutputTokens)
        let requests = api?.todayRequests.map { " · " + l.t("todayRequests") + " \($0)" } ?? ""
        return todayIO + requests
    }

    private func remainingLine(_ remaining: Int?) -> String {
        remaining.map { "\($0)%" } ?? "?"
    }

    private func resetLine(after seconds: Int?, at timestamp: TimeInterval?) -> String {
        let l = L10n.shared
        guard let seconds else { return l.t("reset") + " " + l.t("unknown") }
        if let point = resetPoint(timestamp) {
            return point + " · " + duration(seconds)
        }
        return duration(seconds)
    }

    private func duration(_ seconds: Int) -> String { L10n.shared.duration(seconds) }
    private func resetPoint(_ timestamp: TimeInterval?) -> String? { L10n.shared.resetPoint(timestamp) }
}

@preconcurrency @MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, @unchecked Sendable {
    fileprivate enum TaskLightState: Equatable {
        case idle
        case running
        case unread

        static func from(_ raw: String?) -> TaskLightState {
            switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "running", "busy", "in_progress", "in-progress", "yellow":
                return .running
            case "unread", "done", "completed", "complete", "finished", "red":
                return .unread
            case "idle", "none", "empty", "green":
                return .idle
            default:
                return .idle
            }
        }

        var rawValue: String {
            switch self {
            case .idle: return "idle"
            case .running: return "running"
            case .unread: return "unread"
            }
        }

        var activeLightIndex: Int {
            switch self {
            case .unread: return 0
            case .running: return 1
            case .idle: return 2
            }
        }

        var tooltipText: String {
            switch self {
            case .idle: return "任务：当前无任务"
            case .running: return "任务：正在执行中"
            case .unread: return "任务：已完成，未读"
            }
        }
    }

    private struct CodexThreadSnapshot {
        let id: String
        let updatedAt: TimeInterval
        let rolloutPath: String?
        let threadSource: String
        let agentNickname: String
        let agentRole: String
        let agentPath: String

        var isUserVisible: Bool {
            if threadSource.lowercased() == "subagent" {
                return false
            }
            if !agentNickname.isEmpty || !agentRole.isEmpty || !agentPath.isEmpty {
                return false
            }
            return true
        }
    }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let menu = NSMenu()
    private let fetcher = CodexUsageFetcher()
    private var timer: Timer?
    private var taskLightTimer: Timer?
    private var outsideClickMonitor: Any?
    private var lastSummary: CodexUsageSummary?
    private var lastError: String?
    private var taskLightState: TaskLightState = .idle
    private var trainStyleIndex = 0
    private let trainStartTime = Date.timeIntervalSinceReferenceDate
    private let taskStatusFile = AppDelegate.defaultTaskStatusFile()
    private let codexStateDatabase = AppDelegate.defaultCodexStateDatabase()
    private let codexGlobalStateFile = AppDelegate.defaultCodexGlobalStateFile()
    private let codexActiveWindowSeconds: TimeInterval = 75
    private let codexUnreadWindowSeconds: TimeInterval = 7 * 24 * 60 * 60

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        taskLightState = readTaskLightState()
        updateStatusButton(title: "5h … / 7d …")
        statusItem.button?.toolTip = L10n.shared.t("title")
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover(_:))
        popover.behavior = .transient
        popover.delegate = self
        updatePopoverContent()
        refresh(nil)
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let delegate = self else { return }
            Task { @MainActor in
                delegate.refresh(nil)
            }
        }
        taskLightTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let delegate = self else { return }
            Task { @MainActor in
                delegate.refreshTaskLight()
            }
        }
    }

    @objc private func refresh(_ sender: Any?) {
        if let lastSummary {
            updateStatusButton(summary: lastSummary)
        } else {
            updateStatusButton(title: "5h … / 7d …")
        }
        fetcher.fetch { [weak self] result in
            guard let delegate = self else { return }
            DispatchQueue.main.async { [delegate] in
                switch result {
                case .success(let summary):
                    delegate.lastSummary = summary
                    delegate.lastError = nil
                    delegate.updateStatusButton(summary: summary)
                    delegate.statusItem.button?.toolTip = delegate.tooltip(for: summary)
                case .failure(let error):
                    delegate.lastError = error.description
                    if let summary = delegate.lastSummary {
                        delegate.updateStatusButton(summary: summary)
                    } else {
                        delegate.updateStatusButton(title: "5h ? / 7d ?")
                    }
                    delegate.statusItem.button?.toolTip = L10n.shared.t("fetchFailed") + ": \(error.description)"
                }
                if delegate.popover.isShown == true {
                    delegate.updatePopoverContent()
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
            quitAction: #selector(quit),
            languageAction: #selector(languageChanged(_:)),
            trainStyleIndex: trainStyleIndex,
            trainStartTime: trainStartTime,
            trainClickAction: { [weak self] in
                self?.cycleTrainStyle()
            }
        )
        popover.contentSize = NSSize(width: 410, height: 372)
    }

    private func cycleTrainStyle() {
        trainStyleIndex = (trainStyleIndex + 1) % UsageCardView.styleCount
        updatePopoverContent()
    }

    @objc private func refreshFromPopover(_ sender: Any?) {
        refresh(nil)
    }

    @objc private func openUsagePageFromPopover(_ sender: Any?) {
        openUsagePage()
    }

    @objc private func languageChanged(_ sender: Any?) {
        guard let popup = sender as? NSPopUpButton,
              let code = popup.selectedItem?.representedObject as? String else { return }
        L10n.shared.setSelectedCode(code)
        if let summary = lastSummary {
            updateStatusButton(summary: summary)
            statusItem.button?.toolTip = tooltip(for: summary)
        } else {
            updateStatusButton(title: "5h … / 7d …")
            statusItem.button?.toolTip = L10n.shared.t("title")
        }
        updatePopoverContent()
    }


    private func updateStatusButton(title: String) {
        guard let button = statusItem.button else { return }
        button.image = nil
        button.attributedTitle = statusAttributedTitle(from: title)
    }

    private func updateStatusButton(summary: CodexUsageSummary) {
        guard let button = statusItem.button else { return }
        button.image = nil
        button.attributedTitle = summary.isAPIAccount ? apiStatusAttributedTitle(summary) : statusAttributedTitle(from: summary.title)
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
        appendTaskLight(to: result)
        return result
    }

    private func apiStatusAttributedTitle(_ summary: CodexUsageSummary) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let bodyFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [.font: bodyFont, .foregroundColor: NSColor.labelColor]
        let api = summary.apiUsage
        appendSymbol("money", to: result)
        result.append(NSAttributedString(string: " \(apiAmount(api?.displayRemaining, unit: api?.unit)) / T \(compactNumber(api?.todayTokens ?? api?.totalTokens))", attributes: attrs))
        appendTaskLight(to: result)
        return result
    }

    private static func defaultTaskStatusFile() -> URL {
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        let stateDir: URL
        if let value = environment["CODEX_BALANCE_STATE_DIR"], !value.isEmpty {
            stateDir = URL(fileURLWithPath: (value as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            stateDir = home.appendingPathComponent("Library/Application Support/CodexBalance", isDirectory: true)
        }
        return stateDir.appendingPathComponent("task-status.json")
    }

    private static func defaultCodexHome() -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let value = environment["CODEX_HOME"], !value.isEmpty {
            return URL(fileURLWithPath: (value as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }

    private static func defaultCodexStateDatabase() -> URL {
        defaultCodexHome().appendingPathComponent("state_5.sqlite")
    }

    private static func defaultCodexGlobalStateFile() -> URL {
        defaultCodexHome().appendingPathComponent(".codex-global-state.json")
    }

    fileprivate func readTaskLightState() -> TaskLightState {
        if let manual = readManualTaskLightState(requireOverride: true) {
            return manual
        }
        if let automatic = readAutomaticTaskLightState() {
            return automatic
        }
        return .idle
    }

    private func readManualTaskLightState(requireOverride: Bool) -> TaskLightState? {
        guard let data = try? Data(contentsOf: taskStatusFile) else {
            return nil
        }
        let manualMode = ProcessInfo.processInfo.environment["CODEX_BALANCE_TASK_LIGHT_MODE"] == "manual"
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let state = object["state"] as? String {
            let override = (object["override"] as? Bool) == true
            if requireOverride && !manualMode && !override {
                return nil
            }
            return TaskLightState.from(state)
        }
        if let text = String(data: data, encoding: .utf8) {
            if requireOverride && !manualMode {
                return nil
            }
            return TaskLightState.from(text)
        }
        return nil
    }

    private func readAutomaticTaskLightState() -> TaskLightState? {
        guard let threads = readCodexThreadSnapshots() else {
            return nil
        }
        let now = Date().timeIntervalSince1970
        if threads.contains(where: { isRecentlyActive($0, now: now) }) {
            return .running
        }
        let unreadThreadIDs = readUnreadCodexThreadIDs()
        if !unreadThreadIDs.isEmpty {
            let hasRecentUnread = threads.contains { thread in
                thread.isUserVisible && unreadThreadIDs.contains(thread.id) && isRecent(thread.updatedAt, now: now, window: codexUnreadWindowSeconds)
            }
            if hasRecentUnread {
                return .unread
            }
        }
        return .idle
    }

    private func readCodexThreadSnapshots() -> [CodexThreadSnapshot]? {
        guard FileManager.default.fileExists(atPath: codexStateDatabase.path) else {
            return nil
        }
        let sql = """
        SELECT id, updated_at, IFNULL(rollout_path, ''), IFNULL(thread_source, ''), IFNULL(agent_nickname, ''), IFNULL(agent_role, ''), IFNULL(agent_path, '')
        FROM threads
        WHERE archived = 0
        ORDER BY updated_at DESC
        LIMIT 250;
        """
        guard let rows = runSQLiteRows(sql, database: codexStateDatabase) else {
            return nil
        }
        return rows.compactMap { row in
            let columns = row.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard columns.count >= 2, let updatedAt = TimeInterval(columns[1]) else {
                return nil
            }
            let rolloutPath = columns.count >= 3 && !columns[2].isEmpty ? columns[2] : nil
            return CodexThreadSnapshot(
                id: columns[0],
                updatedAt: updatedAt,
                rolloutPath: rolloutPath,
                threadSource: columns.count >= 4 ? columns[3] : "",
                agentNickname: columns.count >= 5 ? columns[4] : "",
                agentRole: columns.count >= 6 ? columns[5] : "",
                agentPath: columns.count >= 7 ? columns[6] : ""
            )
        }
    }

    private func runSQLiteRows(_ sql: String, database: URL) -> [String]? {
        let sqlitePath = "/usr/bin/sqlite3"
        guard FileManager.default.isExecutableFile(atPath: sqlitePath) else {
            return nil
        }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: sqlitePath)
        process.arguments = ["-readonly", "-separator", "\t", "-noheader", database.path, sql]
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return nil
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    private func isRecentlyActive(_ thread: CodexThreadSnapshot, now: TimeInterval) -> Bool {
        guard let rolloutPath = thread.rolloutPath else {
            return false
        }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: rolloutPath),
              let modifiedAt = attributes[.modificationDate] as? Date,
              isRecent(modifiedAt.timeIntervalSince1970, now: now, window: codexActiveWindowSeconds) else {
            return false
        }
        return rolloutHasOpenTurn(at: rolloutPath)
    }

    private func rolloutHasOpenTurn(at path: String) -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return false
        }
        let tailLimit = 96 * 1024
        let tail: Data
        if data.count > tailLimit {
            tail = data.subdata(in: (data.count - tailLimit)..<data.count)
        } else {
            tail = data
        }
        guard let text = String(data: tail, encoding: .utf8) else {
            return false
        }
        var openTurn = false
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = String(rawLine).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }
            let eventType = object["type"] as? String
            let payload = object["payload"] as? [String: Any]
            let payloadType = payload?["type"] as? String

            if eventType == "turn_context" {
                openTurn = true
                continue
            }

            switch payloadType {
            case "task_complete":
                openTurn = false
            case "message":
                if payload?["role"] as? String == "assistant",
                   payload?["phase"] as? String == "final_answer" {
                    openTurn = false
                }
            case "agent_message":
                if payload?["phase"] as? String == "final_answer" {
                    openTurn = false
                }
            case "function_call", "function_call_output", "tool_search_call", "tool_search_output", "custom_tool_call", "custom_tool_call_output", "reasoning":
                openTurn = true
            default:
                break
            }
        }
        return openTurn
    }

    private func isRecent(_ timestamp: TimeInterval, now: TimeInterval, window: TimeInterval) -> Bool {
        let age = now - timestamp
        return age >= 0 && age <= window
    }

    private func readUnreadCodexThreadIDs() -> Set<String> {
        guard let data = try? Data(contentsOf: codexGlobalStateFile),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let persisted = root["electron-persisted-atom-state"] as? [String: Any],
              let unreadByHost = persisted["unread-thread-ids-by-host-v1"] as? [String: Any] else {
            return []
        }
        var result = Set<String>()
        if let local = unreadByHost["local"] as? [String] {
            result.formUnion(local)
        }
        return result
    }

    private func refreshTaskLight() {
        let nextState = readTaskLightState()
        guard nextState != taskLightState else { return }
        taskLightState = nextState
        if let summary = lastSummary {
            updateStatusButton(summary: summary)
            statusItem.button?.toolTip = tooltip(for: summary)
        } else {
            updateStatusButton(title: "5h … / 7d …")
            statusItem.button?.toolTip = L10n.shared.t("title") + "\n" + taskLightState.tooltipText
        }
    }

    private func appendTaskLight(to result: NSMutableAttributedString) {
        result.append(NSAttributedString(string: " "))
        let attachment = NSTextAttachment()
        attachment.image = taskLightImage()
        attachment.bounds = NSRect(x: 0, y: -3, width: 40, height: 14)
        result.append(NSAttributedString(attachment: attachment))
    }

    private func taskLightImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 40, height: 14))
        image.lockFocus()
        let lights: [(NSColor, Int)] = [
            (NSColor(calibratedRed: 1.00, green: 0.25, blue: 0.22, alpha: 1), 0),
            (NSColor(calibratedRed: 1.00, green: 0.74, blue: 0.22, alpha: 1), 1),
            (NSColor(calibratedRed: 0.23, green: 0.88, blue: 0.38, alpha: 1), 2)
        ]
        NSColor.labelColor.withAlphaComponent(0.10).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0.5, y: 0.5, width: 39, height: 13), xRadius: 6.5, yRadius: 6.5).fill()
        NSColor.labelColor.withAlphaComponent(0.18).setStroke()
        let shell = NSBezierPath(roundedRect: NSRect(x: 0.5, y: 0.5, width: 39, height: 13), xRadius: 6.5, yRadius: 6.5)
        shell.lineWidth = 0.6
        shell.stroke()
        for (color, index) in lights {
            let x = CGFloat(5 + index * 12)
            let isActive = index == taskLightState.activeLightIndex
            color.withAlphaComponent(isActive ? 1.0 : 0.23).setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: 2.75, width: 8.5, height: 8.5)).fill()
            if isActive {
                color.withAlphaComponent(0.30).setStroke()
                let glow = NSBezierPath(ovalIn: NSRect(x: x - 1.4, y: 1.35, width: 11.3, height: 11.3))
                glow.lineWidth = 1.0
                glow.stroke()
            }
        }
        image.unlockFocus()
        return image
    }

    private func apiAmount(_ value: Double?, unit: String?) -> String {
        guard let value else { return "—" }
        if value < 0 { return L10n.shared.t("unlimited") }
        let absValue = abs(value)
        let decimals = absValue >= 100 ? 1 : (absValue >= 1 ? 2 : 4)
        let number = String(format: "%.\(decimals)f", value)
        switch (unit ?? "").uppercased() {
        case "USD", "$":
            return "$" + number
        case "CNY", "RMB", "¥":
            return "¥" + number
        case "":
            return number
        default:
            return number + " " + (unit ?? "")
        }
    }

    private func compactNumber(_ value: Int64?) -> String {
        guard let value else { return "—" }
        let number = Double(value)
        if value >= 1_000_000_000 { return String(format: "%.1fB", number / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.1fM", number / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", number / 1_000) }
        return "\(value)"
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
        } else if name == "money", let symbol = NSImage(systemSymbolName: "dollarsign.circle", accessibilityDescription: nil) {
            symbol.isTemplate = true
            symbol.size = NSSize(width: 13, height: 13)
            image = symbol
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
            result.append(NSAttributedString(string: name == "timer" ? "⏱" : (name == "money" ? "$" : "7")))
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
            let l = L10n.shared
            card.view = UsageCardView(
                summary: summary,
                errorText: lastError == nil ? nil : l.t("readFailed"),
                trainStyleIndex: trainStyleIndex,
                trainStartTime: trainStartTime,
                onTrainClick: { [weak self] in
                    self?.cycleTrainStyle()
                }
            )
            menu.addItem(card)
            menu.addItem(.separator())
            menu.addItem(disabled(l.t("account") + ": \(summary.email)"))
            menu.addItem(disabled(l.t("plan") + ": \(summary.plan)"))
            menu.addItem(disabled(l.t("status") + ": " + (summary.allowed && !summary.limitReached ? l.t("available") : l.t("limitReached"))))
            menu.addItem(.separator())
            menu.addItem(disabled(l.t("fiveHours") + ": \(windowLine(remaining: summary.primaryRemaining, resetAfter: summary.primaryResetAfterSeconds, resetAt: summary.primaryResetAt))"))
            if summary.secondaryUsed != nil {
                menu.addItem(disabled(l.t("weeklyQuota") + ": \(windowLine(remaining: summary.secondaryRemaining, resetAfter: summary.secondaryResetAfterSeconds, resetAt: summary.secondaryResetAt))"))
            }
            if let sp = summary.sparkPrimaryRemaining, let ss = summary.sparkSecondaryRemaining {
                menu.addItem(disabled("Spark: " + l.t("remaining") + " 5h \(sp)% / " + l.t("weeklyQuota") + " \(ss)%"))
            }
            let credits = summary.creditsUnlimited ? l.t("unlimited") : (summary.creditsBalance ?? l.t("unknown"))
            menu.addItem(disabled(l.t("credits") + ": \(credits)"))
            if let count = summary.resetCreditsAvailable {
                menu.addItem(disabled(l.t("resetCredits") + ": \(count)"))
            }
            menu.addItem(disabled(l.t("updated") + ": \(timeString(summary.fetchedAt))"))
        } else {
            menu.addItem(disabled(L10n.shared.t("loading")))
        }
        if let lastError = lastError {
            menu.addItem(.separator())
            menu.addItem(disabled(L10n.shared.t("error") + ": \(lastError)"))
        }
        menu.addItem(.separator())
        let refreshItem = NSMenuItem(title: L10n.shared.t("refreshNow"), action: #selector(refresh(_:)), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)
        let openItem = NSMenuItem(title: L10n.shared.t("openUsagePage"), action: #selector(openUsagePage), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: L10n.shared.t("quit"), action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func windowLine(remaining: Int?, resetAfter: Int?, resetAt: TimeInterval?) -> String {
        let l = L10n.shared
        let remainText = remaining.map { "\($0)%" } ?? l.t("unknown")
        let resetText = resetAfter.map { " · " + l.t("reset") + " \(resetPoint(resetAt).map { "\($0) · " } ?? "")\(duration($0))" } ?? ""
        return "\(remainText)\(resetText)"
    }

    private func duration(_ seconds: Int) -> String {
        L10n.shared.duration(seconds)
    }

    private func resetPoint(_ timestamp: TimeInterval?) -> String? {
        L10n.shared.resetPoint(timestamp)
    }

    private func timeString(_ date: Date) -> String {
        L10n.shared.timeString(date)
    }

    private func tooltip(for summary: CodexUsageSummary) -> String {
        let l = L10n.shared
        if summary.isAPIAccount {
            var lines = [l.t("title"), l.t("apiRelayAccount")]
            if let alias = summary.alias { lines.append(alias) }
            if let baseURL = summary.baseURL { lines.append(baseURL) }
            if let usage = summary.apiUsage, usage.error == nil {
                lines.append(l.t("balance") + ": \(apiAmount(usage.displayRemaining, unit: usage.unit))")
                lines.append(l.t("todayCost") + ": \(apiAmount(usage.displayTodayCost, unit: usage.unit))")
                lines.append(l.t("todayTokens") + ": \(compactNumber(usage.todayTokens))")
            }
            lines.append(taskLightState.tooltipText)
            return lines.joined(separator: "\n")
        }
        var lines = [l.t("title"), summary.email]
        if let p = summary.primaryRemaining { lines.append(l.t("primaryRemaining") + ": \(p)%") }
        if let s = summary.secondaryRemaining { lines.append(l.t("secondaryRemaining") + ": \(s)%") }
        lines.append(taskLightState.tooltipText)
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

if CommandLine.arguments.contains("--task-light-once") {
    let delegate = AppDelegate()
    let state = delegate.readTaskLightState()
    printJSON(["ok": true, "state": state.rawValue])
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
