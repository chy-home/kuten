import AppKit

final class WorkerWindowController: NSWindowController {
    private let statusLabel = NSTextField(labelWithString: "等待任务")
    private let detailLabel = NSTextField(labelWithString: "")
    private let textView = NSTextView()

    init(workerIndex: Int, totalWorkers: Int) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "分解任务 \(workerIndex)/\(totalWorkers)"
        super.init(window: window)
        buildUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    private func buildUI() {
        guard let contentView = window?.contentView else {
            return
        }

        statusLabel.font = .boldSystemFont(ofSize: 13)
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor

        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.string = ""

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .bezelBorder
        scrollView.drawsBackground = false
        scrollView.documentView = textView

        let rootStack = NSStackView()
        rootStack.orientation = .vertical
        rootStack.spacing = 10
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        rootStack.addArrangedSubview(statusLabel)
        rootStack.addArrangedSubview(detailLabel)
        rootStack.addArrangedSubview(scrollView)

        contentView.addSubview(rootStack)

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            rootStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            rootStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            rootStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 240),
        ])
    }

    func prepareForDisplay() {
        showWindow(nil)
        window?.orderFrontRegardless()
    }

    func setIdle(detail: String = "等待分配任务") {
        statusLabel.stringValue = "空闲"
        detailLabel.stringValue = detail
    }

    func setRunning(job: FFmpegJob, position: Int, total: Int) {
        statusLabel.stringValue = "运行中"
        detailLabel.stringValue = "第 \(position)/\(total) 段 -> \(job.outputURL.lastPathComponent)"
        appendLog(">>> \(job.commandPreview)\n")
    }

    func setFinished(success: Bool, detail: String) {
        statusLabel.stringValue = success ? "完成" : "失败"
        detailLabel.stringValue = detail
    }

    func appendLog(_ text: String) {
        guard !text.isEmpty else {
            return
        }

        let attributed = NSAttributedString(string: text)
        textView.textStorage?.append(attributed)
        textView.scrollToEndOfDocument(nil)
    }
}
