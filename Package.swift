// swift-tools-version: 5.9
// Stiletto — compile-time-checked dependency injection for Swift.

import PackageDescription
import CompilerPluginSupport

let package = Package(
    name: "Stiletto",
    platforms: [.iOS(.v13), .macOS(.v10_15)],
    products: [
        // The runtime container + macro declarations consumers import.
        .library(
            name: "Stiletto",
            targets: ["Stiletto"]
        ),
        // Build-tool plugin that auto-generates ordered DI registration per target.
        .plugin(
            name: "StilettoPlugin",
            targets: ["StilettoPlugin"]
        ),
        // The scanner/codegen executable, exported so projects can also run the
        // whole-program `--validate` pass from a build phase or CI.
        .executable(
            name: "StilettoGenerator",
            targets: ["StilettoGenerator"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "601.0.0-latest"),
    ],
    targets: [
        // Macro implementations (compiler plugin).
        .macro(
            name: "StilettoMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ]
        ),

        // Public library: DIContainer runtime, property wrappers, macro declarations.
        .target(
            name: "Stiletto",
            dependencies: ["StilettoMacros"]
        ),

        // Whole-module DI code generator invoked by the StilettoPlugin build tool
        // (generate mode) and by a project-level build phase (validate mode).
        .executableTarget(
            name: "StilettoGenerator",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ]
        ),

        // Build-tool plugin that runs StilettoGenerator over a target's sources.
        .plugin(
            name: "StilettoPlugin",
            capability: .buildTool(),
            dependencies: ["StilettoGenerator"]
        ),

        // End-to-end example (and smoke test): uses the macros + plugin, then
        // resolves the generated graph at runtime. `swift run StilettoExample`.
        .executableTarget(
            name: "StilettoExample",
            dependencies: ["Stiletto"],
            plugins: ["StilettoPlugin"]
        ),

        .testTarget(
            name: "StilettoTests",
            dependencies: [
                "Stiletto",
                "StilettoMacros",
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ]
        ),
    ]
)
