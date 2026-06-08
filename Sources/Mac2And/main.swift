import AppKit

if CommandLine.arguments.contains("--self-test") {
  SelfTest.run()
  exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
