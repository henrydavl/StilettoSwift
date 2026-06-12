//
//  Macros.swift
//  Stiletto
//
//  Macro declarations. `@Provide` marks an implementation class as a binding in
//  the DI graph; the build-time `StilettoGenerator` discovers every `@Provide`,
//  validates the graph, and emits ordered registration — so there is no manual
//  registration call or ordering to maintain (Hilt-style).
//

/// Lifetime of a provided dependency. Mirrors `DIContainer.Scope` but is
/// declared separately so the macro signature stays usable without referencing
/// the container type.
public enum ProvideScope {
    case singleton
    case session
    case factory
}

/// Marker conformance synthesized by `@Provide`. The build-time
/// `StilettoGenerator` emits an ordered call to `__diRegister()` for every
/// annotated type, so the container never has a "forgot to register" gap at
/// runtime.
public protocol AutoRegistrable {
    static func __diRegister()
}

/// Declares that the annotated class provides `type` into the DI graph with the
/// given `scope`.
///
///     @Provide(HeaderProviderProtocol.self, scope: .session)
///     @InjectConstructor
///     public final class DefaultHeaderProvider: HeaderProviderProtocol { ... }
///
/// When combined with `@InjectConstructor`, the synthesized registration resolves
/// the class's constructor dependencies from the container; otherwise it uses the
/// class's no-argument initializer.
@attached(extension, conformances: AutoRegistrable, names: named(__diRegister))
public macro Provide<T>(_ type: T.Type, scope: ProvideScope = .singleton) =
    #externalMacro(module: "StilettoMacros", type: "ProvideMacro")

/// Declares that the annotated class provides **itself** into the DI graph (the
/// binding type is the class type). Use this form when a concrete class is
/// resolved directly rather than behind a protocol:
///
///     @Provide(scope: .factory)
///     @InjectConstructor
///     public final class InquiryUserUseCase { ... }
///
/// This form avoids passing the type as an argument, which would otherwise create
/// a circular reference (the macro argument referencing the type whose extension
/// is being synthesized).
@attached(extension, conformances: AutoRegistrable, names: named(__diRegister))
public macro Provide(scope: ProvideScope = .singleton) =
    #externalMacro(module: "StilettoMacros", type: "ProvideMacro")

/// Synthesizes `static func resolve(in:)` and `static var auto` that construct
/// the class by resolving every initializer parameter from the container.
/// Parameters with a **default value are skipped** — they keep their default and
/// are not resolved or validated (how you mix injected deps with SDK values).
@attached(member, names: named(resolve), named(auto))
public macro InjectConstructor() =
    #externalMacro(module: "StilettoMacros", type: "InjectConstructorMacro")

/// Like `@InjectConstructor`, but synthesizes `@LazyInject` stored properties
/// instead of resolving dependencies at construction time. The class must have
/// a no-argument initializer.
@attached(member, names: named(resolve), named(auto), arbitrary)
public macro LazyInjectConstructor() =
    #externalMacro(module: "StilettoMacros", type: "LazyInjectConstructorMacro")
