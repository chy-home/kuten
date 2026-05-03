import AppKit
import UniformTypeIdentifiers

final class MainWindowController: NSWindowController, NSTextFieldDelegate, SplitCoordinatorDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let headerTitleLabel = NSTextField(labelWithString: "Video Change")
    private let headerSubtitleLabel = NSTextField(labelWithString: "识别换场，生成脚本，并按并发窗口执行分解。")

    private let videoPathField = DroppablePathField(acceptKind: .file)
    private let outputDirectoryField = DroppablePathField(acceptKind: .directory)
    private let prefixField = NSTextField()
    private let concurrencyField = NSTextField()
    private let concurrencyStepper = NSStepper()
    private let skipStartField = NSTextField()
    private let cropField = NSTextField()
    private let fadeStrategyStack = NSStackView()
    private var fadeStrategyButtons: [FadeRemovalStrategy: NSButton] = [:]
    private var fadeLeftFields: [FadeRemovalStrategy: NSTextField] = [:]
    private var fadeRightFields: [FadeRemovalStrategy: NSTextField] = [:]
    private let namingPreviewLabel = NSTextField(labelWithString: "未选择视频")
    private let statusLabel = NSTextField(labelWithString: "请选择视频文件，或直接拖入。")

    private let parseButton = NSButton(title: "解析", target: nil, action: nil)
    private let splitButton = NSButton(title: "分解", target: nil, action: nil)

    private let summaryLabel = NSTextField(labelWithString: "等待解析")
    private let eventTableView = NSTableView()
    private let scriptTextView = NSTextView()
    private var scriptLineRanges: [NSRange] = []

    private var selectedVideoURL: URL?
    private var selectedOutputDirectoryURL: URL?
    private var outputDirectoryWasChosenManually = false
    private var isProgrammaticallyUpdatingOutputDirectoryField = false
    private var isProgrammaticallyUpdatingFadeFields = false
    private var detectorPayload: DetectorPayload?
    private var generatedJobs: [FFmpegJob] = []
    private var splitCoordinator: SplitCoordinator?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1240, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Video Change"
        window.minSize = NSSize(width: 1100, height: 760)
        super.init(window: window)
        buildUI()
        updateNamingPreview()
        updateSplitButtonState()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    private func buildUI() {
        guard let contentView = window?.contentView else {
            return
        }

        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        headerTitleLabel.font = .systemFont(ofSize: 34, weight: .bold)
        headerSubtitleLabel.font = .systemFont(ofSize: 15, weight: .regular)
        headerSubtitleLabel.textColor = .secondaryLabelColor

        configureInputField(videoPathField, placeholder: "拖入视频文件，或点击右侧按钮选择")
        configureInputField(outputDirectoryField, placeholder: "默认使用视频所在目录，也可拖入文件夹或手工输入")
        outputDirectoryField.isEditable = true
        outputDirectoryField.isSelectable = true

        prefixField.placeholderString = "输出前缀，例如 my-video"
        prefixField.font = .systemFont(ofSize: 15)
        prefixField.delegate = self

        concurrencyField.stringValue = "3"
        concurrencyField.alignment = .center
        concurrencyField.font = .systemFont(ofSize: 15, weight: .medium)
        concurrencyField.delegate = self
        concurrencyField.translatesAutoresizingMaskIntoConstraints = false
        concurrencyField.widthAnchor.constraint(equalToConstant: 92).isActive = true

        concurrencyStepper.minValue = 1
        concurrencyStepper.maxValue = 12
        concurrencyStepper.integerValue = 3
        concurrencyStepper.increment = 1
        concurrencyStepper.target = self
        concurrencyStepper.action = #selector(concurrencyStepperChanged(_:))

        parseButton.bezelStyle = .rounded
        parseButton.font = .systemFont(ofSize: 15, weight: .semibold)
        parseButton.target = self
        parseButton.action = #selector(parseVideo(_:))

        splitButton.bezelStyle = .rounded
        splitButton.font = .systemFont(ofSize: 15, weight: .semibold)
        splitButton.target = self
        splitButton.action = #selector(splitVideo(_:))

        configureSmallField(skipStartField, placeholder: "0")
        skipStartField.stringValue = "0"
        configureLargeField(cropField, placeholder: "1728:910:0:85")
        configureFadeStrategyControls()

        statusLabel.font = .systemFont(ofSize: 14)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 2
        statusLabel.lineBreakMode = .byWordWrapping

        namingPreviewLabel.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        namingPreviewLabel.textColor = .secondaryLabelColor
        namingPreviewLabel.lineBreakMode = .byTruncatingMiddle

        videoPathField.onURLDropped = { [weak self] url in
            self?.applyVideoURL(url)
        }
        outputDirectoryField.onURLDropped = { [weak self] url in
            self?.applyOutputDirectoryURL(url, manual: true)
        }

        configureEventTable()
        configureScriptView()

        let headerStack = NSStackView()
        headerStack.orientation = .vertical
        headerStack.spacing = 6
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        headerStack.addArrangedSubview(headerTitleLabel)
        headerStack.addArrangedSubview(headerSubtitleLabel)

        let controlsPanel = buildControlsPanel()
        let resultPanel = buildResultPanel()
        let scriptPanel = buildScriptPanel()

        let contentSplit = NSSplitView()
        contentSplit.isVertical = true
        contentSplit.dividerStyle = .thin
        contentSplit.translatesAutoresizingMaskIntoConstraints = false
        contentSplit.addArrangedSubview(resultPanel)
        contentSplit.addArrangedSubview(scriptPanel)
        contentSplit.setPosition(560, ofDividerAt: 0)

        let rootStack = NSStackView()
        rootStack.orientation = .vertical
        rootStack.spacing = 18
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        rootStack.addArrangedSubview(headerStack)
        rootStack.addArrangedSubview(controlsPanel)
        rootStack.addArrangedSubview(contentSplit)

        contentView.addSubview(rootStack)

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 22),
            rootStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -22),
            rootStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 22),
            rootStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -22),
            controlsPanel.heightAnchor.constraint(greaterThanOrEqualToConstant: 260),
            contentSplit.heightAnchor.constraint(greaterThanOrEqualToConstant: 420),
        ])
    }

    private func buildControlsPanel() -> NSView {
        let panel = PanelContainerView()
        panel.translatesAutoresizingMaskIntoConstraints = false

        let chooseVideoButton = NSButton(title: "选择视频", target: self, action: #selector(selectVideo(_:)))
        let chooseOutputButton = NSButton(title: "选择目录", target: self, action: #selector(selectOutputDirectory(_:)))
        let useVideoDirectoryButton = NSButton(title: "跟随视频目录", target: self, action: #selector(resetOutputDirectory(_:)))

        let sectionTitle = makeSectionTitle("输入与输出")
        let cropRow = makeHorizontalRow([
            cropField,
            makeHintLabel("格式：宽:高:X:Y，留空表示不裁剪"),
        ])
        let skipRow = makeHorizontalRow([
            skipStartField,
            makeHintLabel("从视频开头跳过多少秒后再开始检测"),
        ])
        let fadeStrategyRow = makeHorizontalRow([
            fadeStrategyStack,
            makeHintLabel("左侧别太激进，右侧别太保守；秒数可直接手调"),
        ])

        let formGrid = NSGridView(views: [
            [makeFieldLabel("视频文件"), makeHorizontalRow([videoPathField, chooseVideoButton])],
            [makeFieldLabel("输出目录"), makeHorizontalRow([outputDirectoryField, chooseOutputButton, useVideoDirectoryButton])],
            [makeFieldLabel("输出前缀"), makeHorizontalRow([prefixField, makeHintLabel("输出文件名格式：前缀-01、前缀-02")])],
            [makeFieldLabel("画面裁剪"), cropRow],
            [makeFieldLabel("跳过检测"), skipRow],
            [makeFieldLabel("Fade 删除"), fadeStrategyRow],
            [makeFieldLabel("命名预览"), namingPreviewLabel],
            [makeFieldLabel("并发窗口"), makeHorizontalRow([concurrencyField, concurrencyStepper, makeHintLabel("默认 3 个子窗口并发执行")])],
            [makeFieldLabel("状态"), statusLabel],
        ])
        formGrid.translatesAutoresizingMaskIntoConstraints = false
        formGrid.rowSpacing = 14
        formGrid.columnSpacing = 16
        formGrid.column(at: 0).xPlacement = .trailing
        formGrid.column(at: 1).xPlacement = .fill

        let actionStack = NSStackView(views: [parseButton, splitButton])
        actionStack.orientation = .horizontal
        actionStack.spacing = 12
        actionStack.alignment = .centerY
        actionStack.translatesAutoresizingMaskIntoConstraints = false

        let rootStack = NSStackView()
        rootStack.orientation = .vertical
        rootStack.spacing = 16
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        rootStack.addArrangedSubview(sectionTitle)
        rootStack.addArrangedSubview(formGrid)
        rootStack.addArrangedSubview(actionStack)

        panel.contentView.addSubview(rootStack)
        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: panel.contentView.leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: panel.contentView.trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: panel.contentView.topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: panel.contentView.bottomAnchor),
        ])

        return panel
    }

    private func buildResultPanel() -> NSView {
        let panel = PanelContainerView()
        panel.translatesAutoresizingMaskIntoConstraints = false

        let title = makeSectionTitle("换场结果")
        let subtitle = NSTextField(labelWithString: "展示开始时间、结束时间、时长和换场类型。")
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor

        summaryLabel.font = .systemFont(ofSize: 14, weight: .medium)
        summaryLabel.textColor = .secondaryLabelColor

        let scrollView = makeTableScrollView(for: eventTableView)

        let headerStack = NSStackView(views: [title, subtitle, summaryLabel])
        headerStack.orientation = .vertical
        headerStack.spacing = 4
        headerStack.translatesAutoresizingMaskIntoConstraints = false

        let rootStack = NSStackView()
        rootStack.orientation = .vertical
        rootStack.spacing = 14
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        rootStack.addArrangedSubview(headerStack)
        rootStack.addArrangedSubview(scrollView)

        panel.contentView.addSubview(rootStack)
        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: panel.contentView.leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: panel.contentView.trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: panel.contentView.topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: panel.contentView.bottomAnchor),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 320),
        ])

        return panel
    }

    private func buildScriptPanel() -> NSView {
        let panel = PanelContainerView()
        panel.translatesAutoresizingMaskIntoConstraints = false

        let title = makeSectionTitle("FFmpeg 脚本")
        let subtitle = NSTextField(labelWithString: "这里直接显示将要执行的脚本。")
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor

        let scrollView = makeTextScrollView(for: scriptTextView)

        let headerStack = NSStackView(views: [title, subtitle])
        headerStack.orientation = .vertical
        headerStack.spacing = 4
        headerStack.translatesAutoresizingMaskIntoConstraints = false

        let rootStack = NSStackView()
        rootStack.orientation = .vertical
        rootStack.spacing = 14
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        rootStack.addArrangedSubview(headerStack)
        rootStack.addArrangedSubview(scrollView)

        panel.contentView.addSubview(rootStack)
        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: panel.contentView.leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: panel.contentView.trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: panel.contentView.topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: panel.contentView.bottomAnchor),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 320),
        ])

        return panel
    }

    private func configureInputField(_ field: DroppablePathField, placeholder: String) {
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 15)
        field.delegate = self
    }

    private func configureSmallField(_ field: NSTextField, placeholder: String) {
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 15, weight: .medium)
        field.alignment = .center
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 110).isActive = true
        field.controlSize = .large
    }

    private func configureLargeField(_ field: NSTextField, placeholder: String) {
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 15, weight: .medium)
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        field.controlSize = .large
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
    }

    private func configureFadeStrategyControls() {
        fadeStrategyStack.orientation = .vertical
        fadeStrategyStack.spacing = 8
        fadeStrategyStack.alignment = .leading
        fadeStrategyStack.translatesAutoresizingMaskIntoConstraints = false

        isProgrammaticallyUpdatingFadeFields = true
        for strategy in FadeRemovalStrategy.allCases {
            let button = NSButton(radioButtonWithTitle: strategy.displayName, target: self, action: #selector(fadeStrategyRadioChanged(_:)))
            button.font = .systemFont(ofSize: 15, weight: .medium)
            button.tag = FadeRemovalStrategy.allCases.firstIndex(of: strategy) ?? 0
            button.setButtonType(.radio)
            button.state = strategy == .defaultValue ? .on : .off
            fadeStrategyButtons[strategy] = button

            let leftField = NSTextField()
            leftField.placeholderString = "左扩秒"
            leftField.font = .systemFont(ofSize: 14, weight: .medium)
            leftField.alignment = .center
            leftField.delegate = self
            leftField.controlSize = .large
            leftField.translatesAutoresizingMaskIntoConstraints = false
            leftField.widthAnchor.constraint(equalToConstant: 78).isActive = true
            leftField.stringValue = String(format: "%.2f", strategy.defaultPaddingSettings.leftSeconds)
            fadeLeftFields[strategy] = leftField

            let rightField = NSTextField()
            rightField.placeholderString = "右扩秒"
            rightField.font = .systemFont(ofSize: 14, weight: .medium)
            rightField.alignment = .center
            rightField.delegate = self
            rightField.controlSize = .large
            rightField.translatesAutoresizingMaskIntoConstraints = false
            rightField.widthAnchor.constraint(equalToConstant: 78).isActive = true
            rightField.stringValue = String(format: "%.2f", strategy.defaultPaddingSettings.rightSeconds)
            fadeRightFields[strategy] = rightField

            let labelsRow = makeHorizontalRow([
                button,
                makeHintLabel("左"),
                leftField,
                makeHintLabel("右"),
                rightField,
                makeHintLabel("秒"),
            ])
            fadeStrategyStack.addArrangedSubview(labelsRow)
        }
        isProgrammaticallyUpdatingFadeFields = false
    }

    private func configureEventTable() {
        eventTableView.headerView = NSTableHeaderView()
        eventTableView.usesAlternatingRowBackgroundColors = true
        eventTableView.rowHeight = 34
        eventTableView.intercellSpacing = NSSize(width: 8, height: 4)
        eventTableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        eventTableView.delegate = self
        eventTableView.dataSource = self

        let columns: [(String, String, CGFloat)] = [
            ("index", "#", 52),
            ("type", "类型", 110),
            ("start", "开始时间", 130),
            ("end", "结束时间", 130),
            ("duration", "时长", 110),
            ("source", "来源", 220),
        ]

        for (identifier, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            column.minWidth = width
            eventTableView.addTableColumn(column)
        }
    }

    private func configureScriptView() {
        scriptTextView.isEditable = false
        scriptTextView.isSelectable = true
        scriptTextView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        scriptTextView.drawsBackground = true
        scriptTextView.backgroundColor = .textBackgroundColor
        scriptTextView.textContainerInset = NSSize(width: 12, height: 14)
        scriptTextView.isVerticallyResizable = true
        scriptTextView.isHorizontallyResizable = false
        scriptTextView.autoresizingMask = [.width]
        scriptTextView.textContainer?.widthTracksTextView = true
        scriptTextView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        scriptTextView.string = "生成的 ffmpeg 脚本会显示在这里。"
    }

    private func makeTextScrollView(for textView: NSTextView) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .bezelBorder
        scrollView.drawsBackground = false
        scrollView.documentView = textView
        return scrollView
    }

    private func makeTableScrollView(for tableView: NSTableView) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .bezelBorder
        scrollView.drawsBackground = false
        scrollView.documentView = tableView
        return scrollView
    }

    private func updateScriptText(with jobs: [FFmpegJob]) {
        scriptLineRanges = []

        guard !jobs.isEmpty else {
            scriptTextView.string = "没有可分解的保留片段。"
            return
        }

        let fullText = jobs.map(\.commandPreview).joined(separator: "\n")
        let attributed = NSMutableAttributedString(string: fullText)
        let fullRange = NSRange(location: 0, length: attributed.length)
        attributed.addAttributes([
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.labelColor,
            .backgroundColor: NSColor.textBackgroundColor,
        ], range: fullRange)

        var cursor = 0
        for (index, job) in jobs.enumerated() {
            let line = job.commandPreview
            let range = NSRange(location: cursor, length: line.count)
            scriptLineRanges.append(range)
            cursor += line.count
            if index < jobs.count - 1 {
                cursor += 1
            }
        }

        scriptTextView.textStorage?.setAttributedString(attributed)
        scriptTextView.layoutManager?.ensureLayout(for: scriptTextView.textContainer!)
    }

    private func highlightScriptRanges(forEventAt row: Int?) {
        guard let payload = detectorPayload else {
            return
        }

        let attributed = NSMutableAttributedString(attributedString: scriptTextView.attributedString())
        let fullRange = NSRange(location: 0, length: attributed.length)
        if fullRange.length > 0 {
            attributed.addAttribute(.backgroundColor, value: NSColor.textBackgroundColor, range: fullRange)
        }

        guard
            let row,
            row >= 0,
            row < payload.events.count,
            !generatedJobs.isEmpty
        else {
            scriptTextView.textStorage?.setAttributedString(attributed)
            return
        }

        let event = payload.events[row]
        let relatedIndices = relatedKeepSegmentIndices(for: event)
        var firstHighlightedRange: NSRange?

        for keepIndex in relatedIndices {
            let scriptLineIndex = keepIndex - 1
            guard scriptLineIndex >= 0, scriptLineIndex < scriptLineRanges.count else {
                continue
            }

            let range = scriptLineRanges[scriptLineIndex]
            attributed.addAttribute(
                .backgroundColor,
                value: NSColor.controlAccentColor.withAlphaComponent(0.22),
                range: range
            )
            if firstHighlightedRange == nil {
                firstHighlightedRange = range
            }
        }

        scriptTextView.textStorage?.setAttributedString(attributed)

        if let range = firstHighlightedRange {
            scriptTextView.scrollRangeToVisible(range)
            scriptTextView.setSelectedRange(range)
        } else {
            scriptTextView.setSelectedRange(NSRange(location: 0, length: 0))
        }
    }

    private func relatedKeepSegmentIndices(for event: TransitionEvent) -> [Int] {
        guard let payload = detectorPayload else {
            return []
        }

        var matched: [Int] = []
        let epsilon = 0.0005

        for segment in payload.keepSegments {
            if abs(segment.end - event.start) <= epsilon || abs(segment.start - event.end) <= epsilon {
                matched.append(segment.index)
            }
        }

        if !matched.isEmpty {
            return matched
        }

        var closestBefore: (index: Int, gap: Double)?
        var closestAfter: (index: Int, gap: Double)?
        for segment in payload.keepSegments {
            if segment.end <= event.start {
                let gap = event.start - segment.end
                if closestBefore == nil || gap < closestBefore!.gap {
                    closestBefore = (segment.index, gap)
                }
            }
            if segment.start >= event.end {
                let gap = segment.start - event.end
                if closestAfter == nil || gap < closestAfter!.gap {
                    closestAfter = (segment.index, gap)
                }
            }
        }

        var fallback: [Int] = []
        if let before = closestBefore {
            fallback.append(before.index)
        }
        if let after = closestAfter, !fallback.contains(after.index) {
            fallback.append(after.index)
        }
        return fallback
    }

    private func makeSectionTitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 19, weight: .semibold)
        return label
    }

    private func makeFieldLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        return label
    }

    private func makeHintLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func makeHorizontalRow(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.alignment = .centerY
        if let firstField = views.first {
            firstField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        return stack
    }

    private func currentCropParameters() -> CropParameters? {
        let trimmed = cropField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard
            parts.count == 4,
            let width = Int(parts[0]),
            let height = Int(parts[1]),
            let x = Int(parts[2]),
            let y = Int(parts[3]),
            width > 0,
            height > 0,
            x >= 0,
            y >= 0
        else {
            return nil
        }

        return CropParameters(width: width, height: height, x: x, y: y)
    }

    private func validateCropParametersIfNeeded() -> String? {
        let trimmed = cropField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        if currentCropParameters() == nil {
            return "裁剪参数格式应为 宽:高:X:Y，例如 1728:910:0:85。"
        }
        return nil
    }

    private func currentSkipStartSeconds() -> Double {
        let trimmed = skipStartField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(trimmed), value >= 0 else {
            return 0
        }
        return value
    }

    private func currentFadeRemovalStrategy() -> FadeRemovalStrategy {
        for strategy in FadeRemovalStrategy.allCases {
            if fadeStrategyButtons[strategy]?.state == .on {
                return strategy
            }
        }
        return .defaultValue
    }

    private func currentFadePaddingSettings(for strategy: FadeRemovalStrategy) -> FadePaddingSettings {
        let defaults = strategy.defaultPaddingSettings
        let left = Double(fadeLeftFields[strategy]?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? defaults.leftSeconds
        let right = Double(fadeRightFields[strategy]?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? defaults.rightSeconds
        return FadePaddingSettings(
            leftSeconds: max(0.0, left),
            rightSeconds: max(0.0, right)
        )
    }

    private func validateFadePaddingIfNeeded() -> String? {
        for strategy in FadeRemovalStrategy.allCases {
            guard
                let leftText = fadeLeftFields[strategy]?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                let rightText = fadeRightFields[strategy]?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                let leftValue = Double(leftText),
                let rightValue = Double(rightText),
                leftValue >= 0,
                rightValue >= 0
            else {
                return "Fade 左右扩秒数必须是大于等于 0 的数字。"
            }
            if leftValue > 5 || rightValue > 5 {
                return "Fade 左右扩秒数过大。"
            }
        }
        return nil
    }

    private func validateSkipStartIfNeeded() -> String? {
        let trimmed = skipStartField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        guard let value = Double(trimmed), value >= 0 else {
            return "跳过检测秒数必须是大于等于 0 的数字。"
        }
        if value > 24 * 3600 {
            return "跳过检测秒数过大。"
        }
        return nil
    }

    private func applyVideoURL(_ url: URL) {
        selectedVideoURL = url
        videoPathField.stringValue = url.path

        if !outputDirectoryWasChosenManually || selectedOutputDirectoryURL == nil {
            applyOutputDirectoryURL(url.deletingLastPathComponent(), manual: false)
        }

        if prefixField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            prefixField.stringValue = url.deletingPathExtension().lastPathComponent
        }

        clearDetectionResults()
        updateNamingPreview()
        statusLabel.stringValue = "视频已准备好，点击“解析”生成结果和脚本。"
    }

    private func applyOutputDirectoryURL(_ url: URL, manual: Bool) {
        outputDirectoryWasChosenManually = manual
        selectedOutputDirectoryURL = url
        isProgrammaticallyUpdatingOutputDirectoryField = true
        outputDirectoryField.stringValue = url.path
        isProgrammaticallyUpdatingOutputDirectoryField = false
        updateNamingPreview()
        if detectorPayload != nil {
            refreshGeneratedJobs()
        }
    }

    private func resolvedOutputDirectoryURL() -> URL? {
        let typed = outputDirectoryField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty {
            return URL(fileURLWithPath: typed, isDirectory: true)
        }
        if let selectedOutputDirectoryURL {
            return selectedOutputDirectoryURL
        }
        return selectedVideoURL?.deletingLastPathComponent()
    }

    private func refreshGeneratedJobs() {
        guard let detectorPayload, let selectedVideoURL, let outputDirectoryURL = resolvedOutputDirectoryURL() else {
            generatedJobs = []
            scriptLineRanges = []
            scriptTextView.string = "生成的 ffmpeg 脚本会显示在这里。"
            updateSplitButtonState()
            updateNamingPreview()
            return
        }

        generatedJobs = buildJobs(
            payload: detectorPayload,
            videoURL: selectedVideoURL,
            outputDirectoryURL: outputDirectoryURL,
            prefix: prefixField.stringValue,
            crop: currentCropParameters()
        )

        updateScriptText(with: generatedJobs)

        summaryLabel.stringValue = "换场 \(detectorPayload.events.count) 个，保留片段 \(detectorPayload.keepSegments.count) 个"
        eventTableView.reloadData()
        highlightScriptRanges(forEventAt: eventTableView.selectedRow >= 0 ? eventTableView.selectedRow : nil)
        updateSplitButtonState()
        updateNamingPreview()
    }

    private func updateSplitButtonState() {
        splitButton.isEnabled = splitCoordinator == nil && !generatedJobs.isEmpty
    }

    private func updateNamingPreview() {
        let extensionName = selectedVideoURL?.pathExtension ?? "mp4"
        let fallbackPrefix = selectedVideoURL?.deletingPathExtension().lastPathComponent ?? "clip"
        let safePrefix = sanitizePrefix(prefixField.stringValue, fallback: fallbackPrefix)
        let sampleName = makeOutputFileName(prefix: safePrefix, index: 1, pathExtension: extensionName)
        if let outputDirectoryURL = resolvedOutputDirectoryURL() {
            namingPreviewLabel.stringValue = outputDirectoryURL.appendingPathComponent(sampleName).path
        } else {
            namingPreviewLabel.stringValue = sampleName
        }
    }

    private func clearDetectionResults() {
        detectorPayload = nil
        generatedJobs = []
        scriptLineRanges = []
        summaryLabel.stringValue = "等待解析"
        scriptTextView.string = "生成的 ffmpeg 脚本会显示在这里。"
        eventTableView.reloadData()
        updateSplitButtonState()
    }

    private func currentConcurrency() -> Int {
        let parsed = Int(concurrencyField.stringValue) ?? 3
        let clamped = min(12, max(1, parsed))
        concurrencyField.stringValue = "\(clamped)"
        concurrencyStepper.integerValue = clamped
        return clamped
    }

    private func resolveRuntime() throws -> RuntimeConfiguration {
        try RuntimeResolver.resolve()
    }

    private func showError(_ message: String) {
        guard let window else {
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "操作失败"
        alert.informativeText = message
        alert.beginSheetModal(for: window)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else {
            return
        }

        if field == prefixField {
            updateNamingPreview()
            if detectorPayload != nil {
                refreshGeneratedJobs()
            }
            return
        }

        if field == cropField || field == skipStartField {
            if detectorPayload != nil {
                refreshGeneratedJobs()
            }
            return
        }

        if fadeLeftFields.values.contains(where: { $0 == field }) || fadeRightFields.values.contains(where: { $0 == field }) {
            if isProgrammaticallyUpdatingFadeFields {
                return
            }
            if detectorPayload != nil {
                parseVideo(field)
            }
            return
        }

        if field == outputDirectoryField {
            if isProgrammaticallyUpdatingOutputDirectoryField {
                return
            }
            outputDirectoryWasChosenManually = true
            updateNamingPreview()
            if detectorPayload != nil {
                refreshGeneratedJobs()
            }
            return
        }

        if field == concurrencyField {
            _ = currentConcurrency()
        }
    }

    @objc private func concurrencyStepperChanged(_ sender: NSStepper) {
        concurrencyField.stringValue = "\(sender.integerValue)"
    }

    @objc private func fadeStrategyRadioChanged(_ sender: NSButton) {
        let selectedIndex = sender.tag
        guard selectedIndex >= 0, selectedIndex < FadeRemovalStrategy.allCases.count else {
            return
        }
        let selectedStrategy = FadeRemovalStrategy.allCases[selectedIndex]
        for strategy in FadeRemovalStrategy.allCases {
            fadeStrategyButtons[strategy]?.state = strategy == selectedStrategy ? .on : .off
        }
        guard selectedVideoURL != nil else {
            statusLabel.stringValue = "Fade 删除策略已切换为 \(currentFadeRemovalStrategy().displayName)。"
            return
        }
        if detectorPayload != nil {
            parseVideo(sender)
        } else {
            statusLabel.stringValue = "Fade 删除策略已切换为 \(currentFadeRemovalStrategy().displayName)。"
        }
    }

    @objc private func selectVideo(_ sender: Any?) {
        guard let window else {
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            .mpeg4Movie,
            .quickTimeMovie,
            .movie,
            .audiovisualContent,
            .video,
        ]
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else {
                return
            }
            self.applyVideoURL(url)
        }
    }

    @objc private func selectOutputDirectory(_ sender: Any?) {
        guard let window else {
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = resolvedOutputDirectoryURL()
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else {
                return
            }
            self.applyOutputDirectoryURL(url, manual: true)
        }
    }

    @objc private func resetOutputDirectory(_ sender: Any?) {
        outputDirectoryWasChosenManually = false
        if let videoURL = selectedVideoURL {
            applyOutputDirectoryURL(videoURL.deletingLastPathComponent(), manual: false)
        } else {
            selectedOutputDirectoryURL = nil
            outputDirectoryField.stringValue = ""
            updateNamingPreview()
        }
    }

    @objc private func parseVideo(_ sender: Any?) {
        guard let videoURL = selectedVideoURL else {
            showError("请先选择视频文件，或直接拖入视频。")
            return
        }

        if let skipError = validateSkipStartIfNeeded() {
            showError(skipError)
            return
        }
        if let cropError = validateCropParametersIfNeeded() {
            showError(cropError)
            return
        }
        if let fadePaddingError = validateFadePaddingIfNeeded() {
            showError(fadePaddingError)
            return
        }

        guard let outputDirectoryURL = resolvedOutputDirectoryURL() else {
            showError("无法确定输出目录。")
            return
        }

        outputDirectoryField.stringValue = outputDirectoryURL.path
        parseButton.isEnabled = false
        splitButton.isEnabled = false
        statusLabel.stringValue = "解析中，请稍候..."

        do {
            let runtime = try resolveRuntime()
            let detector = DetectorService(runtime: runtime)
            let strategy = currentFadeRemovalStrategy()
            let padding = currentFadePaddingSettings(for: strategy)
            detector.detect(
                videoURL: videoURL,
                skipStartSeconds: currentSkipStartSeconds(),
                fadeRemovalStrategy: strategy,
                fadeLeftPaddingSeconds: padding.leftSeconds,
                fadeRightPaddingSeconds: padding.rightSeconds
            ) { result in
                DispatchQueue.main.async {
                    self.parseButton.isEnabled = true
                    switch result {
                    case .success(let payload):
                        self.detectorPayload = payload
                        self.refreshGeneratedJobs()
                        self.statusLabel.stringValue = "解析完成：\(payload.events.count) 个换场，\(payload.keepSegments.count) 个保留片段，Fade=\(strategy.displayName) L=\(String(format: "%.2f", padding.leftSeconds))s R=\(String(format: "%.2f", padding.rightSeconds))s。"
                    case .failure(let error):
                        self.clearDetectionResults()
                        self.statusLabel.stringValue = "解析失败。"
                        self.showError(error.localizedDescription)
                    }
                }
            }
        } catch {
            parseButton.isEnabled = true
            statusLabel.stringValue = "解析失败。"
            showError(error.localizedDescription)
        }
    }

    @objc private func splitVideo(_ sender: Any?) {
        guard splitCoordinator == nil else {
            return
        }

        guard !generatedJobs.isEmpty else {
            showError("当前没有可执行的 ffmpeg 任务，请先点击“解析”。")
            return
        }

        if let skipError = validateSkipStartIfNeeded() {
            showError(skipError)
            return
        }
        if let cropError = validateCropParametersIfNeeded() {
            showError(cropError)
            return
        }
        if let fadePaddingError = validateFadePaddingIfNeeded() {
            showError(fadePaddingError)
            return
        }

        do {
            let runtime = try resolveRuntime()
            guard let outputDirectoryURL = resolvedOutputDirectoryURL() else {
                throw AppRuntimeError.invalidDetectorOutput("无法确定输出目录。")
            }

            try FileManager.default.createDirectory(at: outputDirectoryURL, withIntermediateDirectories: true)
            refreshGeneratedJobs()

            let coordinator = SplitCoordinator(
                jobs: generatedJobs,
                concurrency: currentConcurrency(),
                runtime: runtime
            )
            coordinator.delegate = self
            splitCoordinator = coordinator

            parseButton.isEnabled = false
            splitButton.isEnabled = false
            statusLabel.stringValue = "开始分解..."
            coordinator.start()
        } catch {
            statusLabel.stringValue = "分解启动失败。"
            showError(error.localizedDescription)
        }
    }

    func splitCoordinatorDidStart(totalJobs: Int, workerCount: Int) {
        statusLabel.stringValue = "开始分解：\(totalJobs) 个任务，\(workerCount) 个并发窗口。"
    }

    func splitCoordinatorDidUpdate(completed: Int, failed: Int, total: Int) {
        statusLabel.stringValue = "分解中：完成 \(completed) / \(total)，失败 \(failed)。"
    }

    func splitCoordinatorDidFinish(completed: Int, failed: Int, total: Int) {
        splitCoordinator = nil
        parseButton.isEnabled = true
        updateSplitButtonState()
        statusLabel.stringValue = "分解完成：成功 \(completed) / \(total)，失败 \(failed)。"
        if failed > 0 {
            showError("共有 \(failed) 个 ffmpeg 任务失败，请检查子窗口日志。")
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        detectorPayload?.events.count ?? 0
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        highlightScriptRanges(forEventAt: eventTableView.selectedRow >= 0 ? eventTableView.selectedRow : nil)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard
            let event = detectorPayload?.events[row],
            let identifier = tableColumn?.identifier
        else {
            return nil
        }

        let cellIdentifier = NSUserInterfaceItemIdentifier("cell-\(identifier.rawValue)")
        let textField: NSTextField
        if let cell = tableView.makeView(withIdentifier: cellIdentifier, owner: nil) as? NSTextField {
            textField = cell
        } else {
            textField = NSTextField(labelWithString: "")
            textField.identifier = cellIdentifier
            textField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            textField.lineBreakMode = .byTruncatingTail
        }

        switch identifier.rawValue {
        case "index":
            textField.stringValue = "\(event.index)"
        case "type":
            textField.stringValue = event.type
        case "start":
            textField.stringValue = formatHMS(event.start)
        case "end":
            textField.stringValue = formatHMS(event.end)
        case "duration":
            textField.stringValue = formatShortSeconds(event.duration)
        case "source":
            textField.stringValue = event.source
        default:
            textField.stringValue = ""
        }
        return textField
    }
}
