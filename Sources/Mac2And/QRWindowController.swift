import AppKit
import CoreImage
import Foundation

@MainActor
final class QRWindowController: NSWindowController {
  private let imageView = NSImageView()
  private let urlField = NSTextField(labelWithString: "")

  init() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 360, height: 430),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    window.title = "Mac2And"
    window.center()
    super.init(window: window)

    let root = NSStackView()
    root.orientation = .vertical
    root.alignment = .centerX
    root.spacing = 16
    root.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)

    imageView.imageScaling = .scaleProportionallyUpOrDown
    imageView.translatesAutoresizingMaskIntoConstraints = false
    imageView.widthAnchor.constraint(equalToConstant: 280).isActive = true
    imageView.heightAnchor.constraint(equalToConstant: 280).isActive = true

    urlField.lineBreakMode = .byTruncatingMiddle
    urlField.maximumNumberOfLines = 2
    urlField.alignment = .center
    urlField.translatesAutoresizingMaskIntoConstraints = false
    urlField.widthAnchor.constraint(equalToConstant: 300).isActive = true

    let copyButton = NSButton(title: "Copy URL", target: self, action: #selector(copyURL))

    root.addArrangedSubview(imageView)
    root.addArrangedSubview(urlField)
    root.addArrangedSubview(copyButton)
    window.contentView = root
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func show(url: String) {
    urlField.stringValue = url
    imageView.image = makeQRImage(url)
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  @objc private func copyURL() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(urlField.stringValue, forType: .string)
  }

  private func makeQRImage(_ text: String) -> NSImage? {
    let filter = CIFilter(name: "CIQRCodeGenerator")
    filter?.setValue(Data(text.utf8), forKey: "inputMessage")
    filter?.setValue("M", forKey: "inputCorrectionLevel")
    guard let output = filter?.outputImage else { return nil }

    let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
    let rep = NSCIImageRep(ciImage: scaled)
    let image = NSImage(size: rep.size)
    image.addRepresentation(rep)
    return image
  }
}
