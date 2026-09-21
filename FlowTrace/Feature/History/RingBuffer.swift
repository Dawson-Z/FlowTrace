//
//  RingBuffer.swift
//  FlowTrace — Feature/History
//
//  Bounded FIFO buffer used to back the sparkline. Backing storage is a
//  pre-allocated array of `capacity` slots, so append is O(1) and never
//  allocates after init. This matters: the upstream's nettop pumps a frame
//  every 1 second, and a 60-frame window means 60 writes/minute forever.
//

import Foundation

struct RingBuffer<Element> {
    private(set) var capacity: Int
    private var storage: [Element?]
    /// Index of the next slot to write into. `count` is the number of valid
    /// entries so far, capped at `capacity`.
    private var writeIndex: Int = 0
    private(set) var count: Int = 0

    init(capacity: Int) {
        precondition(capacity > 0, "RingBuffer capacity must be positive")
        self.capacity = capacity
        self.storage = Array(repeating: nil, count: capacity)
    }

    mutating func append(_ element: Element) {
        storage[writeIndex] = element
        writeIndex = (writeIndex + 1) % capacity
        if count < capacity { count += 1 }
    }

    /// Drop every element (all slots nil, counts reset) so the sparkline
    /// renders empty. Used by the Settings "Clear data" action.
    mutating func removeAll() {
        storage = Array(repeating: nil, count: capacity)
        writeIndex = 0
        count = 0
    }

    /// Returns the elements in insertion order. The most recent element is
    /// the *last* one in the returned array, which is what the sparkline
    /// wants (left-to-right = old-to-new).
    func snapshot() -> [Element] {
        guard count > 0 else { return [] }
        var out: [Element] = []
        out.reserveCapacity(count)
        // Oldest valid index = writeIndex when the buffer is full, else 0.
        let start = count < capacity ? 0 : writeIndex
        for offset in 0..<count {
            let idx = (start + offset) % capacity
            if let v = storage[idx] { out.append(v) }
        }
        return out
    }
}
