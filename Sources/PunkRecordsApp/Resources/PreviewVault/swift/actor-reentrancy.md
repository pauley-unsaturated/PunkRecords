---
id: 33333333-3333-3333-3333-333333333333
title: Actor Reentrancy
tags: [swift, concurrency]
created: 2026-03-20
modified: 2026-03-28
---

# Actor Reentrancy

Actor reentrancy is a subtle issue in Swift concurrency. When an actor method hits a suspension
point (`await`), other callers can execute on the actor in the meantime.

## The Problem

```swift
actor ImageLoader {
    var cache: [URL: Image] = [:]

    func loadImage(from url: URL) async -> Image {
        if let cached = cache[url] { return cached }

        // ⚠️ Suspension point — another call could start here
        let image = await downloadImage(from: url)

        cache[url] = image  // Might overwrite a different caller's result
        return image
    }
}
```

## The Fix

Check state **after** the await, not just before:

```swift
func loadImage(from url: URL) async -> Image {
    if let cached = cache[url] { return cached }
    let image = await downloadImage(from: url)
    // Re-check after suspension
    if let cached = cache[url] { return cached }
    cache[url] = image
    return image
}
```

See [[Swift Concurrency Deep Dive]] for the broader concurrency model.
