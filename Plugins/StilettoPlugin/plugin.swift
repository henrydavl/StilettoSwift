//
//  plugin.swift
//  StilettoPlugin
//
//  SwiftPM build-tool plugin that runs `StilettoGenerator` over a target's Swift
//  sources before compilation, emitting `GeneratedDI.swift` into the build.
//

import PackagePlugin
import Foundation

@main
struct StilettoPlugin: BuildToolPlugin {
    /// For SwiftPM package targets (the modules).
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        guard let swiftTarget = target as? SwiftSourceModuleTarget else {
            return []
        }
        let inputFiles = swiftTarget.sourceFiles(withSuffix: "swift").map(\.path)
        return [
            makeCommand(
                generator: try context.tool(named: "StilettoGenerator").path,
                outputPath: context.pluginWorkDirectory.appending("GeneratedDI.swift"),
                moduleName: target.name,
                inputFiles: inputFiles
            )
        ]
    }

    private func makeCommand(
        generator: Path,
        outputPath: Path,
        moduleName: String,
        inputFiles: [Path]
    ) -> Command {
        .buildCommand(
            displayName: "Stiletto: generating DI graph for \(moduleName)",
            executable: generator,
            arguments: ["--output", outputPath.string, "--module", moduleName]
                + inputFiles.map(\.string),
            inputFiles: inputFiles,
            outputFiles: [outputPath]
        )
    }
}

#if canImport(XcodeProjectPlugin)
import XcodeProjectPlugin

// Required for the plugin to run on an Xcode project target (the app), as opposed
// to a SwiftPM package target. Without this conformance the build fails with
// "Plugin doesn't support Xcode projects".
extension StilettoPlugin: XcodeBuildToolPlugin {
    func createBuildCommands(context: XcodePluginContext, target: XcodeTarget) throws -> [Command] {
        let inputFiles = target.inputFiles
            .filter { $0.path.extension == "swift" }
            .map(\.path)
        return [
            makeCommand(
                generator: try context.tool(named: "StilettoGenerator").path,
                outputPath: context.pluginWorkDirectory.appending("GeneratedDI.swift"),
                moduleName: target.displayName,
                inputFiles: inputFiles
            )
        ]
    }
}
#endif
