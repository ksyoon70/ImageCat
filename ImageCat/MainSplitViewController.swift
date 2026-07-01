//
//  MainSplitViewController.swift
//  ImageCat
//

import Cocoa

final class MainSplitViewController: NSSplitViewController {
    private enum Defaults {
        static let sidebarMinimumWidth: CGFloat = 160
        static let fileListMinimumWidth: CGFloat = 100
        static let previewMinimumWidth: CGFloat = 220
        static let controlMinimumWidth: CGFloat = 180
        static let unboundedMaximumWidth: CGFloat = 10_000
        static let maximumWidthThreshold: CGFloat = 9_999
    }

    private var originalWindowMinimumSize: NSSize?

    override func viewDidLoad() {
        super.viewDidLoad()

        splitView.delegate = self
        applyDefaultSplitLimits()
    }

    override func viewDidAppear() {
        super.viewDidAppear()

        applyDefaultSplitLimits()
        updateWindowMinimumSize()
    }

    override func viewDidLayout() {
        super.viewDidLayout()

        applyDefaultSplitLimits()
    }

    override func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        return false
    }

    override func splitView(
        _ splitView: NSSplitView,
        shouldCollapseSubview subview: NSView,
        forDoubleClickOnDividerAt dividerIndex: Int
    ) -> Bool {
        return false
    }

    override func splitView(
        _ splitView: NSSplitView,
        constrainSplitPosition proposedPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        guard splitView === self.splitView,
              dividerIndex >= 0,
              dividerIndex < splitViewItems.count - 1 else {
            return proposedPosition
        }

        let splitLength = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
        let dividerThickness = splitView.dividerThickness

        var lowerBound = minimumLength(for: 0...dividerIndex, dividerThickness: dividerThickness)
        var upperBound = splitLength
            - dividerThickness
            - minimumLength(for: (dividerIndex + 1)..<splitViewItems.count, dividerThickness: dividerThickness)

        if let leftMaximum = maximumLength(for: 0...dividerIndex, dividerThickness: dividerThickness) {
            upperBound = min(upperBound, leftMaximum)
        }

        if let rightMaximum = maximumLength(
            for: (dividerIndex + 1)..<splitViewItems.count,
            dividerThickness: dividerThickness
        ) {
            lowerBound = max(lowerBound, splitLength - dividerThickness - rightMaximum)
        }

        guard lowerBound <= upperBound else {
            return super.splitView(splitView, constrainSplitPosition: proposedPosition, ofSubviewAt: dividerIndex)
        }

        return min(max(proposedPosition, lowerBound), upperBound)
    }

    private func applyDefaultSplitLimits() {
        for item in splitViewItems {
            item.canCollapse = false
            item.maximumThickness = Defaults.unboundedMaximumWidth
        }

        if let sidebarItem = splitViewItem(for: SidebarViewController.self) {
            let sidebarWidth = max(sidebarItem.minimumThickness, Defaults.sidebarMinimumWidth)
            sidebarItem.minimumThickness = sidebarWidth
            sidebarItem.maximumThickness = sidebarWidth
        }

        if let fileListItem = splitViewItem(for: ViewController.self) {
            fileListItem.minimumThickness = Defaults.fileListMinimumWidth
            fileListItem.maximumThickness = Defaults.unboundedMaximumWidth
            fileListItem.holdingPriority = .defaultLow
        }

        if let previewItem = splitViewItem(for: ImagePreviewViewController.self) {
            previewItem.minimumThickness = Defaults.previewMinimumWidth
            previewItem.maximumThickness = Defaults.unboundedMaximumWidth
            previewItem.holdingPriority = .defaultLow
        }

        if let controlItem = splitViewItem(for: ImageControlViewController.self) {
            controlItem.minimumThickness = Defaults.controlMinimumWidth
            controlItem.maximumThickness = Defaults.unboundedMaximumWidth
            controlItem.holdingPriority = .defaultLow
        }
    }

    private func splitViewItem<T: NSViewController>(for type: T.Type) -> NSSplitViewItem? {
        return splitViewItems.first { $0.viewController is T }
    }

    private func minimumLength<Bounds: RangeExpression>(
        for bounds: Bounds,
        dividerThickness: CGFloat
    ) -> CGFloat where Bounds.Bound == Int {
        let indexes = splitViewItems.indices.filter { bounds.contains($0) }
        guard !indexes.isEmpty else { return 0 }

        let itemLength = indexes.reduce(CGFloat(0)) { partialResult, index in
            partialResult + splitViewItems[index].minimumThickness
        }

        return itemLength + CGFloat(indexes.count - 1) * dividerThickness
    }

    private func maximumLength<Bounds: RangeExpression>(
        for bounds: Bounds,
        dividerThickness: CGFloat
    ) -> CGFloat? where Bounds.Bound == Int {
        let indexes = splitViewItems.indices.filter { bounds.contains($0) }
        guard !indexes.isEmpty else { return 0 }

        var itemLength = CGFloat(0)
        for index in indexes {
            let maximum = splitViewItems[index].maximumThickness
            guard maximum >= 0, maximum < Defaults.maximumWidthThreshold else { return nil }
            itemLength += maximum
        }

        return itemLength + CGFloat(indexes.count - 1) * dividerThickness
    }

    private func updateWindowMinimumSize() {
        guard splitView.isVertical, let window = view.window else { return }

        if originalWindowMinimumSize == nil {
            originalWindowMinimumSize = window.minSize
        }

        let minimumContentWidth = minimumLength(
            for: splitViewItems.indices,
            dividerThickness: splitView.dividerThickness
        )
        let minimumFrameWidth = window.frameRect(
            forContentRect: NSRect(x: 0, y: 0, width: minimumContentWidth, height: view.bounds.height)
        ).width

        let originalMinimumSize = originalWindowMinimumSize ?? window.minSize
        var minimumSize = originalMinimumSize
        minimumSize.width = max(originalMinimumSize.width, minimumFrameWidth)
        window.minSize = minimumSize
    }
}
