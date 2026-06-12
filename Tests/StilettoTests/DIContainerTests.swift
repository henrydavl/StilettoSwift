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
