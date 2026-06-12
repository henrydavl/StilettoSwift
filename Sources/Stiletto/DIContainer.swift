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
    private let lock = NSLock()

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

    /// Register a type with a factory and scope.
    public func register<T>(_ type: T.Type, scope: Scope = .factory, factory: @escaping () -> T) {
        let key = keyFor(type)
        lock.lock(); defer { lock.unlock() }

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
    public func resolve<T>(_ type: T.Type) -> T {
        let key = keyFor(type)
        lock.lock()
        // 1. App
        if let instance = appSingletons[key] as? T {
            Self.logHandler?("RESOLVE singleton (cached): \(key)")
            lock.unlock()
            return instance
        }
        // If missing but factory exists, recreate
        if let factory = singletons[key] as? () -> T {
            lock.unlock()
            let newInstance = factory()
            lock.lock()
            appSingletons[key] = newInstance
            Self.logHandler?("RESOLVE singleton (recreated): \(key)")
            lock.unlock()
            return newInstance
        }

        // 2. Session
        if let instance = sessionSingletons[key] as? T {
            Self.logHandler?("RESOLVE session (cached): \(key)")
            lock.unlock()
            return instance
        }
        if let factory = sessions[key] as? () -> T {
            lock.unlock()
            let newInstance = factory()
            lock.lock()
            sessionSingletons[key] = newInstance
            Self.logHandler?("RESOLVE session (recreated): \(key)")
            lock.unlock()
            return newInstance
        }

        // 3. Factory
        // Release the lock BEFORE invoking the factory: creating the instance may
        // recursively resolve other dependencies on this same thread, and NSLock
        // is non-recursive — calling factory() while holding the lock deadlocks.
        if let factory = factories[key] {
            lock.unlock()
            guard let instance = factory() as? T else {
                fatalError("No dependency found for \(key)")
            }
            Self.logHandler?("RESOLVE factory (new instance): \(key)")
            return instance
        }

        lock.unlock()
        fatalError("No dependency found for \(key)")
    }

    private func keyFor<T>(_ type: T.Type) -> String { String(describing: type) }
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
}
