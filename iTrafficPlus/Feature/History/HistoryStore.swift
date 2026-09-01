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

    init(capacity: Int) {
        self.capacity = capacity
        self.buffer = RingBuffer<HistoryFrame>(capacity: capacity)
    }

    func append(inBytesPerSec: Int, outBytesPerSec: Int) {
        buffer.append(HistoryFrame(inBytesPerSec: inBytesPerSec, outBytesPerSec: outBytesPerSec))
        // Always publish a fresh snapshot. SwiftUI's diffing skips the view
        // update if the array is element-wise equal, so this is cheap when
        // nothing moved.
        samples = buffer.snapshot()
    }
}
