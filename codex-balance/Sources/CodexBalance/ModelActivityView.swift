import AppKit

@MainActor
final class ModelActivityView: NSView {
    static let panelSpace: CGFloat = 120
    private let scroll = NSScrollView()
    private final class Document: NSView { override var isFlipped: Bool { true } }
    private let content = Document()
    private let empty = NSTextField(labelWithString: "")
    private var samplingHint: NSTextField?
    private var rowViews: [String: Row] = [:]
    private var lastSnapshot: ModelActivitySnapshot?
    private let chinese = L10n.shared.effectiveCode.hasPrefix("zh")
    private let primary: NSColor
    private let secondary: NSColor
    private let light: Bool

    init(frame: NSRect, primary: NSColor, secondary: NSColor, light: Bool) {
        self.primary = primary; self.secondary = secondary; self.light = light
        super.init(frame: frame)
        let separator = NSBox(frame: NSRect(x: 0, y: 107, width: bounds.width, height: 1))
        separator.boxType = .separator
        addSubview(separator)
        addSubview(field(chinese ? "本机模型 TPS" : "Local model TPS", frame: NSRect(x: 0, y: 89, width: 170, height: 16), weight: .semibold))
        let hint = field(chinese ? "响应采样" : "Response samples", frame: NSRect(x: 180, y: 89, width: bounds.width - 180, height: 16), color: secondary, alignment: .right)
        hint.toolTip = chinese
            ? "仅观察本机 Codex 会话，不额外调用模型。输入为每任务最近响应的 token 数（含缓存），不是输入 TPS。TPS = 输出 tokens ÷ 模型生成时间（含推理、不含工具等待）。并发同模型相加；不是逐 token 实时测速。15 秒无新样本显示 —；部分任务有数据时标注覆盖数。"
            : "Observes local Codex sessions without calling a model. Input is each task's latest response token count, including cache, not input TPS. TPS = output tokens / model-item time, including reasoning and excluding tools. Concurrent tasks are summed, not a per-request benchmark. This is not per-token live telemetry. Samples expire after 15s; partial coverage is marked."
        addSubview(hint)
        samplingHint = hint
        scroll.frame = NSRect(x: 0, y: 19, width: bounds.width, height: 68)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.horizontalScrollElasticity = .none
        scroll.documentView = content
        addSubview(scroll)
        empty.frame = NSRect(x: 0, y: 38, width: bounds.width, height: 24)
        empty.font = .systemFont(ofSize: 11)
        empty.textColor = secondary
        empty.alignment = .center
        addSubview(empty)
        addSubview(field(chinese ? "TPS = 每秒输出 token 数" : "TPS = output tokens per second", frame: NSRect(x: 0, y: 2, width: bounds.width, height: 14), size: 9, color: secondary))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ snapshot: ModelActivitySnapshot) {
        guard snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot
        samplingHint?.stringValue = snapshot.availability == .unavailable
            ? (chinese ? "发现受限" : "Discovery unavailable") : (chinese ? "响应采样" : "Response samples")
        let models = Set(snapshot.rows.map(\.model))
        for model in Array(rowViews.keys) where !models.contains(model) { rowViews.removeValue(forKey: model)?.removeFromSuperview() }
        content.frame = NSRect(x: 0, y: 0, width: scroll.bounds.width, height: max(68, CGFloat(snapshot.rows.count * 34)))
        for (index, data) in snapshot.rows.enumerated() {
            let row = rowViews[data.model] ?? Row(primary: primary, secondary: secondary, light: light)
            if row.superview == nil { content.addSubview(row); rowViews[data.model] = row }
            row.frame = NSRect(x: 0, y: CGFloat(index * 34), width: content.bounds.width, height: 32)
            row.update(data, chinese: chinese)
        }
        empty.isHidden = !snapshot.rows.isEmpty
        scroll.isHidden = snapshot.rows.isEmpty
        switch snapshot.availability {
        case .starting: empty.stringValue = chinese ? "正在读取本机活动…" : "Reading local activity…"
        case .unavailable: empty.stringValue = chinese ? "暂时无法读取 Codex 活动" : "Codex activity is unavailable"
        case .ready: empty.stringValue = chinese ? "当前没有活动模型" : "No active models"
        }
    }

    private func field(_ text: String, frame: NSRect, size: CGFloat = 11, weight: NSFont.Weight = .regular, color: NSColor? = nil, alignment: NSTextAlignment = .left) -> NSTextField {
        let value = NSTextField(labelWithString: text)
        value.frame = frame; value.font = .systemFont(ofSize: size, weight: weight)
        value.textColor = color ?? primary; value.alignment = alignment
        return value
    }

    private final class Row: NSView {
        let name = NSTextField(labelWithString: "")
        let status = NSTextField(labelWithString: "")
        let input = NSTextField(labelWithString: "")
        let output = NSTextField(labelWithString: "")
        let secondary: NSColor
        let outputTint: NSColor

        init(primary: NSColor, secondary: NSColor, light: Bool) {
            self.secondary = secondary
            outputTint = light ? NSColor(calibratedRed: 0.50, green: 0.26, blue: 0.67, alpha: 1) : .systemPurple
            super.init(frame: .zero)
            for field in [name, status, input, output] { addSubview(field) }
            name.font = .systemFont(ofSize: 11, weight: .medium)
            name.textColor = primary; name.lineBreakMode = .byTruncatingMiddle
            status.font = .systemFont(ofSize: 9); status.textColor = secondary; status.alignment = .right
            input.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            input.textColor = secondary; input.alignment = .left
            output.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
            output.alignment = .right
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layout() {
            super.layout()
            let width = bounds.width - 20 // Keep values clear of the overlay scroller.
            name.frame = NSRect(x: 0, y: 17, width: width * 0.55, height: 14)
            status.frame = NSRect(x: width * 0.55, y: 17, width: width * 0.45, height: 14)
            input.frame = NSRect(x: 0, y: 0, width: width * 0.42, height: 16)
            output.frame = NSRect(x: width * 0.42, y: 0, width: width * 0.58, height: 16)
        }

        func update(_ row: ModelActivityRow, chinese: Bool) {
            name.stringValue = row.model
            name.toolTip = row.model
            status.stringValue = chinese
                ? "\(row.tasks) 任务 · " + (row.generating == 0 ? "工具等待" : "\(row.generating) 生成中")
                : "\(row.tasks) task\(row.tasks == 1 ? "" : "s") · " + (row.generating == 0 ? "tools" : "\(row.generating) generating")
            if row.quietTasks == row.tasks {
                status.stringValue = chinese ? "\(row.tasks) 任务 · 等待更新" : "\(row.tasks) tasks · quiet"
            } else if row.quietTasks > 0 {
                status.stringValue += chinese ? " · \(row.quietTasks) 待确认" : " · \(row.quietTasks) quiet"
            }
            status.toolTip = status.stringValue
            let inputCoverage = row.inputTasks > 0 && row.inputTasks < row.tasks ? " [\(row.inputTasks)/\(row.tasks)]" : ""
            input.stringValue = (chinese ? "输入 " : "Input ") + (row.inputTokens.map(Self.compact) ?? "—") + " tok" + inputCoverage
            input.toolTip = row.inputTokens.map { chinese ? "\($0) 个输入 token（非 TPS）" : "\($0) input tokens (not TPS)" }
            var value = row.outputTPS.map { "≈ " + String(format: "%.1f", $0) } ?? "—"
            value += " TPS"
            if row.measuredTasks > 0, row.measuredTasks < row.tasks { value += " [\(row.measuredTasks)/\(row.tasks)]" }
            output.stringValue = value
            output.textColor = row.outputTPS == nil || row.generating == 0 ? secondary : outputTint
            needsLayout = true
        }

        private static func compact(_ number: Int) -> String {
            if number >= 1_000_000 { return String(format: "%.1fM", Double(number) / 1_000_000) }
            if number >= 1_000 { return String(format: "%.1fk", Double(number) / 1_000) }
            return String(number)
        }
    }
}
