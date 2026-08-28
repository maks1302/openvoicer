// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "OpenVoicer",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OpenVoicerSubtitles", targets: ["OpenVoicerSubtitles"]),
        .library(name: "OpenVoicerModels", targets: ["OpenVoicerModels"]),
        .library(name: "OpenVoicerExport", targets: ["OpenVoicerExport"])
    ],
    targets: [
        .target(
            name: "OpenVoicerSubtitles",
            path: "openvoicer/Subtitles"
        ),
        .target(
            name: "OpenVoicerModels",
            path: "openvoicer/Models"
        ),
        .target(
            name: "OpenVoicerExport",
            path: "openvoicer/Export",
            exclude: ["ExportController.swift"]
        ),
        .testTarget(
            name: "OpenVoicerSubtitlesTests",
            dependencies: ["OpenVoicerSubtitles", "OpenVoicerModels", "OpenVoicerExport"],
            path: "openvoicerTests"
        )
    ]
)
