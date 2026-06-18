//
//  ImagePreviewViewController.swift
//  ImageCat
//

import Cocoa

class ImagePreviewViewController: NSViewController {
    var imageURL: URL? {
        didSet {
            updateImage()
        }
    }

    private let imageView = NSImageView()
    private let emptyLabel = NSTextField(labelWithString: "이미지를 선택하세요.")

    override func viewDidLoad() {
        super.viewDidLoad()
        configureView()
        updateImage()
    }

    override func viewDidAppear() {
        super.viewDidAppear()

        ownSplitViewItem?.minimumThickness = 220
        ownSplitViewItem?.maximumThickness = CGFloat.greatestFiniteMagnitude
    }

    private func configureView() {
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        imageView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        imageView.setContentHuggingPriority(.defaultLow, for: .vertical)
        imageView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(imageView)
        view.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            imageView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            imageView.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            imageView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),

            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    private func updateImage() {
        guard isViewLoaded else { return }
        guard let imageURL = imageURL, let image = NSImage(contentsOf: imageURL) else {
            imageView.image = nil
            emptyLabel.isHidden = false
            return
        }

        imageView.image = image
        emptyLabel.isHidden = true
    }

    private var ownSplitViewItem: NSSplitViewItem? {
        return (parent as? NSSplitViewController)?.splitViewItems
            .first { $0.viewController === self }
    }
    
    func applyCurve(using curveControl: ImageCurveControl) {
        guard let imageURL = self.imageURL,
              let originalImage = NSImage(contentsOf: imageURL) else { return }

        imageView.image = curveControl.apply(to: originalImage)
    }
}
