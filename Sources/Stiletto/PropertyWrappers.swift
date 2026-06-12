//
//  PropertyWrappers.swift
//  Stiletto
//
//  Property-wrapper sugar over `DIContainer.shared`. Note that `@Inject` /
//  `@LazyInject` properties are resolved at runtime and are NOT part of the
//  compile-time-validated graph — prefer constructor injection via
//  `@InjectConstructor` wherever possible.
//

import Foundation

/// Resolves the dependency eagerly when the enclosing object is initialized.
@propertyWrapper
public struct Inject<T> {
    public var wrappedValue: T

    public init() {
        let typeName = String(describing: T.self)
        DIContainer.logHandler?("💉 Inject → requesting \(typeName)")
        self.wrappedValue = DIContainer.shared.resolve(T.self)
    }
}

/// Resolves the dependency on first access, then caches it.
@propertyWrapper
public struct LazyInject<T> {
    private var dependency: T?

    public var wrappedValue: T {
        mutating get {
            let typeName = String(describing: T.self)
            if dependency == nil {
                DIContainer.logHandler?("💉 LazyInject → loading \(typeName)")
                dependency = DIContainer.shared.resolve(T.self)
            } else {
                DIContainer.logHandler?("💉 LazyInject → using cached \(typeName)")
            }
            return dependency!
        }
    }

    public init() {
        self.dependency = nil
    }
}

/// Manual registration escape hatch for values that can't carry `@Provide`
/// (e.g. instances built from third-party SDK types). The whole-program
/// validator recognizes `@Provides var x: SomeType` as providing `SomeType`.
@propertyWrapper
public struct Provides<T> {
    public let wrappedValue: T

    public init(wrappedValue: T, scope: DIContainer.Scope = .singleton) {
        self.wrappedValue = wrappedValue
        if DIContainer.shared.registerIfAbsent(T.self, scope: scope, factory: { wrappedValue }) {
            DIContainer.logHandler?("Registering \(T.self) with scope \(scope)")
        } else {
            DIContainer.logHandler?("\(T.self) with scope \(scope) already registered")
        }
    }
}
