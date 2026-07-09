//
//  DocumentWindowController.swift
//  ImageCat
//
//  Created by headway on 2026/06/30.
//

import Cocoa

// 오늘 수정 상세:
// DocumentWindowController는 toolbar뿐 아니라 File 메뉴 항목도 런타임에 보강한다.
// storyboard의 File > Save Automatically는 AppKit document 메뉴 보정 때문에 상태가 흔들릴 수 있으므로,
// NSMenuItemValidation까지 직접 맡아 체크 표시와 enabled 상태를 현재 window 상태와 맞춘다.
class DocumentWindowController: NSWindowController, NSToolbarItemValidation, NSMenuItemValidation {
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

    private enum MenuLabel {
        static let save = "Save"
        static let saveAutomatically = "Save Automatically"
    }

    private enum ToolbarDefaults {
        // 오늘 수정: 사용자가 toolbar 표시 방식을 Icon Only / Icon and Text 등으로 바꾸면
        // 다음 실행에서도 유지되도록 NSToolbar.DisplayMode를 UserDefaults에 저장한다.
        static let displayModeKey = "ImageCat.DocumentToolbar.DisplayMode"
    }

    // 오늘 수정: toolbar displayMode는 사용자가 customize menu에서 바꿀 수 있으므로
    // KVO로 변경을 감지해 즉시 UserDefaults에 저장한다.
    private var toolbarDisplayModeObservation: NSKeyValueObservation?
    // 오늘 수정 상세:
    // Save Automatically는 사용자가 "이번 실행/이번 창에서만" 켜는 작업 모드다.
    // UserDefaults에 저장하지 않아 앱을 새로 시작하면 항상 false(off)에서 출발한다.
    // 자동저장이 꺼진 상태에서 변경된 annotation을 두고 다른 파일로 이동하면 저장 확인 alert를 띄운다.
    private var isSaveAutomaticallyEnabled = false

    override func windowDidLoad() {
        super.windowDidLoad()

        window?.titleVisibility = .hidden
        window?.toolbarStyle = .expanded
        // 오늘 수정: Storyboard 기본값 대신 마지막 사용자의 toolbar 표시 방식을 먼저 복원한다.
        configureToolbarDisplayModePersistence()
        configureFileMenuItems()
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
        // 오늘 수정 상세:
        // toolbar의 Delete File은 이미지 파일을 삭제하지 않는다.
        // 현재 선택된 이미지와 같은 basename의 LabelMe JSON 파일만 삭제하며,
        // 실수로 라벨 파일을 지우지 않도록 먼저 확인 alert를 띄운다.
        guard confirmDeletingCurrentAnnotationFile() else { return }

        do {
            try imagePreviewViewController?.deleteCurrentAnnotationFile()
            updatePolygonToolbarItems()
        } catch {
            showSaveError(error)
        }
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

    @IBAction func saveDocument(_ sender: Any?) {
        // 오늘 수정 상세:
        // File > Save 메뉴가 NSDocument의 기본 saveDocument:로 빠지면
        // 이 앱의 LabelMe JSON 저장 흐름을 타지 않는다.
        // 메뉴 Save와 toolbar Save가 같은 annotation 저장 코드를 쓰도록 여기서 saveAnnotation으로 모은다.
        saveAnnotation(sender)
    }

    @IBAction func toggleSaveAutomatically(_ sender: Any?) {
        // 오늘 수정 상세:
        // 이 토글은 즉시 메뉴 체크 표시만 바꾼다.
        // 상태를 저장하지 않기 때문에 앱을 다시 켜면 기본 off 상태가 된다.
        isSaveAutomaticallyEnabled.toggle()
        updateFileMenuItems()
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

    func saveCurrentAnnotationBeforeNavigationIfNeeded() -> Bool {
        // 오늘 수정 상세:
        // 모든 이미지 전환 경로(File List 직접 선택, a/d, toolbar Next/Prev, 폴더 이동)는
        // ViewController에서 최종적으로 이 함수를 호출한다.
        // 반환값이 false이면 사용자가 Cancel했거나 저장 실패가 난 것이므로 이동을 중단해야 한다.
        guard imagePreviewViewController?.hasUnsavedAnnotationEdits == true else {
            return true
        }

        if !isSaveAutomaticallyEnabled {
            // 자동저장이 꺼져 있으면 macOS 문서 앱처럼 Save / Cancel / Don't Save 선택지를 보여준다.
            return confirmSavingCurrentAnnotationBeforeNavigation()
        }

        do {
            try imagePreviewViewController?.saveCurrentAnnotation()
            return true
        } catch {
            showSaveError(error)
            return false
        }
    }

    private func confirmSavingCurrentAnnotationBeforeNavigation() -> Bool {
        // 오늘 수정 상세:
        // alert 버튼 순서는 사용자가 요청한 예시와 맞춘다.
        // 1번째: 저장하지 않고 이동, 2번째: 이동 취소, 3번째: 저장 후 이동.
        // NSAlert의 반환값도 이 순서에 맞춰 alertFirst/Second/ThirdButtonReturn으로 분기한다.
        let alert = NSAlert()
        alert.alertStyle = .informational
        let imagePath = imagePreviewViewController?.imageURL?.path ?? "the current image"
        alert.messageText = "Save annotations to \"\(imagePath)\" before closing?"
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Save")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return true
        case .alertSecondButtonReturn:
            return false
        case .alertThirdButtonReturn:
            do {
                try imagePreviewViewController?.saveCurrentAnnotation()
                return true
            } catch {
                showSaveError(error)
                return false
            }
        default:
            return false
        }
    }

    private func confirmDeletingCurrentAnnotationFile() -> Bool {
        // 오늘 수정 상세:
        // 삭제 대상은 annotation JSON이므로 warning alert로 확인한다.
        // No를 기본 첫 버튼으로 둬 실수 삭제를 줄이고, Yes는 두 번째 버튼일 때만 true로 처리한다.
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "You are about to permanently delete this label file, proceed anyway?"
        alert.addButton(withTitle: "No")
        alert.addButton(withTitle: "Yes")

        return alert.runModal() == .alertSecondButtonReturn
    }

    private func updatePolygonToolbarItems() {
        let mode = imagePreviewViewController?.polygonInteractionMode ?? .inactive
        updateFileMenuItems()

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

    private func configureFileMenuItems() {
        // 오늘 수정 상세:
        // AppKit의 document-based app 메뉴 보정이 실행 후 File 메뉴를 바꿀 수 있다.
        // 그래서 storyboard 연결만 믿지 않고 windowDidLoad에서 실제 메뉴 item을 title로 찾아
        // Save와 Save Automatically의 target/action을 이 window controller로 다시 연결한다.
        fileMenuItem(withTitle: MenuLabel.save)?.target = self
        fileMenuItem(withTitle: MenuLabel.save)?.action = #selector(saveAnnotation(_:))
        fileMenuItem(withTitle: MenuLabel.saveAutomatically)?.target = self
        fileMenuItem(withTitle: MenuLabel.saveAutomatically)?.action = #selector(toggleSaveAutomatically(_:))
        updateFileMenuItems()
    }

    private func updateFileMenuItems() {
        // 오늘 수정 상세:
        // Save Automatically는 checkable menu item이다.
        // 상태는 UserDefaults가 아니라 isSaveAutomaticallyEnabled 런타임 변수만 반영한다.
        fileMenuItem(withTitle: MenuLabel.saveAutomatically)?.state = isSaveAutomaticallyEnabled ? .on : .off
    }

    private func fileMenuItem(withTitle title: String) -> NSMenuItem? {
        guard let fileMenu = NSApp.mainMenu?.items.first(where: { $0.title == "File" })?.submenu else {
            return nil
        }

        return menuItem(withTitle: title, in: fileMenu)
    }

    private func menuItem(withTitle title: String, in menu: NSMenu) -> NSMenuItem? {
        for item in menu.items {
            if item.title == title {
                return item
            }
            if let submenu = item.submenu,
               let foundItem = menuItem(withTitle: title, in: submenu) {
                return foundItem
            }
        }

        return nil
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

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(saveAnnotation(_:)), #selector(saveDocument(_:)):
            return imagePreviewViewController != nil
        case #selector(toggleSaveAutomatically(_:)):
            menuItem.state = isSaveAutomaticallyEnabled ? .on : .off
            return true
        default:
            return true
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
