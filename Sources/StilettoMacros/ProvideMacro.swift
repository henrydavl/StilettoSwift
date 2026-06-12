//
//  ProvideMacro.swift
//  StilettoMacros
//
//  Implementation of the `@Provide` macro. Synthesizes an `AutoRegistrable`
//  conformance whose `__diRegister()` registers the bound type into the shared
//  container. The factory uses `Type.auto` when the class is also annotated with
//  `@InjectConstructor` (constructor injection), and `Type()` otherwise.
//

import SwiftSyntax
import SwiftSyntaxMacros
import SwiftDiagnostics

public struct ProvideMacro: ExtensionMacro {
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        guard let classDecl = declaration.as(ClassDeclSyntax.self) else {
            throw MacroError("@Provide can only be applied to a class")
        }

        let arguments = node.arguments?.as(LabeledExprListSyntax.self)
        let typeName = type.trimmedDescription

        // Bound type: a leading positional argument (`SomeProtocol.self`) binds to
        // that type; with no positional argument the class binds to itself.
        var boundType = typeName
        if let first = arguments?.first, first.label == nil {
            let boundExpr = first.expression.trimmedDescription
            boundType = boundExpr.hasSuffix(".self")
                ? String(boundExpr.dropLast(".self".count))
                : boundExpr
        }

        // Scope: read the `.case` name from the optional `scope:` argument.
        var scopeCase = "singleton"
        for argument in arguments ?? [] where argument.label?.text == "scope" {
            if let member = argument.expression.as(MemberAccessExprSyntax.self) {
                scopeCase = member.declName.baseName.text
            }
        }

        // Use constructor injection when @InjectConstructor / @LazyInjectConstructor
        // is also present (those macros synthesize `auto`); otherwise no-arg init.
        let hasConstructorInjection = classDecl.attributes.contains { element in
            guard let attribute = element.as(AttributeSyntax.self) else { return false }
            let name = attribute.attributeName.trimmedDescription
            return name == "InjectConstructor" || name == "LazyInjectConstructor"
        }
        // Reference the concrete type name (not `Self`) so non-final classes don't
        // require a `required` initializer for `Type()`.
        let factory = hasConstructorInjection ? "\(typeName).auto" : "\(typeName)()"

        let extensionDecl: DeclSyntax =
            """
            extension \(raw: typeName): AutoRegistrable {
                public static func __diRegister() {
                    DIContainer.shared.register(\(raw: boundType).self, scope: .\(raw: scopeCase)) { \(raw: factory) }
                }
            }
            """

        guard let ext = extensionDecl.as(ExtensionDeclSyntax.self) else {
            throw MacroError("@Provide failed to synthesize registration extension")
        }
        return [ext]
    }
}

/// Lightweight error type for macro diagnostics.
struct MacroError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
