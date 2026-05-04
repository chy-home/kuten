import AppKit

final class PanelContainerView: NSView {
    let contentView = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    private func configure() {
        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.96).cgColor

        contentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentView)

        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            contentView.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
        ])
    }
}

final class DroppablePathField: NSTextField {
    enum AcceptKind {
        case file
        case directory
        case any
    }

    var acceptKind: AcceptKind = .any
    var onURLDropped: ((URL) -> Void)?
    private var isHighlightedForDrop = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    convenience init(acceptKind: AcceptKind) {
        self.init(frame: .zero)
        self.acceptKind = acceptKind
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    private func commonInit() {
        registerForDraggedTypes([.fileURL])
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.25).cgColor
        focusRingType = .none
        isBordered = true
        lineBreakMode = .byTruncatingMiddle
        font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        drawsBackground = true
        backgroundColor = .textBackgroundColor
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let url = firstAcceptedURL(from: sender) else {
            setDropHighlight(false)
            return []
        }
        setDropHighlight(true)
        return fileManagerValidation(for: url) ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        setDropHighlight(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        firstAcceptedURL(from: sender) != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        setDropHighlight(false)
        guard let url = firstAcceptedURL(from: sender), fileManagerValidation(for: url) else {
            return false
        }
        stringValue = url.path
        onURLDropped?(url)
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        setDropHighlight(false)
    }

    private func setDropHighlight(_ highlighted: Bool) {
        guard highlighted != isHighlightedForDrop else {
            return
        }
        isHighlightedForDrop = highlighted
        layer?.borderColor = highlighted
            ? NSColor.controlAccentColor.cgColor
            : NSColor.separatorColor.withAlphaComponent(0.25).cgColor
        layer?.borderWidth = highlighted ? 2 : 1
    }

    private func firstAcceptedURL(from draggingInfo: NSDraggingInfo) -> URL? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
        ]
        let urls = draggingInfo.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]
        return urls?.first(where: fileManagerValidation(for:))
    }

    private func fileManagerValidation(for url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        guard exists else {
            return false
        }

        switch acceptKind {
        case .file:
            return !isDirectory.boolValue
        case .directory:
            return isDirectory.boolValue
        case .any:
            return true
        }
    }
}

final class SegmentTimeField: NSTextField {
    enum Kind {
        case start
        case end
    }

    var segmentRow: Int = -1
    var kind: Kind = .start
}
