// swift-tools-version:5.10
import PackageDescription

let package = Package(
  name: "webkit-cli",
  platforms: [.macOS(.v14)],
  products: [.executable(name: "webkit-cli", targets: ["webkit-cli"])],
  targets: [
    // Linux: WPE WebKit 2.54+ — the WPEPlatform headless display for tabs, Wayland for windows (Debian sid/forky: libwpewebkit-2.0-dev)
    .systemLibrary(name: "CWPE", path: "Sources/CWPE", pkgConfig: "wpe-webkit-2.0 wpe-platform-headless-2.0 wpe-platform-wayland-2.0 cairo"),
    .target(name: "WPEShim", dependencies: ["CWPE"], path: "Sources/WPEShim"),
    .executableTarget(
      name: "webkit-cli",
      dependencies: [.target(name: "WPEShim", condition: .when(platforms: [.linux]))],
      linkerSettings: [
        .linkedFramework("AppKit", .when(platforms: [.macOS])),
        .linkedFramework("WebKit", .when(platforms: [.macOS])),
      ]
    ),
  ]
)
