import Foundation

/// Deterministic subset selection for flywheel runs.
///
/// When `PUNKRECORDS_EVAL_SAMPLE=n` asks for a subset, selection must be a pure
/// function of the scenario id and the run's calendar day — **not** an RNG — so
/// re-running the same sample size on the same day picks the *same* scenarios.
/// That keeps same-day reruns directly comparable while still rotating coverage
/// across the full set from one day to the next.
public enum ScenarioSampler {

    /// Stable 64-bit FNV-1a hash over the UTF-8 bytes.
    ///
    /// Deliberately NOT Swift's `Hashable.hashValue`: that is seeded per process
    /// (SipHash), so it changes run to run and would make "same-day" selection
    /// non-reproducible. FNV-1a is identical across processes and OS versions,
    /// which is exactly the property the flywheel needs.
    public static func stableHash(_ string: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037  // FNV-1a offset basis
        let prime: UInt64 = 1_099_511_628_211
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return hash
    }

    /// The calendar-day key (`yyyy-MM-dd`, UTC) used to salt the hash so the
    /// sample rotates day to day but stays stable within a single day.
    public static func dayKey(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Deterministically order `ids` by `stableHash(id + "@" + dayKey)`, tie-broken
    /// by the id itself for a total, stable ordering.
    public static func order(ids: [String], date: Date) -> [String] {
        let key = dayKey(for: date)
        return ids.sorted { lhs, rhs in
            let hl = stableHash(lhs + "@" + key)
            let hr = stableHash(rhs + "@" + key)
            if hl != hr { return hl < hr }
            return lhs < rhs
        }
    }

    /// Deterministically pick `count` scenarios for the given `date`.
    ///
    /// - `count <= 0` or `count >= scenarios.count` returns every scenario in its
    ///   original order (i.e. "no sampling").
    /// - Otherwise returns the `count` scenarios whose ids sort first under the
    ///   day-salted stable hash, restored to their **original relative order** so
    ///   printed reports stay readable and stable.
    public static func sample(_ scenarios: [EvalScenario], count: Int, date: Date = Date()) -> [EvalScenario] {
        guard count > 0, count < scenarios.count else { return scenarios }
        let chosen = Set(order(ids: scenarios.map(\.id), date: date).prefix(count))
        return scenarios.filter { chosen.contains($0.id) }
    }
}
