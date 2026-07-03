//
//  DocumentWindowController.swift
//  ImageCat
//
//  Created by headway on 2026/06/30.
//

import Cocoa

class DocumentWindowController: NSWindowController {

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

    @IBAction func toggleEditPolygons(_ sender: Any?) {
        guard let imagePreviewViewController else { return }

        // Edit Polygons는 다시 누르면 비활성화되고, 켜진 동안 Create Polygons를 잠근다.
        let nextMode: PolygonInteractionMode = imagePreviewViewController.polygonInteractionMode == .edit
            ? .inactive
            : .edit
        imagePreviewViewController.setPolygonInteractionMode(nextMode)
        updatePolygonToolbarItems()
    }

    @IBAction func toggleCreatePolygons(_ sender: Any?) {
        guard let imagePreviewViewController else { return }

        // Create Polygons는 기존 라벨 편집을 막고 새 도형 생성 입력만 받는다.
        let nextMode: PolygonInteractionMode = imagePreviewViewController.polygonInteractionMode == .create
            ? .inactive
            : .create
        imagePreviewViewController.setPolygonInteractionMode(nextMode)
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

        // Create/Edit 버튼은 서로 배타적인 모드라서 반대 모드가 켜지면 비활성화한다.
        window?.toolbar?.items.forEach { toolbarItem in
            switch toolbarItem.action {
            case #selector(toggleCreatePolygons(_:)):
                toolbarItem.isEnabled = mode != .edit
                toolbarItem.label = "Create Polygons"
                toolbarItem.paletteLabel = "Create Polygons"
            case #selector(toggleEditPolygons(_:)):
                toolbarItem.isEnabled = mode != .create
                toolbarItem.label = "Edit Polygons"
                toolbarItem.paletteLabel = "Edit Polygons"
            case #selector(saveAnnotation(_:)):
                toolbarItem.isEnabled = imagePreviewViewController != nil
            default:
                break
            }
        }
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
