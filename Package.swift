// swift-tools-version:5.10
import PackageDescription

let package = Package(
  name: "webkit-cli",
  platforms: [.macOS(.v14)],
  targets: [
    .executableTarget(
      name: "webkit-cli",
      linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("WebKit")]
    )
  ]
)
