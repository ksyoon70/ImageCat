//
//  SidebarItem.swift
//  ImageCat
//
//  Created by headway on 2026/04/14.
//

import Cocoa

class SidebarItem: NSObject {
    @objc dynamic var name: String
    @objc dynamic var icon: NSImage?
    @objc dynamic var url: URL?
    @objc dynamic var children: [SidebarItem] = []
    @objc dynamic var isLeaf: Bool { return children.isEmpty }
    
    init(
        name: String,
        iconName: String? = nil,
        url: URL? = nil,
        children: [SidebarItem] = []
    ) {
        self.name = name
        self.url = url
        if let iconName = iconName {
            self.icon = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)
        }
        self.children = children
    }
}
