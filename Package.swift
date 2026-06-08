// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "Mac2And",
  platforms: [
    .macOS(.v13),
  ],
  products: [
    .executable(name: "Mac2And", targets: ["Mac2And"]),
  ],
  targets: [
    .executableTarget(
      name: "Mac2And",
      resources: [
        .copy("Resources"),
      ],
      linkerSettings: [
        .linkedFramework("AppKit"),
        .linkedFramework("CryptoKit"),
        .linkedFramework("Network"),
        .linkedFramework("CoreImage"),
      ]
    ),
  ]
)
