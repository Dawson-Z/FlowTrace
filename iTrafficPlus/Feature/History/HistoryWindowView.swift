//
//  HistoryWindowView.swift
//  iTrafficPlus — Feature/History
//
//  Content of the standalone history window: range selector (presets +
//  custom dates), interface-category filter, direction toggle, and the
//  heatmap grid. Owns its HistoryHeatmapModel so filters survive window
//  close/reopen (the hosting controller is cached by AppDelegate).
//

import SwiftUI

struct HistoryWindowView: View {
    @StateObject private var model = HistoryHeatmapModel()
    @State private var direction: HeatmapDirection = .dayPerRow
    // Observing LocalizationManager repaints on language change.
    @ObservedObject private var l10n = LocalizationManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Row 1: range presets + direction toggle
            HStack(spacing: 8) {
                Picker("", selection: $model.range) {
                    ForEach(HeatmapRange.allCases) { range in
                        Text(Loc.l(range.labelKey)).tag(range)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 300)

                Spacer()

                Picker("", selection: $direction) {
                    ForEach(HeatmapDirection.allCases) { dir in
                        Text(dir.symbol).tag(dir)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 76)
                .help(direction == .dayPerRow
                      ? Loc.l("Day as row")
                      : Loc.l("Day as column"))
            }

            // Row 2 (custom only): date bounds
            if model.range == .custom {
                HStack(spacing: 8) {
                    Text(Loc.l("From"))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    DatePicker("", selection: $model.customFrom, displayedComponents: .date)
                        .labelsHidden()
                        .frame(width: 130)
                    Text(Loc.l("To"))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    DatePicker("", selection: $model.customTo, in: ...Date(), displayedComponents: .date)
                        .labelsHidden()
                        .frame(width: 130)
                }
            }

            // Row 3: interface-category filter (all on = totals table)
            HStack(spacing: 10) {
                Text(Loc.l("interface"))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                ForEach(InterfaceCategory.allCases) { category in
                    Toggle(isOn: categoryBinding(category)) {
                        HStack(spacing: 3) {
                            Circle()
                                .fill(color(for: category))
                                .frame(width: 7, height: 7)
                            Text(Loc.l(category.rawValue))
                                .font(.system(size: 11))
                        }
                    }
                    .toggleStyle(.checkbox)
                }
                Spacer()
            }

            Divider()

            // Heatmap
            HistoryHeatmapView(cells: model.cells,
                               direction: direction,
                               model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Legend / status line
            HStack(spacing: 6) {
                Text(Loc.l("Less"))
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                ForEach([0.15, 0.35, 0.6, 0.85, 1.0], id: \.self) { level in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.accentColor.opacity(level))
                        .frame(width: 12, height: 12)
                }
                Text(Loc.l("More"))
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                Spacer()
                Text(Loc.l("hour cell = mean rate; ≈volume = rate × 1 h"))
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
        }
        .padding(14)
        .frame(width: 680, height: 480)
        .onAppear { model.reload() }
    }

    /// Checkbox binding for one category: toggling mutates the model's set,
    /// whose didSet triggers reload. All-off is allowed and reads as an
    /// empty grid (deliberate: it never silently means "all").
    private func categoryBinding(_ category: InterfaceCategory) -> Binding<Bool> {
        Binding(
            get: { model.selectedCategories.contains(category) },
            set: { on in
                if on { model.selectedCategories.insert(category) }
                else { model.selectedCategories.remove(category) }
            }
        )
    }

    private func color(for category: InterfaceCategory) -> Color {
        switch category {
        case .wifi:        return .blue
        case .wired:       return .green
        case .localDirect: return .orange
        case .other:       return .gray
        }
    }
}
