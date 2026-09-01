//
//  ListViewModel.swift
//  iTrafficPlus
//
//  Created by f.zou on 2021/5/23.
//

import Foundation

class ListViewModel: ObservableObject {

    @Published var items: [ProcessEntity] = []
    /// Mirrors the user's text in the search bar. Set by `ProcessSearchBar`;
    /// read by `ContentView` to filter the rendered list. Never consumed by
    /// `updateData` — keeping the merge and the filter in different layers
    /// means a keystroke does not invalidate the cached PID-merge work.
    @Published var searchText: String = ""
    var globalModel = SharedStore.globalModel
    var gcCounter = 0

    public func updateData(newItems: [ProcessEntity]) {
        if shouldClearItemsForReduceSomeMemory() {
            items.removeAll()
        }

        var pid2IndexForItems = [Int: Int]()
        var pidInNewItems = [Int: Int]()
        for (i, item) in items.enumerated() {
            pid2IndexForItems[item.pid] = i
        }

        for newItem in newItems {
            let i = pid2IndexForItems[newItem.pid] ?? -1
            if i != -1 {
                items[i].icon = newItem.icon
                items[i].name = newItem.name
                items[i].inBytesPerSec = newItem.inBytesPerSec
                items[i].outBytesPerSec = newItem.outBytesPerSec
            } else {
                items.append(newItem)
                pid2IndexForItems[newItem.pid] = items.count - 1
            }
            pidInNewItems[newItem.pid] = 1
        }

        items = items.filter { pidInNewItems[$0.pid] != nil }
        items = sort(items: items)
    }

    func sort(items: [ProcessEntity]) -> [ProcessEntity] {
        return items.sorted {  (lhs:ProcessEntity, rhs:ProcessEntity) in
            let lTotalRate = lhs.inBytesPerSec + lhs.outBytesPerSec
            let rTotalRate = rhs.inBytesPerSec + rhs.outBytesPerSec
            if lTotalRate != rTotalRate {
                return lTotalRate > rTotalRate
            }
            return lhs.name < rhs.name
        }
    }

    public func shouldClearItemsForReduceSomeMemory() -> Bool {
        gcCounter += 1
        if !self.globalModel.viewShowing && gcCounter >= 50 {
            gcCounter = 0
            return true
        }
        return false
    }
}
