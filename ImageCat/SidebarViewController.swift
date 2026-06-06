//
//  SidebarViewController.swift
//  ImageCat
//
//  Created by headway on 2026/04/14.
//

import Cocoa

class SidebarViewController: NSViewController {
    @IBOutlet weak var outlineView: NSOutlineView!
    @IBOutlet weak var treeController: NSTreeController!

    private struct SystemFolder {
        let directory: FileManager.SearchPathDirectory
        let iconName: String
        let fallbackNames: [String]
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(outlineViewSelectionDidChange(_:)),
            name: NSOutlineView.selectionDidChangeNotification,
            object: outlineView
        )

        let fileManager = FileManager.default
        let homeURL = fileManager.homeDirectoryForCurrentUser
            
        let systemFolders: [SystemFolder] = [
            SystemFolder(directory: .desktopDirectory, iconName: "desktopcomputer", fallbackNames: ["Desktop", "데스크탑", "데스크톱"]),
            SystemFolder(directory: .downloadsDirectory, iconName: "arrow.down.circle", fallbackNames: ["Downloads", "다운로드"]),
            SystemFolder(directory: .documentDirectory, iconName: "doc.text", fallbackNames: ["Documents", "문서"]),
            SystemFolder(directory: .moviesDirectory, iconName: "film", fallbackNames: ["Movies", "동영상"]),
            SystemFolder(directory: .picturesDirectory, iconName: "photo", fallbackNames: ["Pictures", "사진", "그림"])
        ]
            
        var homeSubItems: [SidebarItem] = []
            
        for folder in systemFolders {
            if let url = resolvedUserFolderURL(for: folder, homeURL: homeURL) {
                let name = fileManager.displayName(atPath: url.path)
                let item = SidebarItem(
                    name: name,
                    iconName: folder.iconName,
                    url: url
                )
                homeSubItems.append(item)
            }
        }
            
        let homeName = fileManager.displayName(atPath: homeURL.path)
        let homeGroup = SidebarItem(name: homeName, iconName: "house.fill", url: homeURL, children: homeSubItems)
            
        let favoriteGroup = SidebarItem(name: "즐겨찾기", iconName: "star", children: [
            SidebarItem(name: "에어드롭", iconName: "dot.radiowaves.left.and.right"),
            SidebarItem(
                name: "응용 프로그램",
                iconName: "app.badge",
                url: fileManager.urls(for: .applicationDirectory, in: .localDomainMask).first
            )
        ])
            
        treeController.addObject(homeGroup)
        treeController.addObject(favoriteGroup)
            
        DispatchQueue.main.async {
            self.outlineView.expandItem(nil, expandChildren: true)
        }
    }

    @objc private func outlineViewSelectionDidChange(_ notification: Notification) {
        let selectedRow = outlineView.selectedRow
        guard selectedRow >= 0 else { return }

        let treeNode = outlineView.item(atRow: selectedRow) as? NSTreeNode
        guard let selectedItem = treeNode?.representedObject as? SidebarItem,
              let folderURL = selectedItem.url else {
            return
        }

        fileListViewController?.folderURL = folderURL
    }

    private var fileListViewController: ViewController? {
        return (parent as? NSSplitViewController)?.splitViewItems
            .compactMap { $0.viewController as? ViewController }
            .first
    }

    private func resolvedUserFolderURL(for folder: SystemFolder, homeURL: URL) -> URL? {
        let fileManager = FileManager.default

        if let url = fileManager.urls(for: folder.directory, in: .userDomainMask).first,
           fileManager.fileExists(atPath: url.path) {
            return url
        }

        for fallbackName in folder.fallbackNames {
            let url = homeURL.appendingPathComponent(fallbackName, isDirectory: true)
            if fileManager.fileExists(atPath: url.path) {
                return url
            }
        }

        return nil
    }
}
