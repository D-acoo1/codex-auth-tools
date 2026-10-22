import Foundation
import SQLite3
import Darwin

// Only metadata is decoded. Conversation text, tool arguments and tool results
// never become retained objects, and nothing collected here is sent or saved.
struct ActivityRecord: Decodable {
    let type: String
    let timestamp: String?
    let payload: Payload?

    struct Usage: Decodable {
        let input_tokens: Int?
        let output_tokens: Int?
    }
    struct Info: Decodable {
        let last_token_usage: Usage?
        let total_token_usage: Usage?
    }
    struct Item: Decodable {
        let type: String?
    }
    struct Payload: Decodable {
        let type: String?
        let model: String?
        let turn_id: String?
        let response_id: String?
        let role: String?
        let phase: String?
        let call_id: String?
        let started_at_ms: Double?
        let completed_at_ms: Double?
        let usage: Usage?
        let thread_token_usage: Usage?
        let info: Info?
        let item: Item?
    }

    var date: TimeInterval? {
        guard let timestamp else { return nil }
        return ActivityClock.parse(timestamp)
    }
}

private enum ActivityClock {
    static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    static let seconds = Date.ISO8601FormatStyle()
    static func parse(_ text: String) -> TimeInterval? {
        ((try? fractional.parse(text)) ?? (try? seconds.parse(text)))?.timeIntervalSince1970
    }
}

struct ModelActivityRow: Equatable, Sendable {
    let model: String
    let tasks: Int
    let generating: Int
    let inputTokens: Int?
    let inputTasks: Int
    let outputTPS: Double?
    let measuredTasks: Int
    var quietTasks: Int = 0
    var responseSamples: Int = 0
}

struct ModelActivitySnapshot: Equatable, Sendable {
    enum Availability: String, Sendable { case starting, ready, unavailable }
    var availability: Availability = .starting
    var rows: [ModelActivityRow] = []
    var hasUnread = false
    var overallTPS: Double?
    var hasRunning: Bool { rows.contains { $0.tasks > $0.quietTasks } }
}

/// Response-sampled throughput, not a synthetic per-second token counter.
/// Codex's output count already includes reasoning; input already includes cache.
/// Model item intervals are unioned so overlapping reasoning/message carriers do
/// not double the denominator. Tool execution intervals are not model intervals.
struct ModelActivitySession {
    static let averageSeconds: TimeInterval = 60
    static let maximumSamples = 128
    struct Sample {
        let at: TimeInterval
        let model: String
        let input: Int?
        let output: Int
        let duration: TimeInterval?
        var tps: Double? { duration.map { Double(output) / $0 } }
    }
    var model: String
    var isOpen = false
    var isWaiting = false
    var sample: Sample?
    private(set) var recentSamples: [Sample] = []
    private var turnID: String?
    private var intervals: [(Double, Double)] = []
    private var lastUsageKey: String?
    private var responseIDs: [String] = []
    private var hasAccountingBoundary = false
    private var pendingCalls = Set<String>()
    private var timingComplete = true

    init(model: String) { self.model = model }

    mutating func pruneSamples(now: TimeInterval) {
        recentSamples.removeAll { now - $0.at > Self.averageSeconds }
    }

    mutating func invalidateTiming() {
        intervals.removeAll(keepingCapacity: true)
        timingComplete = false
    }

    mutating func consume(_ record: ActivityRecord) {
        guard let p = record.payload else {
            if record.type == "turn_context" { isOpen = true }
            return
        }
        let at = record.type == "token_usage_record" || p.type == "token_count" || p.type == "item_completed"
            ? record.date : nil
        if let id = p.turn_id, id != turnID {
            turnID = id
            intervals.removeAll(keepingCapacity: true)
            sample = nil
            lastUsageKey = nil
            responseIDs.removeAll(keepingCapacity: true)
            pendingCalls.removeAll(keepingCapacity: true)
            hasAccountingBoundary = false
            timingComplete = true
        }
        if let nextModel = p.model, !nextModel.isEmpty, nextModel != model {
            model = nextModel
            sample = nil
            invalidateTiming()
        }
        if record.type == "turn_context" || (record.type == "event_msg" && p.type == "task_started") {
            isOpen = true
            isWaiting = false
            // A complete turn start establishes the first request boundary.
            hasAccountingBoundary = true
        }
        if record.type == "event_msg" {
            switch p.type {
            case "task_complete", "turn_aborted", "task_failed":
                isOpen = false
                isWaiting = false
                pendingCalls.removeAll(keepingCapacity: true)
            case "item_completed":
                if ["Reasoning", "AgentMessage", "Plan"].contains(p.item?.type ?? "") {
                    isOpen = true
                    isWaiting = false
                    if let start = p.started_at_ms, let end = p.completed_at_ms,
                       start > 0, end > start, let at, end / 1000 <= at + 5 {
                        if intervals.count < 128 { intervals.append((start / 1000, end / 1000)) }
                        else { invalidateTiming() }
                    }
                } else if p.item?.type == "ContextCompaction" {
                    invalidateTiming()
                }
            default: break
            }
        }
        if record.type == "response_item" {
            switch p.type {
            case "function_call", "custom_tool_call", "tool_search_call":
                isOpen = true
                isWaiting = true
                if let id = p.call_id { pendingCalls.insert(id) }
            case "function_call_output", "custom_tool_call_output", "tool_search_output":
                isOpen = true
                if let id = p.call_id { pendingCalls.remove(id) }
                isWaiting = !pendingCalls.isEmpty
            case "reasoning":
                isOpen = true
                isWaiting = false
            default: break
            }
        }
        if p.type == "agent_message" || (record.type == "response_item" && p.type == "message") {
            if p.phase == "final_answer", p.role == nil || p.role == "assistant" { isOpen = false }
        }

        let usage: ActivityRecord.Usage?
        let total: ActivityRecord.Usage?
        if record.type == "token_usage_record" {
            usage = p.usage; total = p.thread_token_usage
        } else if record.type == "event_msg", p.type == "token_count" {
            usage = p.info?.last_token_usage; total = p.info?.total_token_usage
        } else { return }
        guard let usage, let output = usage.output_tokens, output >= 0, let at else { return }
        // Authoritative and legacy carriers often describe the same response.
        let key = "\(total?.output_tokens ?? -1):\(total?.input_tokens ?? -1):\(output):\(usage.input_tokens ?? -1)"
        if let id = p.response_id, responseIDs.contains(id) { return }
        if key == lastUsageKey, total != nil || intervals.isEmpty { return }
        lastUsageKey = key
        if let id = p.response_id {
            responseIDs.append(id)
            if responseIDs.count > 16 { responseIDs.removeFirst() }
        }
        let duration = Self.unionDuration(intervals)
        let measurement = Sample(at: at, model: model,
            input: usage.input_tokens.flatMap { $0 >= 0 ? $0 : nil }, output: output,
            duration: hasAccountingBoundary && timingComplete && duration > 0 ? duration : nil)
        sample = measurement
        pruneSamples(now: at)
        if measurement.duration != nil {
            recentSamples.append(measurement)
            if recentSamples.count > Self.maximumSamples { recentSamples.removeFirst() }
        }
        intervals.removeAll(keepingCapacity: true)
        hasAccountingBoundary = true
        timingComplete = true
    }

    static func unionDuration(_ ranges: [(Double, Double)]) -> Double {
        let sorted = ranges.sorted { $0.0 < $1.0 }
        guard var current = sorted.first else { return 0 }
        var result = 0.0
        for range in sorted.dropFirst() {
            if range.0 <= current.1 { current.1 = max(current.1, range.1) }
            else { result += current.1 - current.0; current = range }
        }
        return result + current.1 - current.0
    }
}

struct ActivityThread {
    let id: String
    let updatedAt: TimeInterval
    let path: String
    let model: String
    let userVisible: Bool
}

/// A read-only SQLite connection, never a sqlite3 child process. Reopening per
/// discovery also handles Codex replacing the database during an upgrade.
enum ActivityDatabase {
    static func threads(at url: URL) -> [ActivityThread]? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }; return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 30)
        var schema: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(threads)", -1, &schema, nil) == SQLITE_OK else { return nil }
        var columns = Set<String>()
        while sqlite3_step(schema) == SQLITE_ROW {
            if let name = sqlite3_column_text(schema, 1) { columns.insert(String(cString: name)) }
        }
        sqlite3_finalize(schema)
        guard columns.contains("id"), columns.contains("updated_at"), columns.contains("rollout_path") else { return nil }
        func column(_ name: String) -> String { columns.contains(name) ? "IFNULL(\(name), '')" : "''" }
        let sql = """
        SELECT id, updated_at, \(column("rollout_path")), \(column("model")),
            \(column("thread_source")), \(column("agent_nickname")), \(column("agent_role")), \(column("agent_path"))
        FROM threads \(columns.contains("archived") ? "WHERE archived = 0" : "")
        ORDER BY updated_at DESC LIMIT 250
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        func text(_ index: Int32) -> String {
            sqlite3_column_text(statement, index).map { String(cString: $0) } ?? ""
        }
        var rows: [ActivityThread] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            rows.append(ActivityThread(id: text(0), updatedAt: sqlite3_column_double(statement, 1),
                path: text(2), model: text(3), userVisible: text(4).lowercased() != "subagent"
                    && text(5).isEmpty && text(6).isEmpty && text(7).isEmpty))
            status = sqlite3_step(statement)
        }
        return status == SQLITE_DONE ? rows : nil
    }
}

/// Bounded append reader. Attach once to a 256 KiB tail; thereafter read only
/// new bytes. Oversized content lines are skipped without accumulating text.
final class ActivityRollout {
    static let tailBytes = 256 * 1024
    static let maximumLineBytes = 256 * 1024
    let fd: Int32
    let inode: UInt64
    private(set) var offset: Int64
    private(set) var modifiedAt: TimeInterval
    private(set) var bytesRead = 0
    var session: ModelActivitySession
    var source: DispatchSourceFileSystemObject?
    private var pending = Data()
    private var skippingLine = false
    private let decoder = JSONDecoder()

    init?(path: String, model: String) {
        fd = Darwin.open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { Darwin.close(fd); return nil }
        inode = UInt64(info.st_ino)
        offset = max(0, info.st_size - Int64(Self.tailBytes))
        skippingLine = offset > 0
        modifiedAt = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
        session = ModelActivitySession(model: model)
    }

    deinit {
        if let source { source.cancel() } else { Darwin.close(fd) }
    }

    /// Returns true if a bounded batch left more bytes to read.
    @discardableResult func drain() -> Bool {
        var info = stat()
        guard fstat(fd, &info) == 0 else { return false }
        modifiedAt = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
        if info.st_size < offset {
            offset = 0; pending.removeAll(keepingCapacity: true); skippingLine = false
            session = ModelActivitySession(model: session.model)
        }
        let target = min(info.st_size, offset + Int64(Self.tailBytes))
        guard target > offset else { return false }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while offset < target {
            let count = pread(fd, &buffer, min(buffer.count, Int(target - offset)), off_t(offset))
            guard count > 0 else { break }
            offset += Int64(count); bytesRead += count
            ingest(Data(buffer.prefix(count)))
        }
        return offset < info.st_size
    }

    func ingest(_ bytes: Data) {
        var start = bytes.startIndex
        while start < bytes.endIndex {
            let end = bytes[start...].firstIndex(of: 10) ?? bytes.endIndex
            if !skippingLine {
                if pending.count + end - start <= Self.maximumLineBytes { pending.append(bytes[start..<end]) }
                else {
                    pending = Data(); skippingLine = true
                    session.invalidateTiming()
                }
            }
            if end == bytes.endIndex { break }
            if !skippingLine, !pending.isEmpty {
                if let record = try? decoder.decode(ActivityRecord.self, from: pending) { session.consume(record) }
                else { session.invalidateTiming() }
            }
            if pending.count > 16 * 1024 { pending = Data() }
            else { pending.removeAll(keepingCapacity: true) }
            skippingLine = false
            start = end + 1
        }
    }
}

/// One serial, low-priority collector shared by the task lights and model panel.
/// No recursive directory scans, network requests, hooks, or extra processes.
final class ModelActivityMonitor: @unchecked Sendable {
    static let activeSeconds: TimeInterval = 75
    static let sampleSeconds = ModelActivitySession.averageSeconds
    let home: URL
    private let queue = DispatchQueue(label: "CodexBalance.model-activity", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var files: [String: ActivityRollout] = [:]
    private var threads: [ActivityThread] = []
    private var unread = Set<String>()
    private var globalStamp: Date?
    private var available = false
    private var stopped = true
    private var flushScheduled = false
    private var lastSnapshot: ModelActivitySnapshot?
    private let onUpdate: @MainActor @Sendable (ModelActivitySnapshot) -> Void

    init(home: URL, onUpdate: @escaping @MainActor @Sendable (ModelActivitySnapshot) -> Void) {
        self.home = home; self.onUpdate = onUpdate
    }

    func start() {
        queue.async { [self] in
            guard stopped else { return }
            stopped = false
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: 2, leeway: .milliseconds(200))
            timer.setEventHandler { [weak self] in self?.discover() }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.async { [self] in
            stopped = true; timer?.cancel(); timer = nil; files.removeAll()
        }
    }

    // Also used by the read-only diagnostic entry point and isolated tests.
    func collectOnce(now: TimeInterval = Date().timeIntervalSince1970) -> ModelActivitySnapshot {
        discover(now: now, watch: false)
        return snapshot(now: now)
    }

    private func discover(now: TimeInterval = Date().timeIntervalSince1970, watch: Bool = true) {
        let dbRows = ActivityDatabase.threads(at: home.appendingPathComponent("state_5.sqlite"))
        available = dbRows != nil
        if let dbRows { threads = dbRows }
        readUnread()
        let candidates = threads.filter { !$0.path.isEmpty }
        let paths = Set(candidates.map(\.path))
        for path in Array(files.keys) where !paths.contains(path) { files.removeValue(forKey: path) }
        for thread in candidates {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: thread.path),
                  let modified = attributes[.modificationDate] as? Date,
                  let inode = attributes[.systemFileNumber] as? NSNumber else { files.removeValue(forKey: thread.path); continue }
            if files[thread.path]?.inode != inode.uint64Value { files.removeValue(forKey: thread.path) }
            guard now - modified.timeIntervalSince1970 <= Self.activeSeconds,
                  modified.timeIntervalSince1970 <= now + 5 else {
                // Keep an already observed open turn subscribed. Silence is not
                // completion: a long inference/tool wait becomes "quiet", not
                // falsely idle or live. Discovery is still bounded to 250 rows.
                if files[thread.path]?.session.isOpen != true { files.removeValue(forKey: thread.path) }
                continue
            }
            if files[thread.path] == nil, let file = ActivityRollout(path: thread.path, model: thread.model) {
                files[thread.path] = file
                if watch {
                    let fd = file.fd
                    let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: queue)
                    source.setEventHandler { [weak self] in self?.scheduleFlush() }
                    source.setCancelHandler { Darwin.close(fd) }
                    file.source = source
                    source.resume()
                }
            }
        }
        drain()
        if watch { publish(now: now) }
    }

    private func scheduleFlush() {
        guard !stopped, !flushScheduled else { return }
        flushScheduled = true
        queue.asyncAfter(deadline: .now() + .milliseconds(150)) { [weak self] in
            guard let self else { return }
            self.flushScheduled = false
            guard !self.stopped else { return }
            self.drain()
            self.publish(now: Date().timeIntervalSince1970)
        }
    }

    private func drain() {
        var more = false
        for file in files.values { if file.drain() { more = true } }
        if more { scheduleFlush() }
    }

    private struct GlobalState: Decodable {
        struct Persisted: Decodable {
            let unread: [String: [String]]?
            enum CodingKeys: String, CodingKey { case unread = "unread-thread-ids-by-host-v1" }
        }
        let persisted: Persisted?
        enum CodingKeys: String, CodingKey { case persisted = "electron-persisted-atom-state" }
    }

    private func readUnread() {
        let path = home.appendingPathComponent(".codex-global-state.json")
        let stamp = (try? FileManager.default.attributesOfItem(atPath: path.path)[.modificationDate]) as? Date
        guard stamp != globalStamp else { return }
        globalStamp = stamp
        guard let data = try? Data(contentsOf: path), let state = try? JSONDecoder().decode(GlobalState.self, from: data) else {
            unread.removeAll(); return
        }
        unread = Set(state.persisted?.unread?.values.flatMap { $0 } ?? [])
    }

    private func snapshot(now: TimeInterval) -> ModelActivitySnapshot {
        for file in files.values { file.session.pruneSamples(now: now) }
        let active = files.values.filter { $0.session.isOpen }
        let grouped = Dictionary(grouping: active) { $0.session.model }
        let recent = Dictionary(grouping: files.flatMap { path, file in
            file.session.recentSamples.filter { now >= $0.at }.map { (path, $0) }
        }) { $0.1.model }
        var totalOutput = 0.0, totalDuration = 0.0
        let rows = Set(grouped.keys).union(recent.keys).map { model in
            let members = grouped[model] ?? []
            let samples = members.compactMap(\.session.sample).filter { now >= $0.at && now - $0.at <= Self.sampleSeconds }
            let inputs = samples.compactMap(\.input)
            let responses = recent[model] ?? []
            let duration = responses.reduce(0.0) { $0 + ($1.1.duration ?? 0) }
            let output = responses.reduce(0.0) { $0 + Double($1.1.output) }
            totalOutput += output
            totalDuration += duration
            return ModelActivityRow(model: model.isEmpty ? "Codex" : model, tasks: members.count,
                generating: members.filter { !$0.session.isWaiting && now - $0.modifiedAt <= Self.activeSeconds }.count,
                inputTokens: inputs.isEmpty ? nil : inputs.reduce(0, +),
                inputTasks: inputs.count,
                outputTPS: duration > 0 ? output / duration : nil,
                measuredTasks: Set(responses.map { $0.0 }).count,
                quietTasks: members.filter { now - $0.modifiedAt > Self.activeSeconds }.count,
                responseSamples: responses.count)
        }.sorted { $0.model.localizedStandardCompare($1.model) == .orderedAscending }
        let hasUnread = (!available && threads.isEmpty && !unread.isEmpty)
            || threads.contains { $0.userVisible && unread.contains($0.id) && now >= $0.updatedAt && now - $0.updatedAt <= 86_400 }
        return ModelActivitySnapshot(availability: available ? .ready : .unavailable, rows: rows, hasUnread: hasUnread,
            overallTPS: totalDuration > 0 ? totalOutput / totalDuration : nil)
    }

    private func publish(now: TimeInterval) {
        let next = snapshot(now: now)
        guard next != lastSnapshot else { return }
        lastSnapshot = next
        let callback = onUpdate
        DispatchQueue.main.async { callback(next) }
    }
}
