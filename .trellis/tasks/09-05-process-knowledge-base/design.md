# Process knowledge base — Design (retrospective, 2026-09)

This task has no shipped implementation, so this file documents
the **non-design**: the constraints that rule out the design the
PRD proposed, and the design path a future contributor would
take if those constraints change.

## Why no implementation

The PRD proposed a bundled-JSON knowledge base. The fork's
hard rules eliminate three options, leaving no viable shape:

| Option | Killed by |
| --- | --- |
| Bundled JSON, updated with the app | Maintained-by-the-project process names age out of date every macOS minor release. A 30-entry JSON for "common macOS processes" written in 2026 is wrong about half its entries by 2027. |
| Network-fetched JSON, refreshed on launch | `AGENTS.md` forbids any network request. |
| User-curated JSON in `~/Library/Application Support/` | Out of scope of the PRD; introduces a new maintenance surface that the user did not ask for. |

The PRD also proposed surfacing entries via SwiftUI `.help(_:)`
tooltips on process rows. That part is implementable but useless
without the data, so it is also not done.

## What a future implementation would look like

If a future contributor revisits this task, the smallest viable
shape is:

```
FlowTrace/Feature/Knowledge/
├── processes.json       # bundled, frozen at release
└── ProcessKB.swift      # longest-prefix match, pure, unit-testable
```

The matcher:

```swift
struct ProcessKB {
    struct Entry {
        let name: String          // match key (lower-cased)
        let displayName: String
        let descriptionZhHans: String
        let descriptionEn: String
        let descriptionZhHant: String
        let risk: Risk            // safe | caution | risk
        let category: Category    // system | app | daemon
    }

    static let entries: [Entry] = loadBundledJSON()

    /// Longest-prefix, case-insensitive match. None on no match.
    static func match(name: String) -> Entry? {
        let needle = name.lowercased()
        return entries
            .filter { needle.hasPrefix($0.name) || $0.name.hasPrefix(needle) }
            .max(by: { $0.name.count < $1.name.count })
    }
}
```

This is a pure function: testable without UI, without a database,
without a network. The schema above is the smallest set of fields
the original PRD asked for; nothing else needs to ship.

The UI hook:

```swift
// ContentView.swift, ProcessRow.body
.help(kb?.description(locale: l10n.locale) ?? "")
```

`.help(_:)` is exactly the SwiftUI surface for a one-line tooltip.
No layout change, no extra window.

## Why a future contributor should weigh this carefully

- `AGENTS.md` would need to be amended (or relaxed) before this
  task is reopened. The current "no network requests" rule is
  load-bearing for the project's stance that this tool never
  transmits anything off the user's machine.
- The user value of a process name → description mapping is real
  but small. The same question can be answered by `man`,
  `Activity Monitor`'s built-in columns, or a search engine. The
  cost-benefit is not obviously favourable over the project
  lifetime.

## Summary

- This task exists in `planning` because no work has been done on it.
- The original PRD's bullet list is preserved here for the record.
- The descoping decision is documented so a future contributor
  does not silently re-add the cost-benefit question without seeing
  the answer.

If you are reading this and considering opening a PR for this
task, please do the cost-benefit analysis first. The PRD above
is not a green light; it is a record of what was proposed and why
the project declined.
