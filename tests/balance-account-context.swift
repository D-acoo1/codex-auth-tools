import Foundation

private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    func append(_ request: URLRequest) {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
    }

    func take() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        let result = requests
        requests.removeAll()
        return result
    }
}

private final class AccountUsageProtocol: URLProtocol, @unchecked Sendable {
    static let recorder = RequestRecorder()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.recorder.append(request)
        guard request.url?.host == "chatgpt.com" else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let account = request.value(forHTTPHeaderField: "ChatGPT-Account-Id")
        let expectedToken = account == "acct-other" ? "Bearer fake-other-token" : "Bearer fake-access-token"
        guard request.value(forHTTPHeaderField: "Authorization") == expectedToken else {
            client?.urlProtocol(self, didFailWithError: URLError(.userAuthenticationRequired))
            return
        }
        let body: [String: Any]
        switch request.url?.path {
        case "/backend-api/wham/usage":
            let used = account == "acct-demo" ? 65 : account == "acct-other" ? 24 : 100
            body = [
                "email": "demo@example.com",
                "plan_type": "pro",
                "rate_limit": [
                    "allowed": used < 100,
                    "limit_reached": used == 100,
                    "primary_window": [
                        "used_percent": used,
                        "limit_window_seconds": 604800,
                        "reset_at": 2_000_000_000,
                    ],
                    "secondary_window": NSNull(),
                ],
                "rate_limit_reset_credits": ["available_count": account == "acct-other" ? 0 : 2],
            ]
        case "/backend-api/wham/rate-limit-reset-credits":
            guard account == "acct-demo" else {
                client?.urlProtocol(self, didFailWithError: URLError(.userAuthenticationRequired))
                return
            }
            body = [
                "available_count": 2,
                "credits": [
                    ["status": "available", "expires_at": "2030-09-28T21:09:00Z"],
                    ["status": "available", "expires_at": "2030-10-01T18:00:00Z"],
                ],
            ]
        default:
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: body)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

func testQuotaAndResetCreditsFollowCurrentAccount() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("balance-account-context-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let environment = [
        "CODEX_HOME": directory.appendingPathComponent("codex").path,
        "CODEX_AC_HOME": directory.appendingPathComponent("accounts").path,
        "CODEX_BALANCE_STATE_DIR": directory.appendingPathComponent("state").path,
    ]
    var saved: [String: String] = [:]
    for (key, value) in environment {
        saved[key] = getenv(key).map { String(cString: $0) }
        setenv(key, value, 1)
        try FileManager.default.createDirectory(atPath: value, withIntermediateDirectories: true)
    }
    try require(URLProtocol.registerClass(AccountUsageProtocol.self), "mock protocol registration")
    _ = AccountUsageProtocol.recorder.take()
    defer {
        URLProtocol.unregisterClass(AccountUsageProtocol.self)
        for key in environment.keys {
            if let value = saved[key] { setenv(key, value, 1) }
            else { unsetenv(key) }
        }
        try? FileManager.default.removeItem(at: directory)
    }
    let authURL = directory.appendingPathComponent("codex/auth.json")
    func writeAuth(account: String, token: String) throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "auth_mode": "chatgpt",
            "tokens": ["account_id": account, "access_token": token],
        ])
        try data.write(to: authURL, options: .atomic)
    }
    try writeAuth(account: "acct-demo", token: "fake-access-token")
    let fetcher = CodexUsageFetcher()
    let first = try fetcher.fetchSync(timeout: 5).get()
    try require(first.secondaryRemaining == 35, "account quota: expected 35%, got \(String(describing: first.secondaryRemaining))")
    try require(first.primaryUnlimited, "weekly-only quota stays weekly")
    try require(first.allowed && !first.limitReached, "account remains available")
    try require(first.resetCredits.count == 2, "reset-credit details")
    let firstRequests = AccountUsageProtocol.recorder.take()
    try require(firstRequests.count == 2, "usage and reset-credit requests")
    try require(Set(firstRequests.compactMap { $0.url?.path }) == [
        "/backend-api/wham/usage", "/backend-api/wham/rate-limit-reset-credits",
    ], "request destinations")
    try require(firstRequests.allSatisfy {
        $0.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "acct-demo"
    }, "both requests use current account")

    // Reuse the fetcher after replacing auth.json, as the running app does after ca s.
    try writeAuth(account: "acct-other", token: "fake-other-token")
    let second = try fetcher.fetchSync(timeout: 5).get()
    try require(second.secondaryRemaining == 76, "switched account quota")
    try require(second.primaryUnlimited, "switched weekly-only quota")
    try require(second.resetCreditsAvailable == 0, "switched reset-credit count")
    let secondRequests = AccountUsageProtocol.recorder.take()
    try require(secondRequests.count == 1, "no reset-credit fetch for zero credits")
    try require(secondRequests.first?.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "acct-other", "account header updates after switch")
    try require(secondRequests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer fake-other-token", "token updates after switch")
}

enum AccountContextTestError: Error { case assertion(String) }

func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw AccountContextTestError.assertion(message) }
}

do {
    try testQuotaAndResetCreditsFollowCurrentAccount()
    print("balance account-context regression passed")
} catch {
    fputs("balance account-context regression failed: \(error)\n", stderr)
    exit(1)
}
