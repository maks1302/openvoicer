// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "DubLab",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DubLabSubtitles", targets: ["DubLabSubtitles"]),
        .library(name: "DubLabModels", targets: ["DubLabModels"]),
        .library(name: "DubLabExport", targets: ["DubLabExport"])
    ],
    targets: [
        .target(
            name: "DubLabSubtitles",
            path: "openvoicer/Subtitles"
        ),
        .target(
            name: "DubLabModels",
            path: "openvoicer/Models"
        ),
        .target(
            name: "DubLabExport",
            path: "openvoicer/Export",
            exclude: ["ExportController.swift"]
        ),
        .testTarget(
            name: "DubLabSubtitlesTests",
            dependencies: ["DubLabSubtitles", "DubLabModels", "DubLabExport"],
            path: "openvoicerTests"
        )
    ]
)
