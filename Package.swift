// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QRDrop",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "QRDropCore",
            targets: ["QRDropCore"]
        ),
        .executable(
            name: "qrdrop",
            targets: ["QRDropCLI"]
        )
    ],
    targets: [
        .target(
            name: "QRDropCore",
            path: "QRDrop",
            exclude: [
                "Assets.xcassets",
                "AppIcon.icns",
                "Info.plist",
                "QRDrop.entitlements",
                "MyApp.swift",
                "ContentView.swift",
                "SenderView.swift",
                "ReceiverView.swift",
                "CameraScannerView.swift"
            ],
            sources: [
                "TransferModels.swift",
                "FountainCoder.swift",
                "CryptoEnvelope.swift",
                "StructuredPayloads.swift",
                "QRGenerator.swift",
                "SenderViewModel.swift",
                "ReceiverViewModel.swift"
            ]
        ),
        .executableTarget(
            name: "QRDropCLI",
            dependencies: ["QRDropCore"],
            path: "Sources/QRDropCLI"
        ),
        .testTarget(
            name: "QRDropTests",
            dependencies: ["QRDropCore"],
            path: "Tests/QRDropTests"
        )
    ]
)
