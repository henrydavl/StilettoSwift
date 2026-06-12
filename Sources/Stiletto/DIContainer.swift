//
//  DIContainer.swift
//  Stiletto
//
//  The runtime container. Registration is fully lazy — only factories are
//  stored — so registration order never matters at runtime. Ordering and
//  completeness of the graph are guaranteed at build time by StilettoGenerator.
//

import Foundation

public final class DIContainer {
    public static let shared = DIContainer()

    /// Optional hook for observing container events (register / resolve / clear).
    /// Silent by default; set it to plug in your app's logger:
    ///
    ///     DIContainer.logHandler = { AppLog.d($0) }
    public static var logHandler: ((String) -> Void)?

    // MARK: - Storage
    // Recursive so a factory can re-enter resolve() on the same thread while the
    // container creates a cached instance under the lock (see resolve).
    private let lock = NSRecursiveLock()

    private var singletons: [String: Any] = [:]
    private var factories: [String: () -> Any] = [:]
    private var sessions: [String: Any] = [:]

    // Cached instances
    private var appSingletons: [String: Any] = [:]
    private var sessionSingletons: [String: Any] = [:]

    private init() {}

    // Scopes
    public enum Scope {
        case session    // Alive while user session active
        case singleton  // Alive forever
        case factory    // New instance every resolve
    }

    /// Register a type with a factory and scope. Last registration wins: any
    /// previous factory, scope, or cached instance for the type is discarded —
    /// otherwise a re-registration would be silently shadowed by the old scope's
    /// entry (resolve checks scopes in order) or by an already-cached instance.
    public func register<T>(_ type: T.Type, scope: Scope = .factory, factory: @escaping () -> T) {
        let key = keyFor(type)
        lock.lock(); defer { lock.unlock() }

        singletons[key] = nil
        sessions[key] = nil
        factories[key] = nil
        appSingletons[key] = nil
        sessionSingletons[key] = nil

        switch scope {
        case .singleton:
            // Store the factory only; the instance is created lazily on first
            // resolve (see resolve's "recreated" branch). Lazy registration makes
            // registration order irrelevant — a dependency no longer needs its own
            // dependencies registered at the moment it is registered.
            singletons[key] = factory
            Self.logHandler?("REGISTER singleton: \(key)")

        case .session:
            // Lazy, same as singleton but scoped to the user session.
            sessions[key] = factory
            Self.logHandler?("REGISTER session: \(key)")

        case .factory:
            factories[key] = factory
            Self.logHandler?("REGISTER factory: \(key)")
        }
    }

    /// Resolve an instance for a type. If an instance is not present for session/app and a factory exists, a new instance will be created and cached.
    ///
    /// The lock is held while the factory runs: the recursive lock lets the
    /// factory re-enter resolve() on this thread for its own dependencies, while
    /// other threads wait — so a singleton/session factory runs exactly once and
    /// every caller observes the same cached instance.
    public func resolve<T>(_ type: T.Type) -> T {
        let key = keyFor(type)
        lock.lock(); defer { lock.unlock() }

        // 1. App
        if let instance = appSingletons[key] as? T {
            Self.logHandler?("RESOLVE singleton (cached): \(key)")
            return instance
        }
        if let factory = singletons[key] as? () -> T {
            let newInstance = factory()
            appSingletons[key] = newInstance
            Self.logHandler?("RESOLVE singleton (created): \(key)")
            return newInstance
        }

        // 2. Session
        if let instance = sessionSingletons[key] as? T {
            Self.logHandler?("RESOLVE session (cached): \(key)")
            return instance
        }
        if let factory = sessions[key] as? () -> T {
            let newInstance = factory()
            sessionSingletons[key] = newInstance
            Self.logHandler?("RESOLVE session (created): \(key)")
            return newInstance
        }

        // 3. Factory
        if let factory = factories[key] {
            guard let instance = factory() as? T else {
                fatalError("No dependency found for \(key)")
            }
            Self.logHandler?("RESOLVE factory (new instance): \(key)")
            return instance
        }

        fatalError("No dependency found for \(key)")
    }

    /// Fully-qualified key (`String(reflecting:)`, e.g. "MyModule.Logger").
    /// `String(describing:)` would give the bare name, so two types with the
    /// same simple name in different modules would collide and silently
    /// overwrite each other's binding.
    private func keyFor<T>(_ type: T.Type) -> String { String(reflecting: type) }
}

public extension DIContainer {
    func autoregister<T>(
        _ type: T.Type = T.self,
        scope: Scope = .singleton,
        initializer: @escaping () -> T
    ) {
        register(type, scope: scope, factory: initializer)
    }

    // MARK: - Clear / Reset
    /// Clear only cached session instances but keep session factories so DI can recreate them automatically.
    func clearSession() {
        lock.lock(); defer { lock.unlock() }
        sessionSingletons.removeAll()
        Self.logHandler?("CLEAR session instances (factories retained)")
    }

    // Utility
    func isRegistered<T>(_ type: T.Type) -> Bool {
        let key = keyFor(type)
        lock.lock(); defer { lock.unlock() }
        return singletons[key] != nil || sessions[key] != nil || factories[key] != nil || appSingletons[key] != nil || sessionSingletons[key] != nil
    }

    /// Registers the type only if nothing is registered for it yet, atomically —
    /// a separate `isRegistered` check followed by `register` would race when two
    /// threads register the same type concurrently.
    /// - Returns: `true` if the registration was performed.
    @discardableResult
    func registerIfAbsent<T>(_ type: T.Type, scope: Scope = .factory, factory: @escaping () -> T) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !isRegistered(type) else { return false }
        register(type, scope: scope, factory: factory)
        return true
    }
}
