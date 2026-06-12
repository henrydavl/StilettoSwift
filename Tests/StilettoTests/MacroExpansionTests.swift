//
//  MacroExpansionTests.swift
//  StilettoTests
//

import XCTest
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import StilettoMacros

private let testMacros: [String: Macro.Type] = [
    "Provide": ProvideMacro.self,
    "InjectConstructor": InjectConstructorMacro.self,
    "LazyInjectConstructor": LazyInjectConstructorMacro.self,
]

final class MacroExpansionTests: XCTestCase {

    func testProvideWithProtocolBinding() {
        assertMacroExpansion(
            """
            @Provide(BarProtocol.self, scope: .session)
            class Foo {
            }
            """,
            expandedSource: """
            class Foo {
            }

            extension Foo: AutoRegistrable {
                public static func __diRegister() {
                    DIContainer.shared.register(BarProtocol.self, scope: .session) {
                        Foo()
                    }
                }
            }
            """,
            macros: testMacros
        )
    }

    func testProvideSelfBinding() {
        assertMacroExpansion(
            """
            @Provide(scope: .factory)
            class Foo {
            }
            """,
            expandedSource: """
            class Foo {
            }

            extension Foo: AutoRegistrable {
                public static func __diRegister() {
                    DIContainer.shared.register(Foo.self, scope: .factory) {
                        Foo()
                    }
                }
            }
            """,
            macros: testMacros
        )
    }

    func testProvideUsesAutoWhenInjectConstructorPresent() {
        assertMacroExpansion(
            """
            @Provide(BarProtocol.self)
            @InjectConstructor
            class Foo {
                init(bar: BarProtocol) {
                }
            }
            """,
            expandedSource: """
            @InjectConstructor
            class Foo {
                init(bar: BarProtocol) {
                }
            }

            extension Foo: AutoRegistrable {
                public static func __diRegister() {
                    DIContainer.shared.register(BarProtocol.self, scope: .singleton) {
                        Foo.auto
                    }
                }
            }
            """,
            macros: ["Provide": ProvideMacro.self]
        )
    }

    func testInjectConstructorResolvesParams() {
        assertMacroExpansion(
            """
            @InjectConstructor
            class Foo {
                init(bar: BarProtocol, baz: BazProtocol) {
                }
            }
            """,
            expandedSource: """
            class Foo {
                init(bar: BarProtocol, baz: BazProtocol) {
                }

                public static func resolve(in container: DIContainer) -> Foo {
                    Foo(bar: container.resolve(BarProtocol.self), baz: container.resolve(BazProtocol.self))
                }

                public static var auto: Foo {
                    resolve(in: DIContainer.shared)
                }
            }
            """,
            macros: testMacros
        )
    }

    func testLazyInjectConstructorSynthesizesLazyProperties() {
        assertMacroExpansion(
            """
            @LazyInjectConstructor
            class Foo {
                init(bar: BarProtocol, baz: BazProtocol) {
                }
            }
            """,
            expandedSource: """
            class Foo {
                init(bar: BarProtocol, baz: BazProtocol) {
                }

                @LazyInject private var bar: BarProtocol

                @LazyInject private var baz: BazProtocol

                public static func resolve(in container: DIContainer) -> Foo {
                    Foo()
                }

                public static var auto: Foo {
                    resolve(in: DIContainer.shared)
                }
            }
            """,
            macros: testMacros
        )
    }

    func testLazyInjectConstructorSkipsDefaultedParams() {
        assertMacroExpansion(
            """
            @LazyInjectConstructor
            class Foo {
                init(bar: BarProtocol, sdk: SDKThing = SDKThing.shared()) {
                }
            }
            """,
            expandedSource: """
            class Foo {
                init(bar: BarProtocol, sdk: SDKThing = SDKThing.shared()) {
                }

                @LazyInject private var bar: BarProtocol

                public static func resolve(in container: DIContainer) -> Foo {
                    Foo()
                }

                public static var auto: Foo {
                    resolve(in: DIContainer.shared)
                }
            }
            """,
            macros: testMacros
        )
    }

    func testInjectConstructorSkipsDefaultedParams() {
        assertMacroExpansion(
            """
            @InjectConstructor
            class Foo {
                init(bar: BarProtocol, sdk: SDKThing = SDKThing.shared()) {
                }
            }
            """,
            expandedSource: """
            class Foo {
                init(bar: BarProtocol, sdk: SDKThing = SDKThing.shared()) {
                }

                public static func resolve(in container: DIContainer) -> Foo {
                    Foo(bar: container.resolve(BarProtocol.self))
                }

                public static var auto: Foo {
                    resolve(in: DIContainer.shared)
                }
            }
            """,
            macros: testMacros
        )
    }
}
