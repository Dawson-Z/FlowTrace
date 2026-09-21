//
//  HistoryView.swift
//  FlowTrace — Feature/History
//
//  A 60-sample sparkline drawn with raw `Path`s — no Charts framework, since
//  the deployment target is 11.0 and Charts requires macOS 13. Two stacked
//  paths: in (above baseline, primary tint) and out (below, secondary tint).
//  The most recent sample is on the right, oldest on the left.
//

import SwiftUI

struct HistoryView: View {
    @ObservedObject var store: HistoryStore

    // The entry row below reads its colour from the window root's
    // `appAccentScope`, so it repaints when the accent changes.
    @Environment(\.appAccent) private var appAccent

    /// Drives the hover tint on the history-window entry button.
    @State private var isHoveringEntry = false

    var body: some View {
        let samples = store.samples
        let peak = max(1, samples.map { max($0.inBytesPerSec, $0.outBytesPerSec) }.max() ?? 1)
        let latestIn  = samples.last?.inBytesPerSec  ?? 0
        let latestOut = samples.last?.outBytesPerSec ?? 0
        let summary = store.summary

        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(Loc.l("last 2 min"))
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                Spacer()
                HStack(spacing: 4) {
                    Text("↓ \(formatBytesCompact(bytes: latestIn))")
                        .font(.system(size: 9, design: .monospaced))
                    Text("↑ \(formatBytesCompact(bytes: latestOut))")
                        .font(.system(size: 9, design: .monospaced))
                }
                .foregroundColor(.secondary)
            }
            sparkline(samples: samples, peak: peak)
                .frame(height: 28)

            // Milestone 8: today's peaks + today's totals, both from the
            // on-disk history. `summary` is 0-filled before enough data has
            // accumulated after a fresh install; a 0 formats as "—" via
            // formatBytesCompact's 0.05 KB/s threshold, so no special-case
            // blanking is needed here.
            HStack(spacing: 6) {
                Text(Loc.l("today peak"))
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                Text("↓ \(formatBytesCompact(bytes: summary.todayPeakIn))")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
                Text("↑ \(formatBytesCompact(bytes: summary.todayPeakOut))")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
                Spacer()
                Text(Loc.l("Total today"))
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                Text("↓ \(formatBytesCompact(bytes: summary.todayInBytes))")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
                Text("↑ \(formatBytesCompact(bytes: summary.todayOutBytes))")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
                // The combined figure. Without it the two arrows read as the
                // total and the row answers "down how much, up how much" but
                // never "how much altogether". Weight separates it from the
                // two detail figures; the colour stays with the rest of the row.
                Text("= \(formatBytesCompact(bytes: summary.todayTotalBytes))")
                    .font(.system(size: 9, design: .monospaced))
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
            }

            // A full-width, obvious entry to the standalone history window
            // (heatmap + range + interface filter). The old tiny "⤢" glyph
            // was too easy to miss — it sat directly under four rows of 9pt
            // grey statistics in the same colour, so the whole block read as
            // one grey mass. It is now a bordered, accent-tinted button that
            // lights up on hover, with its own divider to separate it from
            // those statistics.
            Divider()
                .padding(.top, 4)

            Button(action: { NSApp.sendAction(#selector(AppDelegate.showHistoryWindow), to: nil, from: nil) }) {
                HStack(spacing: 6) {
                    Image(systemName: "chart.xyaxis.line")
                        .font(.system(size: 11))
                    Text(Loc.l("Open history statistics"))
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundColor(appAccent)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(appAccent.opacity(isHoveringEntry ? 0.16 : 0.07))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(appAccent.opacity(0.30), lineWidth: 0.5)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHoveringEntry = $0 }
            .animation(.easeOut(duration: 0.12), value: isHoveringEntry)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func sparkline(samples: [HistoryFrame], peak: Int) -> some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height
            let mid = h / 2
            // X step is constant; we don't compress the line for missing
            // samples, since nettop emits exactly one frame every 1 second
            // and the buffer slots line up with that.
            let stepX: CGFloat = samples.count > 1 ? w / CGFloat(samples.count - 1) : 0

            ZStack {
                // Faint center line so the two halves read as a single chart.
                Path { p in
                    p.move(to: CGPoint(x: 0, y: mid))
                    p.addLine(to: CGPoint(x: w, y: mid))
                }
                .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)

                // Download (in) — above the center line.
                Path { p in
                    for (i, s) in samples.enumerated() {
                        let x = CGFloat(i) * stepX
                        let ratio = CGFloat(s.inBytesPerSec) / CGFloat(peak)
                        let y = mid - ratio * mid
                        if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
                        else { p.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                .stroke(Color.primary.opacity(0.7), lineWidth: 1)

                // Upload (out) — below the center line.
                Path { p in
                    for (i, s) in samples.enumerated() {
                        let x = CGFloat(i) * stepX
                        let ratio = CGFloat(s.outBytesPerSec) / CGFloat(peak)
                        let y = mid + ratio * mid
                        if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
                        else { p.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                .stroke(Color.secondary.opacity(0.7), lineWidth: 1)
            }
        }
    }
}

struct HistoryView_Previews: PreviewProvider {
    static var previews: some View {
        let store = HistoryStore(capacity: 60)
        // Seed a few pretend frames so the preview isn't empty.
        for i in 0..<30 {
            let v = Int(sin(Double(i) / 3) * 50_000 + 60_000)
            store.append(inBytesPerSec: v, outBytesPerSec: v / 4)
        }
        return HistoryView(store: store).frame(width: 340)
    }
}
