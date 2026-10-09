# Notification interactions: click navigation + quota 100% actions — PRD

> **Status: implemented 2026-10-09** (219 tests passing, including 13 new cases
> in `Quota100InteractionTests.swift` + `LocalizationParityTests`). The four
> open decisions in §5 were settled during implementation as marked inline.
> `docs/NOTIFICATIONS.md` documents the shipped behavior; keep it in sync with
> any future change to this spec.

## Goal

Make the three local notifications (process alert / quota threshold / data
retention) interactive and precisely re-triggerable:

1. clicking a notification opens the exact surface that gives the user a way
   to act on it (history-window alert tab / settings quota pane / settings
   storage pane);
2. the quota 100% notification carries three actions and follows a
   growth-driven re-trigger semantics with mute options, instead of today's
   "once per period, period".

Everything the spec asks for in terms of *trigger, dedup, and reset* already
matches the shipped code (see §4.1) — the work is interactions (G1, G2) and
one state-machine change (G3).

## Requirements (spec finalized 2026-09-28)

### 1. Process traffic alert (示警提醒)

1. **Trigger**: a process fires when its traffic today reaches the
   per-direction MB floor **and** exceeds its 7-day daily median × the
   configured multiplier.
2. **Independence**: download and upload are judged independently.
3. **Limit**: at most one notification per process per direction per local
   day; once sent, that process+direction is suppressed until midnight.
4. **Reset**: cumulative data clears at midnight; judging restarts.
5. **Interaction**: clicking the notification opens the history window's
   **alert-log tab**.

### 2. Quota alert (配额提醒)

1. **Percentage thresholds** (80% / custom):
   - fires at most once per period;
   - dismissing the banner or clearing the notification changes no state —
     the periodic check does not fire the same notification again.
2. **100% threshold**:
   - the notification carries three actions: **Acknowledge** (「已知」),
     **Mute 1 hour** (「1 小时不再提醒」), **Mute today** (「今天不再提醒」);
   - after dismissing the banner, clearing the notification, or tapping
     *Acknowledge*: if usage stops growing, the periodic check must not
     re-fire; if usage keeps growing, it must re-fire;
   - after *Mute 1 hour*: suppressed for one hour; after that, the periodic
     check re-fires if usage keeps growing;
   - after *Mute today*: suppressed until midnight; after midnight, the
     periodic check re-fires if usage keeps growing.
3. **Interaction**: clicking the notification opens the settings window's
   **quota pane**.

### 3. Data-retention reminder (存储通知提醒)

1. **Trigger**: checked only at the configured daily check time; fires when
   overdue rows exist; at most once per day; no polling that could fire more
   than once in a day; dismissing the banner changes no state — the next
   day's check re-evaluates.
2. **Interaction**: clicking the notification opens the settings window's
   **storage pane**.

## Gap analysis vs shipped implementation (checked 2026-09-28)

### Already satisfied — no work needed

| Spec item | Where it lives today |
| --- | --- |
| Alert 1: MB floor AND 7-day-median×multiplier | `ProcessAlertMonitor.decide()` (pure function, AND) |
| Alert 2: direction independence | per-direction floor + multiplier settings |
| Alert 3: one per process per direction per day, suppressed to midnight | `process_alert` unique index `(day, name_key, direction)`; day-ordinal rollover re-arms |
| Alert 4: midnight reset | `feed()` detects day change → clears accumulator, reloads baselines |
| Quota 1: 80%/custom once per period; dismiss changes no state | `QuotaMonitor.firedKeys` (written only on successful delivery) |
| Retention 1: check-time-only, once per day, dismiss changes no state | `DataRetentionController.lastFiredDay` + at-time check |

### Gaps to implement

| ID | Gap | Spec item | Scope sketch |
| --- | --- | --- | --- |
| **G1** | **Click navigation missing on all three notifications**: alert → history window alert tab; quota → settings quota pane; retention → settings storage pane | Alert 5 / Quota 3 / Retention 2 | Register notification categories + `userInfo` routing; handle `UNUserNotificationCenterDelegate.userNotificationCenter(_:didReceive:withCompletionHandler:)`; add "open settings/history window **and select tab X**" entry points in `AppDelegate` (`SettingsTabSelection` and the history-window tab structure already exist — they need selection APIs) |
| **G2** | **Quota 100% actions**: three buttons on the notification | Quota 2 | `UNNotificationCategory` + three `UNNotificationAction`s + callback writes the mute ledger |
| **G3** | **Quota 100% re-trigger semantics**: from "once per period" (same as 80%) to growth-driven with mute bookkeeping — dismiss/Acknowledge = no state but growth re-fires; Mute-1-hour; Mute-today | Quota 2 (all) | `QuotaMonitor` gets 100%-only state: mute-until timestamp, muted-today flag, bytes-used-at-last-notification; re-fire condition = not muted AND used > used-at-last-notification (increment threshold, see §5.1) |

### Spec errata (not blocking)

- Quota checking has **no** "60-second checkpoint": it is driven by usage
  updates (internally throttled to ~2 s). The 60-second figures belong to the
  alert evaluation interval and the retention clock poll.
- The retention controller does run an internal 60 s Timer, but only as a
  clock check ("has the configured time passed today?"); the *observable*
  behavior matches the spec (one notification at the check time, at most).

## Open decisions — settled during implementation (2026-10-09)

1. **G3 re-fire increment threshold** → **1% of the quota** (`limitBytes / 100`,
   floor 1 byte) since the last notification. Recorded in `docs/NOTIFICATIONS.md` §B1.
2. **"Mute today" survives restart** → **Option A**: the muted day key persists
   in UserDefaults (`quota100MutedDay`). The 1-hour mute is in-memory, as suggested.
3. **Identifier policy** → unchanged: `quota-<period-start>-<threshold>`;
   re-adding replaces the entry in Notification Center.
4. **Cold-start navigation** → no special handling needed in practice: the
   delegate is set during `applicationDidFinishLaunching`, the system holds
   the click until then, and both `open*` methods create their windows lazily
   on demand (they are not dependent on any prior UI state).

## Implementation checklist (when picked up)

- New strings (three action titles) go into all 21 `.lproj` tables;
  `LocalizationParityTests` guards parity.
- `docs/NOTIFICATIONS.md` sections for quota 100% and click navigation are
  rewritten to the new behavior once shipped.
- `AGENTS.md` bilingual "Active experiments" entry (touches upstream
  `AppDelegate.swift` at minimum).
- `docs/ARCHITECTURE.md` bilingual rows for `QuotaMonitor` / delivery seam.
- Tests: G3 state machine as pure functions (mute checks, increment
  threshold), action-callback routing, navigation targets; keep the
  URLProtocol-free style of the existing alert/quota tests.
