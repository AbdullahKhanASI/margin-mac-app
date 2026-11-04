// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Margin",
    platforms: [.macOS(.v14)],
    targets: [
        // Thin C layer over Apple's private MultitouchSupport / DisplayServices / CGS APIs.
        // Everything is resolved with dlopen/dlsym at runtime, so nothing private is linked.
        .target(name: "CMultitouch"),
        // The gesture model and its pure logic, in plain Foundation so it can be tested without the app.
        .target(name: "MarginCore"),
        .executableTarget(
            name: "Margin",
            dependencies: ["CMultitouch", "MarginCore"]
        ),
        .testTarget(
            name: "MarginTests",
            dependencies: ["MarginCore"]
        ),
    ]
)
