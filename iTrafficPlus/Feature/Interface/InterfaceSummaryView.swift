//
//  InterfaceSummaryView.swift
//  iTrafficPlus — Feature/Interface
//
//  A compact four-bucket overview of external network traffic split by
//  semantic interface category: Wi-Fi / Wired / Local Direct (AWDL) /
//  Other. Reads `SharedStore.interfaceModel`. The drawing uses raw layout
//  (no iOS Charts — deployment target is 11.0) and a Unicode glyph beside
//  each category, following the AGENTS.md "no SF Symbols at small sizes"
//  rule.
//

import SwiftUI

struct InterfaceSummaryView: View {
    @ObservedObject var model = SharedStore.interfaceModel

    var body: some View {
        let snapshot = model.snapshot
        let totalIn = snapshot.totalIn
        let totalOut = snapshot.totalOut
        // Guard against a zero-window (no external traffic yet): the bar
        // stays flat and the numbers show as "—" via formatBytesCompact.
        let maxTotal = max(1, max(totalIn, totalOut))

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("interface")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                Spacer()
                Text("↓ \(formatBytesCompact(bytes: totalIn))")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
                Text("↑ \(formatBytesCompact(bytes: totalOut))")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            // Stacked bar: each segment's width is its share of the max of
            // in/out totals. (Using a single bar with per-category colour.)
            GeometryReader { proxy in
                let w = proxy.size.width
                let h = proxy.size.height
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.08))
                    HStack(spacing: 1) {
                        ForEach(InterfaceCategory.allCases) { cat in
                            let inW = CGFloat(snapshot.bytesIn[cat] ?? 0) / CGFloat(maxTotal)
                            let outW = CGFloat(snapshot.bytesOut[cat] ?? 0) / CGFloat(maxTotal)
                            let seg = max(inW, outW)
                            if seg > 0.001 {
                                Rectangle()
                                    .fill(cat.color)
                                    .frame(width: max(2, seg * w))
                            }
                        }
                    }
                }
                .frame(height: h)
            }
            .frame(height: 6)

            HStack(spacing: 10) {
                ForEach(InterfaceCategory.allCases) { cat in
                    HStack(spacing: 3) {
                        Circle().fill(cat.color).frame(width: 6, height: 6)
                        Text(cat.rawValue)
                            .font(.system(size: 8))
                            .foregroundColor(.secondary)
                        Text("↓\(formatBytesCompact(bytes: snapshot.bytesIn[cat] ?? 0))")
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}

private extension InterfaceCategory {
    var color: Color {
        switch self {
        case .wifi:        return .blue
        case .wired:       return .green
        case .usb:         return .purple
        case .localDirect: return .orange
        case .other:       return .gray
        }
    }
}
