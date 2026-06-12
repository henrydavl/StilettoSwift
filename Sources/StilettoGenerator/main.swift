//
//  main.swift
//  StilettoGenerator
//
//  Two modes:
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
import SwiftSyntax
import SwiftParser

// MARK: - Model

/// A `@Provide`-annotated implementation discovered in the sources.
struct Provider {
    let implName: String       // e.g. "DefaultHeaderProvider"
    let boundType: String      // e.g. "HeaderProviderProtocol"
    let scope: String          // e.g. "session"
    let dependencies: [String] // constructor dep types, when @InjectConstructor present
    let hasInject: Bool
}

// MARK: - Helpers

/// Strips a trailing `.self` from a metatype expression like `Foo.self`.
func stripDotSelf(_ text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.hasSuffix(".self") ? String(trimmed.dropLast(".self".count)) : trimmed
}

/// Normalizes a type annotation to a bare type name for graph matching.
func normalizeType(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

// MARK: - Syntax scanning

final class DIScanner: SyntaxVisitor {
    var providers: [Provider] = []
    /// Bound types registered via the manual `@Provides var x: T = ...` wrapper.
    var manualProvided: Set<String> = []
    /// Types declared in an `external` list (genuine third-party / non-scanned deps).
    var externals: Set<String> = []

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        guard let provideAttr = node.attributes.firstAttribute(named: "Provide") else {
            return .visitChildren
        }
        let arguments = provideAttr.arguments?.as(LabeledExprListSyntax.self)

        // A leading positional argument binds to that type; with no positional
        // argument the class binds to itself (self-binding).
        var boundType = node.name.text
        if let first = arguments?.first, first.label == nil {
            boundType = stripDotSelf(first.expression.trimmedDescription)
        }

        var scope = "singleton"
        for argument in arguments ?? [] where argument.label?.text == "scope" {
            if let member = argument.expression.as(MemberAccessExprSyntax.self) {
                scope = member.declName.baseName.text
            }
        }

        let hasInject = node.attributes.firstAttribute(named: "InjectConstructor") != nil
            || node.attributes.firstAttribute(named: "LazyInjectConstructor") != nil

        var dependencies: [String] = []
        if hasInject, let initializer = node.firstInitializer {
            // Parameters with a default value are not injected (they keep their
            // default, e.g. an SDK singleton), so they are not graph edges.
            dependencies = initializer.signature.parameterClause.parameters
                .filter { $0.defaultValue == nil }
                .map { normalizeType($0.type.trimmedDescription) }
        }

        providers.append(
            Provider(
                implName: node.name.text,
                boundType: boundType,
                scope: scope,
                dependencies: dependencies,
                hasInject: hasInject
            )
        )
        return .visitChildren
    }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        // Manual registration: `@Provides var x: SomeType = ...` provides SomeType.
        if node.attributes.firstAttribute(named: "Provides") != nil {
            for binding in node.bindings {
                if let annotation = binding.typeAnnotation {
                    manualProvided.insert(normalizeType(annotation.type.trimmedDescription))
                }
            }
        }

        // Optional escape hatch: `static let external: [Any.Type] = [A.self, B.self]`.
        for binding in node.bindings {
            guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self),
                  pattern.identifier.text == "external",
                  let array = binding.initializer?.value.as(ArrayExprSyntax.self) else {
                continue
            }
            for element in array.elements {
                externals.insert(stripDotSelf(element.expression.trimmedDescription))
            }
        }
        return .visitChildren
    }
}

extension AttributeListSyntax {
    /// Returns the first attribute whose name matches, ignoring leading module
    /// qualification (e.g. both `@Provide` and `@Stiletto.Provide`).
    func firstAttribute(named name: String) -> AttributeSyntax? {
        for element in self {
            guard let attribute = element.as(AttributeSyntax.self) else { continue }
            let attrName = attribute.attributeName.trimmedDescription
            if attrName == name || attrName.hasSuffix(".\(name)") {
                return attribute
            }
        }
        return nil
    }
}

extension ClassDeclSyntax {
    /// The first initializer declared in the class body, if any.
    var firstInitializer: InitializerDeclSyntax? {
        memberBlock.members
            .compactMap { $0.decl.as(InitializerDeclSyntax.self) }
            .first
    }
}

// MARK: - Shared scanning / graph utilities

func scanFiles(_ files: [String]) -> DIScanner {
    let scanner = DIScanner(viewMode: .sourceAccurate)
    for path in files {
        guard let source = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
        scanner.walk(Parser.parse(source: source))
    }
    return scanner
}

/// Recursively collects `.swift` files from the given directories (or returns a
/// passed file directly), skipping build/dependency/test directories.
func collectSwiftFiles(from paths: [String]) -> [String] {
    let excluded = ["/.build/", "/Pods/", "/Test/", "/Tests/", "/DerivedData/", "/.git/"]
    let fm = FileManager.default
    var result: [String] = []
    for path in paths {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else { continue }
        if isDir.boolValue {
            guard let enumerator = fm.enumerator(atPath: path) else { continue }
            for case let relative as String in enumerator where relative.hasSuffix(".swift") {
                let full = (path as NSString).appendingPathComponent(relative)
                if !excluded.contains(where: { full.contains($0) }) {
                    result.append(full)
                }
            }
        } else if path.hasSuffix(".swift") {
            result.append(path)
        }
    }
    return result
}

/// Returns the cycle path if the providers contain a dependency cycle, else nil.
/// Only edges between in-scope providers participate.
func detectCycle(_ providers: [Provider]) -> [String]? {
    var providerByBoundType: [String: Provider] = [:]
    for provider in providers { providerByBoundType[provider.boundType] = provider }

    enum Mark { case visiting, done }
    var marks: [String: Mark] = [:]
    var cyclePath: [String]?

    func visit(_ provider: Provider, _ stack: [String]) -> Bool {
        switch marks[provider.boundType] {
        case .done: return true
        case .visiting: cyclePath = stack + [provider.boundType]; return false
        case .none: break
        }
        marks[provider.boundType] = .visiting
        for dependency in provider.dependencies {
            if let dep = providerByBoundType[dependency], !visit(dep, stack + [provider.boundType]) {
                return false
            }
        }
        marks[provider.boundType] = .done
        return true
    }

    for provider in providers where !visit(provider, []) { return cyclePath }
    return nil
}

// MARK: - VALIDATE mode (whole program)

func runValidate(roots: [String]) -> Never {
    let files = collectSwiftFiles(from: roots)
    let scanner = scanFiles(files)

    let providedTypes = Set(scanner.providers.map(\.boundType))
        .union(scanner.manualProvided)
        .union(scanner.externals)

    var errors: [String] = []
    for provider in scanner.providers {
        for dependency in provider.dependencies where !providedTypes.contains(dependency) {
            errors.append(
                "error: DI graph: \(provider.implName) requires '\(dependency)', which is not "
                + "provided by any @Provide (or @Provides) in the program. Annotate its "
                + "implementation with @Provide, or declare it external."
            )
        }
    }
    if let cycle = detectCycle(scanner.providers) {
        errors.append("error: DI graph: dependency cycle detected: \(cycle.joined(separator: " → "))")
    }

    if !errors.isEmpty {
        fail(errors.joined(separator: "\n"))
    }
    print("StilettoGenerator: validated \(scanner.providers.count) providers across \(files.count) files — OK")
    exit(0)
}

// MARK: - GENERATE mode (per target)

func runGenerate(outputPath: String, moduleName: String, files: [String]) -> Never {
    let scanner = scanFiles(files)
    let providers = scanner.providers

    // Cross-module dependencies are validated by the aggregate `--validate` pass,
    // so we do NOT fail here on unresolved deps. Intra-target cycles are still an
    // error (they would crash at runtime regardless of order).
    if let cycle = detectCycle(providers) {
        fail("error: \(moduleName): dependency cycle detected: \(cycle.joined(separator: " → "))")
    }

    // Topological order (dependency-first); deps not provided in this target are
    // assumed external and simply don't participate in ordering.
    var providerByBoundType: [String: Provider] = [:]
    for provider in providers { providerByBoundType[provider.boundType] = provider }

    var visited: Set<String> = []
    var ordered: [Provider] = []
    func visit(_ provider: Provider) {
        guard !visited.contains(provider.boundType) else { return }
        visited.insert(provider.boundType)
        for dependency in provider.dependencies {
            if let dep = providerByBoundType[dependency] { visit(dep) }
        }
        ordered.append(provider)
    }
    for provider in providers { visit(provider) }

    var output = """
    //
    //  GeneratedDI.swift
    //  \(moduleName)
    //
    //  Generated by StilettoGenerator. DO NOT EDIT.
    //  Bindings are emitted in dependency (leaf-first) order.
    //

    import Stiletto

    /// Internal so each module/target owns its own `GeneratedDI` without colliding
    /// with another module's when both are imported (e.g. in the app). Call it from
    /// this module's public `register()` wrapper.
    enum GeneratedDI {
        /// Registers every `@Provide`-annotated type in this module, in dependency order.
        static func register() {

    """
    for provider in ordered {
        output += "        \(provider.implName).__diRegister()\n"
    }
    output += """
        }
    }

    """

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
