
// Synthetic, production-view acceptance. Requires a graphical macOS session.
_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)
warmReadmeSampleGlyphs()
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
private let sampleTarget = ReadmeSampleActionTarget()
let sampleAction = #selector(ReadmeSampleActionTarget.ignore(_:))
var checks = 0
let chinese = L10n.shared.effectiveCode.hasPrefix("zh")
@MainActor func check(_ passed: @autoclosure () -> Bool, _ text: String) {
    guard passed() else {
        FileHandle.standardError.write(Data("FAIL: \(text)\n".utf8))
        preconditionFailure(text)
    }
    checks += 1
}
@MainActor func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }

let samples = (0..<8).map { index in
    ModelActivityRow(model: index == 0 ? "a-very-long-model-name-that-needs-truncation" : "model-\(index)",
        tasks: 3, generating: index % 2, inputTokens: 24000, inputTasks: 2, outputTPS: index == 1 ? nil : 123.4, measuredTasks: index == 1 ? 0 : 2, responseSamples: index == 1 ? 0 : 8)
}
for mode in [CardThemeMode.dark, .light] {
    let controller = CodexPanelViewController(summary: try readmeSampleSummary(), errorText: nil,
        target: sampleTarget, refreshAction: sampleAction, openAction: sampleAction, quitAction: sampleAction,
        languageAction: sampleAction, themeAction: sampleAction, resetCreditsAction: sampleAction,
        trainStyleIndex: 0, trainStartTime: 0, themeMode: mode, trainSegmentMask: 0,
        showResetCreditsDetail: true, dismissResetCredits: {}, trainClickAction: {}, animationSettingsAction: { _, _ in },
        modelActivity: ModelActivitySnapshot(availability: .ready, rows: samples))
    let root = controller.view
    root.layoutSubtreeIfNeeded()
    check(root.bounds.height == 524, "panel has stable space for model rows")
    let activity = root.subviews.first { $0 is ModelActivityView }!
    let card = root.subviews.first { $0 is UsageCardView }!
    let bubble = root.subviews.first { $0 is ResetCreditsBubbleView }!
    let rowIdentities = allViews(activity).filter { $0 is NSTextField }.map(ObjectIdentifier.init)
    let scroll = allViews(activity).compactMap { $0 as? NSScrollView }.first!
    check(scroll.documentView!.isFlipped, "model list starts at the first model")
    check(scroll.documentView!.frame.height == 272, "all models are scrollable, not capped to two")
    check(scroll.documentView!.subviews.count == 8, "eight rows retained")
    check(bubble.frame.minY >= 234 && activity.frame.maxY < 196, "coupon anchor and model panel do not overlap")
    let labels = allViews(activity).compactMap { $0 as? NSTextField }
    let tps = labels.first { $0.stringValue == "≈ 123 TPS" }!
    let input = labels.first { $0.stringValue == (chinese ? "输入 24.0k tok [2/3]" : "Input 24.0k tok [2/3]") }!
    check(tps.font!.pointSize == 13 && tps.font!.pointSize > input.font!.pointSize, "TPS is the primary readout, not the input amount")
    check(tps.alignment == .right && input.alignment == .left, "primary and secondary values have stable alignment")
    check(labels.contains { $0.stringValue == "— TPS" }, "missing measurement keeps an explicit TPS unit, not fake zero")
    check(labels.contains { $0.stringValue == (chinese ? "近1分钟平均" : "1-minute average") }, "visible qualifier identifies the average window")
    check(tps.toolTip!.contains("8") && tps.toolTip!.contains("2"), "average tooltip reports sample and contributing-session counts")
    check(!labels.contains { $0.stringValue.contains("↑") || $0.stringValue.contains("↓") || $0.stringValue.contains("tok/s") }, "readout does not require decoding traffic arrows or a different rate unit")
    for field in [tps, input] {
        check(field.cell!.cellSize.width <= field.bounds.width && field.cell!.cellSize.height <= field.bounds.height, "\(field.stringValue) fits without clipping: \(field.cell!.cellSize) in \(field.bounds.size)")
    }
    try writeReadmeSamplePNG(view: root, to: output.appendingPathComponent("many-\(mode.rawValue).png"))
    controller.updateModelActivity(ModelActivitySnapshot(availability: .ready, rows: samples))
    check(rowIdentities == allViews(activity).filter { $0 is NSTextField }.map(ObjectIdentifier.init), "unchanged update reuses labels")
    var changed = samples
    changed[0] = ModelActivityRow(model: samples[0].model, tasks: 4, generating: 3, inputTokens: 48200, inputTasks: 4, outputTPS: 198.2, measuredTasks: 4, responseSamples: 12)
    controller.updateModelActivity(ModelActivitySnapshot(availability: .ready, rows: changed))
    check(allViews(activity).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "≈ 198 TPS" }, "averages use whole TPS to avoid decimal jitter")
    check(rowIdentities == allViews(activity).filter { $0 is NSTextField }.map(ObjectIdentifier.init), "changed values do not recreate row labels")
    check(root.subviews.contains { $0 === card } && root.subviews.contains { $0 === bubble }, "updating TPS preserves card animation and open bubble")
    scroll.documentView!.scroll(NSPoint(x: 0, y: 206))
    try writeReadmeSamplePNG(view: root, to: output.appendingPathComponent("scrolled-\(mode.rawValue).png"))
    for availability in [ModelActivitySnapshot.Availability.starting, .ready, .unavailable] {
        controller.updateModelActivity(ModelActivitySnapshot(availability: availability))
        check(allViews(activity).compactMap { $0 as? NSScrollView }.first!.isHidden, "empty/loading/error have no stale rows")
        check(root.subviews.contains { $0 === bubble }, "empty state preserves the bubble")
        try writeReadmeSamplePNG(view: root, to: output.appendingPathComponent("\(availability.rawValue)-\(mode.rawValue).png"))
    }
    controller.updateModelActivity(ModelActivitySnapshot(availability: .ready, rows: [
        ModelActivityRow(model: "quiet-model", tasks: 3, generating: 0, inputTokens: nil, inputTasks: 0,
            outputTPS: nil, measuredTasks: 0, quietTasks: 3)
    ]))
    check(allViews(activity).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains(chinese ? "等待更新" : "quiet") }, "quiet tasks are not called generating or complete")
    try writeReadmeSamplePNG(view: root, to: output.appendingPathComponent("quiet-\(mode.rawValue).png"))
    controller.updateModelActivity(ModelActivitySnapshot(availability: .ready, rows: [
        ModelActivityRow(model: "recent-model", tasks: 0, generating: 0, inputTokens: nil, inputTasks: 0,
            outputTPS: 86.4, measuredTasks: 2, responseSamples: 8)
    ]))
    let recentLabels = allViews(activity).compactMap { $0 as? NSTextField }
    check(recentLabels.contains { $0.stringValue == (chinese ? "近期均值 · 当前无任务" : "Recent average · idle") }, "recent mean does not imply an active task")
    check(recentLabels.contains { $0.stringValue == "≈ 86 TPS" }, "completion retains a readable numeric mean")
    try writeReadmeSamplePNG(view: root, to: output.appendingPathComponent("recent-\(mode.rawValue).png"))
}
let statusDelegate = AppDelegate()
defer { statusDelegate.removeReadmeSampleStatusItem() }
@MainActor func activity(_ value: Double?, modelValue: Double? = nil, tasks: Int = 1) -> ModelActivitySnapshot {
    ModelActivitySnapshot(availability: .ready, rows: [
        ModelActivityRow(model: "model-a", tasks: tasks, generating: tasks, inputTokens: nil, inputTasks: 0,
            outputTPS: modelValue ?? value, measuredTasks: value == nil ? 0 : 1, responseSamples: value == nil ? 0 : 8)
    ], overallTPS: value)
}
let statusButton = statusDelegate.readmeSampleStatusButton(for: try readmeSampleSummary(), activity: activity(86.4))!
check(statusButton.attributedTitle.string.hasSuffix("86 tps"), "menu bar uses only a whole number and lowercase tps")
check(!statusButton.attributedTitle.string.contains("≈") && !statusButton.attributedTitle.string.contains("model-a"), "no extra prefix, icon or model name in the numeric readout")
check(statusButton.toolTip!.contains("model-a: 86 tps"), "model detail is in the hover tooltip")
statusDelegate.updateModelActivity(activity(98.2))
check(statusButton.attributedTitle.string.hasSuffix("98 tps"), "TPS refreshes even when quotas and task lights stay unchanged")
statusDelegate.updateModelActivity(activity(98.4, modelValue: 99))
let unchangedTitle = statusButton.attributedTitle
statusDelegate.updateModelActivity(activity(98.49, modelValue: 101))
check(unchangedTitle.isEqual(to: statusButton.attributedTitle), "same rounded TPS does not rebuild the status title")
check(statusButton.toolTip!.contains("model-a: 101 tps"), "model tooltip stays fresh even without a title redraw")
var widths: [CGFloat] = []
for value in [8.0, 86, 186] {
    statusDelegate.updateModelActivity(activity(value))
    widths.append(statusButton.attributedTitle.size().width)
}
check(widths.max()! - widths.min()! < 0.01, "one to three digit TPS has stable menu bar width")
statusDelegate.updateModelActivity(activity(nil))
check(statusButton.attributedTitle.string.hasSuffix("— tps"), "no sample is unknown, never a fabricated zero")
statusDelegate.updateModelActivity(activity(0))
check(statusButton.attributedTitle.string.hasSuffix("0 tps"), "a measured zero remains distinct from missing data")
statusDelegate.updateModelActivity(activity(86.4, tasks: 0))
check(statusButton.attributedTitle.string.hasSuffix("86 tps") && statusButton.toolTip!.contains(chinese ? "（近期）" : "(recent)"), "recent idle means remain visible and identified in the tooltip")
statusDelegate.updateModelActivity(activity(86.4))
for mode in [CardThemeMode.dark, .light] {
    let title = statusButton.attributedTitle
    let preview = NSButton(frame: NSRect(x: 0, y: 0, width: ceil(title.size().width) + 14, height: 24))
    preview.isBordered = false; preview.appearance = NSAppearance(named: mode == .dark ? .darkAqua : .aqua)
    preview.attributedTitle = title
    try writeReadmeSamplePNG(view: preview, to: output.appendingPathComponent("statusbar-\(mode.rawValue).png"))
}
var apiSummary = try readmeSampleSummary()
apiSummary.kind = "api"
apiSummary.apiUsage = APIUsageSummary(unit: "USD", remaining: 12, todayTokens: 3200)
let apiButton = statusDelegate.readmeSampleStatusButton(for: apiSummary, activity: activity(86.4))!
check(apiButton === statusButton && apiButton.attributedTitle.string.hasSuffix("86 tps"), "API status uses the same item and numeric TPS suffix")
statusDelegate.updateModelActivity(activity(99))
check(apiButton.attributedTitle.string.contains("T ") && apiButton.attributedTitle.string.hasSuffix("99 tps"), "API TPS updates independently without replacing its balance/token display")
statusDelegate.updateModelActivity(ModelActivitySnapshot(availability: .unavailable))
check(apiButton.attributedTitle.string.hasSuffix("— tps") && apiButton.toolTip!.contains(chinese ? "暂时无法发现" : "discovery is unavailable"), "discovery failure is unknown and explained, not a fake zero or idle")
print("model-activity-panel (\(L10n.shared.effectiveCode)): \(checks) assertions passed")
