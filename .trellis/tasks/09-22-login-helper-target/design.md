# macOS 11–12 launch-at-login helper target — Design

Parked design. Nothing below is implemented. Read § "Should this be built at
all" first — it is the part most likely to change the decision.

## Should this be built at all

The LaunchAgent that ships today works. It is not a stub and not a
half-measure: `~/Library/LaunchAgents/local.FlowTrace.login.plist` is a real
launchd user agent, launchd does load it at login, and toggling the setting off
deletes it. Nothing is broken.

What the helper buys over it:

| | LaunchAgent (shipped) | Helper + `SMLoginItemSetEnabled` |
| --- | --- | --- |
| Lives in | `~/Library/LaunchAgents/` | Inside the app bundle |
| Records | An absolute path to the bundle | A bundle identifier |
| Survives the app being moved | Needs a rewrite (done on every status read) | Yes, by construction |
| Survives the app being deleted | Leaves an orphaned plist | Registration goes with the bundle |
| Shows in the login-item UI | As a background item | As the app |
| Cost | ~40 lines, one file | A target, a bundle, an embed phase, nested signing |

So this is an **upgrade in tidiness, not a fix**. Building it is worth it if any
of these become true: the LaunchAgent's orphan-on-delete bothers you, the
login-item UI listing is wrong for the product, or the app is going to move
around often. If none of those apply, the honest recommendation is to leave it
parked.

Note also that the whole task is 11–12-only. On 13+ `SMAppService.mainApp`
already provides the bundle-owned, move-safe, identifier-based registration this
task is trying to reach, so the helper would be dead weight on any machine that
runs 13 or later.

## The mechanism

`SMLoginItemSetEnabled(_ identifier: CFString, _ enabled: Bool) -> Bool`
(10.6+, deprecated 13.0) registers **a bundle identifier, not a launcher**. For
the identifier to resolve, that bundle must be a helper `.app` inside the main
app:

```
FlowTrace.app/
└── Contents/
    ├── MacOS/FlowTrace
    ├── Info.plist
    └── Library/
        └── LoginItems/
            └── FlowTraceLoginHelper.app/     ← the registered bundle
```

At login launchd starts the helper. The helper has no job other than to start
the main app and exit — it is the trampoline, not the app. This indirection is
the entire reason a second target is unavoidable; there is no API that
registers the main app on 11–12.

The helper must carry `LSUIElement = true` so it never shows a Dock tile or
steals focus during the second or two it is alive.

## XcodeGen wiring

**Verified** against XcodeGen 2.46.0 (`project.yml` requires ≥ 2.44.0) in an
isolated probe project: this YAML produces a `PBXCopyFilesBuildPhase` with
`dstSubfolderSpec = 1` (wrapper), `dstPath = Contents/Library/LoginItems`, a
`CodeSignOnCopy` attribute on the embedded build file, and a
`PBXTargetDependency` from the app to the helper.

```yaml
targets:
  FlowTrace:
    # ... existing keys unchanged ...
    dependencies:
      - target: FlowTraceLoginHelper
        embed: true
        codeSign: true
        copy:
          destination: wrapper
          subpath: Contents/Library/LoginItems

  FlowTraceLoginHelper:
    type: application
    platform: macOS
    deploymentTarget: "11.0"          # same floor as the app
    sources:
      - path: FlowTraceLoginHelper
        excludes:
          - Info.plist
    settings:
      base:
        PRODUCT_NAME: FlowTraceLoginHelper
        PRODUCT_BUNDLE_IDENTIFIER: local.FlowTrace.LoginHelper
        INFOPLIST_FILE: FlowTraceLoginHelper/Info.plist
        CODE_SIGN_IDENTITY: "Dawson"  # see § Signing
        SWIFT_VERSION: 5.0
```

`embed: true` is what names the phase; `copy:` is what moves it out of
`Contents/Frameworks` and into `Contents/Library/LoginItems`. With `copy:`
present only one phase is emitted — there is no double-embed.

**The helper's sources must live in a new top-level `FlowTraceLoginHelper/`
directory.** Not under `FlowTrace/` and not under `FlowTraceForMac/`: both of
those are declared as recursive `sources:` paths on the main target, so a
`main.swift` placed there would also be compiled into the main app and the two
entry points would collide at link time. The repo is a two-tree layout today and
this would make it three; `.trellis/spec/macos/project-layout.md` and the
`AGENTS.md` "Layout" block both need amending.

## Helper sources

`FlowTraceLoginHelper/main.swift`:

```swift
import AppKit

// The helper is the bundle launchd starts; its only job is to hand off to the
// real app and exit. `openApplication` (not a raw `exec`) because the main app
// needs an ordinary LaunchServices launch — activation policy, window
// restoration, and the single-instance check all come from being opened rather
// than spawned.
//
// The completion handler fires on a background queue, so the main thread parks
// on a semaphore. Exiting immediately after the call is the race that makes
// this kind of helper look flaky at login: LaunchServices has not necessarily
// recorded the request yet.
guard let mainApp = mainAppURL(from: Bundle.main.bundleURL) else {
    exit(EXIT_FAILURE)
}

let configuration = NSWorkspace.OpenConfiguration()
configuration.activates = false          // launch at login must not steal focus
let done = DispatchSemaphore(value: 0)
NSWorkspace.shared.openApplication(at: mainApp, configuration: configuration) { _, _ in
    done.signal()
}
_ = done.wait(timeout: .now() + 10)
exit(EXIT_SUCCESS)

/// The main app is the nearest enclosing `.app` going up from
/// `<Main>.app/Contents/Library/LoginItems/<Helper>.app` — four levels.
/// Walking up instead of hard-coding four `deletingLastPathComponent()` calls
/// means a future layout change fails loudly (no `.app` found) rather than
/// silently resolving to the wrong bundle.
private func mainAppURL(from helper: URL) -> URL? {
    var url = helper
    for _ in 0..<6 {
        url = url.deletingLastPathComponent()
        if url.pathExtension == "app" { return url }
    }
    return nil
}
```

`FlowTraceLoginHelper/Info.plist` is the minimum that makes the bundle a valid,
invisible app — mirror the main app's plist minus the storyboard:

- `CFBundleExecutable` = `$(EXECUTABLE_NAME)`
- `CFBundleIdentifier` = `$(PRODUCT_BUNDLE_IDENTIFIER)`
- `CFBundlePackageType` = `$(PRODUCT_BUNDLE_PACKAGE_TYPE)`
- `CFBundleShortVersionString` = `$(MARKETING_VERSION)`
- `CFBundleVersion` = `$(CURRENT_PROJECT_VERSION)`
- `LSMinimumSystemVersion` = `$(MACOSX_DEPLOYMENT_TARGET)`
- `LSUIElement` = `true`
- **no** `NSMainStoryboardFile`, **no** `NSPrincipalClass`

`Bundle.main` inside the helper resolves to the *helper's* bundle, which is what
the four-level walk above depends on.

## Signing

This is the part that cannot be skipped and cannot be verified without the
identity installed.

- **Ad-hoc (`CODE_SIGN_IDENTITY: "-"`) will not do.** The identity of an ad-hoc
  signature is a hash of the binary, so it changes on every rebuild. A login
  registration keyed to a bundle whose identity changes underneath it is not
  something to rely on. The app must be signed by a stable identity — here, a
  `Dawson` self-signed code-signing certificate prepared outside this repository
  (`CN=Dawson`, `X509v3 Extended Key Usage: critical, Code Signing`, valid to
  2076).
- **Both bundles must use the same identity.** The embedded helper is signed by
  the app's build, so `CODE_SIGN_IDENTITY` has to be set on the helper target
  *and* on the app target.
- **Nested code signs inside-out.** `codesign` on the outer bundle does not
  re-sign what is already inside it, so a manual sequence is helper first, then
  app:
  ```bash
  codesign -f -s "Dawson" FlowTrace.app/Contents/Library/LoginItems/FlowTraceLoginHelper.app
  codesign -f -s "Dawson" FlowTrace.app
  codesign --verify --deep --strict --verbose=2 FlowTrace.app
  ```
  `xcodebuild` performs this ordering itself when `codeSign: true` is on the
  embed — the manual sequence is only for hand-signing a build that was made
  with `CODE_SIGNING_ALLOWED=NO`.
- **`CODE_SIGN_STYLE`.** The app target currently sets `Automatic` alongside
  `CODE_SIGN_IDENTITY: "-"`. Whether `Automatic` still behaves with a concrete
  non-Apple identity, or whether it needs to become `Manual` (there is no
  `DEVELOPMENT_TEAM` and no profile, since the app is unsandboxed and
  unnotarised), is **unverified**. Try `Automatic` first; if Xcode insists on a
  team, switch the target to `Manual`.
- **Build-verification is unfortunately a real prerequisite.** `codesign` in the
  sandbox this design was written in fails with `errSecInternalComponent` when
  it needs the keychain, so none of the above was actually executed. Whoever
  picks this up must do the signing on a machine with the identity in the login
  keychain.

## Status on 11–12

`SMAppService.mainApp.status` has no counterpart here: `SMLoginItemSetEnabled`
returns whether the *call* succeeded, not whether the registration is currently
live. `currentStatus()` therefore needs its own answer, and there are two
candidates:

- **A UserDefaults flag written on every toggle.** Simple and synchronous. Its
  weakness is exactly the weakness `SettingsStore` was written to avoid on 13+:
  the flag drifts if the registration is changed anywhere else. Since nothing
  else can change a helper registration on 11–12 (there is no login-item UI that
  exposes it in Big Sur or Monterey), the drift surface is small — but it is not
  zero if the user deletes the app bundle, which silently drops the registration
  while the flag survives.
- **Query launchd.** `SMCopyAllJobDictionaries(kSMDomainUserLaunchd)` returns
  the user's job dictionaries; the helper's presence can be inferred from its
  bundle identifier. This is a `ServiceManagement` C API — also deprecated in
  13.0, alongside `SMLoginItemSetEnabled` — that reads real state instead of a
  shadow of it. It is more code and more to get wrong, but it does not drift.

Recommendation: start with the UserDefaults flag, and treat the "app bundle
deleted while enabled" case as a known small wart — the same class of wart the
LaunchAgent path already has today (a stale plist pointing at nothing). If the
drift turns out to matter, the launchd query is the upgrade path. Whichever is
chosen, the fallback for a failed registration must keep returning `.failed` so
`SettingsStore`'s existing rollback path keeps working unchanged.

## Migration

A machine that had the LaunchAgent enabled (its author's machine does) would end
up with *both* mechanisms firing: the stale plist opening the app, and the helper
doing the same. LaunchServices coalesces the second `open` so there is no
duplicate instance — but leaving the plist behind is untidy and defeats the point
of the task. So the work includes a one-time cleanup:

```swift
// On first launch of a build that uses the helper, remove the launchd agent
// left by the previous implementation. Idempotent: the guard is the file's
// absence.
try? FileManager.default.removeItem(at: launchAgentURL)
```

This also means the `LaunchAgent` nested enum in `LaunchAtLoginManager.swift`
should be **deleted**, not kept as a fallback. Two mechanisms for one setting is
how they drift apart.

## Risk register

| Unknown | Why it matters | How to resolve |
| --- | --- | --- |
| Does `SMLoginItemSetEnabled` return `true` for a self-signed helper on 11–12? | If it refuses non-Developer-ID signatures, the whole approach is dead and the LaunchAgent stays. | Log out / in on an 11 or 12 machine and check the return value plus whether the app starts. |
| Does `CODE_SIGN_STYLE: Automatic` tolerate a self-signed identity with no team? | Determines whether the app target needs `Manual`. | One `xcodebuild build` with the identity installed. |
| Deprecation warning for `SMLoginItemSetEnabled` in the `#available` `else` branch | Cosmetic, but the fork has no warnings-as-errors, so it is acceptable. | Build; confirm it is a warning, not an error. |
| `xcodebuild` nested-signing order with `codeSign: true` | Wrong order produces a helper whose signature does not validate against the app. | `codesign --verify --deep --strict` on the built app. |
| Behaviour of macOS 11 vs 12 specifically | Both are in scope and were never tested. | The two log-out/log-in acceptance checks. |

## Docs this task must touch when it lands

- `AGENTS.md` and `AGENTS.zh-CN.md` — the "writes exactly one file outside its
  bundle" convention becomes false; rewrite the bullet rather than deleting it,
  since the *rule* (state exactly what the app writes outside its bundle) is
  still the point.
- `AGENTS.md` "Layout" — add the third tree.
- `docs/ARCHITECTURE.md` and `docs/ARCHITECTURE.en.md` — the login-item row in
  the tech table, the `LaunchAtLoginManager.swift` row, and the
  `project.yml`-declares-N-targets statement.
- `.trellis/spec/macos/project-layout.md` — "declares two targets" and the
  two-tree table.
- `changelog/0.3.0.md`, `changelog/0.3.0.zh-CN.md`,
  `changelog/0.3.0.full-translation.zh-CN.md` — a new milestone section, in the
  same shape the existing per-milestone entries use.

## Summary

- Not built. The LaunchAgent path is live and works.
- The YAML in § XcodeGen wiring is verified against XcodeGen 2.46.0; everything
  in § Signing and § Risk register is not.
- The decision to build this should be re-made on the grounds in § "Should this
  be built at all", not on the assumption that this document is an approval.
