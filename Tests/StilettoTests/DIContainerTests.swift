//
//  DIContainerTests.swift
//  StilettoTests
//

import XCTest
@testable import Stiletto

// Distinct types per test — DIContainer.shared is process-global and keyed by
// type name, so each test uses its own types to stay independent.

private final class SingletonThing {}
private final class FactoryThing {}
private final class SessionThing {}

// Two distinct types sharing the same simple name "Collider": container keys
// must be fully qualified or these overwrite each other's binding.
private enum NamespaceA { final class Collider {} }
private enum NamespaceB { final class Collider {} }
private protocol BoundProtocol {}
private final class BoundImpl: BoundProtocol {}
private final class OuterThing {
    let inner: FactoryThing
    init(inner: FactoryThing) { self.inner = inner }
}

final class DIContainerTests: XCTestCase {

    func testSingletonIsCachedAcrossResolves() {
        DIContainer.shared.register(SingletonThing.self, scope: .singleton) { SingletonThing() }
        let first = DIContainer.shared.resolve(SingletonThing.self)
        let second = DIContainer.shared.resolve(SingletonThing.self)
        XCTAssertTrue(first === second)
    }

    func testFactoryReturnsNewInstanceEveryResolve() {
        DIContainer.shared.register(FactoryThing.self, scope: .factory) { FactoryThing() }
        let first = DIContainer.shared.resolve(FactoryThing.self)
        let second = DIContainer.shared.resolve(FactoryThing.self)
        XCTAssertFalse(first === second)
    }

    func testSessionIsCachedUntilClearedThenRecreated() {
        DIContainer.shared.register(SessionThing.self, scope: .session) { SessionThing() }
        let first = DIContainer.shared.resolve(SessionThing.self)
        let cached = DIContainer.shared.resolve(SessionThing.self)
        XCTAssertTrue(first === cached)

        DIContainer.shared.clearSession()
        let recreated = DIContainer.shared.resolve(SessionThing.self)
        XCTAssertFalse(first === recreated)
    }

    func testProtocolBinding() {
        DIContainer.shared.register(BoundProtocol.self, scope: .singleton) { BoundImpl() }
        let resolved = DIContainer.shared.resolve(BoundProtocol.self)
        XCTAssertTrue(resolved is BoundImpl)
    }

    func testIsRegistered() {
        XCTAssertFalse(DIContainer.shared.isRegistered(OuterThing.self))
        DIContainer.shared.register(OuterThing.self, scope: .factory) {
            OuterThing(inner: DIContainer.shared.resolve(FactoryThing.self))
        }
        XCTAssertTrue(DIContainer.shared.isRegistered(OuterThing.self))
    }

    // Regression: a factory whose closure re-enters resolve() must not deadlock
    // (resolve releases the lock before invoking the factory).
    func testReentrantFactoryResolutionDoesNotDeadlock() {
        DIContainer.shared.register(FactoryThing.self, scope: .factory) { FactoryThing() }
        DIContainer.shared.register(OuterThing.self, scope: .factory) {
            OuterThing(inner: DIContainer.shared.resolve(FactoryThing.self))
        }
        let outer = DIContainer.shared.resolve(OuterThing.self)
        XCTAssertNotNil(outer.inner)
    }

    // Regression: types with the same simple name in different namespaces must
    // not share a container key (String(describing:) would collide them; the
    // second registration would clobber the first and resolving the first type
    // would trap with "No dependency found").
    func testSameSimpleNameInDifferentNamespacesDoesNotCollide() {
        DIContainer.shared.register(NamespaceA.Collider.self, scope: .singleton) { NamespaceA.Collider() }
        DIContainer.shared.register(NamespaceB.Collider.self, scope: .singleton) { NamespaceB.Collider() }
        XCTAssertNotNil(DIContainer.shared.resolve(NamespaceA.Collider.self))
        XCTAssertNotNil(DIContainer.shared.resolve(NamespaceB.Collider.self))
    }

    // Regression: re-registering must take effect even after the previous
    // singleton was resolved (the stale cached instance must be discarded),
    // and re-registering under a different scope must not be shadowed by the
    // old scope's entry.
    func testReRegistrationReplacesCachedSingletonAndScope() {
        final class Rebindable {}
        DIContainer.shared.register(Rebindable.self, scope: .singleton) { Rebindable() }
        let original = DIContainer.shared.resolve(Rebindable.self)

        let replacement = Rebindable()
        DIContainer.shared.register(Rebindable.self, scope: .singleton) { replacement }
        XCTAssertTrue(DIContainer.shared.resolve(Rebindable.self) === replacement)
        XCTAssertFalse(DIContainer.shared.resolve(Rebindable.self) === original)

        // Singleton → factory: the singleton entry must not shadow the new scope.
        DIContainer.shared.register(Rebindable.self, scope: .factory) { Rebindable() }
        let first = DIContainer.shared.resolve(Rebindable.self)
        let second = DIContainer.shared.resolve(Rebindable.self)
        XCTAssertFalse(first === second)
    }

    // Regression: two threads racing on first resolve of a singleton must get
    // the SAME instance (the factory must not run once per thread).
    func testConcurrentSingletonResolveYieldsOneInstance() {
        final class RacedSingleton {}
        let creationCount = ManagedAtomicCounter()
        DIContainer.shared.register(RacedSingleton.self, scope: .singleton) {
            creationCount.increment()
            // Widen the race window: without serialization both threads would
            // enter the factory before either caches the instance.
            Thread.sleep(forTimeInterval: 0.05)
            return RacedSingleton()
        }

        var results = [RacedSingleton?](repeating: nil, count: 8)
        let resultsLock = NSLock()
        DispatchQueue.concurrentPerform(iterations: 8) { index in
            let instance = DIContainer.shared.resolve(RacedSingleton.self)
            resultsLock.lock()
            results[index] = instance
            resultsLock.unlock()
        }

        XCTAssertEqual(creationCount.value, 1)
        let first = results[0]
        for instance in results {
            XCTAssertTrue(instance === first)
        }
    }

    func testRegisterIfAbsentIsAtomicUnderConcurrency() {
        final class RacedRegistration {}
        let winCount = ManagedAtomicCounter()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            if DIContainer.shared.registerIfAbsent(RacedRegistration.self, scope: .singleton, factory: { RacedRegistration() }) {
                winCount.increment()
            }
        }
        XCTAssertEqual(winCount.value, 1)
        XCTAssertTrue(DIContainer.shared.isRegistered(RacedRegistration.self))
    }

    func testRegistrationOrderDoesNotMatter() {
        // Register the dependent BEFORE its dependency — lazy registration means
        // nothing is constructed until first resolve, so this must still work.
        final class LateDep {}
        final class EarlyConsumer {
            let dep: LateDep
            init(dep: LateDep) { self.dep = dep }
        }
        DIContainer.shared.register(EarlyConsumer.self, scope: .singleton) {
            EarlyConsumer(dep: DIContainer.shared.resolve(LateDep.self))
        }
        DIContainer.shared.register(LateDep.self, scope: .singleton) { LateDep() }
        XCTAssertNotNil(DIContainer.shared.resolve(EarlyConsumer.self).dep)
    }
}

// MARK: - @Provides wrapper

private final class ManualSDKValue {}
private final class ManualDuplicateValue {}

final class ProvidesWrapperTests: XCTestCase {

    func testProvidesRegistersWrappedValue() {
        struct Holder {
            @Provides(scope: .singleton) var sdk: ManualSDKValue = ManualSDKValue()
        }
        let holder = Holder()
        XCTAssertTrue(DIContainer.shared.isRegistered(ManualSDKValue.self))
        XCTAssertTrue(DIContainer.shared.resolve(ManualSDKValue.self) === holder.sdk)
    }

    func testProvidesSkipsAlreadyRegisteredType() {
        struct First {
            @Provides(scope: .singleton) var value: ManualDuplicateValue = ManualDuplicateValue()
        }
        struct Second {
            @Provides(scope: .singleton) var value: ManualDuplicateValue = ManualDuplicateValue()
        }
        let first = First()
        _ = Second()
        // The first registration wins; the second is a no-op.
        XCTAssertTrue(DIContainer.shared.resolve(ManualDuplicateValue.self) === first.value)
    }
}

// MARK: - Test helpers

/// Minimal lock-based counter (no swift-atomics dependency).
private final class ManagedAtomicCounter {
    private let lock = NSLock()
    private var count = 0
    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
    func increment() {
        lock.lock(); defer { lock.unlock() }
        count += 1
    }
}
