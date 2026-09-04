//
//  HistoryView.swift
//  iTrafficPlus — Feature/History
//
//  A 60-sample sparkline drawn with raw `Path`s — no Charts framework, since
//  the deployment target is 10.15 and Charts requires macOS 13. Two stacked
//  paths: in (above baseline, primary tint) and out (below, secondary tint).
//  The most recent sample is on the right, oldest on the left.
//

import SwiftUI

struct HistoryView: View {
    @ObservedObject var store: HistoryStore

    var body: some View {
        let samples = store.samples
        let peak = max(1, samples.map { max($0.inBytesPerSec, $0.outBytesPerSec) }.max() ?? 1)
        let latestIn  = samples.last?.inBytesPerSec  ?? 0
        let latestOut = samples.last?.outBytesPerSec ?? 0
        let summary = store.summary

        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("last 2 min")
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

            // Milestone 8: today's peaks + 24 h averages, both from the
            // on-disk history. `summary` is 0-filled before enough data has
            // accumulated after a fresh install; a 0 formats as "—" via
            // formatBytesCompact's 0.05 KB/s threshold, so no special-case
            // blanking is needed here.
            HStack(spacing: 6) {
                Text("today peak")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                Text("↓ \(formatBytesCompact(bytes: summary.todayPeakIn))")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
                Text("↑ \(formatBytesCompact(bytes: summary.todayPeakOut))")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
                Spacer()
                Text("24 h avg")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                Text("↓ \(formatBytesCompact(bytes: summary.avgLast24hIn))")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
                Text("↑ \(formatBytesCompact(bytes: summary.avgLast24hOut))")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
            }
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
            // samples, since nettop emits exactly one frame every 2 seconds
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
