
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
    check(allViews(root).compactMap { $0 as? NSTextField }.contains { $0.stringValue == L10n.shared.t("fiveHours") }, "the full popover retains the 5-hour quota row")
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
@MainActor func statusText(_ button: NSStatusBarButton) -> String {
    button.attributedTitle.string.trimmingCharacters(in: .whitespaces)
}
let statusSummary = try readmeSampleSummary()
let statusButton = statusDelegate.readmeSampleStatusButton(for: statusSummary, activity: activity(86.4))!
check(statusText(statusButton).hasSuffix("86 TPS"), "menu bar uses only a whole number and uppercase TPS")
check(!statusButton.attributedTitle.string.contains("≈") && !statusButton.attributedTitle.string.contains("model-a"), "no extra prefix, icon or model name in the numeric readout")
check(statusButton.toolTip!.contains("model-a: 86 TPS"), "model detail is in the hover tooltip")

check(statusText(statusButton).hasPrefix("\u{FFFC} 85% \u{FFFC}") && !statusText(statusButton).contains("∞") && !statusText(statusButton).contains("/"), "subscription status begins with weekly quota, not the 5-hour value or separator")
check(statusButton.attributedTitle.string.filter { $0 == "\u{FFFC}" }.count == 2, "only the weekly icon and task-light attachment remain")
check(statusButton.toolTip!.contains(L10n.shared.t("primaryRemaining")), "hover details retain the 5-hour information")
for (rawTitle, weekly) in [("5h 12% / 7d 73%", "73%"), ("5h … / 7d …", "…"), ("5h ? / 7d ?", "?"), ("5h 37%", "?")] {
    var summary = statusSummary
    summary.title = rawTitle
    let button = statusDelegate.readmeSampleStatusButton(for: summary, activity: activity(86.4))!
    check(statusText(button).hasPrefix("\u{FFFC} \(weekly) \u{FFFC}") && !statusText(button).contains("/"), "weekly-only rendering handles finite/loading/error/missing-weekly titles: \(rawTitle)")
}
_ = statusDelegate.readmeSampleStatusButton(for: statusSummary, activity: activity(86.4))

statusDelegate.updateModelActivity(activity(98.2))
check(statusText(statusButton).hasSuffix("98 TPS"), "TPS refreshes even when quotas and task lights stay unchanged")
statusDelegate.updateModelActivity(activity(98.4, modelValue: 99))
let unchangedTitle = statusButton.attributedTitle
statusDelegate.updateModelActivity(activity(98.49, modelValue: 101))
check(unchangedTitle.isEqual(to: statusButton.attributedTitle), "same rounded TPS does not rebuild the status title")
check(statusButton.toolTip!.contains("model-a: 101 TPS"), "model tooltip stays fresh even without a title redraw")
var widths: [CGFloat] = []
var numberOffsets: [CGFloat] = []
for value in [8.0, 86, 186] {
    statusDelegate.updateModelActivity(activity(value))
    let title = statusButton.attributedTitle
    widths.append(title.size().width)
    let number = (title.string as NSString).range(of: "\(Int(value)) TPS", options: .backwards)
    numberOffsets.append(title.attributedSubstring(from: NSRange(location: 0, length: number.location)).size().width)
}
check(widths.max()! - widths.min()! < 0.01, "one to three digit TPS has stable menu bar width")
check(numberOffsets.max()! - numberOffsets.min()! < 0.01, "the first TPS digit stays close to the lights for every digit count")
statusDelegate.updateModelActivity(activity(nil))
check(statusText(statusButton).hasSuffix("— TPS"), "no sample is unknown, never a fabricated zero")
statusDelegate.updateModelActivity(activity(0))
check(statusText(statusButton).hasSuffix("0 TPS"), "a measured zero remains distinct from missing data")
statusDelegate.updateModelActivity(activity(86.4, tasks: 0))
check(statusText(statusButton).hasSuffix("86 TPS") && statusButton.toolTip!.contains(chinese ? "（近期）" : "(recent)"), "recent idle means remain visible and identified in the tooltip")
statusDelegate.updateModelActivity(activity(86.4))
let styledTitle = statusButton.attributedTitle
let numberRange = (styledTitle.string as NSString).range(of: "86 TPS", options: .backwards)
let lightRange = (styledTitle.string as NSString).range(of: "\u{FFFC}", options: .backwards)
check((styledTitle.string as NSString).substring(with: NSRange(location: lightRange.location + 1, length: numberRange.location - lightRange.location - 1)) == " ", "only one space separates the task lights from the number")
let numberFont = styledTitle.attribute(.font, at: numberRange.location, effectiveRange: nil) as! NSFont
let unitFont = styledTitle.attribute(.font, at: numberRange.location + 3, effectiveRange: nil) as! NSFont
let numberColor = styledTitle.attribute(.foregroundColor, at: numberRange.location, effectiveRange: nil) as! NSColor
let unitColor = styledTitle.attribute(.foregroundColor, at: numberRange.location + 3, effectiveRange: nil) as! NSColor
check(numberFont.pointSize > unitFont.pointSize && NSFontManager.shared.weight(of: numberFont) > NSFontManager.shared.weight(of: unitFont), "the number is larger and bolder than its secondary unit")
check(unitColor.isEqual(NSColor.secondaryLabelColor), "TPS unit uses a quieter native secondary color")
for mode in [CardThemeMode.dark, .light] {
    let appearance = NSAppearance(named: mode == .dark ? .darkAqua : .aqua)!
    appearance.performAsCurrentDrawingAppearance {
        _ = statusDelegate.readmeSampleStatusButton(for: statusSummary, activity: activity(86.4))
        let rgb = numberColor.usingColorSpace(.sRGB)!
        func linear(_ c: CGFloat) -> CGFloat { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let luminance = 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
        let contrast = mode == .dark ? (luminance + 0.05) / 0.05 : 1.05 / (luminance + 0.05)
        check(contrast >= 4.5 && rgb.alphaComponent == 1, "numeric accent has readable contrast in \(mode.rawValue) appearance")
        check(rgb.blueComponent > rgb.greenComponent && rgb.redComponent > rgb.greenComponent, "numeric accent matches the panel's purple TPS family")
    }
    let title = statusButton.attributedTitle
    let preview = NSButton(frame: NSRect(x: 0, y: 0, width: ceil(title.size().width) + 14, height: 24))
    preview.isBordered = false; preview.appearance = appearance
    preview.wantsLayer = true
    preview.layer?.backgroundColor = (mode == .dark ? NSColor.black : NSColor.white).cgColor
    preview.attributedTitle = title
    try writeReadmeSamplePNG(view: preview, to: output.appendingPathComponent("statusbar-\(mode.rawValue).png"))
}
var apiSummary = try readmeSampleSummary()
apiSummary.kind = "api"
apiSummary.apiUsage = APIUsageSummary(unit: "USD", remaining: 12, todayTokens: 3200)
let apiButton = statusDelegate.readmeSampleStatusButton(for: apiSummary, activity: activity(86.4))!
check(apiButton === statusButton && statusText(apiButton).hasSuffix("86 TPS"), "API status uses the same item and numeric TPS suffix")
statusDelegate.updateModelActivity(activity(99))
check(apiButton.attributedTitle.string.contains("T ") && statusText(apiButton).hasSuffix("99 TPS"), "API TPS updates independently without replacing its balance/token display")
statusDelegate.updateModelActivity(ModelActivitySnapshot(availability: .unavailable))
check(statusText(apiButton).hasSuffix("— TPS") && apiButton.toolTip!.contains(chinese ? "暂时无法发现" : "discovery is unavailable"), "discovery failure is unknown and explained, not a fake zero or idle")
print("model-activity-panel (\(L10n.shared.effectiveCode)): \(checks) assertions passed")
