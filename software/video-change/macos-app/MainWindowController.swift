import AppKit
import UniformTypeIdentifiers

final class MainWindowController: NSWindowController, NSTextFieldDelegate, SplitCoordinatorDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private static let defaultConcurrency = 5
    private static let fieldLabelColumnWidth: CGFloat = 68
    private static let outputDirectoryDefaultsKey = "VideoChange.lastOutputDirectoryPath"

    private enum PrefixLensMode: String, CaseIterable {
        case firstPerson = "第一视角"
        case thirdPerson = "第三视角"
        case selfie = "自拍"
        case fixed = "固定视角"
        case suggestive = "擦边"
    }

    private enum PrefixFaceMode: String, CaseIterable {
        case noFace = "无脸"
        case showFace = "露脸"
    }

    private enum ExportOperationKind {
        case split
        case validateTransitions

        var workerWindowTitlePrefix: String {
            switch self {
            case .split:
                return "分解任务"
            case .validateTransitions:
                return "验证片段任务"
            }
        }

        var initialStatusText: String {
            switch self {
            case .split:
                return "开始分解..."
            case .validateTransitions:
                return "开始导出验证片段..."
            }
        }

        var emptyJobsErrorMessage: String {
            switch self {
            case .split:
                return "当前分解片段无法生成可执行的 ffmpeg 任务，请检查开始时间、结束时间，或先点击“解析”获取视频时长。"
            case .validateTransitions:
                return "当前没有可导出的换场片段，请先点击“解析”。"
            }
        }

        var launchFailureStatusText: String {
            switch self {
            case .split:
                return "分解启动失败。"
            case .validateTransitions:
                return "验证片段导出启动失败。"
            }
        }

        func startStatusText(totalJobs: Int, workerCount: Int) -> String {
            switch self {
            case .split:
                return "开始分解：\(totalJobs) 个任务，\(workerCount) 个并发窗口。"
            case .validateTransitions:
                return "开始导出验证片段：\(totalJobs) 个任务，\(workerCount) 个并发窗口。"
            }
        }

        func updateStatusText(completed: Int, failed: Int, total: Int) -> String {
            switch self {
            case .split:
                return "分解中：完成 \(completed) / \(total)，失败 \(failed)。"
            case .validateTransitions:
                return "验证片段导出中：完成 \(completed) / \(total)，失败 \(failed)。"
            }
        }

        func finishStatusText(completed: Int, failed: Int, total: Int) -> String {
            switch self {
            case .split:
                return "分解完成：成功 \(completed) / \(total)，失败 \(failed)。"
            case .validateTransitions:
                return "验证片段导出完成：成功 \(completed) / \(total)，失败 \(failed)。"
            }
        }

        func failureAlertMessage(failed: Int) -> String {
            switch self {
            case .split:
                return "共有 \(failed) 个 ffmpeg 任务失败，请检查子窗口日志。"
            case .validateTransitions:
                return "共有 \(failed) 个验证片段导出任务失败，请检查子窗口日志。"
            }
        }
    }

    private let videoPathField = DroppablePathField(acceptKind: .file)
    private let outputDirectoryField = DroppablePathField(acceptKind: .directory)
    private let customPrefixField = NSTextField()
    private let concurrencyField = NSTextField()
    private let concurrencyStepper = NSStepper()
    private let skipStartField = NSTextField()
    private let cropField = NSTextField()
    private let fadeStrategyStack = NSStackView()
    private let prefixLensModeStack = NSStackView()
    private let prefixFaceModeStack = NSStackView()
    private let prefixDateLabel = NSTextField(labelWithString: "")
    private var fadeStrategyButtons: [FadeRemovalStrategy: NSButton] = [:]
    private var fadeLeftFields: [FadeRemovalStrategy: NSTextField] = [:]
    private var fadeRightFields: [FadeRemovalStrategy: NSTextField] = [:]
    private var prefixLensButtons: [PrefixLensMode: NSButton] = [:]
    private var prefixFaceButtons: [PrefixFaceMode: NSButton] = [:]
    private let namingPreviewLabel = NSTextField(labelWithString: "未选择视频")
    private let statusLabel = NSTextField(labelWithString: "请选择视频文件，或直接拖入。")

    private let parseButton = NSButton(title: "解析", target: nil, action: nil)
    private let stopButton = NSButton(title: "停止", target: nil, action: nil)
    private let splitButton = NSButton(title: "分解", target: nil, action: nil)
    private let validateTransitionsButton = NSButton(title: "验证导出", target: nil, action: nil)

    private let summaryLabel = NSTextField(labelWithString: "等待解析")
    private let eventTableView = NSTableView()
    private let segmentTableView = NSTableView()
    private let segmentMasterCheckbox = NSButton(checkboxWithTitle: "全选", target: nil, action: nil)
    private let addSegmentButton = NSButton(title: "追加行", target: nil, action: nil)

    private var selectedVideoURL: URL?
    private var selectedOutputDirectoryURL: URL?
    private var outputDirectoryWasChosenManually = false
    private var isProgrammaticallyUpdatingOutputDirectoryField = false
    private var isProgrammaticallyUpdatingVideoField = false
    private var isProgrammaticallyUpdatingFadeFields = false
    private var detectorPayload: DetectorPayload?
    private var selectableEvents: [SelectableTransitionEvent] = []
    private var automaticSegmentEnabledPreferences: [Int: Bool] = [:]
    private var editableSegments: [EditableSegment] = []
    private var generatedJobs: [FFmpegJob] = []
    private var splitCoordinator: SplitCoordinator?
    private var activeExportOperation: ExportOperationKind?
    private var hoveredManualSegmentRow: Int?
    private var detectorCancellation: DetectorCancellation?
    private var workerWindowControllers: [WorkerWindowController] = []
    private var probedVideoDuration: Double?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Video Change"
        if #available(macOS 13.0, *) {
            window.subtitle = "识别换场，生成脚本，并按并发窗口执行分解。"
        }
        window.minSize = NSSize(width: 760, height: 560)
        super.init(window: window)
        buildUI()
        restorePersistedOutputDirectory()
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

        configureInputField(videoPathField, placeholder: "拖入视频文件，或点击右侧按钮选择")
        configureInputField(outputDirectoryField, placeholder: "默认使用视频所在目录，也可拖入文件夹或手工输入")
        outputDirectoryField.isEditable = true
        outputDirectoryField.isSelectable = true

        customPrefixField.placeholderString = "用户自定义内容"
        customPrefixField.font = .systemFont(ofSize: 15)
        customPrefixField.delegate = self

        concurrencyField.stringValue = "\(Self.defaultConcurrency)"
        concurrencyField.alignment = .center
        concurrencyField.font = .systemFont(ofSize: 15, weight: .medium)
        concurrencyField.delegate = self
        concurrencyField.translatesAutoresizingMaskIntoConstraints = false
        concurrencyField.widthAnchor.constraint(equalToConstant: 92).isActive = true

        concurrencyStepper.minValue = 1
        concurrencyStepper.maxValue = 12
        concurrencyStepper.integerValue = Self.defaultConcurrency
        concurrencyStepper.increment = 1
        concurrencyStepper.target = self
        concurrencyStepper.action = #selector(concurrencyStepperChanged(_:))

        parseButton.bezelStyle = .rounded
        parseButton.font = .systemFont(ofSize: 15, weight: .semibold)
        parseButton.isBordered = true
        parseButton.bezelColor = .systemBlue
        parseButton.target = self
        parseButton.action = #selector(parseVideo(_:))

        stopButton.bezelStyle = .rounded
        stopButton.font = .systemFont(ofSize: 15, weight: .semibold)
        stopButton.isBordered = true
        stopButton.bezelColor = .systemRed
        stopButton.target = self
        stopButton.action = #selector(stopAllProcessing(_:))
        stopButton.isEnabled = false

        splitButton.bezelStyle = .rounded
        splitButton.font = .systemFont(ofSize: 15, weight: .semibold)
        splitButton.isBordered = true
        splitButton.bezelColor = .systemGreen
        splitButton.target = self
        splitButton.action = #selector(splitVideo(_:))

        validateTransitionsButton.bezelStyle = .rounded
        validateTransitionsButton.font = .systemFont(ofSize: 13, weight: .semibold)
        validateTransitionsButton.target = self
        validateTransitionsButton.action = #selector(exportValidationTransitions(_:))

        configureSmallField(skipStartField, placeholder: "0")
        skipStartField.stringValue = "0"
        configureLargeField(cropField, placeholder: "1728:910:0:85")
        configurePrefixControls()
        configureFadeStrategyControls()

        statusLabel.font = .systemFont(ofSize: 14)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 2
        statusLabel.lineBreakMode = .byWordWrapping

        namingPreviewLabel.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        namingPreviewLabel.textColor = .secondaryLabelColor
        namingPreviewLabel.lineBreakMode = .byTruncatingMiddle
        namingPreviewLabel.toolTip = namingPreviewLabel.stringValue

        videoPathField.onURLDropped = { [weak self] url in
            self?.applyVideoURL(url)
        }
        outputDirectoryField.onURLDropped = { [weak self] url in
            self?.applyOutputDirectoryURL(url, manual: true)
        }

        configureEventTable()
        configureSegmentTable()

        let controlsPanel = buildControlsPanel()
        let resultPanel = buildResultPanel()
        let scriptPanel = buildScriptPanel()

        controlsPanel.translatesAutoresizingMaskIntoConstraints = false
        resultPanel.translatesAutoresizingMaskIntoConstraints = false
        scriptPanel.translatesAutoresizingMaskIntoConstraints = false
        controlsPanel.widthAnchor.constraint(equalToConstant: 500).isActive = true
        resultPanel.widthAnchor.constraint(greaterThanOrEqualToConstant: 516).isActive = true
        scriptPanel.widthAnchor.constraint(equalToConstant: 400).isActive = true
        controlsPanel.setContentHuggingPriority(.required, for: .horizontal)
        controlsPanel.setContentCompressionResistancePriority(.required, for: .horizontal)
        resultPanel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        resultPanel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        scriptPanel.setContentHuggingPriority(.required, for: .horizontal)
        scriptPanel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let contentRow = NSStackView(views: [controlsPanel, resultPanel, scriptPanel])
        contentRow.orientation = .horizontal
        contentRow.spacing = 18
        contentRow.alignment = .top
        contentRow.distribution = .fill
        contentRow.translatesAutoresizingMaskIntoConstraints = false

        let rootStack = NSStackView()
        rootStack.orientation = .vertical
        rootStack.spacing = 0
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        rootStack.addArrangedSubview(contentRow)

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.documentView = rootStack
        scrollView.autohidesScrollers = true

        contentView.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            rootStack.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor, constant: 22),
            rootStack.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor, constant: -22),
            rootStack.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor, constant: 12),
            rootStack.bottomAnchor.constraint(equalTo: scrollView.contentView.bottomAnchor, constant: -22),
            rootStack.widthAnchor.constraint(greaterThanOrEqualToConstant: 1352),
            contentRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 560),
            controlsPanel.heightAnchor.constraint(greaterThanOrEqualToConstant: 560),
            resultPanel.heightAnchor.constraint(greaterThanOrEqualToConstant: 560),
            scriptPanel.heightAnchor.constraint(greaterThanOrEqualToConstant: 560),
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
            [makeFieldLabel("输出前缀"), buildPrefixEditor()],
            [makeFieldLabel("画面裁剪"), cropRow],
            [makeFieldLabel("跳过检测"), skipRow],
            [makeFieldLabel("Fade 删除"), fadeStrategyRow],
            [makeFieldLabel("命名预览"), namingPreviewLabel],
            [makeFieldLabel("并发窗口"), makeHorizontalRow([concurrencyField, concurrencyStepper, makeHintLabel("默认 5 个子窗口并发执行")])],
            [makeFieldLabel("状态"), statusLabel],
        ])
        formGrid.translatesAutoresizingMaskIntoConstraints = false
        formGrid.rowSpacing = 14
        formGrid.columnSpacing = 12
        formGrid.column(at: 0).xPlacement = .trailing
        formGrid.column(at: 1).xPlacement = .fill

        let actionStack = NSStackView(views: [parseButton, stopButton, splitButton])
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
        let subtitle = NSTextField(labelWithString: "支持取消误判换场；取消后会同步合并下方分解片段。")
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor

        summaryLabel.font = .systemFont(ofSize: 14, weight: .medium)
        summaryLabel.textColor = .secondaryLabelColor

        let scrollView = makeTableScrollView(for: eventTableView)

        let titleRow = NSStackView(views: [title, validateTransitionsButton])
        titleRow.orientation = .horizontal
        titleRow.spacing = 12
        titleRow.alignment = .centerY

        let headerStack = NSStackView(views: [titleRow, subtitle, summaryLabel])
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

        let title = makeSectionTitle("分解片段")
        let subtitle = NSTextField(labelWithString: "显示启用、开始时间、结束时间和时长；支持手动修改和禁用。")
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor

        segmentMasterCheckbox.font = .systemFont(ofSize: 13, weight: .medium)
        segmentMasterCheckbox.target = self
        segmentMasterCheckbox.action = #selector(segmentMasterCheckboxChanged(_:))

        addSegmentButton.bezelStyle = .rounded
        addSegmentButton.font = .systemFont(ofSize: 13, weight: .medium)
        addSegmentButton.target = self
        addSegmentButton.action = #selector(addSegmentRow(_:))
        addSegmentButton.bezelColor = .systemGreen

        let scrollView = makeTableScrollView(for: segmentTableView)

        let titleRow = NSStackView(views: [title, addSegmentButton, segmentMasterCheckbox])
        titleRow.orientation = .horizontal
        titleRow.spacing = 12
        titleRow.alignment = .centerY

        let headerStack = NSStackView(views: [titleRow, subtitle])
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

    private func configurePrefixControls() {
        prefixDateLabel.font = .systemFont(ofSize: 15, weight: .medium)
        prefixDateLabel.textColor = .secondaryLabelColor
        prefixDateLabel.stringValue = currentSystemDateString()

        prefixLensModeStack.orientation = .horizontal
        prefixLensModeStack.spacing = 8
        prefixLensModeStack.alignment = .centerY

        prefixFaceModeStack.orientation = .horizontal
        prefixFaceModeStack.spacing = 8
        prefixFaceModeStack.alignment = .centerY

        for mode in PrefixLensMode.allCases {
            let button = NSButton(radioButtonWithTitle: mode.rawValue, target: self, action: #selector(prefixLensModeChanged(_:)))
            button.font = .systemFont(ofSize: 14, weight: .medium)
            button.tag = PrefixLensMode.allCases.firstIndex(of: mode) ?? 0
            button.state = mode == .firstPerson ? .on : .off
            prefixLensButtons[mode] = button
            prefixLensModeStack.addArrangedSubview(button)
        }

        for mode in PrefixFaceMode.allCases {
            let button = NSButton(radioButtonWithTitle: mode.rawValue, target: self, action: #selector(prefixFaceModeChanged(_:)))
            button.font = .systemFont(ofSize: 14, weight: .medium)
            button.tag = PrefixFaceMode.allCases.firstIndex(of: mode) ?? 0
            button.state = mode == .noFace ? .on : .off
            prefixFaceButtons[mode] = button
            prefixFaceModeStack.addArrangedSubview(button)
        }
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
        eventTableView.columnAutoresizingStyle = .noColumnAutoresizing
        eventTableView.delegate = self
        eventTableView.dataSource = self

        let columns: [(String, String, CGFloat)] = [
            ("selected", "选中", 54),
            ("index", "#", 44),
            ("type", "类型", 72),
            ("start", "开始时间", 118),
            ("end", "结束时间", 118),
            ("duration", "时长", 76),
            ("source", "来源", 140),
        ]

        for (identifier, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            column.minWidth = width
            column.maxWidth = 480
            column.resizingMask = .userResizingMask
            eventTableView.addTableColumn(column)
        }
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

    private func configureSegmentTable() {
        segmentTableView.headerView = NSTableHeaderView()
        segmentTableView.usesAlternatingRowBackgroundColors = true
        segmentTableView.rowHeight = 34
        segmentTableView.intercellSpacing = NSSize(width: 8, height: 4)
        segmentTableView.columnAutoresizingStyle = .noColumnAutoresizing
        segmentTableView.delegate = self
        segmentTableView.dataSource = self
        segmentTableView.allowsMultipleSelection = true

        let columns: [(String, String, CGFloat)] = [
            ("enabled", "启用", 62),
            ("start", "开始时间", 102),
            ("end", "结束时间", 102),
            ("duration", "时长", 78),
        ]

        for (identifier, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            column.minWidth = width
            column.maxWidth = 320
            column.resizingMask = .userResizingMask
            segmentTableView.addTableColumn(column)
        }
    }

    private func highlightSegmentRows(forEventAt row: Int?) {
        guard
            let row,
            row >= 0,
            row < selectableEvents.count
        else {
            segmentTableView.deselectAll(nil)
            return
        }

        let event = selectableEvents[row].event
        let relatedIndices = Set(relatedKeepSegmentIndices(for: event))
        let rowIndexes = IndexSet(
            editableSegments.enumerated().compactMap { index, segment in
                !relatedIndices.isDisjoint(with: segment.sourceKeepSegmentIndices) ? index : nil
            }
        )

        guard !rowIndexes.isEmpty else {
            segmentTableView.deselectAll(nil)
            return
        }

        segmentTableView.selectRowIndexes(rowIndexes, byExtendingSelection: false)
        if let first = rowIndexes.first {
            segmentTableView.scrollRowToVisible(first)
        }
    }

    private func selectedTransitionEvents() -> [TransitionEvent] {
        selectableEvents.compactMap { item in
            item.isSelected ? item.event : nil
        }
    }

    private func updateSummaryText() {
        if detectorPayload != nil {
            let totalEvents = selectableEvents.count
            let selectedEventsCount = selectedTransitionEvents().count
            let selectedEventsLabel = totalEvents == selectedEventsCount
                ? "\(totalEvents)"
                : "\(selectedEventsCount) / \(totalEvents)"
            let effectiveSegmentCount = editableSegments.filter(\.isUserToggleable).count
            summaryLabel.stringValue = "换场 \(selectedEventsLabel) 个，保留片段 \(effectiveSegmentCount) 个"
        } else if !editableSegments.isEmpty {
            summaryLabel.stringValue = "手动片段 \(editableSegments.count) 个"
        } else {
            summaryLabel.stringValue = "等待解析"
        }
    }

    private func relatedKeepSegmentIndices(for event: TransitionEvent) -> [Int] {
        let neighbors = adjacentKeepSegments(for: event)
        var indices: [Int] = []
        if let before = neighbors.before {
            indices.append(before.index)
        }
        if let after = neighbors.after, !indices.contains(after.index) {
            indices.append(after.index)
        }
        return indices
    }

    private func adjacentKeepSegments(for event: TransitionEvent) -> (before: KeepSegment?, after: KeepSegment?) {
        guard let payload = detectorPayload else {
            return (nil, nil)
        }

        let epsilon = 0.0005
        var exactBefore: KeepSegment?
        var exactAfter: KeepSegment?
        var closestBefore: (segment: KeepSegment, gap: Double)?
        var closestAfter: (segment: KeepSegment, gap: Double)?

        for segment in payload.keepSegments {
            if abs(segment.end - event.start) <= epsilon {
                exactBefore = segment
            } else if segment.end <= event.start {
                let gap = event.start - segment.end
                if closestBefore == nil || gap < closestBefore!.gap {
                    closestBefore = (segment, gap)
                }
            }

            if abs(segment.start - event.end) <= epsilon {
                exactAfter = segment
            } else if segment.start >= event.end {
                let gap = segment.start - event.end
                if closestAfter == nil || gap < closestAfter!.gap {
                    closestAfter = (segment, gap)
                }
            }
        }

        return (
            exactBefore ?? closestBefore?.segment,
            exactAfter ?? closestAfter?.segment
        )
    }

    private func resetAutomaticSegmentEnabledPreferences(from segments: [EditableSegment]) {
        automaticSegmentEnabledPreferences = [:]
        for segment in segments where segment.isAutomatic {
            for sourceIndex in segment.sourceKeepSegmentIndices {
                automaticSegmentEnabledPreferences[sourceIndex] = segment.isEnabled
            }
        }
    }

    private func buildAutomaticSegment(rowIndex: Int, sourceKeepSegmentIndices: [Int], isEnabled: Bool, isMergedFollower: Bool) -> EditableSegment? {
        guard let payload = detectorPayload else {
            return nil
        }

        let uniqueSortedIndices = Array(Set(sourceKeepSegmentIndices)).sorted()
        guard
            let firstIndex = uniqueSortedIndices.first,
            let lastIndex = uniqueSortedIndices.last
        else {
            return nil
        }

        let keepSegmentsByIndex = Dictionary(uniqueKeysWithValues: payload.keepSegments.map { ($0.index, $0) })
        guard
            let firstSegment = keepSegmentsByIndex[firstIndex],
            let lastSegment = keepSegmentsByIndex[lastIndex]
        else {
            return nil
        }

        let editable = EditableSegment(
            index: rowIndex,
            isEnabled: isEnabled,
            start: firstSegment.start,
            end: lastSegment.end,
            isManual: false,
            sourceKeepSegmentIndices: uniqueSortedIndices,
            isMergedFollower: isMergedFollower
        )
        return EditableSegment(
            index: editable.index,
            isEnabled: !isMergedFollower && isEnabled && editable.shouldDefaultEnable(videoDuration: payload.duration),
            start: editable.start,
            end: editable.end,
            isManual: editable.isManual,
            sourceKeepSegmentIndices: editable.sourceKeepSegmentIndices,
            isMergedFollower: editable.isMergedFollower
        )
    }

    private func deselectedTransitionBoundaryKeys() -> Set<String> {
        var keys = Set<String>()
        for selectableEvent in selectableEvents where !selectableEvent.isSelected {
            let neighbors = adjacentKeepSegments(for: selectableEvent.event)
            guard let beforeIndex = neighbors.before?.index, let afterIndex = neighbors.after?.index else {
                continue
            }
            keys.insert(boundaryKey(beforeIndex: beforeIndex, afterIndex: afterIndex))
        }
        return keys
    }

    private func boundaryKey(beforeIndex: Int, afterIndex: Int) -> String {
        "\(beforeIndex)->\(afterIndex)"
    }

    private func preferredEnabledState(for sourceKeepSegmentIndices: [Int]) -> Bool {
        sourceKeepSegmentIndices.contains { automaticSegmentEnabledPreferences[$0] ?? true }
    }

    private func rebuildAutomaticSegmentsFromSelection() {
        guard let payload = detectorPayload else {
            return
        }

        let manualSegments = editableSegments.filter(\.isManual)
        let keepSegments = payload.keepSegments.sorted { $0.index < $1.index }
        guard !keepSegments.isEmpty else {
            editableSegments = manualSegments
            return
        }

        if automaticSegmentEnabledPreferences.isEmpty {
            let initialSegments = buildEditableSegments(payload: payload)
            resetAutomaticSegmentEnabledPreferences(from: initialSegments)
        }

        let mergedBoundaryKeys = deselectedTransitionBoundaryKeys()
        var groups: [[KeepSegment]] = []
        var currentGroup: [KeepSegment] = []

        for segment in keepSegments {
            if currentGroup.isEmpty {
                currentGroup = [segment]
                continue
            }

            let previousSegment = currentGroup[currentGroup.count - 1]
            if mergedBoundaryKeys.contains(boundaryKey(beforeIndex: previousSegment.index, afterIndex: segment.index)) {
                currentGroup.append(segment)
            } else {
                groups.append(currentGroup)
                currentGroup = [segment]
            }
        }

        if !currentGroup.isEmpty {
            groups.append(currentGroup)
        }

        var automaticSegments: [EditableSegment] = []
        for group in groups {
            let sourceIndices = group.map(\.index)
            let leaderIndex = group[0].index
            if let leaderSegment = buildAutomaticSegment(
                rowIndex: leaderIndex,
                sourceKeepSegmentIndices: sourceIndices,
                isEnabled: preferredEnabledState(for: sourceIndices),
                isMergedFollower: false
            ) {
                automaticSegments.append(leaderSegment)
            }

            for follower in group.dropFirst() {
                if let followerSegment = buildAutomaticSegment(
                    rowIndex: follower.index,
                    sourceKeepSegmentIndices: [follower.index],
                    isEnabled: false,
                    isMergedFollower: true
                ) {
                    automaticSegments.append(followerSegment)
                }
            }
        }

        editableSegments = automaticSegments + manualSegments
    }

    private func applyEventSelectionChange(at row: Int, isSelected: Bool) {
        guard row >= 0, row < selectableEvents.count else {
            return
        }

        let event = selectableEvents[row].event
        let neighbors = adjacentKeepSegments(for: event)
        guard
            neighbors.before?.index != nil,
            neighbors.after?.index != nil
        else {
            rebuildJobsFromEditableSegments(autoDisableInvalidSegments: true)
            return
        }

        selectableEvents[row].isSelected = isSelected
        rebuildAutomaticSegmentsFromSelection()
        rebuildJobsFromEditableSegments(autoDisableInvalidSegments: true)
    }

    private func makeSectionTitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 19, weight: .semibold)
        return label
    }

    private func makeFieldLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: Self.fieldLabelColumnWidth).isActive = true
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        return label
    }

    private func makeFullWidthFieldSection(_ text: String, content: NSView) -> NSView {
        let label = makeFieldLabel(text)
        let row = makeHorizontalRow([label, content])
        row.alignment = .top
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        content.setContentHuggingPriority(.defaultLow, for: .horizontal)
        content.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return row
    }

    private func makeHintLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func segmentTextColor(_ segment: EditableSegment) -> NSColor {
        if segment.isMergedFollower {
            return .tertiaryLabelColor
        }
        if !segment.isEnabled {
            return .secondaryLabelColor
        }
        return .labelColor
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

    private func buildPrefixEditor() -> NSView {
        let stack = NSStackView(views: [
            prefixLensModeStack,
            makePrefixSeparatorLabel(),
            prefixFaceModeStack,
            makePrefixSeparatorLabel(),
            customPrefixField,
            makePrefixSeparatorLabel(),
            makeHorizontalRow([prefixDateLabel, makeHintLabel("末尾自动拼接两位编号")]),
        ])
        stack.orientation = .vertical
        stack.spacing = 6
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func makePrefixSeparatorLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "-")
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func currentSystemDateString() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: Date())
    }

    private func currentPrefixLensMode() -> PrefixLensMode {
        for mode in PrefixLensMode.allCases where prefixLensButtons[mode]?.state == .on {
            return mode
        }
        return .firstPerson
    }

    private func currentPrefixFaceMode() -> PrefixFaceMode {
        for mode in PrefixFaceMode.allCases where prefixFaceButtons[mode]?.state == .on {
            return mode
        }
        return .noFace
    }

    private func currentOutputPrefix() -> String {
        let parts = [
            currentPrefixLensMode().rawValue,
            currentPrefixFaceMode().rawValue,
            customPrefixField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            prefixDateLabel.stringValue,
        ]
        return parts.joined(separator: "-")
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

    private func persistOutputDirectoryPath(_ path: String?) {
        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let defaults = UserDefaults.standard
        if trimmed.isEmpty {
            defaults.removeObject(forKey: Self.outputDirectoryDefaultsKey)
        } else {
            defaults.set(trimmed, forKey: Self.outputDirectoryDefaultsKey)
        }
    }

    private func restorePersistedOutputDirectory() {
        let defaults = UserDefaults.standard
        guard
            let path = defaults.string(forKey: Self.outputDirectoryDefaultsKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !path.isEmpty
        else {
            return
        }

        outputDirectoryWasChosenManually = true
        selectedOutputDirectoryURL = URL(fileURLWithPath: path, isDirectory: true)
        isProgrammaticallyUpdatingOutputDirectoryField = true
        outputDirectoryField.stringValue = path
        isProgrammaticallyUpdatingOutputDirectoryField = false
    }

    private func applyVideoURL(_ url: URL) {
        selectedVideoURL = url
        isProgrammaticallyUpdatingVideoField = true
        videoPathField.stringValue = url.path
        isProgrammaticallyUpdatingVideoField = false

        if !outputDirectoryWasChosenManually, selectedOutputDirectoryURL != nil {
            applyOutputDirectoryURL(url.deletingLastPathComponent(), manual: false)
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
        persistOutputDirectoryPath(url.path)
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
        if editableSegments.isEmpty, let detectorPayload, selectableEvents.isEmpty {
            selectableEvents = buildSelectableTransitionEvents(payload: detectorPayload)
            editableSegments = buildEditableSegments(payload: detectorPayload)
            resetAutomaticSegmentEnabledPreferences(from: editableSegments)
        }

        guard let selectedVideoURL, let outputDirectoryURL = resolvedOutputDirectoryURL() else {
            generatedJobs = []
            segmentTableView.reloadData()
            updateSegmentMasterCheckboxState()
            updateSplitButtonState()
            updateNamingPreview()
            updateSummaryText()
            return
        }

        generatedJobs = buildJobs(
            segments: editableSegments,
            videoURL: selectedVideoURL,
            outputDirectoryURL: outputDirectoryURL,
            prefix: currentOutputPrefix(),
            crop: currentCropParameters(),
            videoDuration: effectiveVideoDuration()
        )

        updateSummaryText()
        eventTableView.reloadData()
        segmentTableView.reloadData()
        updateSegmentMasterCheckboxState()
        highlightSegmentRows(forEventAt: eventTableView.selectedRow >= 0 ? eventTableView.selectedRow : nil)
        updateSplitButtonState()
        updateNamingPreview()
    }

    private func updateSplitButtonState() {
        splitButton.isEnabled = splitCoordinator == nil && !editableSegments.isEmpty
        validateTransitionsButton.isEnabled = splitCoordinator == nil && !selectedTransitionEvents().isEmpty
        addSegmentButton.isEnabled = splitCoordinator == nil
        stopButton.isEnabled = true
    }

    private func updateNamingPreview() {
        let extensionName = selectedVideoURL?.pathExtension ?? "mp4"
        let fallbackPrefix = selectedVideoURL?.deletingPathExtension().lastPathComponent ?? "clip"
        prefixDateLabel.stringValue = currentSystemDateString()
        let safePrefix = sanitizePrefix(currentOutputPrefix(), fallback: fallbackPrefix)
        let sampleName = makeOutputFileName(
            prefix: safePrefix,
            index: 1,
            totalCount: max(1, generatedJobs.count),
            pathExtension: extensionName
        )
        if let outputDirectoryURL = resolvedOutputDirectoryURL() {
            namingPreviewLabel.stringValue = outputDirectoryURL.appendingPathComponent(sampleName).path
        } else {
            namingPreviewLabel.stringValue = sampleName
        }
        namingPreviewLabel.toolTip = namingPreviewLabel.stringValue
    }

    private func effectiveVideoDuration() -> Double? {
        detectorPayload?.duration ?? probedVideoDuration
    }

    private func ensureVideoDurationAvailable(runtime: RuntimeConfiguration, videoURL: URL) throws -> Double? {
        if let duration = effectiveVideoDuration() {
            return duration
        }
        let duration = try MediaProbeService(runtime: runtime).resolveDuration(videoURL: videoURL)
        probedVideoDuration = duration
        return duration
    }

    private func clearDetectionResults() {
        detectorPayload = nil
        selectableEvents = []
        automaticSegmentEnabledPreferences = [:]
        probedVideoDuration = nil
        editableSegments = []
        generatedJobs = []
        hoveredManualSegmentRow = nil
        summaryLabel.stringValue = "等待解析"
        eventTableView.reloadData()
        segmentTableView.reloadData()
        updateSegmentMasterCheckboxState()
        updateSplitButtonState()
    }

    private func rebuildJobsFromEditableSegments(autoDisableInvalidSegments: Bool = false) {
        if autoDisableInvalidSegments {
            normalizeSegmentEnabledStates()
        }
        refreshGeneratedJobs()
    }

    private func normalizeSegmentEnabledStates() {
        let videoDuration = effectiveVideoDuration()
        for index in editableSegments.indices {
            if editableSegments[index].isMergedFollower {
                editableSegments[index].isEnabled = false
                continue
            }
            if !editableSegments[index].shouldDefaultEnable(videoDuration: videoDuration) {
                editableSegments[index].isEnabled = false
                if editableSegments[index].isAutomatic {
                    for sourceIndex in editableSegments[index].sourceKeepSegmentIndices {
                        automaticSegmentEnabledPreferences[sourceIndex] = false
                    }
                }
            }
        }
    }

    private func updateSegmentMasterCheckboxState() {
        let toggleableSegments = editableSegments.filter(\.isUserToggleable)
        guard !toggleableSegments.isEmpty else {
            segmentMasterCheckbox.state = .off
            segmentMasterCheckbox.isEnabled = false
            return
        }

        segmentMasterCheckbox.isEnabled = true
        let enabledCount = toggleableSegments.filter(\.isEnabled).count
        if enabledCount == 0 {
            segmentMasterCheckbox.state = .off
        } else if enabledCount == toggleableSegments.count {
            segmentMasterCheckbox.state = .on
        } else {
            segmentMasterCheckbox.state = .mixed
        }
    }

    @objc private func eventSelectedChanged(_ sender: NSButton) {
        let row = sender.tag
        guard row >= 0, row < selectableEvents.count else {
            return
        }

        let isSelected = sender.state == .on
        applyEventSelectionChange(at: row, isSelected: isSelected)
    }

    @objc private func segmentEnabledChanged(_ sender: NSButton) {
        let row = sender.tag
        guard row >= 0, row < editableSegments.count, editableSegments[row].isUserToggleable else {
            return
        }
        let isEnabled = sender.state == .on
        editableSegments[row].isEnabled = isEnabled
        if editableSegments[row].isAutomatic {
            for sourceIndex in editableSegments[row].sourceKeepSegmentIndices {
                automaticSegmentEnabledPreferences[sourceIndex] = isEnabled
            }
        }
        rebuildJobsFromEditableSegments()
    }

    @objc private func segmentMasterCheckboxChanged(_ sender: NSButton) {
        guard editableSegments.contains(where: \.isUserToggleable) else {
            updateSegmentMasterCheckboxState()
            return
        }

        let shouldEnableAll = sender.state != .off
        for index in editableSegments.indices {
            guard editableSegments[index].isUserToggleable else {
                editableSegments[index].isEnabled = false
                continue
            }
            editableSegments[index].isEnabled = shouldEnableAll
            if editableSegments[index].isAutomatic {
                for sourceIndex in editableSegments[index].sourceKeepSegmentIndices {
                    automaticSegmentEnabledPreferences[sourceIndex] = shouldEnableAll
                }
            }
        }
        rebuildJobsFromEditableSegments()
    }

    @objc private func addSegmentRow(_ sender: Any?) {
        let nextIndex = (editableSegments.map(\.index).max() ?? -1) + 1
        let maxDuration = effectiveVideoDuration()
        let lastEnd = editableSegments.last?.resolvedEnd(videoDuration: maxDuration) ?? 0.0
        let start = min(maxDuration ?? .greatestFiniteMagnitude, max(0.0, lastEnd))
        let rawEnd = min(maxDuration ?? .greatestFiniteMagnitude, start + 1.0)
        let end = rawEnd > start ? rawEnd : start + 0.001

        editableSegments.append(
            EditableSegment(
                index: nextIndex,
                isEnabled: end > start,
                start: start,
                end: end,
                isManual: true,
                sourceKeepSegmentIndices: [],
                isMergedFollower: false
            )
        )
        rebuildJobsFromEditableSegments()

        let row = editableSegments.count - 1
        if row >= 0 {
            segmentTableView.scrollRowToVisible(row)
            segmentTableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }

    @objc private func deleteManualSegmentRow(_ sender: NSButton) {
        let row = sender.tag
        guard row >= 0, row < editableSegments.count, editableSegments[row].isManual else {
            return
        }
        editableSegments.remove(at: row)
        hoveredManualSegmentRow = nil
        rebuildJobsFromEditableSegments()
    }

    @objc private func segmentTimeFieldChanged(_ sender: SegmentTimeField) {
        let row = sender.segmentRow
        guard row >= 0, row < editableSegments.count else {
            return
        }
        guard !editableSegments[row].isMergedFollower else {
            sender.stringValue = sender.kind == .start
                ? formatSegmentStartHMS(editableSegments[row].start)
                : formatOptionalSegmentEndHMS(editableSegments[row].end)
            return
        }

        let videoDuration = detectorPayload?.duration
        let fallbackDuration = effectiveVideoDuration()
        let trimmed = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        if sender.kind == .end, trimmed.isEmpty {
            editableSegments[row].end = nil
            rebuildJobsFromEditableSegments(autoDisableInvalidSegments: true)
            segmentTableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 2))
            return
        }

        guard let parsed = parseHMS(trimmed) else {
            sender.stringValue = sender.kind == .start
                ? formatSegmentStartHMS(editableSegments[row].start)
                : formatOptionalSegmentEndHMS(editableSegments[row].end)
            showError("时间格式应为 时:分:秒.毫秒，例如 00:01:23.456。")
            return
        }

        switch sender.kind {
        case .start:
            editableSegments[row].start = parsed
            if let currentEnd = editableSegments[row].resolvedEnd(videoDuration: videoDuration ?? fallbackDuration), parsed >= currentEnd {
                editableSegments[row].end = parsed + 60.0
            }
        case .end:
            guard parsed > editableSegments[row].start else {
                sender.stringValue = formatOptionalSegmentEndHMS(editableSegments[row].end)
                showError("结束时间必须大于开始时间。")
                return
            }
            editableSegments[row].end = parsed
        }

        rebuildJobsFromEditableSegments(autoDisableInvalidSegments: true)
    }

    private func currentConcurrency() -> Int {
        let parsed = Int(concurrencyField.stringValue) ?? Self.defaultConcurrency
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

        if field == videoPathField {
            if isProgrammaticallyUpdatingVideoField {
                return
            }
            let typed = videoPathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !typed.isEmpty else {
                selectedVideoURL = nil
                clearDetectionResults()
                updateNamingPreview()
                statusLabel.stringValue = "请输入视频文件路径，或直接拖入视频。"
                return
            }

            let url = URL(fileURLWithPath: typed)
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            if exists && !isDirectory.boolValue {
                selectedVideoURL = url
                if !outputDirectoryWasChosenManually, selectedOutputDirectoryURL != nil {
                    applyOutputDirectoryURL(url.deletingLastPathComponent(), manual: false)
                }
                if detectorPayload != nil {
                    clearDetectionResults()
                }
                updateNamingPreview()
                statusLabel.stringValue = "视频路径已更新，点击“解析”生成结果和脚本。"
            } else {
                selectedVideoURL = nil
                clearDetectionResults()
                updateNamingPreview()
                statusLabel.stringValue = "当前视频路径无效，请检查文件是否存在。"
            }
            return
        }

        if field == customPrefixField {
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
            let typed = outputDirectoryField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if typed.isEmpty {
                outputDirectoryWasChosenManually = false
                selectedOutputDirectoryURL = nil
                persistOutputDirectoryPath(nil)
            } else {
                outputDirectoryWasChosenManually = true
                selectedOutputDirectoryURL = URL(fileURLWithPath: typed, isDirectory: true)
                persistOutputDirectoryPath(typed)
            }
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

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else {
            return
        }

        if let segmentField = field as? SegmentTimeField {
            segmentTimeFieldChanged(segmentField)
        }
    }

    @objc private func concurrencyStepperChanged(_ sender: NSStepper) {
        concurrencyField.stringValue = "\(sender.integerValue)"
    }

    @objc private func prefixLensModeChanged(_ sender: NSButton) {
        let selectedIndex = sender.tag
        guard selectedIndex >= 0, selectedIndex < PrefixLensMode.allCases.count else {
            return
        }
        let selectedMode = PrefixLensMode.allCases[selectedIndex]
        for mode in PrefixLensMode.allCases {
            prefixLensButtons[mode]?.state = mode == selectedMode ? .on : .off
        }
        updateNamingPreview()
        if detectorPayload != nil {
            refreshGeneratedJobs()
        }
    }

    @objc private func prefixFaceModeChanged(_ sender: NSButton) {
        let selectedIndex = sender.tag
        guard selectedIndex >= 0, selectedIndex < PrefixFaceMode.allCases.count else {
            return
        }
        let selectedMode = PrefixFaceMode.allCases[selectedIndex]
        for mode in PrefixFaceMode.allCases {
            prefixFaceButtons[mode]?.state = mode == selectedMode ? .on : .off
        }
        updateNamingPreview()
        if detectorPayload != nil {
            refreshGeneratedJobs()
        }
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
            isProgrammaticallyUpdatingOutputDirectoryField = true
            outputDirectoryField.stringValue = ""
            isProgrammaticallyUpdatingOutputDirectoryField = false
            persistOutputDirectoryPath(nil)
            updateNamingPreview()
            if detectorPayload != nil {
                refreshGeneratedJobs()
            }
        }
    }

    @objc private func parseVideo(_ sender: Any?) {
        guard detectorCancellation == nil else {
            return
        }
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

        guard resolvedOutputDirectoryURL() != nil else {
            showError("无法确定输出目录。")
            return
        }

        parseButton.isEnabled = false
        splitButton.isEnabled = false
        validateTransitionsButton.isEnabled = false
        stopButton.isEnabled = true
        statusLabel.stringValue = "解析中，请稍候..."

        do {
            let runtime = try resolveRuntime()
            let detector = DetectorService(runtime: runtime)
            let strategy = currentFadeRemovalStrategy()
            let padding = currentFadePaddingSettings(for: strategy)
            detectorCancellation = detector.detect(
                videoURL: videoURL,
                skipStartSeconds: currentSkipStartSeconds(),
                fadeRemovalStrategy: strategy,
                fadeLeftPaddingSeconds: padding.leftSeconds,
                fadeRightPaddingSeconds: padding.rightSeconds,
                progress: { [weak self] message in
                    DispatchQueue.main.async {
                        self?.statusLabel.stringValue = message
                    }
                }
            ) { result in
                DispatchQueue.main.async {
                    self.detectorCancellation = nil
                    self.parseButton.isEnabled = true
                    self.updateSplitButtonState()
                    switch result {
                    case .success(let payload):
                        self.detectorPayload = payload
                        self.selectableEvents = buildSelectableTransitionEvents(payload: payload)
                        self.probedVideoDuration = payload.duration
                        self.editableSegments = buildEditableSegments(payload: payload)
                        self.resetAutomaticSegmentEnabledPreferences(from: self.editableSegments)
                        self.refreshGeneratedJobs()
                        self.statusLabel.stringValue = "解析完成：\(payload.events.count) 个换场，\(payload.keepSegments.count) 个保留片段，Fade=\(strategy.displayName) L=\(String(format: "%.2f", padding.leftSeconds))s R=\(String(format: "%.2f", padding.rightSeconds))s。"
                    case .failure(let error):
                        if case AppRuntimeError.operationCancelled = error {
                            self.statusLabel.stringValue = "解析已停止。"
                            return
                        }
                        self.clearDetectionResults()
                        self.statusLabel.stringValue = "解析失败。"
                        self.showError(error.localizedDescription)
                    }
                }
            }
        } catch {
            detectorCancellation = nil
            parseButton.isEnabled = true
            updateSplitButtonState()
            statusLabel.stringValue = "解析失败。"
            showError(error.localizedDescription)
        }
    }

    @objc private func stopAllProcessing(_ sender: Any?) {
        guard splitCoordinator != nil || detectorCancellation != nil else {
            closeAllWorkerWindows()
            statusLabel.stringValue = "已关闭所有任务窗口。"
            updateSplitButtonState()
            return
        }
        detectorCancellation?.cancel()
        detectorCancellation = nil
        splitCoordinator?.cancelAll()
        parseButton.isEnabled = true
        statusLabel.stringValue = "正在停止..."
        updateSplitButtonState()
    }

    @objc private func splitVideo(_ sender: Any?) {
        startExport(operation: .split) { [weak self] runtime in
            guard let self else {
                return []
            }
            if
                let videoURL = self.selectedVideoURL,
                (try? self.ensureVideoDurationAvailable(runtime: runtime, videoURL: videoURL)) != nil
            {
                self.rebuildJobsFromEditableSegments(autoDisableInvalidSegments: true)
            }
            return self.generatedJobs
        }
    }

    @objc private func exportValidationTransitions(_ sender: Any?) {
        startExport(operation: .validateTransitions) { [weak self] _ in
            guard
                let self,
                let payload = self.detectorPayload,
                let videoURL = self.selectedVideoURL,
                let outputDirectoryURL = self.resolvedOutputDirectoryURL()
            else {
                return []
            }

            return buildTransitionValidationJobs(
                events: self.selectedTransitionEvents(),
                payload: payload,
                videoURL: videoURL,
                outputDirectoryURL: outputDirectoryURL,
                prefix: self.currentOutputPrefix(),
                crop: self.currentCropParameters()
            )
        }
    }

    private func startExport(operation: ExportOperationKind, jobsBuilder: (RuntimeConfiguration) throws -> [FFmpegJob]) {
        guard splitCoordinator == nil else {
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
            let jobs = try jobsBuilder(runtime)
            guard !jobs.isEmpty else {
                showError(operation.emptyJobsErrorMessage)
                return
            }

            let coordinator = SplitCoordinator(
                jobs: jobs,
                concurrency: currentConcurrency(),
                runtime: runtime,
                workerWindowTitlePrefix: operation.workerWindowTitlePrefix
            )
            coordinator.delegate = self
            workerWindowControllers = coordinator.workerWindowControllers
            splitCoordinator = coordinator
            activeExportOperation = operation

            parseButton.isEnabled = false
            splitButton.isEnabled = false
            validateTransitionsButton.isEnabled = false
            stopButton.isEnabled = true
            statusLabel.stringValue = operation.initialStatusText
            coordinator.start()
        } catch {
            activeExportOperation = nil
            workerWindowControllers = []
            statusLabel.stringValue = operation.launchFailureStatusText
            updateSplitButtonState()
            showError(error.localizedDescription)
        }
    }

    func splitCoordinatorDidStart(totalJobs: Int, workerCount: Int) {
        let operation = activeExportOperation ?? .split
        statusLabel.stringValue = operation.startStatusText(totalJobs: totalJobs, workerCount: workerCount)
    }

    func splitCoordinatorDidUpdate(completed: Int, failed: Int, total: Int) {
        let operation = activeExportOperation ?? .split
        statusLabel.stringValue = operation.updateStatusText(completed: completed, failed: failed, total: total)
    }

    func splitCoordinatorDidFinish(completed: Int, failed: Int, total: Int, wasCancelled: Bool) {
        let operation = activeExportOperation ?? .split
        splitCoordinator = nil
        activeExportOperation = nil
        parseButton.isEnabled = true
        updateSplitButtonState()
        if wasCancelled {
            statusLabel.stringValue = "已停止：成功 \(completed) / \(total)，失败 \(failed)。"
            return
        }
        statusLabel.stringValue = operation.finishStatusText(completed: completed, failed: failed, total: total)
        if failed > 0 {
            showError(operation.failureAlertMessage(failed: failed))
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView == eventTableView {
            return selectableEvents.count
        }
        if tableView == segmentTableView {
            return editableSegments.count
        }
        return 0
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let tableView = notification.object as? NSTableView else {
            return
        }
        if tableView == eventTableView {
            highlightSegmentRows(forEventAt: eventTableView.selectedRow >= 0 ? eventTableView.selectedRow : nil)
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        guard tableView == segmentTableView else {
            return nil
        }

        let identifier = NSUserInterfaceItemIdentifier("segment-row-view")
        let rowView: HoverAwareTableRowView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? HoverAwareTableRowView {
            rowView = reused
        } else {
            rowView = HoverAwareTableRowView()
            rowView.identifier = identifier
        }

        rowView.rowIndex = row
        rowView.hoverChanged = { [weak self] hoveredRow, isHovered in
            guard let self else { return }
            let nextHoveredRow = isHovered ? hoveredRow : (self.hoveredManualSegmentRow == hoveredRow ? nil : self.hoveredManualSegmentRow)
            guard self.hoveredManualSegmentRow != nextHoveredRow else { return }
            self.hoveredManualSegmentRow = nextHoveredRow
            self.segmentTableView.reloadData(forRowIndexes: IndexSet(integersIn: 0..<self.editableSegments.count), columnIndexes: IndexSet(integer: 2))
        }
        return rowView
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let identifier = tableColumn?.identifier else {
            return nil
        }

        if tableView == eventTableView {
            guard row >= 0, row < selectableEvents.count else {
                return nil
            }
            let selectableEvent = selectableEvents[row]
            let event = selectableEvent.event

            switch identifier.rawValue {
            case "selected":
                let buttonIdentifier = NSUserInterfaceItemIdentifier("event-selected")
                let button: NSButton
                if let reused = tableView.makeView(withIdentifier: buttonIdentifier, owner: nil) as? NSButton {
                    button = reused
                } else {
                    button = NSButton(checkboxWithTitle: "", target: self, action: #selector(eventSelectedChanged(_:)))
                    button.identifier = buttonIdentifier
                }
                button.tag = row
                button.state = selectableEvent.isSelected ? .on : .off
                return button
            case "index":
                break
            case "type":
                break
            case "start":
                break
            case "end":
                break
            case "duration":
                break
            case "source":
                break
            default:
                return nil
            }

            let cellIdentifier = NSUserInterfaceItemIdentifier("event-cell-\(identifier.rawValue)")
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
            textField.textColor = selectableEvent.isSelected ? .labelColor : .secondaryLabelColor
            return textField
        }

        if tableView == segmentTableView {
            let segment = editableSegments[row]
            let manualBackgroundColor = NSColor.systemGreen.withAlphaComponent(0.14)

            switch identifier.rawValue {
            case "enabled":
                let buttonIdentifier = NSUserInterfaceItemIdentifier("segment-enabled")
                let button: NSButton
                if let reused = tableView.makeView(withIdentifier: buttonIdentifier, owner: nil) as? NSButton {
                    button = reused
                } else {
                    button = NSButton(checkboxWithTitle: "", target: self, action: #selector(segmentEnabledChanged(_:)))
                    button.identifier = buttonIdentifier
                }
                button.tag = row
                button.state = segment.isEnabled ? .on : .off
                button.isEnabled = segment.isUserToggleable
                button.contentTintColor = segment.isMergedFollower ? .tertiaryLabelColor : nil
                if let cell = button.superview {
                    cell.wantsLayer = true
                    cell.layer?.backgroundColor = segment.isManual ? manualBackgroundColor.cgColor : NSColor.clear.cgColor
                }
                return button
            case "duration":
                let cellIdentifier = NSUserInterfaceItemIdentifier("segment-duration")
                let textField: NSTextField
                if let cell = tableView.makeView(withIdentifier: cellIdentifier, owner: nil) as? NSTextField {
                    textField = cell
                } else {
                    textField = NSTextField(labelWithString: "")
                    textField.identifier = cellIdentifier
                    textField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
                    textField.alignment = .center
                    textField.lineBreakMode = .byTruncatingTail
                }
                if let duration = segment.duration(videoDuration: effectiveVideoDuration()) {
                    textField.stringValue = formatShortSeconds(duration)
                } else {
                    textField.stringValue = ""
                }
                textField.textColor = segmentTextColor(segment)
                return textField
            case "start", "end":
                let isEndColumn = identifier.rawValue == "end"
                let containerIdentifier = NSUserInterfaceItemIdentifier("segment-container-\(identifier.rawValue)")
                let fieldIdentifier = NSUserInterfaceItemIdentifier("segment-\(identifier.rawValue)")
                let container: NSView
                let field: SegmentTimeField
                let deleteButton: NSButton?
                if let reused = tableView.makeView(withIdentifier: containerIdentifier, owner: nil) {
                    container = reused
                    field = reused.subviews.compactMap { $0 as? SegmentTimeField }.first ?? SegmentTimeField(frame: .zero)
                    deleteButton = reused.subviews.compactMap { $0 as? NSButton }.first
                } else {
                    container = NSView(frame: .zero)
                    container.identifier = containerIdentifier
                    container.translatesAutoresizingMaskIntoConstraints = false

                    field = SegmentTimeField(frame: .zero)
                    field.identifier = fieldIdentifier
                    field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
                    field.alignment = identifier.rawValue == "start" ? .right : .left
                    field.controlSize = .large
                    field.placeholderString = isEndColumn ? "留空到结尾" : nil
                    field.delegate = self
                    field.target = self
                    field.action = #selector(segmentTimeFieldChanged(_:))
                    field.translatesAutoresizingMaskIntoConstraints = false
                    field.widthAnchor.constraint(equalToConstant: 84).isActive = true
                    container.addSubview(field)

                    if isEndColumn {
                        let button = NSButton(title: "✕", target: self, action: #selector(deleteManualSegmentRow(_:)))
                        button.isBordered = false
                        button.font = .systemFont(ofSize: 12, weight: .bold)
                        button.contentTintColor = .systemRed
                        button.translatesAutoresizingMaskIntoConstraints = false
                        button.setButtonType(.momentaryPushIn)
                        container.addSubview(button)
                        deleteButton = button

                        NSLayoutConstraint.activate([
                            field.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                            field.topAnchor.constraint(equalTo: container.topAnchor),
                            field.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                            field.trailingAnchor.constraint(equalTo: button.leadingAnchor, constant: -4),
                            button.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -2),
                            button.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                            button.widthAnchor.constraint(equalToConstant: 16),
                        ])
                    } else {
                        deleteButton = nil
                        NSLayoutConstraint.activate([
                            field.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                            field.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                            field.topAnchor.constraint(equalTo: container.topAnchor),
                            field.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                        ])
                    }
                }
                field.segmentRow = row
                field.kind = identifier.rawValue == "start" ? .start : .end
                field.alignment = identifier.rawValue == "start" ? .right : .left
                field.placeholderString = identifier.rawValue == "end" ? "留空到结尾" : nil
                field.stringValue = identifier.rawValue == "start"
                    ? formatSegmentStartHMS(segment.start)
                    : formatOptionalSegmentEndHMS(segment.end)
                field.textColor = segmentTextColor(segment)
                field.isEditable = !segment.isMergedFollower
                field.isSelectable = !segment.isMergedFollower
                field.drawsBackground = true
                field.backgroundColor = segment.isManual
                    ? manualBackgroundColor
                    : (segment.isMergedFollower ? NSColor.controlBackgroundColor : .textBackgroundColor)
                if let deleteButton {
                    deleteButton.tag = row
                    deleteButton.isHidden = !(segment.isManual && hoveredManualSegmentRow == row)
                }
                return container
            default:
                return nil
            }
        }

        return nil
    }

    private func closeAllWorkerWindows() {
        for controller in workerWindowControllers {
            controller.close()
        }
        workerWindowControllers.removeAll()
    }
}
