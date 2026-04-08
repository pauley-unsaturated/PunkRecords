---
id: A1B2C3D4-E5F6-7890-ABCD-EF1234567890
title: Swift Concurrency Deep Dive
tags: [swift, concurrency, async-await]
created: 2026-03-15
modified: 2026-04-01
---

# Swift Concurrency Deep Dive

Swift's concurrency model is built on **structured concurrency** and the `async/await` pattern.
This note covers the key concepts and how they fit together.

## Actors

Actors provide *data-race safety* by isolating their mutable state. Only one task can execute
on an actor at a time:

```swift
actor BankAccount {
    private var balance: Double = 0

    func deposit(_ amount: Double) {
        balance += amount
    }

    func withdraw(_ amount: Double) throws -> Double {
        guard balance >= amount else {
            throw BankError.insufficientFunds
        }
        balance -= amount
        return amount
    }
}
```

## Task Groups

Use `withTaskGroup` when you need to fan out work and collect results:

```swift
let results = await withTaskGroup(of: String.self) { group in
    for url in urls {
        group.addTask { await fetch(url) }
    }
    return await group.reduce(into: []) { $0.append($1) }
}
```

## Key Takeaways

- [x] Understand `async/await` basics
- [x] Learn about actor isolation
- [ ] Explore `AsyncSequence` patterns
- [ ] Study `Sendable` conformance rules

> **Note:** See also [[Actor Reentrancy]] and [[Sendable Protocol]] for deeper dives.

Related: [[Swift Language Notes]] | [[WWDC 2024 Sessions]]

---
*Last reviewed: 2026-04-01*
