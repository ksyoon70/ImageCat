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
        // 오늘 수정: Delete Polygons toolbar item을 코드에서 식별하기 위한 label이다.
        static let deletePolygons = "Delete Polygons"
    }

    override func windowDidLoad() {
        super.windowDidLoad()

        window?.titleVisibility = .hidden
        window?.toolbarStyle = .expanded
        updatePolygonToolbarItems()
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
            default:
                break
            }
        }
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.action {
        case #selector(toggleCreatePolygons(_:)):
            return imagePreviewViewController?.polygonInteractionMode != .create
        case #selector(toggleEditPolygons(_:)):
            return imagePreviewViewController?.polygonInteractionMode != .edit
        case #selector(saveAnnotation(_:)):
            return imagePreviewViewController != nil
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
