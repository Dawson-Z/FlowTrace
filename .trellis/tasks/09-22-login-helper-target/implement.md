# macOS 11–12 launch-at-login helper target — Implementation plan

**No implementation was produced.** This file exists so the task has a complete
`prd.md` / `design.md` / `implement.md` / two JSONL / `task.json` set, and so
whoever unparks it has an ordered plan and a verification list rather than a
design document to re-read from scratch.

## Why nothing was implemented

Not a scope call — a tooling one. Three of the four steps below need something
the authoring environment does not have:

1. **Nested-bundle signing needs the login keychain.** `codesign` there fails
   with `errSecInternalComponent`, so the app + helper signature pair could not
   be produced or verified. This is the blocking one: the design is worthless if
   `SMLoginItemSetEnabled` turns out to reject a self-signed helper, and that
   question cannot be answered without signing.
2. **The runtime behaviour is 11–12-only.** Every acceptance check that matters
   ends in a log-out / log-in cycle on Big Sur or Monterey.
3. **The LaunchAgent path already works.** There was no defect to fix, so
   shipping an unverifiable second mechanism would have been a regression in
   confidence for no user-visible gain.

The one step that *was* verifiable — the XcodeGen wiring — was verified, in an
isolated probe project. See `design.md` § "XcodeGen wiring".

## Ordered plan

Each step ends in something checkable. Do not proceed past a step whose check
fails; the later steps assume the earlier ones hold.

1. **Confirm the mechanism is viable at all.** Before writing any project
   config, prove that `SMLoginItemSetEnabled` returns `true` for a self-signed
   helper. The cheapest version of this is a throwaway signed bundle pair on an
   11/12 machine. If it returns `false`, stop — the answer is "the LaunchAgent
   stays", and this task gets re-parked with that finding recorded here.
   *Check:* a logged return value of `true`.

2. **Create `FlowTraceLoginHelper/`.** `main.swift` from `design.md`
   § "Helper sources", plus `Info.plist`. Nothing in the repo references it yet.
   *Check:* the directory exists with exactly two files, and neither is under
   `FlowTrace/` or `FlowTraceForMac/`.

3. **Wire `project.yml`.** Add the helper target and the app's `dependencies:`
   entry from `design.md` § "XcodeGen wiring". Set a concrete signing identity on
   both targets.
   *Check:* `xcodegen generate` succeeds and the app product contains
   `Contents/Library/LoginItems/FlowTraceLoginHelper.app`. Inspect the built
   bundle, not the pbxproj — the phase existing in the project file is not proof
   the file landed.

4. **Reach the 11–12 branch from the app.** In `LaunchAtLoginManager.swift`,
   replace the `LaunchAgent` nested enum with `SMLoginItemSetEnabled` calls, add
   the status mechanism chosen in `design.md` § "Status on 11–12", and keep
   13+ on `SMAppService` untouched.
   *Check:* the 13+ code path is byte-identical to what ships today.

5. **Migrate.** Delete the left-over `~/Library/LaunchAgents/local.FlowTrace.login.plist`
   on first launch, and delete the `LaunchAgent` enum. Do not keep both.
   *Check:* on a machine where the old mechanism was enabled, the plist is gone
   after one launch and the app is started exactly once per login.

6. **Update the docs.** The list is in `design.md` § "Docs this task must
   touch". `AGENTS.md`'s "writes exactly one file outside its bundle" bullet is
   the one most likely to be forgotten, because after this task the fork writes
   *zero* — the rule's premise inverts rather than disappears.

7. **Run the acceptance list.** `prd.md` § "Acceptance criteria". Everything from
   the fourth box down needs macOS 11 or 12.

## What to do if step 1 fails

If `SMLoginItemSetEnabled` refuses the self-signed helper, the LaunchAgent is
the correct and only answer for this fork, and the useful output of this task
becomes the negative result — not a code change. In that case: add the finding
to `design.md` § "Risk register", leave the task in `planning`, and note in
`FlowTrace/Feature/Settings/LaunchAtLoginManager.swift` that the helper route was
empirically ruled out, so the next person does not spend the same afternoon on
it. The launchd query in `design.md` § "Status on 11–12" is then the only
remaining item worth considering, and it is small enough to be its own task.

## What the milestone would look like in `changelog/0.3.0.md`

A sketch of the change a future contributor would commit, not a shipped entry:

```markdown
## 0.3.0 (research milestone N — new) — Bundle-owned launch at login

- `FlowTraceLoginHelper/` — a new top-level target: an invisible (`LSUIElement`)
  helper `.app` whose only job is to open the main app and exit, embedded at
  `Contents/Library/LoginItems/`.
- `Feature/Settings/LaunchAtLoginManager.swift` — the macOS 11–12 branch now
  registers the helper with `SMLoginItemSetEnabled` instead of writing a launchd
  agent into `~/Library/LaunchAgents`; the agent left by the previous
  implementation is removed on first launch.
- `project.yml` — a third target. The fork is no longer a two-target project.
- macOS 13+ is unchanged: `SMAppService.mainApp`, no helper registration.
```

## Precedent

This is the second task in this repo kept in `planning` with no code behind it.
The first is `09-05-process-knowledge-base`, which is *descoped*; this one is
*deferred*. The distinction matters for whoever reads them: a descoped task
records a decision not to build something, a deferred one records a decision not
to build it **yet**, together with what would have to become true.
