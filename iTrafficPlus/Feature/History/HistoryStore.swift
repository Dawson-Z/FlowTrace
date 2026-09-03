//
//  HistoryStore.swift
//  iTrafficPlus — Feature/History
//
//  Per-frame totals (in/out) pushed from Network. Owns the ring buffer,
//  publishes a snapshot every time it changes. SwiftUI's `@Published` does
//  the diff for us — readers can re-render the sparkline in O(1) on each
//  push without comparing the previous frame themselves.
//

import Foundation
import SwiftUI

struct HistoryFrame: Equatable {
    let inBytesPerSec: Int
    let outBytesPerSec: Int
}

final class HistoryStore: ObservableObject {
    @Published private(set) var samples: [HistoryFrame] = []
    let capacity: Int

    private var buffer: RingBuffer<HistoryFrame>
    /// Optional SQLite-backed history. When present, every append also
    /// writes one row to disk on a private serial queue, and `bootstrap()`
    /// seeds `buffer` from the last `capacity` rows so the sparkline is
    /// not empty after a restart. Nil means "memory only" — used by
    /// unit tests so they don't need an Application Support directory.
    private let persistence: HistoryPersistence?

    init(capacity: Int, persistence: HistoryPersistence? = nil) {
        self.capacity = capacity
        self.buffer = RingBuffer<HistoryFrame>(capacity: capacity)
        self.persistence = persistence
    }

    /// One-shot, called from `AppDelegate.applicationDidFinishLaunching`
    /// after the store is wired into `SharedStore`. Bounded SELECT, so
    /// safe to call on the main thread during launch.
    func bootstrap() {
        guard let persistence = persistence else { return }
        for row in persistence.recent(limit: capacity) {
            buffer.append(HistoryFrame(inBytesPerSec: row.inBytesPerSec, outBytesPerSec: row.outBytesPerSec))
        }
        let seeded = buffer.snapshot().count
        if seeded > 0 {
            samples = buffer.snapshot()
        }
        Log.persistence.info("bootstrap: seeded \(seeded) frames from on-disk history")
    }

    func append(inBytesPerSec: Int, outBytesPerSec: Int) {
        buffer.append(HistoryFrame(inBytesPerSec: inBytesPerSec, outBytesPerSec: outBytesPerSec))
        // Always publish a fresh snapshot. SwiftUI's diffing skips the view
        // update if the array is element-wise equal, so this is cheap when
        // nothing moved.
        samples = buffer.snapshot()
        if let persistence = persistence {
            let ts = Int64(Date().timeIntervalSince1970 * 1000)
            persistence.append(HistoryRow(
                ts: ts,
                inBytesPerSec: inBytesPerSec,
                outBytesPerSec: outBytesPerSec
            ))
        }
    }
}
