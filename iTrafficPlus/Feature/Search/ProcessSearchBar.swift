//
//  ProcessSearchBar.swift
//  iTrafficPlus — Feature/Search
//
//  Single-line text field bound to ListViewModel.searchText. The actual
//  filtering happens in ContentView (via SearchFilter), not here, so this
//  view stays trivial: one TextField, no business logic.
//

import SwiftUI

struct ProcessSearchBar: View {
    @ObservedObject var viewModel: ListViewModel

    var body: some View {
        HStack(spacing: 6) {
            // Magnifier glyph as a Unicode character — the upstream's
            // convention is "no SF Symbols at small sizes", so a glyph avoids
            // the .resizable() trap.
            Text("⌕")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            TextField("Filter processes", text: $viewModel.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !viewModel.searchText.isEmpty {
                Button(action: { viewModel.searchText = "" }) {
                    Text("×")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}

struct ProcessSearchBar_Previews: PreviewProvider {
    static var previews: some View {
        ProcessSearchBar(viewModel: ListViewModel())
            .frame(width: 340)
    }
}
