//
//  ColorDotView.swift
//  ImageCat
//
//  Created by headway on 2026/06/30.
//

import Cocoa

final class ColorDotView: NSView {
    var color: NSColor {
        didSet {
            needsDisplay = true
        }
    }

    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        self.color = .systemBlue
        super.init(coder: coder)
        wantsLayer = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        color.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}
