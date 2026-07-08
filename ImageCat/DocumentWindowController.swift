//
//  DocumentWindowController.swift
//  ImageCat
//
//  Created by headway on 2026/06/30.
//

import Cocoa

class DocumentWindowController: NSWindowController, NSToolbarItemValidation {
    private enum ToolbarLabel {
        static let deleteFile = "Delete File"
        // 오늘 수정: Storyboard의 Next Image toolbar item에는 action 연결이 없으므로
        // label/paletteLabel을 기준으로 item을 찾아 코드에서 target/action을 보강한다.
        static let nextImage = "Next Image"
        // 오늘 수정: Storyboard label은 "Prev Image"이므로 이 문자열을 기준으로 이전 이미지 버튼을 찾는다.
        static let previousImage = "Prev Image"
        // 오늘 수정: Delete Polygons toolbar item을 코드에서 식별하기 위한 label이다.
        static let deletePolygons = "Delete Polygons"
    }

    private enum ToolbarDefaults {
        // 오늘 수정: 사용자가 toolbar 표시 방식을 Icon Only / Icon and Text 등으로 바꾸면
        // 다음 실행에서도 유지되도록 NSToolbar.DisplayMode를 UserDefaults에 저장한다.
        static let displayModeKey = "ImageCat.DocumentToolbar.DisplayMode"
    }

    // 오늘 수정: toolbar displayMode는 사용자가 customize menu에서 바꿀 수 있으므로
    // KVO로 변경을 감지해 즉시 UserDefaults에 저장한다.
    private var toolbarDisplayModeObservation: NSKeyValueObservation?

    override func windowDidLoad() {
        super.windowDidLoad()

        window?.titleVisibility = .hidden
        window?.toolbarStyle = .expanded
        // 오늘 수정: Storyboard 기본값 대신 마지막 사용자의 toolbar 표시 방식을 먼저 복원한다.
        configureToolbarDisplayModePersistence()
        // 오늘 수정: preview overlay가 focus를 가진 상태에서 a/d 키를 눌러도
        // 실제 이미지 선택은 파일 리스트 컨트롤러가 수행하도록 callback을 연결한다.
        configureImageNavigationCallbacks()
        updatePolygonToolbarItems()
    }

    deinit {
        toolbarDisplayModeObservation?.invalidate()
    }

    @IBAction func openDirectory(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.title = "Open Directory"
        panel.prompt = "Open"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        guard let window else { return }

        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let folderURL = panel.url else { return }
            self?.fileListViewController?.folderURL = folderURL
        }
    }

    @IBAction func deleteFile(_ sender: Any?) {
        // 현재는 항상 활성화만 보장한다. 실제 삭제 동작은 별도 구현 시 여기에 연결한다.
    }

    @IBAction func nextImage(_ sender: Any?) {
        // 오늘 수정: toolbar 버튼과 preview overlay 단축키가 모두 같은 파일 리스트 이동 경로를 사용한다.
        fileListViewController?.selectNextImage(sender)
        updatePolygonToolbarItems()
    }

    @IBAction func previousImage(_ sender: Any?) {
        // 오늘 수정: 이전 이미지 이동도 파일 리스트 선택을 바꾸는 방식으로 처리해
        // table selection, preview imageURL, toolbar validation이 한 흐름으로 움직이게 한다.
        fileListViewController?.selectPreviousImage(sender)
        updatePolygonToolbarItems()
    }

    @IBAction func toggleEditPolygons(_ sender: Any?) {
        guard let imagePreviewViewController else { return }

        // Edit 버튼은 edit 모드 진입용으로만 쓰고, edit 모드 중에는 버튼 자체를 잠근다.
        imagePreviewViewController.setPolygonInteractionMode(.edit)
        updatePolygonToolbarItems()
    }

    @IBAction func toggleCreatePolygons(_ sender: Any?) {
        guard let imagePreviewViewController else { return }

        // Create 버튼은 create 모드 진입용으로만 쓰고, create 모드 중에는 버튼 자체를 잠근다.
        imagePreviewViewController.setPolygonInteractionMode(.create)
        updatePolygonToolbarItems()
    }

    @IBAction func deletePolygons(_ sender: Any?) {
        guard let imagePreviewViewController else { return }

        // 오늘 수정: edit 모드에서 overlay가 기억한 선택 shape를 삭제한다.
        imagePreviewViewController.deleteSelectedAnnotationShape()
        updatePolygonToolbarItems()
    }

    @IBAction func zoomIn(_ sender: Any?) {
        imagePreviewViewController?.zoomIn()
        updatePolygonToolbarItems()
    }

    @IBAction func zoomOut(_ sender: Any?) {
        imagePreviewViewController?.zoomOut()
        updatePolygonToolbarItems()
    }

    @IBAction func fitImage(_ sender: Any?) {
        imagePreviewViewController?.fitImage()
        updatePolygonToolbarItems()
    }

    @IBAction func saveAnnotation(_ sender: Any?) {
        do {
            // 미리보기 오버레이에 반영된 최신 annotation 좌표를 원본 JSON에 저장한다.
            try imagePreviewViewController?.saveCurrentAnnotation()
        } catch {
            showSaveError(error)
        }
    }

    private var fileListViewController: ViewController? {
        return (contentViewController as? NSSplitViewController)?
            .splitViewItems
            .compactMap { $0.viewController as? ViewController }
            .first
    }

    private var imagePreviewViewController: ImagePreviewViewController? {
        return (contentViewController as? NSSplitViewController)?
            .splitViewItems
            .compactMap { $0.viewController as? ImagePreviewViewController }
            .first
    }

    private func updatePolygonToolbarItems() {
        let mode = imagePreviewViewController?.polygonInteractionMode ?? .inactive

        // Create/Edit 버튼은 현재 활성 모드 버튼만 잠그고, 반대 버튼은 모드 전환용으로 열어둔다.
        window?.toolbar?.items.forEach { toolbarItem in
            if isDeleteFileToolbarItem(toolbarItem) {
                configureDeleteFileToolbarItem(toolbarItem)
                return
            }
            if isNextImageToolbarItem(toolbarItem) {
                // 오늘 수정: Storyboard에서 action이 비어 있는 Next Image item을 런타임에 연결한다.
                configureImageNavigationToolbarItem(toolbarItem, action: #selector(nextImage(_:)))
                return
            }
            if isPreviousImageToolbarItem(toolbarItem) {
                // 오늘 수정: Storyboard에서 action이 비어 있는 Prev Image item을 런타임에 연결한다.
                configureImageNavigationToolbarItem(toolbarItem, action: #selector(previousImage(_:)))
                return
            }
            if isDeletePolygonsToolbarItem(toolbarItem) {
                // 오늘 수정: Storyboard toolbar item이 validation 중 비활성화되지 않도록 target/action을 보강한다.
                configureDeletePolygonsToolbarItem(toolbarItem, mode: mode)
                return
            }

            switch toolbarItem.action {
            case #selector(toggleCreatePolygons(_:)):
                toolbarItem.isEnabled = mode != .create
                toolbarItem.label = "Create Polygons"
                toolbarItem.paletteLabel = "Create Polygons"
            case #selector(toggleEditPolygons(_:)):
                toolbarItem.isEnabled = mode != .edit
                toolbarItem.label = "Edit Polygons"
                toolbarItem.paletteLabel = "Edit Polygons"
            case #selector(saveAnnotation(_:)):
                toolbarItem.isEnabled = imagePreviewViewController != nil
            case #selector(zoomIn(_:)):
                toolbarItem.isEnabled = imagePreviewViewController?.canZoomIn == true
            case #selector(zoomOut(_:)):
                toolbarItem.isEnabled = imagePreviewViewController?.canZoomOut == true
            case #selector(fitImage(_:)):
                toolbarItem.isEnabled = imagePreviewViewController?.canFitImage == true
            default:
                break
            }
        }
    }

    private func configureToolbarDisplayModePersistence() {
        guard let toolbar = window?.toolbar else { return }

        // 오늘 수정: 앱 시작 시 저장된 표시 방식을 복원한 뒤, 이후 변경을 관찰한다.
        // restore가 먼저 호출되어야 관찰 시작 직후 기본값으로 덮어쓰는 일을 피할 수 있다.
        restoreToolbarDisplayMode(for: toolbar)
        toolbarDisplayModeObservation = toolbar.observe(\.displayMode, options: [.new]) { [weak self] toolbar, _ in
            self?.saveToolbarDisplayMode(toolbar.displayMode)
        }
    }

    private func configureImageNavigationCallbacks() {
        // 오늘 수정: edit/create 모드에서는 overlay가 first responder가 될 수 있으므로
        // a/d 키 이벤트를 window controller까지 끌어올려 파일 리스트 선택 변경으로 이어준다.
        imagePreviewViewController?.onSelectNextImage = { [weak self] in
            self?.nextImage(nil)
        }
        imagePreviewViewController?.onSelectPreviousImage = { [weak self] in
            self?.previousImage(nil)
        }
    }

    private func restoreToolbarDisplayMode(for toolbar: NSToolbar) {
        guard let savedValue = UserDefaults.standard.string(forKey: ToolbarDefaults.displayModeKey),
              let displayMode = toolbarDisplayMode(from: savedValue) else {
            return
        }

        // 오늘 수정: 사용자가 이전 실행에서 선택한 toolbar 표시 방식을 그대로 적용한다.
        toolbar.displayMode = displayMode
    }

    private func saveToolbarDisplayMode(_ displayMode: NSToolbar.DisplayMode) {
        guard let value = toolbarDisplayModeStorageValue(for: displayMode) else { return }
        // 오늘 수정: NSToolbar.DisplayMode 자체를 직접 저장하지 않고 문자열로 저장해
        // SDK/런타임 enum raw value 변화와 무관하게 안정적으로 복원한다.
        UserDefaults.standard.set(value, forKey: ToolbarDefaults.displayModeKey)
    }

    private func toolbarDisplayMode(from value: String) -> NSToolbar.DisplayMode? {
        switch value {
        case "default":
            return .default
        case "iconAndLabel":
            return .iconAndLabel
        case "iconOnly":
            return .iconOnly
        case "labelOnly":
            return .labelOnly
        default:
            return nil
        }
    }

    private func toolbarDisplayModeStorageValue(for displayMode: NSToolbar.DisplayMode) -> String? {
        switch displayMode {
        case .default:
            return "default"
        case .iconAndLabel:
            return "iconAndLabel"
        case .iconOnly:
            return "iconOnly"
        case .labelOnly:
            return "labelOnly"
        @unknown default:
            return nil
        }
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.action {
        case #selector(nextImage(_:)), #selector(previousImage(_:)):
            // 오늘 수정: 폴더가 선택되어 있고 이미지가 하나 이상 있을 때만 Next/Prev를 활성화한다.
            // 첫/마지막 이미지 경계에서는 버튼을 눌러도 selectImage가 움직이지 않지만,
            // 사용자는 폴더 단위 이동 가능 여부를 버튼 상태로 볼 수 있게 했다.
            return fileListViewController?.canNavigateImages == true
        case #selector(toggleCreatePolygons(_:)):
            return imagePreviewViewController?.polygonInteractionMode != .create
        case #selector(toggleEditPolygons(_:)):
            return imagePreviewViewController?.polygonInteractionMode != .edit
        case #selector(saveAnnotation(_:)):
            return imagePreviewViewController != nil
        case #selector(zoomIn(_:)):
            return imagePreviewViewController?.canZoomIn == true
        case #selector(zoomOut(_:)):
            return imagePreviewViewController?.canZoomOut == true
        case #selector(fitImage(_:)):
            return imagePreviewViewController?.canFitImage == true
        case #selector(deletePolygons(_:)):
            // 오늘 수정: Delete Polygons는 edit 모드에서만 의미가 있으므로 edit 모드에만 활성화한다.
            return imagePreviewViewController?.polygonInteractionMode == .edit
        case #selector(deleteFile(_:)):
            // Delete File은 선택 상태와 무관하게 항상 눌릴 수 있어야 한다.
            return true
        default:
            return isDeleteFileToolbarItem(item) || item.isEnabled
        }
    }

    private func configureDeleteFileToolbarItem(_ toolbarItem: NSToolbarItem) {
        // Storyboard의 Delete File item에는 action이 없어서 AppKit validation이 disabled로 되돌린다.
        toolbarItem.target = self
        toolbarItem.action = #selector(deleteFile(_:))
        toolbarItem.isEnabled = true
    }

    private func configureImageNavigationToolbarItem(_ toolbarItem: NSToolbarItem, action: Selector) {
        // 오늘 수정: Storyboard item의 target/action 누락을 보완하고,
        // 파일 리스트 상태에 맞춰 validation 전 초기 enabled 값을 설정한다.
        toolbarItem.target = self
        toolbarItem.action = action
        toolbarItem.isEnabled = fileListViewController?.canNavigateImages == true
    }

    private func configureDeletePolygonsToolbarItem(_ toolbarItem: NSToolbarItem, mode: PolygonInteractionMode) {
        // Storyboard의 Delete Polygons item에도 target/action을 보강해서 validation이 안정적으로 동작하게 한다.
        toolbarItem.target = self
        toolbarItem.action = #selector(deletePolygons(_:))
        toolbarItem.isEnabled = mode == .edit
    }

    private func isDeleteFileToolbarItem(_ toolbarItem: NSToolbarItem) -> Bool {
        return toolbarItem.label == ToolbarLabel.deleteFile ||
            toolbarItem.paletteLabel == ToolbarLabel.deleteFile ||
            toolbarItem.action == #selector(deleteFile(_:))
    }

    private func isNextImageToolbarItem(_ toolbarItem: NSToolbarItem) -> Bool {
        // 오늘 수정: Storyboard 연결 전에는 label/paletteLabel로 찾고,
        // 연결 후에는 action으로도 같은 item을 계속 식별할 수 있게 한다.
        return toolbarItem.label == ToolbarLabel.nextImage ||
            toolbarItem.paletteLabel == ToolbarLabel.nextImage ||
            toolbarItem.action == #selector(nextImage(_:))
    }

    private func isPreviousImageToolbarItem(_ toolbarItem: NSToolbarItem) -> Bool {
        // 오늘 수정: Prev Image도 Next Image와 같은 방식으로 Storyboard item을 안정적으로 찾는다.
        return toolbarItem.label == ToolbarLabel.previousImage ||
            toolbarItem.paletteLabel == ToolbarLabel.previousImage ||
            toolbarItem.action == #selector(previousImage(_:))
    }

    private func isDeletePolygonsToolbarItem(_ toolbarItem: NSToolbarItem) -> Bool {
        // 오늘 수정: Storyboard action 연결 전후 어느 상태에서도 Delete Polygons item을 찾을 수 있게 한다.
        return toolbarItem.label == ToolbarLabel.deletePolygons ||
            toolbarItem.paletteLabel == ToolbarLabel.deletePolygons ||
            toolbarItem.action == #selector(deletePolygons(_:))
    }

    private func showSaveError(_ error: Error) {
        let alert = NSAlert(error: error)
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

}
