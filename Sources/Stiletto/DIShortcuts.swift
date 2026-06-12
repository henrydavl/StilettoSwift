//
//  DIShortcuts.swift
//  Stiletto
//
//  Free-function shorthands over `DIContainer.shared`. If a name collides with
//  one of your own, qualify it: `Stiletto.resolve(Foo.self)`.
//

import Foundation

@inlinable
public func register<T>(
    _ type: T.Type,
    scope: DIContainer.Scope = .singleton,
    factory: @escaping () -> T
) {
    DIContainer.shared.register(type, scope: scope, factory: factory)
}

@inlinable
public func autoregister<T>(
    _ type: T.Type = T.self,
    scope: DIContainer.Scope = .singleton,
    initializer: @escaping () -> T
) {
    DIContainer.shared.autoregister(type, scope: scope, initializer: initializer)
}

@inlinable
public func resolve<T>(_ type: T.Type = T.self) -> T {
    DIContainer.shared.resolve(type)
}
