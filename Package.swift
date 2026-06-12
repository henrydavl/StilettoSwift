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

        // Scanner/graph/codegen logic, as a library so the tests can link it.
        // (Linking the executable target into the test bundle would pull in a
        // second copy of SwiftSyntax next to StilettoMacros' and crash the
        // runtime's metadata instantiation.)
        .target(
            name: "StilettoGeneratorCore",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ]
        ),

        // Whole-module DI code generator invoked by the StilettoPlugin build tool
        // (generate mode) and by a project-level build phase (validate mode).
        .executableTarget(
            name: "StilettoGenerator",
            dependencies: ["StilettoGeneratorCore"]
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

        // Drives the built StilettoGenerator binary as a subprocess. It must NOT
        // link StilettoGeneratorCore: the test bundle already contains the macro
        // target's copy of SwiftSyntax (via SwiftSyntaxMacrosTestSupport), and a
        // second SwiftSyntax linked via the core library duplicates type metadata
        // and traps the Swift runtime.
        .testTarget(
            name: "StilettoGeneratorTests"
        ),
    ]
)
