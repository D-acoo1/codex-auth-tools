
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
        tasks: 3, generating: index % 2, inputTokens: 24000, inputTasks: 2, outputTPS: index == 1 ? nil : 123.4, measuredTasks: index == 1 ? 0 : 2)
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
    let tps = labels.first { $0.stringValue == "≈ 123.4 TPS [2/3]" }!
    let input = labels.first { $0.stringValue == (chinese ? "输入 24.0k tok [2/3]" : "Input 24.0k tok [2/3]") }!
    check(tps.font!.pointSize == 13 && tps.font!.pointSize > input.font!.pointSize, "TPS is the primary readout, not the input amount")
    check(tps.alignment == .right && input.alignment == .left, "primary and secondary values have stable alignment")
    check(labels.contains { $0.stringValue == "— TPS" }, "missing measurement keeps an explicit TPS unit, not fake zero")
    check(!labels.contains { $0.stringValue.contains("↑") || $0.stringValue.contains("↓") || $0.stringValue.contains("tok/s") }, "readout does not require decoding traffic arrows or a different rate unit")
    for field in [tps, input] {
        check(field.cell!.cellSize.width <= field.bounds.width && field.cell!.cellSize.height <= field.bounds.height, "\(field.stringValue) fits without clipping: \(field.cell!.cellSize) in \(field.bounds.size)")
    }
    try writeReadmeSamplePNG(view: root, to: output.appendingPathComponent("many-\(mode.rawValue).png"))
    controller.updateModelActivity(ModelActivitySnapshot(availability: .ready, rows: samples))
    check(rowIdentities == allViews(activity).filter { $0 is NSTextField }.map(ObjectIdentifier.init), "unchanged update reuses labels")
    var changed = samples
    changed[0] = ModelActivityRow(model: samples[0].model, tasks: 4, generating: 3, inputTokens: 48200, inputTasks: 4, outputTPS: 198.2, measuredTasks: 4)
    controller.updateModelActivity(ModelActivitySnapshot(availability: .ready, rows: changed))
    check(allViews(activity).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "≈ 198.2 TPS" }, "full coverage omits the partial-coverage suffix")
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
}
print("model-activity-panel (\(L10n.shared.effectiveCode)): \(checks) assertions passed")
