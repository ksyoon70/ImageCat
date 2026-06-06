//
//  ViewController.swift
//  ImageCat
//
//  Created by headway on 2026/03/27.
//

import Cocoa
import UniformTypeIdentifiers

struct FileListItem {
    let url: URL
    let name: String
    let kind: String
    let size: String
    let icon: NSImage
    let isDirectory: Bool
    let isImage: Bool
}

class ViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private enum Column {
        static let icon = NSUserInterfaceItemIdentifier("IconColumn")
        static let name = NSUserInterfaceItemIdentifier("NameColumn")
        static let kind = NSUserInterfaceItemIdentifier("KindColumn")
        static let size = NSUserInterfaceItemIdentifier("SizeColumn")
    }

    var folderURL: URL? {
        didSet {
            currentFolderURL = folderURL
            imagePreviewViewController?.imageURL = nil
            reloadFiles()
        }
    }

    private let toolbarView = NSView()
    private let upButton = NSButton()
    private let pathLabel = NSTextField(labelWithString: "")
    private let tableView = FileTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "폴더를 선택하세요.")
    private var currentFolderURL: URL?
    private var items: [FileListItem] = []
    private let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    override func viewDidLoad() {
        super.viewDidLoad()

        configureView()
        reloadFiles()
    }

    override func viewDidAppear() {
        super.viewDidAppear()

        ownSplitViewItem?.minimumThickness = 220
        ownSplitViewItem?.maximumThickness = CGFloat.greatestFiniteMagnitude
    }

    override var representedObject: Any? {
        didSet {
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        return items.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < items.count, let tableColumn = tableColumn else { return nil }

        let item = items[row]

        switch tableColumn.identifier {
        case Column.icon:
            let cell = tableView.makeView(withIdentifier: Column.icon, owner: self) as? NSTableCellView ?? NSTableCellView()
            cell.identifier = Column.icon
            let imageView = cell.imageView ?? NSImageView()
            imageView.image = item.icon
            imageView.imageScaling = .scaleProportionallyDown
            if imageView.superview == nil {
                imageView.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(imageView)
                cell.imageView = imageView
                NSLayoutConstraint.activate([
                    imageView.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
                    imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    imageView.widthAnchor.constraint(equalToConstant: 18),
                    imageView.heightAnchor.constraint(equalToConstant: 18)
                ])
            }
            return cell

        case Column.name:
            return textCell(identifier: Column.name, text: item.name)

        case Column.kind:
            return textCell(identifier: Column.kind, text: item.kind)

        case Column.size:
            return textCell(identifier: Column.size, text: item.size)

        default:
            return nil
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard tableView.selectedRow >= 0, tableView.selectedRow < items.count else {
            imagePreviewViewController?.imageURL = nil
            return
        }

        let item = items[tableView.selectedRow]
        imagePreviewViewController?.imageURL = item.isImage ? item.url : nil
    }

    private func configureView() {
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        configureToolbar()

        tableView.headerView = NSTableHeaderView()
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(doubleClickTableRow(_:))
        tableView.upNavigationTarget = self
        tableView.upNavigationAction = #selector(goToParentFolder(_:))

        addColumn(identifier: Column.icon, title: "", width: 34)
        addColumn(identifier: Column.name, title: "이름", width: 180)
        addColumn(identifier: Column.kind, title: "종류", width: 120)
        addColumn(identifier: Column.size, title: "크기", width: 80)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(scrollView)
        view.addSubview(toolbarView)
        view.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            toolbarView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbarView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbarView.topAnchor.constraint(equalTo: view.topAnchor),
            toolbarView.heightAnchor.constraint(equalToConstant: 36),

            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: toolbarView.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    private func configureToolbar() {
        toolbarView.translatesAutoresizingMaskIntoConstraints = false

        upButton.bezelStyle = .texturedRounded
        upButton.image = NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "상위 폴더")
        upButton.imageScaling = .scaleProportionallyDown
        upButton.title = ""
        upButton.toolTip = "상위 폴더로 이동"
        upButton.target = self
        upButton.action = #selector(goToParentFolder(_:))
        upButton.translatesAutoresizingMaskIntoConstraints = false

        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.translatesAutoresizingMaskIntoConstraints = false

        toolbarView.addSubview(upButton)
        toolbarView.addSubview(pathLabel)

        NSLayoutConstraint.activate([
            upButton.leadingAnchor.constraint(equalTo: toolbarView.leadingAnchor, constant: 8),
            upButton.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor),
            upButton.widthAnchor.constraint(equalToConstant: 28),
            upButton.heightAnchor.constraint(equalToConstant: 28),

            pathLabel.leadingAnchor.constraint(equalTo: upButton.trailingAnchor, constant: 8),
            pathLabel.trailingAnchor.constraint(equalTo: toolbarView.trailingAnchor, constant: -8),
            pathLabel.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor)
        ])
    }

    private func addColumn(identifier: NSUserInterfaceItemIdentifier, title: String, width: CGFloat) {
        let column = NSTableColumn(identifier: identifier)
        column.title = title
        column.width = width
        column.minWidth = width
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
    }

    private func textCell(identifier: NSUserInterfaceItemIdentifier, text: String) -> NSTableCellView {
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? NSTableCellView()
        cell.identifier = identifier

        let textField = cell.textField ?? NSTextField(labelWithString: "")
        textField.lineBreakMode = .byTruncatingTail
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.stringValue = text

        if textField.superview == nil {
            cell.addSubview(textField)
            cell.textField = textField
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }

        return cell
    }

    private func reloadFiles() {
        guard isViewLoaded else { return }
        guard let folderURL = currentFolderURL else {
            items = []
            emptyLabel.stringValue = "폴더를 선택하세요."
            updateCurrentFolderUI()
            updateContentVisibility()
            return
        }

        do {
            let urls = try FileManager.default.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .localizedTypeDescriptionKey],
                options: [.skipsHiddenFiles]
            )

            var seenPaths = Set<String>()
            items = urls.filter { seenPaths.insert($0.standardizedFileURL.path).inserted }
                .compactMap(makeFileListItem)
                .sorted { lhs, rhs in
                    if lhs.isDirectory != rhs.isDirectory {
                        return lhs.isDirectory && !rhs.isDirectory
                    }
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
            emptyLabel.stringValue = "표시할 파일이 없습니다."
        } catch {
            items = []
            emptyLabel.stringValue = "폴더를 읽을 수 없습니다: \(error.localizedDescription)"
        }

        tableView.reloadData()
        tableView.deselectAll(nil)
        updateCurrentFolderUI()
        updateContentVisibility()
    }

    private func makeFileListItem(url: URL) -> FileListItem? {
        let resourceValues = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .localizedTypeDescriptionKey])
        let isDirectory = resourceValues?.isDirectory ?? false
        let name = FileManager.default.displayName(atPath: url.path)
        let kind = resourceValues?.localizedTypeDescription ?? (isDirectory ? "폴더" : "파일")
        let size = isDirectory ? "" : byteFormatter.string(fromByteCount: Int64(resourceValues?.fileSize ?? 0))
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        let isImage = Self.isImageURL(url)

        return FileListItem(url: url, name: name, kind: kind, size: size, icon: icon, isDirectory: isDirectory, isImage: isImage)
    }

    private func updateContentVisibility() {
        let isEmpty = items.isEmpty
        scrollView.isHidden = isEmpty
        emptyLabel.isHidden = !isEmpty
    }

    @objc private func doubleClickTableRow(_ sender: Any?) {
        let clickedRow = tableView.clickedRow
        guard clickedRow >= 0, clickedRow < items.count else { return }

        let item = items[clickedRow]
        if item.isDirectory {
            navigate(to: item.url)
        } else if item.isImage {
            imagePreviewViewController?.imageURL = item.url
        }
    }

    @objc private func goToParentFolder(_ sender: Any?) {
        guard let currentFolderURL = currentFolderURL else { return }

        let parentURL = currentFolderURL.deletingLastPathComponent()
        guard parentURL.path != currentFolderURL.path else { return }

        navigate(to: parentURL)
    }

    private func navigate(to folderURL: URL) {
        currentFolderURL = folderURL
        imagePreviewViewController?.imageURL = nil
        reloadFiles()
    }

    private func updateCurrentFolderUI() {
        pathLabel.stringValue = currentFolderURL?.path ?? ""
        upButton.isEnabled = currentFolderURL != nil
    }

    private var imagePreviewViewController: ImagePreviewViewController? {
        return (parent as? NSSplitViewController)?.splitViewItems
            .compactMap { $0.viewController as? ImagePreviewViewController }
            .first
    }

    private var ownSplitViewItem: NSSplitViewItem? {
        return (parent as? NSSplitViewController)?.splitViewItems
            .first { $0.viewController === self }
    }

    private static func isImageURL(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }
}

final class FileTableView: NSTableView {
    weak var upNavigationTarget: AnyObject?
    var upNavigationAction: Selector?

    override func keyDown(with event: NSEvent) {
        let modifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifierFlags.contains(.command),
           event.keyCode == 126,
           let target = upNavigationTarget,
           let action = upNavigationAction,
           target.responds(to: action) {
            _ = target.perform(action, with: self)
            return
        }

        super.keyDown(with: event)
    }
}
