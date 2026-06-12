//
//  main.swift
//  StilettoExample
//
//  `swift run StilettoExample`
//
//  `GeneratedDI` is produced by StilettoPlugin at build time, in dependency
//  (leaf-first) order: SystemClock → Greeter → GreetingUseCase.
//

import Stiletto

DIContainer.logHandler = { print("🗡️ \($0)") }

GeneratedDI.register()

let useCase = resolve(GreetingUseCase.self)
print(useCase.run(name: "Stiletto"))
