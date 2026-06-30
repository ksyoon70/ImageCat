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

        let isEditing = !imagePreviewViewController.isPolygonEditingEnabled
        imagePreviewViewController.setPolygonEditingEnabled(isEditing)

        if let toolbarItem = sender as? NSToolbarItem {
            toolbarItem.label = isEditing ? "Done Editing" : "Edit Polygons"
            toolbarItem.paletteLabel = toolbarItem.label
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

}
