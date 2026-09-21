//
//  AccentControls.swift
//  FlowTrace — Feature/Appearance
//
//  Accent-aware replacements for the platform controls whose own drawing
//  reads the *system* accent and cannot be retinted through public API.
//
//  Why these exist
//  ---------------
//  `.tint` reaches only what SwiftUI draws itself (that is why a SwiftUI
//  `Toggle` follows the app accent). Everything AppKit draws takes its
//  colours from app-wide semantic colours that are resolved from the macOS
//  system accent, measured on this machine as:
//
//      NSColor.controlAccentColor              #FFC600
//      NSColor.keyboardFocusIndicatorColor     #FFFF1A
//      NSColor.selectedTextBackgroundColor     #8B7A3F
//      NSColor.selectedContentBackgroundColor  #D19E00
//
//  There is no supported per-app or per-control override for those, so the
//  only way to follow a *custom* accent on those surfaces is to draw them:
//
//    AccentTextField  — borderless `NSTextField` with the native focus ring
//                       suppressed, wrapped in a ring SwiftUI paints with the
//                       accent. AppKit still owns *editing*: the field
//                       editor, IME, undo and text selection behave exactly
//                       as in a stock field. Only the ring and bezel are ours.
//    AccentPicker     — button + popover list, so hover and selection can use
//                       the accent. An `NSMenu` draws both from
//                       `selectedContentBackgroundColor` /
//                       `selectedMenuItemTextColor`, which are not
//                       overridable.
//
//  Trade-off, accepted deliberately
//  --------------------------------
//  These are hand-built controls. `AccentTextField` keeps native editing but
//  loses the system focus ring and the system text-selection colour;
//  `AccentPicker` loses `NSMenu`'s keyboard navigation and scrolling. That is
//  the cost of a custom accent, and the reason "Follow system" is the mode
//  with no such compromises.
//

import SwiftUI
import AppKit

// MARK: - Field chrome

extension View {
    /// Wraps a field in the accent ring. Focused fields get a full-strength
    /// accent ring; idle ones a subdued neutral border — the same
    /// distinction the system field makes, in the app's own colour.
    func accentFieldChrome(isFocused: Bool, cornerRadius: CGFloat = 5) -> some View {
        modifier(AccentFieldChrome(isFocused: isFocused, cornerRadius: cornerRadius))
    }
}

private struct AccentFieldChrome: ViewModifier {
    let isFocused: Bool
    let cornerRadius: CGFloat

    @Environment(\.appAccent) private var accent

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color(NSColor.textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(isFocused ? accent : Color.secondary.opacity(0.35),
                            lineWidth: isFocused ? 2 : 1)
            )
            .animation(.easeInOut(duration: 0.12), value: isFocused)
    }
}

// MARK: - Text field

/// A borderless `NSTextField` with the native focus ring suppressed, so the
/// caller can draw an accent-coloured one via `accentFieldChrome(isFocused:)`.
///
/// `onCommit` returns `false` to reject the typed value; the field then
/// restores `text` (the caller's current canonical value), which is how the
/// hex field reverts bad input. A `true` return means the caller accepted the
/// value, and any canonicalisation it applied arrives on the next render.
struct AccentTextField: NSViewRepresentable {
    let text: String
    var placeholder: String = ""
    var font: NSFont = .systemFont(ofSize: NSFont.systemFontSize)
    var alignment: NSTextAlignment = .left
    /// Called on Return or focus loss. Return `false` to reject.
    let onCommit: (String) -> Bool
    @Binding var isFocused: Bool

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.commit(_:))
        context.coordinator.field = field
        context.coordinator.startObservingFieldEditor()
        return field
    }

    static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) {
        // Deliberately does *not* commit. This runs from inside
        // `NSHostingView.deinit` → `PlatformViewChild.destroy()`, while SwiftUI
        // holds its graph state under an exclusive-access check; writing back
        // through a `@Binding` from here trips `swift_beginAccess` and the
        // process aborts (`EXC_CRASH / SIGABRT`, seen at
        // `GraphHost.asyncTransaction`). The teardown cases it was meant to
        // cover are handled one step earlier, while the views are still alive:
        // a pane switch resigns the field from `SettingsTabBar`, and a window
        // close commits from the `NSWindow.willCloseNotification` hook below.
        coordinator.stopObservingFieldEditor()
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        field.font = font
        field.alignment = alignment
        field.placeholderString = placeholder
        // Never fight the field editor while the user is typing. The test has
        // to ask AppKit directly: `controlTextDidBeginEditing` is not called
        // when a click only puts the caret in the field — it fires once text is
        // actually modified — so an `isEditing` flag set from it reads false
        // for the whole click-then-type window, and a re-render landing in that
        // window would overwrite the user's first keystrokes.
        if field.currentEditor() == nil, field.stringValue != text {
            field.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: AccentTextField

        /// The field this coordinator belongs to, for the field-editor
        /// ownership test below.
        weak var field: NSTextField?
        private var observers: [NSObjectProtocol] = []

        init(_ parent: AccentTextField) { self.parent = parent }

        // MARK: Field editor

        /// Keep `isFocused` and the selection tint in step with the field
        /// editor, from the notifications the editor posts itself.
        ///
        /// The selection highlight is painted by AppKit's field editor
        /// (`NSTextView`) from `NSColor.selectedTextBackgroundColor`, which
        /// follows the *system* accent, and `NSTextView.selectedTextAttributes`
        /// is the only lever that reaches it. Writing it from
        /// `controlTextDidBeginEditing` looked right but does not work in
        /// practice: measured, a click that only puts the caret in the field
        /// never calls that delegate method — it fires once text is actually
        /// modified — so the tint was never applied, the highlight stayed
        /// system-coloured, and the accent ring stayed in its idle state while
        /// the caret sat in the field. These notifications are posted by the
        /// field editor itself and do fire on the real path —
        /// `didBeginEditing` for a re-focus that starts with a selection
        /// already in place, `didChangeSelection` for every new selection
        /// (a highlight cannot appear without one).
        func startObservingFieldEditor() {
            guard let field else { return }
            let center = NotificationCenter.default
            for name in [NSText.didBeginEditingNotification, NSTextView.didChangeSelectionNotification] {
                let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                    guard let self,
                          let editor = note.object as? NSTextView,
                          (editor.delegate as? NSTextField) === self.field else { return }
                    self.parent.isFocused = true
                    self.applySelectionTint(to: editor)
                }
                observers.append(token)
            }

            // The end-of-editing hook. `controlTextDidEndEditing` covers Return
            // and an ordinary focus change, but not a field that is torn down
            // mid-edit — switching settings panes rebuilds the pane's views, so
            // the field disappears without ever resigning first responder, and
            // the typed value was dropped. This notification comes from the
            // control itself, scoped to our field by `object:`.
            let endToken = center.addObserver(forName: NSControl.textDidEndEditingNotification,
                                              object: field, queue: .main) { [weak self] _ in
                guard let self, let field = self.field else { return }
                self.parent.isFocused = false
                self.commit(field)
            }
            observers.append(endToken)

            // Closing the window is the case neither hook above catches: typing
            // a value and dismissing the window immediately tears the whole
            // `NSHostingView` down without AppKit reporting end-of-editing for
            // the field inside it, so the value was lost. Committing from
            // `dismantleNSView` is not an option — that runs inside SwiftUI's
            // teardown and aborts on an exclusivity violation — so commit one
            // step earlier instead, while the window and every view in it are
            // still alive. Matched against `field.window` rather than an
            // `object:`, because the field has no window yet when it is made.
            let closeToken = center.addObserver(forName: NSWindow.willCloseNotification,
                                                object: nil, queue: .main) { [weak self] note in
                guard let self,
                      let field = self.field,
                      let closing = note.object as? NSWindow,
                      field.window === closing else { return }
                self.commit(field)
            }
            observers.append(closeToken)
        }

        func stopObservingFieldEditor() {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers.removeAll()
        }

        /// Point `selectedTextAttributes` at the app accent. AppKit reads it
        /// when it paints the selection, so this must be set before that paint.
        private func applySelectionTint(to editor: NSTextView) {
            let accent = AccentColorManager.shared.accent
            editor.selectedTextAttributes = [
                .backgroundColor: NSColor(accent),
                .foregroundColor: NSColor(AccentColorManager.readableForeground(on: accent)),
            ]
        }

        // MARK: Delegate

        /// Belt and braces: the field editor's `didChangeSelection` above is
        /// the hook that actually fires on a click, but this one does fire once
        /// text is modified, so it also refreshes the ring.
        func controlTextDidBeginEditing(_ notification: Notification) {
            parent.isFocused = true
            if let editor = (notification.object as? NSTextField)?.currentEditor() as? NSTextView {
                applySelectionTint(to: editor)
            }
        }

        /// Return and an ordinary focus change land here. Kept alongside the
        /// notification hook in `startObservingFieldEditor`, which covers the
        /// teardown path this misses; `commit` is idempotent, so a field that
        /// reports both commits once with the same value twice over.
        func controlTextDidEndEditing(_ notification: Notification) {
            parent.isFocused = false
            commit(notification.object)
        }

        @objc func commit(_ sender: Any?) {
            guard let field = sender as? NSTextField else { return }
            if !parent.onCommit(field.stringValue) {
                // Rejected: put the caller's canonical value back.
                field.stringValue = parent.text
            }
        }
    }
}

// MARK: - Drop-down

/// A drop-down built in SwiftUI so hover and selection can use the app accent.
///
/// Replaces the menu-style `Picker` where the accent matters. It sizes its
/// popover to the button, marks the current value with a checkmark and uses a
/// luminance-picked label colour so any user-chosen accent stays readable.
struct AccentPicker<Value: Hashable>: View {
    let options: [(label: String, value: Value)]
    @Binding var selection: Value

    @State private var isOpen = false
    @State private var menuWidth: CGFloat = 200
    @Environment(\.appAccent) private var accent

    private var currentLabel: String {
        options.first { $0.value == selection }?.label ?? ""
    }

    var body: some View {
        Button {
            isOpen = true
        } label: {
            HStack(spacing: 6) {
                Text(currentLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(NSColor.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
            )
            .contentShape(Rectangle())
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: AccentPickerWidthKey.self,
                                           value: proxy.size.width)
                }
            )
        }
        .buttonStyle(.plain)
        .onPreferenceChange(AccentPickerWidthKey.self) { menuWidth = max(120, $0) }
        .popover(isPresented: $isOpen, arrowEdge: .bottom) { menu }
    }

    private var menu: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                    AccentPickerRow(
                        label: option.label,
                        isSelected: option.value == selection,
                        accent: accent
                    ) {
                        selection = option.value
                        isOpen = false
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .frame(width: menuWidth)
        .frame(maxHeight: 340)
        // The popover is its own hosting context, so the accent has to be
        // published inside it too.
        .environment(\.appAccent, accent)
    }
}

private struct AccentPickerWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 200
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct AccentPickerRow: View {
    let label: String
    let isSelected: Bool
    let accent: Color
    let onTap: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .lineLimit(1)
            Spacer(minLength: 8)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
            }
        }
        .foregroundColor(isSelected ? AccentColorManager.readableForeground(on: accent) : .primary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(background)
        )
        .padding(.horizontal, 3)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(perform: onTap)
    }

    /// Selected = solid accent, hovered = accent tint, otherwise transparent —
    /// the same three states a menu row has, in the app's colour.
    private var background: Color {
        if isSelected { return accent }
        if isHovering { return accent.opacity(0.25) }
        return .clear
    }
}

// MARK: - Date field

/// Month-grid date picker.
///
/// Hand-built for the same reason as the controls above: the selected day and
/// the hover highlight use the app accent, which `NSDatePicker` cannot do.
/// Dates after `latest` are disabled, for the range filters that must not look
/// into the future.
///
/// Lives here rather than inside a feature because both the settings Storage
/// pane and the three history-window range filters use it.
struct AccentDateField: View {
    @Binding var date: Date
    var latest: Date = .distantFuture

    @State private var isOpen = false
    @State private var visibleMonth = Date()
    @ObservedObject private var l10n = LocalizationManager.shared
    @Environment(\.appAccent) private var accent

    /// The grid's calendar: the user's own calendar type and time zone
    /// (`Calendar.current`), with the **locale pointed at the app's language**
    /// rather than the system's.
    ///
    /// Both the weekday headings and the week-start rule are derived from the
    /// calendar's locale. Leaving them on `Calendar.current` kept them in the
    /// *system* language while every other string in the window followed the
    /// in-app override — an English override on a Chinese system still showed
    /// 日 一 二 三 四 五 六 above the grid. The two must move together: the
    /// heading order and the column the 1st of the month lands in are computed
    /// from the same `firstWeekday`.
    private var calendar: Calendar {
        var calendar = Calendar.current
        calendar.locale = Locale(identifier: l10n.locale)
        return calendar
    }

    var body: some View {
        Button {
            visibleMonth = date
            isOpen = true
        } label: {
            HStack(spacing: 6) {
                Text(dateLabel)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "calendar")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(NSColor.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(isOpen ? accent : Color.secondary.opacity(0.35),
                            lineWidth: isOpen ? 2 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isOpen, arrowEdge: .bottom) { monthGrid }
    }

    // MARK: Popover

    private var monthGrid: some View {
        VStack(spacing: 6) {
            HStack {
                Button { shiftMonth(-1) } label: {
                    Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                Spacer()
                Text(monthTitle)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button { shiftMonth(1) } label: {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .disabled(!canShiftForward)
            }

            HStack(spacing: 2) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7),
                      spacing: 2) {
                ForEach(Array(gridDays.enumerated()), id: \.offset) { _, day in
                    if let day {
                        AccentDayCell(day: day,
                                      isSelected: calendar.isDate(day, inSameDayAs: date),
                                      isToday: calendar.isDateInToday(day),
                                      isEnabled: day <= latest,
                                      title: "\(calendar.component(.day, from: day))") {
                            date = day
                            isOpen = false
                        }
                    } else {
                        Color.clear.frame(height: 20)
                    }
                }
            }
        }
        .padding(10)
        .frame(width: 224)
        // The popover is its own hosting context, so publish the accent inside
        // it as well.
        .environment(\.appAccent, accent)
    }

    // MARK: Labels

    private var dateLabel: String {
        let formatter = DateFormatter()
        // Locale first for consistency with `Loc.dateFormatter`. Unlike a
        // template, `dateStyle` is resolved at formatting time, so the order
        // here is not load-bearing — but it is easy to get wrong the other way.
        formatter.locale = Locale(identifier: l10n.locale)
        // `.short` matches what the platform date picker shows and stays inside
        // the narrow field widths the range filters use (a `.medium` date such
        // as "2026年9月20日" truncates at 130 pt in Chinese).
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private var monthTitle: String {
        // Via `Loc.dateFormatter` so the locale is set *before* the template is
        // expanded. `setLocalizedDateFormatFromTemplate` resolves the template
        // immediately, against whatever locale is current at that moment, so
        // setting `.locale` afterwards cannot change it: on a Chinese system
        // the English month title came out as "2026年9月" (dateFormat `y年M月`)
        // no matter which language the app was switched to.
        Loc.dateFormatter(template: "yMMMM").string(from: visibleMonth)
    }

    private var weekdaySymbols: [String] {
        Self.weekdayHeadings(for: l10n.locale)
    }

    /// Short weekday headings for `locale`, rotated so the first column is that
    /// locale's first day of the week.
    ///
    /// Internal rather than private so this can be pinned by a test: the
    /// headings must depend on the *requested* locale, never on the system's.
    static func weekdayHeadings(for locale: String) -> [String] {
        var calendar = Calendar.current
        calendar.locale = Locale(identifier: locale)
        let symbols = calendar.veryShortWeekdaySymbols
        let offset = calendar.firstWeekday - 1
        return Array(symbols[offset...] + symbols[..<offset])
    }

    // MARK: Grid

    /// The visible month's days, padded with `nil` so the first day lands on
    /// the right weekday column.
    private var gridDays: [Date?] {
        guard let interval = calendar.dateInterval(of: .month, for: visibleMonth),
              let dayCount = calendar.dateComponents([.day], from: interval.start, to: interval.end).day
        else { return [] }
        let leading = (calendar.component(.weekday, from: interval.start) - calendar.firstWeekday + 7) % 7
        var cells: [Date?] = Array(repeating: nil, count: leading)
        for offset in 0..<dayCount {
            cells.append(calendar.date(byAdding: .day, value: offset, to: interval.start))
        }
        return cells
    }

    private func shiftMonth(_ delta: Int) {
        visibleMonth = calendar.date(byAdding: .month, value: delta, to: visibleMonth) ?? visibleMonth
    }

    /// Forward navigation stops once the next month starts after `latest`.
    private var canShiftForward: Bool {
        guard let next = calendar.date(byAdding: .month, value: 1, to: visibleMonth),
              let start = calendar.dateInterval(of: .month, for: next)?.start
        else { return false }
        return start <= latest
    }
}

/// One day in the month grid: accent fill when selected, accent tint on
/// hover, accent text for today.
private struct AccentDayCell: View {
    let day: Date
    let isSelected: Bool
    let isToday: Bool
    let isEnabled: Bool
    let title: String
    let onTap: () -> Void

    @State private var isHovering = false
    @Environment(\.appAccent) private var accent

    var body: some View {
        Button(action: onTap) {
            Text(title)
                .font(.system(size: 11))
                .frame(maxWidth: .infinity, minHeight: 20)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isSelected ? accent : (isHovering && isEnabled ? accent.opacity(0.25) : .clear))
                )
                .foregroundColor(foreground)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { isHovering = $0 }
    }

    private var foreground: Color {
        if isSelected { return AccentColorManager.readableForeground(on: accent) }
        if !isEnabled { return Color.secondary.opacity(0.4) }
        return isToday ? accent : .primary
    }
}
