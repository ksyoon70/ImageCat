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
    // Sidebar 폭을 항목 중 가장 긴 표시 이름에 맞추기 위해 원본 트리를 보관한다.
    private var sidebarItems: [SidebarItem] = []

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
            
        sidebarItems = [homeGroup, favoriteGroup]
        sidebarItems.forEach { treeController.addObject($0) }
            
        DispatchQueue.main.async {
            self.outlineView.expandItem(nil, expandChildren: true)
            // outlineView가 펼쳐진 뒤 indentation 값을 반영해 고정 폭을 계산한다.
            self.configureFixedSidebarWidth()
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()

        // Split View item은 parent 연결 이후에 안정적으로 찾을 수 있어 표시 시점에도 한 번 더 적용한다.
        configureFixedSidebarWidth()
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

    private var ownSplitViewItem: NSSplitViewItem? {
        return (parent as? NSSplitViewController)?.splitViewItems
            .first { $0.viewController === self }
    }

    private func configureFixedSidebarWidth() {
        let width = sidebarWidthForLargestItem()
        guard width > 0 else { return }

        ownSplitViewItem?.canCollapse = false
        // 최소/최대 폭을 같게 두어 sidebar를 항목 최대 폭으로 고정한다.
        ownSplitViewItem?.minimumThickness = width
        ownSplitViewItem?.maximumThickness = width

        if let splitViewController = parent as? NSSplitViewController,
           splitViewController.splitViewItems.first?.viewController === self {
            // 실제 divider 위치도 같은 값으로 맞춰 초기 표시 폭과 제한 폭이 어긋나지 않게 한다.
            splitViewController.splitView.setPosition(width, ofDividerAt: 0)
        }
    }

    private func sidebarWidthForLargestItem() -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize)
        ]
        // 아이콘, disclosure 영역, cell padding까지 포함해 텍스트가 잘리지 않을 여유 폭을 더한다.
        let rowChromeWidth: CGFloat = 64

        func width(for item: SidebarItem, level: Int) -> CGFloat {
            let textWidth = ceil((item.name as NSString).size(withAttributes: attributes).width)
            let itemWidth = textWidth + CGFloat(level) * outlineView.indentationPerLevel + rowChromeWidth
            let childWidth = item.children
                .map { width(for: $0, level: level + 1) }
                .max() ?? 0
            return max(itemWidth, childWidth)
        }

        return sidebarItems
            .map { width(for: $0, level: 0) }
            .max() ?? 0
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
