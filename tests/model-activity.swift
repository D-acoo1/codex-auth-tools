import Foundation
import SQLite3

// Synthetic metadata only: no real conversation, path, account or credential.
var assertions = 0
@MainActor func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    assertions += 1
    if !condition() { fatalError("FAIL: \(message)") }
}
let epoch = Date().timeIntervalSince1970.rounded(.down) - 10
let formatter = ISO8601DateFormatter()
formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
@MainActor func line(_ type: String, _ payload: [String: Any] = [:], at: Double = 8) -> Data {
    var data = try! JSONSerialization.data(withJSONObject: ["type": type,
        "timestamp": formatter.string(from: Date(timeIntervalSince1970: epoch + at)), "payload": payload])
    data.append(10); return data
}
@MainActor func record(_ type: String, _ payload: [String: Any] = [:], at: Double = 8) -> ActivityRecord {
    try! JSONDecoder().decode(ActivityRecord.self, from: line(type, payload, at: at))
}
@MainActor func start(_ turn: String = "turn-a", model: String = "model-a") -> ActivityRecord {
    record("turn_context", ["turn_id": turn, "model": model])
}
@MainActor func item(_ type: String = "Reasoning", from: Double, to: Double) -> ActivityRecord {
    record("event_msg", ["type": "item_completed", "item": ["type": type],
        "started_at_ms": (epoch + from) * 1000, "completed_at_ms": (epoch + to) * 1000])
}
@MainActor func usage(total: Int = 1400, output: Int = 1400, response: String = "response-a", legacy: Bool = false, at: Double = 8) -> ActivityRecord {
    let last = ["input_tokens": 24000, "cached_input_tokens": 22000, "output_tokens": output, "reasoning_output_tokens": 1200]
    let all = ["output_tokens": total, "input_tokens": total + 50000]
    return legacy
        ? record("event_msg", ["type": "token_count", "info": ["last_token_usage": last, "total_token_usage": all]], at: at)
        : record("token_usage_record", ["response_id": response, "usage": last, "thread_token_usage": all], at: at)
}
@MainActor func measuredSession() -> ModelActivitySession {
    var s = ModelActivitySession(model: "model-a")
    s.consume(start()); s.consume(item(from: 0, to: 4))
    s.consume(item("AgentMessage", from: 5, to: 8)); s.consume(usage())
    return s
}

var session = measuredSession()
expect(abs(session.sample!.tps! - 200) < 0.001, "model windows, not tool/wall time; reasoning counted once")
expect(session.sample?.input == 24000, "cache is a subset, not extra input")
expect(ModelActivitySession.unionDuration([(1, 5), (3, 7), (9, 10)]) == 7, "union overlapping intervals")
session.consume(usage(legacy: true))
expect(session.sample?.tps == 200, "dual carrier does not clear or duplicate the sample")
expect(session.recentSamples.count == 1, "dual carriers contribute only once to the average")
session.consume(item(from: 4, to: 6))
session.consume(usage(legacy: true))
session.consume(usage(total: 1600, output: 200, response: "response-b"))
expect(session.sample?.tps == 100, "late duplicate preserves the next response's timing")
session.consume(record("response_item", ["type": "custom_tool_call", "call_id": "call-a"]))
session.consume(record("response_item", ["type": "custom_tool_call", "call_id": "call-b"]))
expect(session.isWaiting, "parallel tool wait")
session.consume(record("response_item", ["type": "custom_tool_call_output", "call_id": "call-a"]))
expect(session.isWaiting, "one of two tools still pending")
session.consume(record("response_item", ["type": "custom_tool_call_output", "call_id": "call-b"]))
expect(!session.isWaiting, "tools complete")
session.consume(record("event_msg", ["type": "task_complete"]))
expect(!session.isOpen, "completed tasks are not live throughput")
session.consume(start("turn-b"))
expect(session.sample == nil, "new turn clears previous speed")
expect(session.recentSamples.count == 2, "a new turn preserves recent measurements for the average")
session.consume(item(from: 0, to: 4)); session.consume(usage())
expect(session.sample?.tps == 350, "new turn can reuse per-turn counters")
session.consume(start("turn-c", model: "model-b"))
expect(session.model == "model-b" && session.sample == nil, "model switch clears old sample")
expect(session.recentSamples.allSatisfy { $0.model == "model-a" }, "recent history stays attributed to its measured model")
for terminal in ["turn_aborted", "task_failed"] {
    session.consume(start())
    session.consume(record("event_msg", ["type": terminal]))
    expect(!session.isOpen, "interrupted/failed tasks close")
}
session.consume(start())
session.consume(record("response_item", ["type": "message", "role": "assistant", "phase": "final_answer"]))
expect(!session.isOpen, "assistant final answer closes a task")
let integerDate = try! JSONDecoder().decode(ActivityRecord.self,
    from: Data("{\"type\":\"event_msg\",\"timestamp\":\"2026-10-22T14:50:09Z\"}".utf8))
expect(integerDate.date == 1792680609, "ISO timestamp without fractional seconds")

var attached = ModelActivitySession(model: "model-a")
attached.consume(item(from: 0, to: 4)); attached.consume(usage())
expect(attached.sample?.tps == nil, "tail attach cannot assume a complete first response")
attached.consume(item(from: 0, to: 4)); attached.consume(usage(total: 2800, response: "response-b"))
expect(attached.sample?.tps == 350, "later complete response can be measured")
attached.invalidateTiming(); attached.consume(item(from: 0, to: 4)); attached.consume(usage(total: 4200, response: "response-c"))
expect(attached.sample?.tps == nil, "truncated/oversized record invalidates only its measurement")
attached.consume(usage(total: 5600, response: "response-d"))
expect(attached.sample?.tps == nil, "no timings means unavailable, not zero or fabricated TPS")
attached.consume(item(from: 2, to: 2)); attached.consume(usage(total: 7000, response: "response-e"))
expect(attached.sample?.tps == nil, "zero duration is not infinite TPS")
expect(attached.recentSamples.count == 1, "incomplete or invalid timings do not dilute the valid average")
var bounded = ModelActivitySession(model: "model-a")
bounded.consume(start())
for index in 0..<150 {
    bounded.consume(item(from: 0, to: 1))
    bounded.consume(usage(total: 1000 + index, output: 100 + index, response: "bounded-\(index)"))
}
expect(bounded.recentSamples.count == ModelActivitySession.maximumSamples, "high-frequency response history is bounded")
bounded.pruneSamples(now: epoch + 69)
expect(bounded.recentSamples.isEmpty, "expired history releases memory")

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
let rollout = root.appendingPathComponent("append.jsonl")
try! line("turn_context", ["model": "model-a"]).write(to: rollout)
var reader = ActivityRollout(path: rollout.path, model: "model-a")!
reader.drain()
let baseline = reader.bytesRead
reader.drain()
expect(reader.bytesRead == baseline, "unchanged files cost zero additional read bytes")
let pending = line("event_msg", ["type": "task_complete"])
let handle = try! FileHandle(forWritingTo: rollout)
try! handle.seekToEnd(); try! handle.write(contentsOf: pending.dropLast())
reader.drain()
expect(reader.session.isOpen, "partial JSONL is held until newline")
try! handle.write(contentsOf: Data([10])); reader.drain()
expect(!reader.session.isOpen, "append completes a split record")
try! handle.truncate(atOffset: 0); try! handle.seek(toOffset: 0)
try! handle.write(contentsOf: line("turn_context")); reader.drain()
expect(reader.session.isOpen && reader.offset < Int64(baseline + pending.count), "truncation resets the reader")
try! handle.close()
let oversized = Data(repeating: 65, count: ActivityRollout.maximumLineBytes + 64 * 1024) + Data([10])
reader.ingest(oversized)
reader.ingest(line("event_msg", ["type": "task_complete"]))
expect(!reader.session.isOpen, "oversized content does not prevent later lifecycle events")
reader.ingest(line("turn_context", ["model": "模型-🧪"]))
let unicode = line("turn_context", ["model": "模型-🚀"])
for byte in unicode { reader.ingest(Data([byte])) }
expect(reader.session.model == "模型-🚀", "split UTF-8 is decoded only at record boundaries")

let home = root.appendingPathComponent("home", isDirectory: true)
try! FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
let monitor = ModelActivityMonitor(home: home, onUpdate: { _ in })
expect(monitor.collectOnce().availability == .unavailable, "missing database is distinct from idle")
let dbURL = home.appendingPathComponent("state_5.sqlite")
var db: OpaquePointer?
expect(sqlite3_open(dbURL.path, &db) == SQLITE_OK, "create fixture database")
@MainActor func sql(_ value: String) { expect(sqlite3_exec(db, value, nil, nil, nil) == SQLITE_OK, "SQL fixture") }
sql("CREATE TABLE threads (id TEXT, updated_at INTEGER, rollout_path TEXT, archived INTEGER, model TEXT, thread_source TEXT, agent_role TEXT)")
var synthetic = line("turn_context", ["model": "model-a", "turn_id": "fixture-turn"])
synthetic += line("event_msg", ["type": "item_completed", "item": ["type": "Reasoning"], "started_at_ms": epoch * 1000, "completed_at_ms": (epoch + 4) * 1000])
synthetic += line("token_usage_record", ["response_id": "r", "usage": ["input_tokens": 24000, "output_tokens": 400], "thread_token_usage": ["input_tokens": 24000, "output_tokens": 400]])
let first = home.appendingPathComponent("first.jsonl")
try! synthetic.write(to: first)
let second = home.appendingPathComponent("second.jsonl")
try! line("turn_context", ["model": "model-a"]).write(to: second)
let third = home.appendingPathComponent("third.jsonl")
try! synthetic.write(to: third)
sql("INSERT INTO threads VALUES ('a', \(Int(epoch + 10)), '\(first.path)', 0, 'model-a', 'user', '')")
sql("INSERT INTO threads VALUES ('b', \(Int(epoch + 10)), '\(second.path)', 0, 'model-a', 'subagent', 'worker')")
sql("INSERT INTO threads VALUES ('c', \(Int(epoch + 10)), '\(third.path)', 0, 'model-a', 'user', '')")
sql("INSERT INTO threads VALUES ('archived', \(Int(epoch + 10)), '', 1, 'model-a', 'user', '')")
let other = home.appendingPathComponent("other-model.jsonl")
try! line("turn_context", ["model": "model-b"]).write(to: other)
sql("INSERT INTO threads VALUES ('other', \(Int(epoch + 10)), '\(other.path)', 0, 'model-b', 'user', '')")
let stateURL = home.appendingPathComponent(".codex-global-state.json")
func unread(_ ids: [String]) {
    try! JSONSerialization.data(withJSONObject: ["electron-persisted-atom-state": ["unread-thread-ids-by-host-v1": ["local": ids]]]).write(to: stateURL)
}
unread(["a", "b", "archived"])
let now = epoch + 10
var snapshot = monitor.collectOnce(now: now)
expect(snapshot.availability == .ready && snapshot.rows.count == 2, "same model grouped, different models separated")
let group = snapshot.rows[0]
expect(group.tasks == 3 && group.measuredTasks == 2 && group.outputTPS == 100 && group.responseSamples == 2, "same-model concurrent speeds are averaged, not added")
expect(snapshot.overallTPS == 100, "unknown model speeds do not count as zero in the overall mean")
expect(group.inputTokens == 48000, "per-task inputs summed without caching twice")
expect(group.inputTasks == 2, "input coverage is distinct from task count")
expect(snapshot.hasUnread && snapshot.hasRunning, "unread and running are independent")
unread(["b", "archived"])
snapshot = monitor.collectOnce(now: now)
expect(!snapshot.hasUnread && snapshot.hasRunning, "subagent/archived unread excluded, active subagent included")
snapshot = monitor.collectOnce(now: now + 16)
expect(snapshot.rows[0].outputTPS == 100 && snapshot.rows[0].inputTokens == 48000, "the average survives the former 15-second expiry")
snapshot = monitor.collectOnce(now: now + 80)
expect(snapshot.rows[0].outputTPS == nil && snapshot.rows[0].responseSamples == 0, "averages expire after a minute rather than showing stale speed")
expect(!snapshot.hasRunning && snapshot.rows.allSatisfy { $0.quietTasks == $0.tasks }, "silent open turns stay visible as unknown, not live")

// Exercise the actual monitor across responses, turn boundaries, completion and
// model switches, not merely a view that holds onto an old string.
let averageHome = root.appendingPathComponent("average-home", isDirectory: true)
try! FileManager.default.createDirectory(at: averageHome, withIntermediateDirectories: true)
let averageFile = averageHome.appendingPathComponent("average.jsonl")
try! synthetic.write(to: averageFile)
var averageDB: OpaquePointer?
expect(sqlite3_open(averageHome.appendingPathComponent("state_5.sqlite").path, &averageDB) == SQLITE_OK, "open average fixture")
expect(sqlite3_exec(averageDB, "CREATE TABLE threads (id TEXT, updated_at INTEGER, rollout_path TEXT, archived INTEGER, model TEXT, thread_source TEXT, agent_role TEXT)", nil, nil, nil) == SQLITE_OK, "create average table")
expect(sqlite3_exec(averageDB, "INSERT INTO threads VALUES ('average', \(Int(now)), '\(averageFile.path)', 0, 'model-a', 'user', '')", nil, nil, nil) == SQLITE_OK, "insert average fixture")
sqlite3_close(averageDB)
let averageMonitor = ModelActivityMonitor(home: averageHome, onUpdate: { _ in })
@MainActor func averageRows(_ seconds: Double) -> ModelActivitySnapshot { averageMonitor.collectOnce(now: epoch + seconds) }
@MainActor func appendAverage(_ data: Data) {
    let h = try! FileHandle(forWritingTo: averageFile)
    try! h.seekToEnd(); try! h.write(contentsOf: data); try! h.close()
}
expect(averageRows(10).rows.first?.outputTPS == 100, "first valid response is immediately available")
appendAverage(line("event_msg", ["type": "item_completed", "item": ["type": "AgentMessage"],
    "started_at_ms": (epoch + 8) * 1000, "completed_at_ms": (epoch + 9) * 1000], at: 9)
    + line("token_usage_record", ["response_id": "weighted", "usage": ["input_tokens": 1000, "output_tokens": 300],
        "thread_token_usage": ["input_tokens": 25000, "output_tokens": 700]], at: 12))
expect(averageRows(12).rows.first?.outputTPS == 140, "duration-weighted average is (400+300)/(4+1), not (100+300)/2")
expect(averageRows(12).rows.first?.responseSamples == 2, "polling does not multiply responses")
appendAverage(line("turn_context", ["model": "model-a", "turn_id": "next-turn"], at: 13))
expect(averageRows(13).rows.first?.outputTPS == 140, "starting another turn does not blank the average")
appendAverage(line("response_item", ["type": "custom_tool_call", "call_id": "tool"], at: 13))
expect(averageRows(13).rows.first?.generating == 0 && averageRows(13).rows.first?.outputTPS == 140, "tool wait keeps the mean but changes current activity")
appendAverage(line("event_msg", ["type": "task_complete"], at: 14))
let completed = averageRows(14)
expect(completed.rows.first?.tasks == 0 && completed.rows.first?.outputTPS == 140, "completed task leaves a recent average instead of removing its row")
expect(!completed.hasRunning, "a retained average does not light the running indicator")
appendAverage(line("turn_context", ["model": "model-b", "turn_id": "other-model"], at: 15))
let switched = averageRows(15)
expect(switched.rows.count == 2 && switched.rows[0].tasks == 0 && switched.rows[1].outputTPS == nil, "old model average never becomes the new model's speed")
appendAverage(line("event_msg", ["type": "turn_aborted"], at: 16))
expect(averageRows(26).rows.first?.outputTPS == 140, "turn termination does not clear the recent mean")
expect(averageRows(69).rows.first?.outputTPS == 300 && averageRows(69).rows.first?.responseSamples == 1, "window expiry removes only expired responses")
expect(averageRows(73).rows.isEmpty && !averageRows(73).hasRunning, "idle model is removed after all recent samples expire")
expect(averageRows(73).overallTPS == nil, "no valid sample means an unknown overall speed, not zero")

let extraModel = averageHome.appendingPathComponent("extra-model.jsonl")
try! (line("turn_context", ["model": "model-c", "turn_id": "extra"])
    + line("event_msg", ["type": "item_completed", "item": ["type": "Reasoning"],
        "started_at_ms": epoch * 1000, "completed_at_ms": (epoch + 3) * 1000])
    + line("token_usage_record", ["response_id": "extra", "usage": ["input_tokens": 1000, "output_tokens": 600]])).write(to: extraModel)
expect(sqlite3_open(averageHome.appendingPathComponent("state_5.sqlite").path, &averageDB) == SQLITE_OK, "reopen cross-model fixture")
expect(sqlite3_exec(averageDB, "INSERT INTO threads VALUES ('extra', \(Int(now)), '\(extraModel.path)', 0, 'model-c', 'user', '')", nil, nil, nil) == SQLITE_OK, "insert another measured model")
sqlite3_close(averageDB)
let combined = ModelActivityMonitor(home: averageHome, onUpdate: { _ in }).collectOnce(now: epoch + 16)
expect(combined.rows.map(\.outputTPS) == [140, 200], "per-model means remain independent")
expect(combined.overallTPS == 162.5, "overall TPS is (700+600)/(5+3), not the mean or sum of model means")

// A fresh append after attach must be visible without rereading the history.
var observed: [ModelActivitySnapshot] = []
let live = ModelActivityMonitor(home: home) { observed.append($0) }
live.start()
let started = Date()
while observed.isEmpty && Date().timeIntervalSince(started) < 3 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
expect(observed.last?.rows.first?.tasks == 3, "background collector initial delivery")
let file = try! FileHandle(forWritingTo: second)
try! file.seekToEnd(); try! file.write(contentsOf: line("event_msg", ["type": "task_complete"]))
try! file.close()
let changed = Date()
while observed.last?.rows.first?.tasks == 3 && Date().timeIntervalSince(changed) < 2.8 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
expect(observed.last?.rows.first?.tasks == 2, "vnode append notification removes completed task")
expect(Date().timeIntervalSince(changed) < 1, "known-file update is event-driven, not waiting for discovery")
live.stop()
RunLoop.current.run(until: Date().addingTimeInterval(0.2))
sqlite3_close(db)
print("model-activity: \(assertions) assertions passed")
