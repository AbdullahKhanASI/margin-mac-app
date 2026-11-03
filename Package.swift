// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Margin",
    platforms: [.macOS(.v14)],
    targets: [
        // Thin C layer over Apple's private MultitouchSupport / DisplayServices / CGS APIs.
        // Everything is resolved with dlopen/dlsym at runtime, so nothing private is linked.
        .target(name: "CMultitouch"),
        .executableTarget(
            name: "Margin",
            dependencies: ["CMultitouch"]
        ),
    ]
)
