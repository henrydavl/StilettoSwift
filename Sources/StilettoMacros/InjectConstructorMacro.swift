//
//  InjectConstructorMacro.swift
//  StilettoMacros
//

import Foundation
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros
import SwiftCompilerPlugin

@main
struct StilettoCompilerPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        InjectConstructorMacro.self,
        LazyInjectConstructorMacro.self,
        ProvideMacro.self
    ]
}

public struct InjectConstructorMacro: MemberMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let classDecl = declaration.as(ClassDeclSyntax.self) else {
            return []
        }

        let className = classDecl.name.text
        let initArgs = try generateInitArgs(for: classDecl)

        return [
            """
            public static func resolve(in container: DIContainer) -> \(raw: className) {
                \(raw: className)(\(raw: initArgs))
            }
            """,
            """
            public static var auto: \(raw: className) {
                resolve(in: DIContainer.shared)
            }
            """
        ]
    }

    private static func generateInitArgs(for classDecl: ClassDeclSyntax) throws -> String {
        guard let initializer = classDecl.memberBlock.members
            .compactMap({ $0.decl.as(InitializerDeclSyntax.self) })
            .first else { return "" }

        // Parameters with a default value are NOT resolved from the container —
        // they keep their default (e.g. an SDK singleton like
        // `appsFlyerLib: AppsFlyerLib = AppsFlyerLib.shared()`). Only the real
        // dependencies (no default) are injected.
        let parameters = initializer.signature.parameterClause.parameters
            .filter { $0.defaultValue == nil }
            .map { param -> String in
                let label = param.firstName.text
                let typeName = param.type.description.trimmingCharacters(in: .whitespacesAndNewlines)
                return "\(label): container.resolve(\(typeName).self)"
            }.joined(separator: ", ")

        return parameters
    }
}

public struct LazyInjectConstructorMacro: MemberMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let classDecl = declaration.as(ClassDeclSyntax.self) else {
            return []
        }

        let className = classDecl.name.text
        let lazyProperties = try generateLazyProperties(for: classDecl)

        var members: [DeclSyntax] = []

        // Add lazy properties
        members.append(contentsOf: lazyProperties)

        // Add resolve method that creates instance without resolving dependencies
        members.append(
            """
            public static func resolve(in container: DIContainer) -> \(raw: className) {
                \(raw: className)()
            }
            """
        )

        // Add auto property
        members.append(
            """
            public static var auto: \(raw: className) {
                resolve(in: DIContainer.shared)
            }
            """
        )

        return members
    }

    private static func generateLazyProperties(for classDecl: ClassDeclSyntax) throws -> [DeclSyntax] {
        guard let initializer = classDecl.memberBlock.members
            .compactMap({ $0.decl.as(InitializerDeclSyntax.self) })
            .first else { return [] }

        return initializer.signature.parameterClause.parameters
            .filter { $0.defaultValue == nil }
            .map { param -> DeclSyntax in
            let paramName = param.firstName.text
            let typeName = param.type.description.trimmingCharacters(in: .whitespacesAndNewlines)

            return """
            @LazyInject private var \(raw: paramName): \(raw: typeName)
            """
        }
    }
}
