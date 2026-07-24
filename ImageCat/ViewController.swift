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
            // 폴더가 바뀌면 현재 이미지보다 먼저 폴더 전체 label-color set을 준비한다.
            scheduleFolderLabelColorScan(for: folderURL)
            reloadFiles()
        }
    }

    // 폴더 label scan은 label만 필요하므로 전체 annotation 모델보다 가벼운 구조로 디코딩한다.
    private struct FolderAnnotationLabels: Decodable {
        let shapes: [Shape]

        struct Shape: Decodable {
            let label: String?
        }
    }

    // NSSearchField가 입력 중에도 action을 보내므로 검색어가 바뀔 때마다 현재 폴더 목록을 즉시 필터링한다.
    @objc private func searchFieldChanged(_ sender: NSSearchField) {
        applySearchFilter()
    }

    private let toolbarView = NSView()
    private let upButton = NSButton()
    private let pathLabel = NSTextField(labelWithString: "")
    private let tableView = FileTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "폴더를 선택하세요.")
    private var currentFolderURL: URL?
    // 디스크에서 읽은 현재 폴더의 전체 항목을 보관하고, 검색어 변경 시 다시 디스크를 읽지 않도록 한다.
    private var allItems: [FileListItem] = []
    // NSTableView와 Next/Prev 이동은 검색 조건이 적용된 화면 표시 목록만 사용한다.
    private var items: [FileListItem] = []
    private let searchField = NSSearchField()
    private let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()
    // 많은 JSON을 읽어도 UI 스크롤/선택이 멈추지 않도록 백그라운드 queue에서 scan한다.
    private let folderLabelScanQueue = DispatchQueue(label: "ImageCat.folderLabelScanQueue", qos: .userInitiated)
    // 폴더를 빠르게 바꿀 때 오래된 scan 결과가 최신 화면에 덮어쓰이지 않게 세대값을 쓴다.
    private var folderLabelScanGeneration = 0
    // 오늘 수정 상세:
    // File List에서 다른 이미지를 클릭하는 순간 NSTableView selection은 먼저 바뀌고,
    // 그 다음 tableViewSelectionDidChange가 호출된다. 이때 저장 확인 alert에서 Cancel을 누르면
    // 이미 바뀐 table selection을 이전 항목으로 되돌려야 preview와 목록이 엇갈리지 않는다.
    // 검색 결과에 따라 row 번호가 바뀔 수 있으므로 실제 선택은 URL로 기억하고,
    // isRestoringSelection은 코드로 selection을 되돌릴 때 delegate가 다시 도는 순환을 막는다.
    // didCancelSelectionChange는 더블클릭 중 selection change가 먼저 취소된 뒤 doubleAction이 이어서 실행되는 것을 막는다.
    private var currentSelectedItemURL: URL?
    private var isRestoringSelection = false
    private var didCancelSelectionChange = false

    // 오늘 수정: DocumentWindowController가 Next/Prev toolbar item을 validation할 때 사용하는 상태다.
    // 폴더가 선택되어 있고 현재 검색 결과에 이미지가 하나 이상 있으면 이미지 이동 버튼을 활성화한다.
    var canNavigateImages: Bool {
        return currentFolderURL != nil && items.contains { $0.isImage }
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        configureView()
        reloadFiles()
        if currentFolderURL != nil {
            scheduleFolderLabelColorScan(for: currentFolderURL)
        }
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
        // 오늘 수정 상세:
        // restorePreviousSelection()이 table selection을 코드로 되돌릴 때도 이 delegate가 호출된다.
        // 그 경우에는 저장 확인 alert를 다시 띄우면 무한 루프처럼 보이므로 조용히 무시한다.
        guard !isRestoringSelection else { return }

        guard tableView.selectedRow >= 0, tableView.selectedRow < items.count else {
            imagePreviewViewController?.imageURL = nil
            currentSelectedItemURL = nil
            // 오늘 수정: 선택이 사라지면 preview 상태와 toolbar enable 상태도 같이 갱신한다.
            validateDocumentToolbar()
            return
        }

        let selectedRow = tableView.selectedRow
        let item = items[selectedRow]
        let targetImageURL = item.isImage ? item.url : nil
        if imagePreviewViewController?.imageURL != targetImageURL,
           let documentWindowController = view.window?.windowController as? DocumentWindowController,
           !documentWindowController.saveCurrentAnnotationBeforeNavigationIfNeeded() {
            // 오늘 수정 상세:
            // 사용자가 저장 확인 alert에서 Cancel을 누른 경우다.
            // 이미 NSTableView의 선택은 새 row로 바뀐 상태이므로 이전 row로 복원하고,
            // double-click으로 들어온 이벤트라면 이어지는 doubleAction도 무시하게 표시한다.
            didCancelSelectionChange = true
            restorePreviousSelection()
            return
        }

        // 저장 확인까지 통과한 선택만 확정한다. Cancel 전에 URL을 바꾸면 이전 선택을 복원할 수 없다.
        imagePreviewViewController?.imageURL = targetImageURL
        currentSelectedItemURL = item.url
        // 오늘 수정: 파일 선택이 이미지/폴더 사이에서 바뀔 때 Next/Prev 등 toolbar 상태를 즉시 재검증한다.
        validateDocumentToolbar()
    }

    private func configureView() {
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        configureToolbar()

        tableView.headerView = NSTableHeaderView()
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(doubleClickTableRow(_:))
        tableView.upNavigationTarget = self
        tableView.upNavigationAction = #selector(goToParentFolder(_:))
        // 오늘 수정: File List가 first responder일 때 a/d 키가 이미지 이동으로 동작하도록
        // custom table view에 target/action을 전달한다.
        tableView.imageNavigationTarget = self
        tableView.nextImageAction = #selector(selectNextImage(_:))
        tableView.previousImageAction = #selector(selectPreviousImage(_:))

        addColumn(identifier: Column.icon, title: "", width: 34)
        addColumn(identifier: Column.name, title: "이름", width: 180)
        addColumn(identifier: Column.kind, title: "종류", width: 120)
        addColumn(identifier: Column.size, title: "크기", width: 80)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
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
            // 경로와 검색 필드를 두 줄로 배치해 좁은 File List에서도 두 컨트롤이 서로 밀리지 않게 한다.
            toolbarView.heightAnchor.constraint(equalToConstant: 72),

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
        // 긴 경로의 intrinsic width가 파일 리스트 Split View 폭을 밀어내지 않도록 한다.
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        pathLabel.translatesAutoresizingMaskIntoConstraints = false

        // 입력이 끝날 때까지 기다리지 않고 파일명 검색 결과를 실시간으로 갱신한다.
        searchField.placeholderString = "파일 이름 검색"
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.target = self
        searchField.action = #selector(searchFieldChanged(_:))
        searchField.translatesAutoresizingMaskIntoConstraints = false

        toolbarView.addSubview(upButton)
        toolbarView.addSubview(pathLabel)
        toolbarView.addSubview(searchField)

        NSLayoutConstraint.activate([
            upButton.leadingAnchor.constraint(
                equalTo: toolbarView.leadingAnchor,
                constant: 8
            ),
            upButton.topAnchor.constraint(
                equalTo: toolbarView.topAnchor,
                constant: 4
            ),
            upButton.widthAnchor.constraint(equalToConstant: 28),
            upButton.heightAnchor.constraint(equalToConstant: 28),

            pathLabel.leadingAnchor.constraint(
                equalTo: upButton.trailingAnchor,
                constant: 8
            ),
            pathLabel.trailingAnchor.constraint(
                equalTo: toolbarView.trailingAnchor,
                constant: -8
            ),
            pathLabel.centerYAnchor.constraint(equalTo: upButton.centerYAnchor),

            searchField.leadingAnchor.constraint(
                equalTo: toolbarView.leadingAnchor,
                constant: 8
            ),
            searchField.trailingAnchor.constraint(
                equalTo: toolbarView.trailingAnchor,
                constant: -8
            ),
            searchField.topAnchor.constraint(
                equalTo: upButton.bottomAnchor,
                constant: 4
            ),
            searchField.heightAnchor.constraint(equalToConstant: 28)
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
            allItems = []
            items = []
            emptyLabel.stringValue = "폴더를 선택하세요."
            updateCurrentFolderUI()
            updateContentVisibility()
            // 오늘 수정: 폴더가 없으면 Next/Prev Image가 비활성화되어야 하므로 toolbar를 다시 검증한다.
            validateDocumentToolbar()
            return
        }

        do {
            let urls = try FileManager.default.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .localizedTypeDescriptionKey],
                options: [.skipsHiddenFiles]
            )

            var seenPaths = Set<String>()
            allItems = urls.filter { seenPaths.insert($0.standardizedFileURL.path).inserted }
                .compactMap(makeFileListItem)
                .sorted { lhs, rhs in
                    if lhs.isDirectory != rhs.isDirectory {
                        return lhs.isDirectory && !rhs.isDirectory
                    }
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
        } catch {
            allItems = []
            items = []
            emptyLabel.stringValue = "폴더를 읽을 수 없습니다: \(error.localizedDescription)"
            tableView.reloadData()
            tableView.deselectAll(nil)
            updateCurrentFolderUI()
            updateContentVisibility()
            validateDocumentToolbar()
            return
        }

        // 폴더를 한 번 읽은 뒤 현재 검색어를 적용한다. 검색어는 폴더를 이동해도 유지된다.
        updateCurrentFolderUI()
        applySearchFilter()
    }

    private func applySearchFilter() {
        let query = searchField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if query.isEmpty {
            items = allItems
        } else {
            items = allItems.filter { item in
                item.name.range(
                    of: query,
                    options: [
                        .caseInsensitive,
                        .diacriticInsensitive
                    ],
                    locale: .current
                ) != nil
            }
        }

        // reloadData 뒤 같은 row가 다른 파일을 가리킬 수 있으므로 URL로 선택을 다시 찾는다.
        // 검색 결과에서 현재 파일이 사라진 경우에는 Preview를 유지한 채 목록 선택만 잠시 숨긴다.
        isRestoringSelection = true
        tableView.reloadData()
        tableView.deselectAll(nil)
        if let selectedURL = currentSelectedItemURL,
           let row = items.firstIndex(where: {
               $0.url.standardizedFileURL == selectedURL.standardizedFileURL
           }) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
        }
        isRestoringSelection = false

        updateSearchEmptyState(query: query)
        updateContentVisibility()
        validateDocumentToolbar()
    }

    private func updateSearchEmptyState(query: String) {
        // 폴더 자체가 빈 경우와 검색 결과만 빈 경우를 구분해 사용자가 다음 행동을 판단할 수 있게 한다.
        if !query.isEmpty && items.isEmpty {
            emptyLabel.stringValue =
                "\"\(query)\"와 일치하는 파일이 없습니다."
        } else {
            emptyLabel.stringValue = "표시할 파일이 없습니다."
        }
    }

    private func makeFileListItem(url: URL) -> FileListItem? {
        let resourceValues = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .localizedTypeDescriptionKey])
        let isDirectory = resourceValues?.isDirectory ?? false
        let isImage = Self.isImageURL(url)
        // 오늘 수정: annotation 작업 흐름에 필요 없는 일반 파일은 File List에서 숨긴다.
        // 폴더는 탐색을 위해 유지하고, 이미지만 preview/label 작업 대상으로 보여준다.
        guard isDirectory || isImage else { return nil }

        let name = FileManager.default.displayName(atPath: url.path)
        let kind = resourceValues?.localizedTypeDescription ?? (isDirectory ? "폴더" : "파일")
        let size = isDirectory ? "" : byteFormatter.string(fromByteCount: Int64(resourceValues?.fileSize ?? 0))
        let icon = NSWorkspace.shared.icon(forFile: url.path)

        return FileListItem(url: url, name: name, kind: kind, size: size, icon: icon, isDirectory: isDirectory, isImage: isImage)
    }

    private func updateContentVisibility() {
        let isEmpty = items.isEmpty
        scrollView.isHidden = isEmpty
        emptyLabel.isHidden = !isEmpty
    }

    @objc private func doubleClickTableRow(_ sender: Any?) {
        // 오늘 수정 상세:
        // NSTableView doubleAction은 selection change 뒤에 들어올 수 있다.
        // selection change 단계에서 저장 확인이 취소되었으면, 여기서 폴더 이동이나 이미지 열기를 다시 수행하면 안 된다.
        guard !didCancelSelectionChange else {
            didCancelSelectionChange = false
            return
        }

        let clickedRow = tableView.clickedRow
        guard clickedRow >= 0, clickedRow < items.count else { return }

        let item = items[clickedRow]
        if item.isDirectory {
            // 오늘 수정 상세:
            // 폴더 이동도 현재 이미지에서 벗어나는 동작이다.
            // 자동저장이 켜져 있으면 저장 후 이동하고, 꺼져 있으면 저장 확인 alert 결과에 따라 이동 여부를 결정한다.
            if let documentWindowController = view.window?.windowController as? DocumentWindowController,
               !documentWindowController.saveCurrentAnnotationBeforeNavigationIfNeeded() {
                restorePreviousSelection()
                return
            }
            navigate(to: item.url)
        } else if item.isImage {
            tableView.selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
        }
    }

    @objc private func goToParentFolder(_ sender: Any?) {
        guard let currentFolderURL = currentFolderURL else { return }
        // 오늘 수정 상세:
        // 상위 폴더 이동도 현재 이미지 선택을 해제할 수 있으므로,
        // 직접 이미지 row를 클릭하는 것과 같은 저장/취소 정책을 적용한다.
        if let documentWindowController = view.window?.windowController as? DocumentWindowController,
           !documentWindowController.saveCurrentAnnotationBeforeNavigationIfNeeded() {
            return
        }

        let parentURL = currentFolderURL.deletingLastPathComponent()
        guard parentURL.path != currentFolderURL.path else { return }

        navigate(to: parentURL)
    }

    private func navigate(to folderURL: URL) {
        currentFolderURL = folderURL
        imagePreviewViewController?.imageURL = nil
        // 사이드바/더블클릭 이동도 Open Dir와 같은 색상 scan 경로를 타게 한다.
        scheduleFolderLabelColorScan(for: folderURL)
        reloadFiles()
    }

    @objc func selectNextImage(_ sender: Any?) {
        // 오늘 수정: toolbar Next Image와 d 키가 공유하는 공개 entry point다.
        selectImage(direction: 1)
    }

    @objc func selectPreviousImage(_ sender: Any?) {
        // 오늘 수정: toolbar Prev Image와 a 키가 공유하는 공개 entry point다.
        selectImage(direction: -1)
    }

    private func restorePreviousSelection() {
        // 저장 확인에서 Cancel하면 검색으로 row가 달라졌더라도 URL이 같은 이전 항목을 다시 선택한다.
        isRestoringSelection = true

        defer {
            isRestoringSelection = false
            validateDocumentToolbar()
        }

        guard let selectedURL = currentSelectedItemURL,
              let row = items.firstIndex(where: {
                  $0.url.standardizedFileURL ==
                  selectedURL.standardizedFileURL
              }) else {
            tableView.deselectAll(nil)
            return
        }

        tableView.selectRowIndexes(
            IndexSet(integer: row),
            byExtendingSelection: false
        )
        tableView.scrollRowToVisible(row)
    }

    private func selectImage(direction: Int) {
        // 오늘 수정: direction은 1(다음) 또는 -1(이전)만 허용한다.
        // 이미지가 하나도 없으면 toolbar/action/key 입력 모두 조용히 무시한다.
        guard direction == 1 || direction == -1,
              items.contains(where: { $0.isImage }) else {
            return
        }

        let selectedRow = tableView.selectedRow
        let startRow: Int
        if selectedRow >= 0, selectedRow < items.count {
            // 오늘 수정: 현재 선택 row 바로 다음/이전부터 검색한다.
            // 이렇게 해야 현재 이미지를 다시 선택하지 않고 사용자가 기대하는 방향으로만 움직인다.
            startRow = selectedRow + direction
        } else {
            // 오늘 수정: 선택이 없는 상태에서 d는 첫 이미지, a는 마지막 이미지부터 찾는다.
            startRow = direction > 0 ? 0 : items.count - 1
        }

        // 오늘 수정: 이미 첫 항목에서 a를 누르거나 마지막 항목에서 d를 누르면 범위를 벗어나므로 아무 동작도 하지 않는다.
        guard startRow >= 0, startRow < items.count else { return }

        var row = startRow
        while row >= 0 && row < items.count {
            if items[row].isImage {
                // 오늘 수정: 이미지 이동은 imageURL만 직접 바꾸지 않고 table selection을 바꾼다.
                // selectionDidChange가 preview 갱신까지 담당하므로 File List와 Preview가 항상 같은 항목을 가리킨다.
                tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                tableView.scrollRowToVisible(row)
                validateDocumentToolbar()
                return
            }
            // 오늘 수정: 폴더는 건너뛰고 같은 방향의 다음 이미지 row를 찾는다.
            row += direction
        }
    }

    private func scheduleFolderLabelColorScan(for folderURL: URL?) {
        // 새 scan 요청마다 세대값을 올린다. 이전 폴더 scan이 늦게 끝나도 최신 결과를 덮어쓰지 못하게 한다.
        folderLabelScanGeneration += 1
        let generation = folderLabelScanGeneration

        guard let folderURL else {
            // 선택된 폴더가 없으면 overlay와 오른쪽 목록의 폴더 기준 색상 set도 비운다.
            applyFolderLabelColorPairs([])
            return
        }

        // 같은 폴더라도 상대 경로/심볼릭 경로 차이로 비교가 어긋나지 않도록 표준화된 URL로 맞춘다.
        let standardizedFolderURL = folderURL.standardizedFileURL
        // 새 폴더 scan이 끝나기 전까지 이전 폴더의 label-color set이 보이지 않도록 먼저 초기화한다.
        applyFolderLabelColorPairs([])

        folderLabelScanQueue.async { [weak self] in
            // 디스크 I/O와 JSON parsing은 백그라운드에서 끝내고 UI 반영만 main queue에서 한다.
            let pairs = Self.buildFolderLabelColorPairs(for: standardizedFolderURL)

            DispatchQueue.main.async {
                // scan 도중 다른 폴더로 이동했다면 generation 또는 currentFolderURL 검증에서 걸러진다.
                guard let self = self,
                      generation == self.folderLabelScanGeneration,
                      self.currentFolderURL?.standardizedFileURL == standardizedFolderURL else {
                    return
                }

                // 여기까지 온 결과만 현재 폴더의 최신 label-color set으로 인정해 UI에 반영한다.
                self.applyFolderLabelColorPairs(pairs)
            }
        }
    }

    private func applyFolderLabelColorPairs(_ pairs: Set<LabelColorPair>) {
        // overlay와 오른쪽 label 목록이 같은 palette 기준을 공유해야 색상이 흔들리지 않는다.
        imagePreviewViewController?.setFolderLabelColorPairs(pairs)
        imageControlViewController?.setFolderLabelColorPairs(pairs)
    }

    private static func buildFolderLabelColorPairs(for folderURL: URL) -> Set<LabelColorPair> {
        let fileManager = FileManager.default
        let jsonURLs: [URL]

        do {
            jsonURLs = try fileManager.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        } catch {
            print("폴더 JSON 목록 읽기 실패: \(folderURL.path) - \(error.localizedDescription)")
            return []
        }

        let decoder = JSONDecoder()
        var labels: [String] = []

        // 깨진 JSON 하나가 있어도 나머지 label scan은 계속 진행한다.
        for jsonURL in jsonURLs {
            do {
                let data = try Data(contentsOf: jsonURL)
                let annotationLabels = try decoder.decode(FolderAnnotationLabels.self, from: data)
                labels.append(contentsOf: annotationLabels.shapes.compactMap { shape in
                    let label = shape.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    return label.isEmpty ? nil : label
                })
            } catch {
                print("폴더 label scan 실패: \(jsonURL.path) - \(error.localizedDescription)")
            }
        }

        return LabelColorProvider.colorPairs(for: labels)
    }

    private func updateCurrentFolderUI() {
        pathLabel.stringValue = currentFolderURL?.path ?? ""
        upButton.isEnabled = currentFolderURL != nil
    }

    private func validateDocumentToolbar() {
        // 오늘 수정: File List의 폴더/이미지 선택 상태가 toolbar item 활성화 조건에 영향을 주므로
        // reload/selection/navigation 뒤 visible toolbar items를 다시 검증한다.
        view.window?.toolbar?.validateVisibleItems()
    }

    private var imagePreviewViewController: ImagePreviewViewController? {
        return (parent as? NSSplitViewController)?.splitViewItems
            .compactMap { $0.viewController as? ImagePreviewViewController }
            .first
    }

    private var imageControlViewController: ImageControlViewController? {
        return (parent as? NSSplitViewController)?.splitViewItems
            .compactMap { $0.viewController as? ImageControlViewController }
            .first
    }

    private static func isImageURL(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }
}

final class FileTableView: NSTableView {
    weak var upNavigationTarget: AnyObject?
    var upNavigationAction: Selector?
    // 오늘 수정: File List가 keyDown을 직접 받는 동안 a/d 입력을 ViewController의 이미지 이동 action으로 전달한다.
    weak var imageNavigationTarget: AnyObject?
    var nextImageAction: Selector?
    var previousImageAction: Selector?

    override func keyDown(with event: NSEvent) {
        let modifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // 오늘 수정: 단축키 충돌을 피하기 위해 modifier가 없는 순수 a/d만 이미지 이동으로 사용한다.
        // Cmd+A 같은 시스템/테이블 단축키는 기존 AppKit 처리로 넘긴다.
        if modifierFlags.isEmpty,
           let key = event.charactersIgnoringModifiers?.lowercased(),
           let target = imageNavigationTarget {
            switch key {
            case "d":
                if let action = nextImageAction, target.responds(to: action) {
                    _ = target.perform(action, with: self)
                    return
                }
            case "a":
                if let action = previousImageAction, target.responds(to: action) {
                    _ = target.perform(action, with: self)
                    return
                }
            default:
                break
            }
        }

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
