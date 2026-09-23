# macOS 11–12 launch-at-login helper target — PRD

> **Status: parked, deliberately unstarted.** macOS 11–12 launch-at-login
> already works — it ships as a launchd user agent written to
> `~/Library/LaunchAgents/local.FlowTrace.login.plist` by
> `FlowTrace/Feature/Settings/LaunchAtLoginManager.swift`. This task records the
> *other* mechanism (an embedded helper `.app` registered with
> `SMLoginItemSetEnabled`) so the option is not lost, and so a future
> contributor does not have to re-derive it from Apple's documentation.
>
> Nothing here is a green light. Read `design.md` § "Should this be built at
> all" before picking it up.

## Goal

Give macOS 11–12 a launch-at-login registration that, unlike the current
launchd user agent:

- is owned by the app bundle rather than by a file in the user's home directory,
- appears as the app in the system's login-item UI,
- does not record an absolute path to the bundle (so it survives the app being
  moved without a rewrite),
- disappears with the app when the bundle is deleted.

## Background — why the current implementation is not this

`SMLoginItemSetEnabled(_:_:)` (available 10.6, deprecated 13.0) cannot register
a *main app*. It registers a **helper bundle whose bundle identifier you pass
as the first argument**, and the helper must live inside the main app at
`Contents/Library/LoginItems/`. At login launchd starts the helper, and the
helper's job is to start the main app. That is the whole trick, and it is the
reason the current implementation went the other way: a helper means a second
Xcode target, a second bundle, a copy-files build phase, and a second signature.

`SMAppService.mainApp` (macOS 13+) made all of that obsolete by letting the main
app register itself. The deployment floor here is 11.0, so 11–12 is the only
reason this task exists at all.

## Requirements

- R1. On macOS 11–12, toggling "Launch at login" on must cause the app to start
  at the next login, and toggling it off must stop that.
- R2. On macOS 13+, behaviour must be **unchanged**: `SMAppService.mainApp`,
  and no helper registration.
- R3. The helper must not be a second user-visible app: no Dock icon, no menu
  bar item, no window. It starts the main app and exits.
- R4. Quitting the main app from the menu bar must not have launchd resurrect
  it, and must not affect the launch-at-login setting.
- R5. `LaunchAtLoginManager.currentStatus()` must keep reporting the *true*
  state on 11–12. `SMLoginItemSetEnabled` has no status-query counterpart to
  `SMAppService.status`, so this needs a deliberate answer (see `design.md`
  § "Status on 11–12").
- R6. Both bundles must be signed by the same stable identity. Ad-hoc signing
  (`CODE_SIGN_IDENTITY: "-"`) gives a different identity on every rebuild and is
  not acceptable for this path.
- R7. The build must remain reproducible from a fresh clone by someone who has
  the signing identity installed. There is no release pipeline in this fork, so
  "reproducible" means `xcodegen generate && xcodebuild build`.

## Non-goals

- Sandboxing, NetworkExtension, or any entitlement change. This fork stays on
  the upstream zero-permission architecture (`AGENTS.md`).
- Notarisation, Developer ID, or Homebrew packaging. There is no release
  pipeline here.
- Supporting macOS 10.15. The floor is 11.0 and this task does not move it.
- Replacing the helper path with a *fourth* mechanism (e.g. hand-written
  `launchctl bootstrap` calls). If the helper is built, the LaunchAgent is
  retired — see `design.md` § "Migration".

## Acceptance criteria

Every box below is currently unchecked. Verification must happen on a machine
running macOS 11 or 12 for the last four — they cannot be checked on 13+.

- [ ] `xcodegen generate` produces three targets (`FlowTrace`,
  `FlowTraceLoginHelper`, `FlowTraceTests`).
- [ ] `xcodebuild build` succeeds and the product contains
  `FlowTrace.app/Contents/Library/LoginItems/FlowTraceLoginHelper.app`.
- [ ] `codesign -dv --verbose=4` reports the same authority for the app and for
  the embedded helper, and `codesign --verify --deep --strict` passes on the app.
- [ ] On macOS 11 or 12: toggle on, log out and back in, the app starts.
- [ ] On macOS 11 or 12: toggle off, log out and back in, the app does not start.
- [ ] On macOS 11 or 12: delete the app bundle while the toggle is on, then log
  out and back in — no error dialog, no orphaned item left in the login-item UI.
- [ ] On macOS 13+: the toggle behaves exactly as it did before this task, and
  no `SMLoginItemSetEnabled` registration is created.
- [ ] The legacy `~/Library/LaunchAgents/local.FlowTrace.login.plist` is removed
  during migration, so a machine that had the old mechanism enabled does not get
  launched twice.

## Constraints

- **New top-level directory.** The helper's sources cannot go under `FlowTrace/`
  or `FlowTraceForMac/`: both targets declare recursive `sources:` paths in
  `project.yml`, so a `main.swift` placed there would be compiled into the main
  app as well and collide on the entry point. `.trellis/spec/macos/project-layout.md`
  says "`project.yml` declares two targets" and lists the two trees as the whole
  layout — that spec needs amending as part of this task.
- **`AGENTS.md` needs amending.** It currently states the fork "writes exactly
  one file outside its own bundle, and only when asked" and names the
  LaunchAgent as that file. If the helper replaces it, that convention is no
  longer true and the bullet must be rewritten rather than left to rot.
- **Signing identity is a prerequisite, not part of this task.** A `Dawson`
  self-signed code-signing certificate, prepared outside this repository
  (`CN=Dawson`, valid to 2076). This task consumes it; it does not create it.
- **Deprecation warning is expected.** `SMLoginItemSetEnabled` is deprecated as
  of 13.0. The call site sits in the `else` of an `#available(macOS 13.0, *)`
  check, which does not silence the warning. The fork's rule is "guard new API
  with `#available` rather than raising the target" (`AGENTS.md`), so the
  warning is accepted rather than worked around.

## References

- `design.md` — the full technical design, the status-query problem, the
  migration plan, and the reasons this was not built when the LaunchAgent was
  chosen.
- `implement.md` — step-by-step execution plan and the verification the author
  could not perform.
- `FlowTrace/Feature/Settings/LaunchAtLoginManager.swift` — the shipped
  implementation this task would replace on 11–12.
- `AGENTS.md` — deployment-target rule, the "writes one file outside its
  bundle" convention, and the fork's source-only stance.
