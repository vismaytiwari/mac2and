import AppKit

if CommandLine.arguments.contains("--self-test") {
  SelfTest.run()
  exit(0)
}

// Debug/verification: write a QR PNG for the given text. `--qr <text> <out.png>`
if let qrIndex = CommandLine.arguments.firstIndex(of: "--qr"),
   qrIndex + 2 < CommandLine.arguments.count {
  let text = CommandLine.arguments[qrIndex + 1]
  let path = CommandLine.arguments[qrIndex + 2]
  guard
    let image = QRCode.image(for: text),
    let tiff = image.tiffRepresentation,
    let rep = NSBitmapImageRep(data: tiff),
    let png = rep.representation(using: .png, properties: [:])
  else {
    FileHandle.standardError.write(Data("QR generation failed (text too long?)\n".utf8))
    exit(1)
  }
  try? png.write(to: URL(fileURLWithPath: path))
  print("wrote \(path)")
  exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
