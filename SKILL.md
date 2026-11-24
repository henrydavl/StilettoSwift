---
name: stiletto
description: How to wire dependency injection in a Swift/iOS codebase that uses Stiletto — which annotation to reach for (@Provide, @InjectConstructor, @LazyInjectConstructor, @Inject, @LazyInject, @Provides), when calling DIContainer.shared.resolve directly is wrong, how scopes behave, how to register a module, and how to read "error: DI graph:" build failures. Use when adding or reviewing a repository, service, use case, ViewModel or coordinator that needs dependencies, when a type needs something injected, or when a DI graph validation error appears.
---

# Stiletto

Dagger/Hilt for Swift: you annotate implementations, a build-time scanner validates the whole graph, and a missing binding **fails the build** instead of crashing at runtime.

That guarantee has an exact boundary, and it is the single thing to understand:

> **Only non-defaulted initializer parameters of an `@InjectConstructor` class are part of the validated graph.**

Everything else — `DIContainer.shared.resolve(...)` at a call site, `@Inject` properties, parameters with default values — resolves at runtime and is invisible to the validator. Those are escape hatches, not the normal way to get a dependency.

## 1. The one rule

**If a type has dependencies, it is a binding.** `@Provide` + `@InjectConstructor`, plain init parameters, no default values:

```swift
@Provide(OutletRepositoryProtocol.self, scope: .singleton)
@InjectConstructor
public final class OutletRepository: OutletRepositoryProtocol {
    private let session: UserSessionRepository
    private let api: APIClientProtocol

    public init(session: UserSessionRepository, api: APIClientProtocol) {
        self.session = session
        self.api = api
    }
}
```

No registration call. No ordering. Forget to `@Provide` `APIClientProtocol` anywhere in the program and the build stops.

## 2. Which annotation do I reach for?

| Your type | Annotate it | Notes |
|---|---|---|
| Repository / service / use case / helper with deps, used behind a protocol | `@Provide(TheProtocol.self, scope:)` + `@InjectConstructor` | the default choice |
| Same, but resolved as its own concrete type | `@Provide(scope:)` + `@InjectConstructor` | no-argument form — never pass its own type |
| Leaf with no dependencies | `@Provide(Proto.self, scope:)` alone | macro emits `Foo()`, so it needs an accessible no-arg init |
| Needs an SDK value that has a sensible default | `@InjectConstructor`, default the SDK param | defaulted params keep their default; unvalidated by design |
| Needs a value only known at runtime (a `UIScene`, an id) | put the injectables in a `@Provide @InjectConstructor` holder | `Coordinator(scene: scene, deps: .auto)` |
| A third-party instance you cannot annotate | `@Provides(scope: .singleton) var x: Proto = Adapter()` | validator counts it as provided; **first** registration wins |
| ViewModel that SwiftUI/UIKit constructs | plain class, `init(x: XProtocol = resolve())` | sanctioned shorthand — §4 |
| A `struct` | nothing — `@Provide` is classes only | §5 |

`@Provide` synthesizes the registration. `@InjectConstructor` synthesizes `static func resolve(in: DIContainer)` and `static var auto`, which build the instance by resolving each init parameter. Together they produce `register(Proto.self, scope: .x) { Impl.auto }`.

## 3. Three anti-patterns, and what to write instead

### 3a. Reaching into the container from inside a type

```swift
// ✗ wrong
struct AddOutletGate {
    var isEnabled: Bool {
        DIContainer.shared.resolve(UserSessionRepository.self).hasOutletFeature
    }
}
```

Nothing here is a graph node, so `--validate` never sees the edge to `UserSessionRepository`. If any module forgot its `register()`, this is `fatalError("No dependency found for …")` at the moment a user taps something. It is also untestable without mutating the global container.

```swift
// ✓ right — it has a collaborator, so it is a use case, not an entity
@Provide(scope: .factory)
@InjectConstructor
final class AddOutletGate {
    private let session: UserSessionRepository
    init(session: UserSessionRepository) { self.session = session }

    var isEnabled: Bool { session.hasOutletFeature }
}
```

The caller resolves `AddOutletGate` once (or takes it in its own init), and the edge is now validated at build time.

### 3b. `@InjectConstructor` with defaulted params that resolve

```swift
// ✗ wrong — looks validated, isn't
@Provide(NotifUseCaseProtocol.self, scope: .factory)
@InjectConstructor
final class NotifUseCase: NotifUseCaseProtocol {
    init(service: NotifProtocol = DIContainer.shared.resolve(NotifProtocol.self)) { ... }
}
```

`@InjectConstructor` **skips every parameter that has a default value**. So `auto` expands to `NotifUseCase()` — zero resolved parameters, zero validated edges — and the dependency sneaks in through the default expression at runtime. The class carries both annotations and is still entirely unchecked. (`MacroExpansionTests.testInjectConstructorSkipsDefaultedParams` proves the skip.)

```swift
// ✓ right
init(service: NotifProtocol) { ... }
```

Defaults on an `@InjectConstructor` class are **only** for values that genuinely keep their default — an SDK singleton, a punctuation string, a feature flag:

```swift
@Provide(AnalyticsProtocol.self, scope: .singleton)
@InjectConstructor
final class AnalyticsHelper: AnalyticsProtocol {
    init(
        userRepo: UserRepositoryProtocol,           // injected + validated
        sdk: ThirdPartySDK = ThirdPartySDK.shared() // keeps its default
    ) { ... }
}
```

### 3c. `@Inject` / `@LazyInject` as the normal way to get dependencies

```swift
// ✗ not wrong, but not the default choice
final class OutletListPresenter {
    @Inject private var repo: OutletRepositoryProtocol
    @LazyInject private var tracker: TrackerProtocol
}
```

These resolve at runtime and are **not** in the validated graph. Keep them for retrofitting a legacy class whose initializer you cannot change yet; reach for `@InjectConstructor` everywhere else.

`@LazyInject`'s `wrappedValue` has a `mutating get`, so it must be a `var` on a class instance. It cannot be read from a `let` struct or from a SwiftUI `View.body` (which is non-mutating).

## 4. ViewModels — the sanctioned shorthand

A ViewModel is built by a View or a coordinator, often with fakes in previews and tests. For that one layer, default-argument resolution is accepted:

```swift
final class NotificationCenterViewModel {
    init(
        notifService: NotifProtocol = resolve(),
        navigator: NotificationDetailNavigating = resolve()
    ) { ... }
}
```

Rules for this form:

- Use the free `resolve()` — the type is inferred from the parameter, so there is nothing to repeat. Not `DIContainer.shared.resolve(NotifProtocol.self)`; same behaviour, more to read. (If `resolve` collides with one of your own names, write `Stiletto.resolve(Foo.self)`.)
- **Do not add `@Provide` or `@InjectConstructor` to a class that uses it.** That is exactly §3b: the macro skips the defaulted params and you end up with annotations that validate nothing.
- These parameters are **not** validated. The payoff is a call site that can pass a fake positionally; the cost is a runtime `fatalError` instead of a build error if a binding ever goes missing.
- Everything the ViewModel depends on must still be `@Provide`d where it is implemented. The shorthand skips the ViewModel's own registration, not its dependencies'.

This applies to ViewModels and nothing else. Repositories, services, use cases, coordinators and entities use §1.

## 5. Structs

Receiving a dependency in a struct is fine — a protocol existential is a reference to a class instance, so value semantics are intact:

```swift
struct OutletSummary {
    let name: String
    let isActive: Bool   // plain data, computed by whoever built it
}
```

Being a *binding* is not: `@Provide` rejects anything that is not a class, and deliberately. `.singleton` and `.session` cache one instance and hand it to every caller — a struct would be **copied** on each resolve, so "one shared instance" would stop meaning anything and mutations would never propagate. The container is for shared, identity-bearing collaborators, and those are classes.

The consequence that matters: **a struct that resolves from the container internally can never become a graph node.** A class in that state can be promoted to `@Provide @InjectConstructor` later; a struct has to become a class first. So pick one:

- It has collaborators and behaviour → it is a use case or service. `final class` + `@Provide(scope: .factory)` + `@InjectConstructor`.
- It must stay a value (`Equatable`, SwiftUI state, cheap to copy) → it takes no dependencies at all. The caller — which *is* a validated binding — does the work and passes plain data in.

## 6. Scopes

| Scope | Lifetime |
|---|---|
| `.singleton` | one instance for the app's lifetime (created lazily on first resolve) |
| `.session` | one instance until `DIContainer.shared.clearSession()` (lazy; recreated on next resolve) |
| `.factory` | a new instance on every resolve |

`@Provide` defaults to `.singleton` when `scope:` is omitted. Rules of thumb: stateless clients and caches `.singleton`; anything keyed to the logged-in user `.session`; use cases, presenters and ViewModels `.factory`.

Two behaviours worth knowing:

- **The container's lock is held while a factory runs.** It is recursive, so a factory can resolve its own dependencies on the same thread, and a `.singleton`/`.session` factory runs exactly once across threads. But a factory that dispatches to another thread and *blocks waiting for it* will deadlock. Keep factories to plain construction.
- **There is no `reset()`.** Re-registering a type replaces its factory, its scope and any cached instance, so `DIContainer.shared.register(Proto.self, scope: .factory) { FakeImpl() }` is how you override in a test. `clearSession()` drops cached session instances but keeps the factories.

## 7. Wiring a module

In `Package.swift`, for every target that declares bindings (`package:` is the repo identity, not the product name):

```swift
.target(
    name: "OutletModule",
    dependencies: [.product(name: "Stiletto", package: "StilettoSwift")],
    plugins: [.plugin(name: "StilettoPlugin", package: "StilettoSwift")]
)
```

The plugin generates an **internal** `enum GeneratedDI` per target, so modules never collide. Expose it once per module:

```swift
public enum OutletModuleDI {
    public static func register() { GeneratedDI.register() }
}
```

Call every module's `register()` at app startup, **in any order** — registration stores factories only, so nothing is constructed and order cannot matter.

### The step that makes the guarantee real

The per-target plugin validates each target in isolation and **deliberately ignores cross-module edges** (module A may legitimately depend on a binding provided in module B). Without a whole-program pass, a binding missing from another module is a runtime `fatalError`, not a build error — i.e. you lose the headline feature.

Add one pre-build phase that scans every source root:

```bash
swift run --package-path <stiletto-checkout> StilettoGenerator \
    --validate Modules/ MyApp/
```

For an Xcode app target this is a Run Script phase *before* Compile Sources, and it **must** start with `unset SDKROOT` — the phase inherits the iOS SDK and `swift run` breaks without it. The README has the full script, which locates the package checkout correctly for both normal and Archive builds. Also attach the plugin to the app target itself via Build Phases → Run Build Tool Plug-ins.

## 8. Gotchas that cost an afternoon

- The bound type must be the **first, unlabelled** argument. `@Provide(scope: .factory, OutletRepositoryProtocol.self)` silently becomes a self-binding.
- `scope:` must be written as a literal `.case`. A variable or computed expression silently falls back to `.singleton`.
- Graph matching is **textual** on the bare type spelling: `Foo`, `any Foo` and `OutletModule.Foo` are three different nodes. Spell a protocol the same way everywhere.
- Only the **first** initializer declared in the class body is read — by the macro and by the scanner.
- `@Provide` without `@InjectConstructor` emits `Foo()`, so the class needs an accessible no-arg init.
- `@LazyInjectConstructor` is *not* a drop-in swap for `@InjectConstructor`: it emits `@LazyInject` stored properties and its `resolve(in:)` calls `Foo()`, ignoring the init parameters entirely. It needs a no-arg init.
- Paths containing `Tests/` or `Test/` are never scanned, so `@Provide` in test code is invisible to validation. Register fakes explicitly instead.
- A missing dependency is `fatalError`, never `nil` — there is no `resolveOptional`.

## 9. Reading the build errors

```
error: DI graph: OutletRepository requires 'UserSessionRepository', which is not
provided by any @Provide (or @Provides) in the program. Annotate its
implementation with @Provide, or declare it external.
```

The implementation of `UserSessionRepository` is unannotated. Add `@Provide(UserSessionRepository.self, scope:)` to it. If it is a third-party type you cannot touch, use `@Provides` on a property that builds it, or list it as external:

```swift
enum MyExternals { static let external: [Any.Type] = [LegacyThing.self] }
```

If the type *is* annotated, check that the protocol is spelled identically in both places (see §8).

```
error: DI graph: dependency cycle detected: A → B → A
```

Two bindings need each other at construction time. Break it: make one dependency lazy by injecting a factory or a holder instead of the instance, or move the shared part into a third binding both depend on.

## Logging

Silent by default. To watch registration and resolution while debugging:

```swift
DIContainer.logHandler = { print("🗡️ \($0)") }
```

## Reference

Full API, installation and the complete Xcode validation script: [README.md](README.md). A runnable three-node graph: `Sources/StilettoExample/`.
