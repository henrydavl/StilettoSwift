//
//  Services.swift
//  StilettoExample
//
//  A tiny three-node graph exercising protocol binding, self-binding, scopes,
//  constructor injection, and the skipped-default-parameter rule. Note there is
//  no manual registration anywhere — StilettoPlugin generates it.
//

import Foundation
import Stiletto

// MARK: - Leaf dependency (protocol binding, no constructor deps)

protocol ClockProtocol {
    func now() -> String
}

@Provide(ClockProtocol.self, scope: .singleton)
final class SystemClock: ClockProtocol {
    func now() -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        return formatter.string(from: Date())
    }
}

// MARK: - Mid node (protocol binding + constructor injection + defaulted param)

protocol GreeterProtocol {
    func greet(_ name: String) -> String
}

@Provide(GreeterProtocol.self, scope: .session)
@InjectConstructor
final class Greeter: GreeterProtocol {
    private let clock: ClockProtocol
    private let punctuation: String

    // `clock` is injected; `punctuation` has a default so it is skipped by both
    // the macro and the build-time validator.
    init(clock: ClockProtocol, punctuation: String = "!") {
        self.clock = clock
        self.punctuation = punctuation
    }

    func greet(_ name: String) -> String {
        "Hello, \(name)\(punctuation) It is \(clock.now())."
    }
}

// MARK: - Root node (self-binding: resolved by its concrete type)

@Provide(scope: .factory)
@InjectConstructor
final class GreetingUseCase {
    private let greeter: GreeterProtocol

    init(greeter: GreeterProtocol) {
        self.greeter = greeter
    }

    func run(name: String) -> String {
        greeter.greet(name)
    }
}
