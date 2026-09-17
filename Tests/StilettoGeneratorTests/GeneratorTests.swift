//
//  GeneratorTests.swift
//  StilettoGeneratorTests
//
//  Integration tests that drive the built `StilettoGenerator` binary as a
//  subprocess over fixture sources in a temporary directory. Subprocess on
//  purpose: linking the generator (and its SwiftSyntax) into the test bundle
//  next to the macro target's embedded SwiftSyntax traps the Swift runtime.
//

import XCTest

final class GeneratorTests: XCTestCase {

    private var fixtureDir: URL!

    /// The StilettoGenerator binary sits next to the test bundle in the build dir.
    private static let generatorURL: URL = Bundle(for: GeneratorTests.self).bundleURL
        .deletingLastPathComponent()
        .appendingPathComponent("StilettoGenerator")

    override func setUpWithError() throws {
        fixtureDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StilettoGeneratorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fixtureDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: fixtureDir)
    }

    private func writeFixture(_ name: String, _ source: String) throws {
        try source.write(to: fixtureDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private struct RunResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    @discardableResult
    private func runGenerator(_ arguments: [String]) throws -> RunResult {
        let process = Process()
        process.executableURL = Self.generatorURL
        process.arguments = arguments
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        let stdout = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        return RunResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    private func validate() throws -> RunResult {
        try runGenerator(["--validate", fixtureDir.path])
    }

    private struct FileIdentity {
        let contents: String
        let modificationDate: Date
        let inode: UInt64
    }

    /// Content plus the two things a rewrite churns even when the content is equal.
    private func fileIdentity(of url: URL) throws -> FileIdentity {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return FileIdentity(
            contents: try String(contentsOf: url, encoding: .utf8),
            modificationDate: try XCTUnwrap(attributes[.modificationDate] as? Date),
            inode: try XCTUnwrap(attributes[.systemFileNumber] as? UInt64)
        )
    }

    // MARK: - VALIDATE mode

    func testCompleteGraphValidates() throws {
        try writeFixture("Clock.swift", """
        @Provide(ClockProtocol.self, scope: .singleton)
        final class SystemClock: ClockProtocol {}
        """)
        try writeFixture("Greeter.swift", """
        @Provide(GreeterProtocol.self, scope: .session)
        @InjectConstructor
        final class Greeter: GreeterProtocol {
            init(clock: ClockProtocol) {}
        }
        """)

        let result = try validate()
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("validated 2 providers across 2 files"), result.stdout)
    }

    func testMissingBindingFailsValidation() throws {
        try writeFixture("Greeter.swift", """
        @Provide(GreeterProtocol.self)
        @InjectConstructor
        final class Greeter: GreeterProtocol {
            init(clock: ClockProtocol) {}
        }
        """)

        let result = try validate()
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(result.stderr.contains("Greeter requires 'ClockProtocol'"), result.stderr)
    }

    func testCrossFileDependencyIsSatisfied() throws {
        // The defining point of --validate: provider and consumer in different
        // "modules" (files) still form one complete graph.
        try writeFixture("ModuleA.swift", """
        @Provide(RepoProtocol.self)
        @InjectConstructor
        final class Repo: RepoProtocol {
            init(api: APIProtocol) {}
        }
        """)
        try writeFixture("ModuleB.swift", """
        @Provide(APIProtocol.self)
        final class API: APIProtocol {}
        """)

        let result = try validate()
        XCTAssertEqual(result.exitCode, 0, result.stderr)
    }

    func testDirectCycleFailsValidation() throws {
        try writeFixture("Cycle.swift", """
        @Provide(AProtocol.self)
        @InjectConstructor
        final class A: AProtocol {
            init(b: BProtocol) {}
        }

        @Provide(BProtocol.self)
        @InjectConstructor
        final class B: BProtocol {
            init(a: AProtocol) {}
        }
        """)

        let result = try validate()
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(result.stderr.contains("dependency cycle detected"), result.stderr)
    }

    func testLongerCycleFailsValidation() throws {
        try writeFixture("Cycle.swift", """
        @Provide(AProtocol.self)
        @InjectConstructor
        final class A: AProtocol {
            init(b: BProtocol) {}
        }

        @Provide(BProtocol.self)
        @InjectConstructor
        final class B: BProtocol {
            init(c: CProtocol) {}
        }

        @Provide(CProtocol.self)
        @InjectConstructor
        final class C: CProtocol {
            init(a: AProtocol) {}
        }
        """)

        let result = try validate()
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(result.stderr.contains("dependency cycle detected"), result.stderr)
    }

    func testSelfCycleFailsValidation() throws {
        try writeFixture("Cycle.swift", """
        @Provide(AProtocol.self)
        @InjectConstructor
        final class A: AProtocol {
            init(a: AProtocol) {}
        }
        """)

        let result = try validate()
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(result.stderr.contains("dependency cycle detected"), result.stderr)
    }

    func testManualProvidesSatisfiesDependency() throws {
        try writeFixture("Consumer.swift", """
        @Provide(scope: .factory)
        @InjectConstructor
        final class UseCase {
            init(payments: PaymentSDKProtocol) {}
        }

        struct AppDI {
            @Provides(scope: .singleton) var payments: PaymentSDKProtocol = PaymentSDKAdapter()
        }
        """)

        let result = try validate()
        XCTAssertEqual(result.exitCode, 0, result.stderr)
    }

    func testExternalListSatisfiesDependency() throws {
        try writeFixture("Consumer.swift", """
        @Provide(scope: .factory)
        @InjectConstructor
        final class UseCase {
            init(legacy: LegacyThing) {}
        }

        enum MyExternals { static let external: [Any.Type] = [LegacyThing.self] }
        """)

        let result = try validate()
        XCTAssertEqual(result.exitCode, 0, result.stderr)
    }

    func testDefaultedParamsAreNotValidated() throws {
        try writeFixture("Consumer.swift", """
        @Provide(scope: .factory)
        @InjectConstructor
        final class UseCase {
            init(sdk: ThirdPartySDK = ThirdPartySDK.shared()) {}
        }
        """)

        let result = try validate()
        XCTAssertEqual(result.exitCode, 0, result.stderr)
    }

    // MARK: - GENERATE mode

    func testGenerateEmitsRegistrationInDependencyOrder() throws {
        // Pass the consumer file FIRST so plain source order would be wrong.
        let consumer = fixtureDir.appendingPathComponent("Consumer.swift")
        try writeFixture("Consumer.swift", """
        @Provide(GreeterProtocol.self)
        @InjectConstructor
        final class Greeter: GreeterProtocol {
            init(clock: ClockProtocol) {}
        }
        """)
        let leaf = fixtureDir.appendingPathComponent("Leaf.swift")
        try writeFixture("Leaf.swift", """
        @Provide(ClockProtocol.self)
        final class SystemClock: ClockProtocol {}
        """)
        let output = fixtureDir.appendingPathComponent("GeneratedDI.swift")

        let result = try runGenerator(
            ["--output", output.path, "--module", "TestModule", consumer.path, leaf.path]
        )
        XCTAssertEqual(result.exitCode, 0, result.stderr)

        let generated = try String(contentsOf: output, encoding: .utf8)
        XCTAssertTrue(generated.contains("SystemClock.__diRegister()"), generated)
        XCTAssertTrue(generated.contains("Greeter.__diRegister()"), generated)
        // Leaf-first: the dependency must be registered before its consumer.
        let clockIndex = generated.range(of: "SystemClock.__diRegister()")!.lowerBound
        let greeterIndex = generated.range(of: "Greeter.__diRegister()")!.lowerBound
        XCTAssertLessThan(clockIndex, greeterIndex)
    }

    func testRegeneratingIdenticalOutputDoesNotTouchTheFile() throws {
        // A rewrite with identical content still gives the file a new mtime and
        // inode (`atomically:` renames a temp file into place), which makes the
        // build system recompile every target the plugin is attached to. The
        // generator must skip the write when nothing changed.
        let source = fixtureDir.appendingPathComponent("Leaf.swift")
        try writeFixture("Leaf.swift", """
        @Provide(ClockProtocol.self)
        final class SystemClock: ClockProtocol {}
        """)
        let output = fixtureDir.appendingPathComponent("GeneratedDI.swift")
        let arguments = ["--output", output.path, "--module", "TestModule", source.path]

        let first = try runGenerator(arguments)
        XCTAssertEqual(first.exitCode, 0, first.stderr)
        let before = try fileIdentity(of: output)

        // Coarse filesystem timestamps would hide a rewrite that lands in the
        // same tick, so give the clock room to move.
        Thread.sleep(forTimeInterval: 1.1)

        let second = try runGenerator(arguments)
        XCTAssertEqual(second.exitCode, 0, second.stderr)
        let after = try fileIdentity(of: output)

        XCTAssertEqual(after.contents, before.contents, "content should be stable across runs")
        XCTAssertEqual(after.modificationDate, before.modificationDate, "identical output must not be rewritten")
        XCTAssertEqual(after.inode, before.inode, "identical output must not be replaced by a new file")
    }

    func testRegeneratingChangedOutputRewritesTheFile() throws {
        let source = fixtureDir.appendingPathComponent("Leaf.swift")
        try writeFixture("Leaf.swift", """
        @Provide(ClockProtocol.self)
        final class SystemClock: ClockProtocol {}
        """)
        let output = fixtureDir.appendingPathComponent("GeneratedDI.swift")
        let arguments = ["--output", output.path, "--module", "TestModule", source.path]

        let first = try runGenerator(arguments)
        XCTAssertEqual(first.exitCode, 0, first.stderr)
        let before = try fileIdentity(of: output)

        Thread.sleep(forTimeInterval: 1.1)

        // A genuinely new provider must still reach the output.
        try writeFixture("Leaf.swift", """
        @Provide(ClockProtocol.self)
        final class SystemClock: ClockProtocol {}

        @Provide(LoggerProtocol.self)
        final class ConsoleLogger: LoggerProtocol {}
        """)

        let second = try runGenerator(arguments)
        XCTAssertEqual(second.exitCode, 0, second.stderr)
        let after = try fileIdentity(of: output)

        XCTAssertNotEqual(after.contents, before.contents, "changed inputs must change the output")
        XCTAssertTrue(after.contents.contains("ConsoleLogger.__diRegister()"), after.contents)
        XCTAssertGreaterThan(after.modificationDate, before.modificationDate, "changed output must be rewritten")
    }

    func testGenerateFailsOnIntraTargetCycle() throws {
        let file = fixtureDir.appendingPathComponent("Cycle.swift")
        try writeFixture("Cycle.swift", """
        @Provide(AProtocol.self)
        @InjectConstructor
        final class A: AProtocol {
            init(b: BProtocol) {}
        }

        @Provide(BProtocol.self)
        @InjectConstructor
        final class B: BProtocol {
            init(a: AProtocol) {}
        }
        """)
        let output = fixtureDir.appendingPathComponent("GeneratedDI.swift")

        let result = try runGenerator(["--output", output.path, "--module", "TestModule", file.path])
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(result.stderr.contains("dependency cycle detected"), result.stderr)
    }
}
