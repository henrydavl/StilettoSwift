//
//  main.swift
//  StilettoGenerator
//
//  Thin CLI over StilettoGeneratorCore. Two modes:
//
//  1. GENERATE (per target, run by StilettoPlugin):
//       StilettoGenerator --output <path> --module <name> <file1.swift> ...
//     Scans one target's sources, topologically orders its `@Provide` bindings,
//     detects intra-target cycles, and emits a `GeneratedDI.register()`. It does
//     NOT fail on cross-module dependencies — those are validated by the
//     aggregate pass below — so no per-target `external` lists are needed.
//
//  2. VALIDATE (whole program, run once as a pre-build step):
//       StilettoGenerator --validate <rootDirOrFile> ...
//     Recursively scans every source root (all modules + the app), builds the
//     COMPLETE provider graph, and fails the build (`error:` + non-zero exit) on
//     any unsatisfied dependency or cycle anywhere. Because it sees every
//     provider, it needs no `external` declarations — this is what lets you move
//     a type between modules without touching any DI bookkeeping.
//

import Foundation
import StilettoGeneratorCore

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func runValidate(roots: [String]) -> Never {
    let result = validateProgram(roots: roots)
    if !result.errors.isEmpty {
        fail(result.errors.joined(separator: "\n"))
    }
    print("StilettoGenerator: validated \(result.providerCount) providers across \(result.fileCount) files — OK")
    exit(0)
}

func runGenerate(outputPath: String, moduleName: String, files: [String]) -> Never {
    let output: String
    switch generateModuleSource(moduleName: moduleName, files: files) {
    case .failure(let error): fail(error.description)
    case .success(let source): output = source
    }

    let outputURL = URL(fileURLWithPath: outputPath)
    try? FileManager.default.createDirectory(
        at: outputURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    do {
        try output.write(to: outputURL, atomically: true, encoding: .utf8)
    } catch {
        fail("error: StilettoGenerator failed to write \(outputPath): \(error)")
    }
    exit(0)
}

// MARK: - Entry point

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.first == "--validate" {
    runValidate(roots: Array(arguments.dropFirst()))
} else {
    var outputPath: String?
    var moduleName = "Module"
    var inputFiles: [String] = []
    var iterator = arguments.makeIterator()
    while let arg = iterator.next() {
        switch arg {
        case "--output": outputPath = iterator.next()
        case "--module": moduleName = iterator.next() ?? moduleName
        default: inputFiles.append(arg)
        }
    }
    guard let outputPath else {
        fail("error: StilettoGenerator requires --output <path> (or --validate <roots>)")
    }
    runGenerate(outputPath: outputPath, moduleName: moduleName, files: inputFiles)
}
