// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "WebTime",
  platforms: [.macOS(.v13)],
  products: [
    .library(name: "WebTimeCore", targets: ["WebTimeCore"]),
    .executable(name: "WebTime", targets: ["WebTimeApp"]),
    .executable(name: "WebTimeSetup", targets: ["WebTimeSetup"]),
    .executable(name: "webtimed", targets: ["WebTimeDaemon"]),
  ],
  targets: [
    .target(name: "WebTimeCore"),
    .executableTarget(
      name: "WebTimeApp",
      dependencies: ["WebTimeCore"]
    ),
    .executableTarget(
      name: "WebTimeDaemon",
      dependencies: ["WebTimeCore"]
    ),
    .executableTarget(name: "WebTimeSetup"),
    .executableTarget(
      name: "WebTimeSelfTest",
      dependencies: ["WebTimeCore"]
    ),
  ]
)
