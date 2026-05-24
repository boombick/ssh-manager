# Open at Login Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "Open at login" checkbox to the Connections window that registers/unregisters the app as a macOS login item via `SMAppService`.

**Architecture:** One stateless wrapper enum (`LoginItem`) around `SMAppService.mainApp` provides `isEnabled`, `requiresApproval`, and `setEnabled(_:)`. The Connections window header gets a small `Toggle` bound to `@State`, with `.onChange` calling the wrapper and showing an alert on failure or when macOS requires user approval. macOS owns the source of truth; we never persist our own copy.

**Tech Stack:** Swift 6.0, SwiftUI, AppKit, ServiceManagement framework (`SMAppService`), macOS 13+. No git repo, no test target — checkpoints are `swift build` clean and a manual smoke test.

## Project conventions you need to know

- **Not a git repo.** Do not run `git add`/`git commit`. Each task's checkpoint is `swift build` succeeding (and, for the final task, a manual smoke test).
- **No test target.** TDD-style test files are not used here. Verification is `swift build` + reading the resulting code + final smoke test.
- **Build command from project root:** `swift build` (incremental). To produce the `.app`: `./scripts/build-app.sh`. To produce the `.pkg`: `./scripts/build-pkg.sh`.
- **Working directory** for all commands: `/Users/andreysinitsyn/work/ssh-manager`.
- **The app is a menu-bar agent** (`LSUIElement=true`). It has no Dock icon; "open at login" means it launches silently into the menu bar.

## File map

**Create:**
- `Sources/SSHManager/Storage/LoginItem.swift` — stateless enum wrapping `SMAppService.mainApp`. ~25 lines.

**Modify:**
- `Sources/SSHManager/UI/ConnectionListView.swift` — add toggle to header, alert flow, state sync.
- `Resources/Info.plist` — bump `CFBundleShortVersionString` to `0.3.1`.

**Not touched:** `AppDelegate`, `MenuBarController`, `TunnelEngine`, `TunnelSupervisor`, `Connection`, `ConfigStore`, `Paths`, `Package.swift`. `ServiceManagement` is a system framework — no manifest change needed.

---

### Task 1: Add `LoginItem` wrapper

**Files:**
- Create: `Sources/SSHManager/Storage/LoginItem.swift`

- [ ] **Step 1: Verify the directory exists**

Run: `ls Sources/SSHManager/Storage/`
Expected: lists existing files like `ConfigStore.swift`, `HistoryStore.swift`, `Database.swift`, `Paths.swift`. If the directory does not exist, stop and ask — the spec assumes a Storage folder is present.

- [ ] **Step 2: Create the file**

Write the following to `Sources/SSHManager/Storage/LoginItem.swift`:

```swift
import ServiceManagement

/// Thin wrapper around `SMAppService.mainApp` for managing "open at login".
/// Stateless — macOS owns the source of truth. We never persist our own copy.
enum LoginItem {
    /// `true` when macOS will launch us at login.
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// `true` when we are registered but the user must still approve us in
    /// System Settings → General → Login Items.
    static var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    /// Register or unregister the main app as a login item.
    /// Throws on macOS failure (e.g. app running from a transient location).
    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
```

- [ ] **Step 3: Build to verify the file compiles**

Run: `swift build`
Expected: build succeeds. No warnings about `LoginItem`.

If the build fails with "no such module 'ServiceManagement'" — stop and ask. It's a system framework and should be available on macOS 13+, but the SwiftPM target may need a `linkerSettings` entry, in which case escalate.

---

### Task 2: Header toggle in `ConnectionListView`

**Files:**
- Modify: `Sources/SSHManager/UI/ConnectionListView.swift`

The current view at lines 3–10 declares only four `@State`s (`editing`, `addingDraft`, `statsFor`, `errorMessage`). We add two more. The header is the `private var header` computed property at lines 59–73.

- [ ] **Step 1: Add the new `@State` fields and the alert payload type**

Edit `Sources/SSHManager/UI/ConnectionListView.swift`. Replace the existing state block:

```swift
struct ConnectionListView: View {
    @ObservedObject var supervisor: TunnelSupervisor
    @State private var editing: Connection?
    @State private var addingDraft: Connection?
    @State private var statsFor: Connection?
    @State private var errorMessage: String?
```

with:

```swift
struct ConnectionListView: View {
    @ObservedObject var supervisor: TunnelSupervisor
    @State private var editing: Connection?
    @State private var addingDraft: Connection?
    @State private var statsFor: Connection?
    @State private var errorMessage: String?
    @State private var openAtLogin: Bool = LoginItem.isEnabled
    @State private var loginAlert: LoginAlert?

    private struct LoginAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        /// When `true`, the alert offers an "Open Settings" button that
        /// deep-links to System Settings → General → Login Items.
        let openSettings: Bool
    }
```

- [ ] **Step 2: Add the toggle to the header**

Replace the `private var header` computed property (currently lines 59–73):

```swift
    private var header: some View {
        HStack {
            Text("Connections")
                .font(.title2)
                .fontWeight(.semibold)
            Spacer()
            Button {
                addingDraft = .blank()
            } label: {
                Label("Add", systemImage: "plus")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
```

with:

```swift
    private var header: some View {
        HStack(spacing: 12) {
            Text("Connections")
                .font(.title2)
                .fontWeight(.semibold)
            Spacer()
            Toggle("Open at login", isOn: $openAtLogin)
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .onChange(of: openAtLogin) { newValue in
                    handleOpenAtLoginChange(newValue)
                }
            Button {
                addingDraft = .blank()
            } label: {
                Label("Add", systemImage: "plus")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
```

- [ ] **Step 3: Add the change-handler method**

Add this method to `ConnectionListView` (place it directly after the `header` computed property, before `content`):

```swift
    /// Wire SMAppService toggle to the UI state.
    /// - On throw: revert the toggle and surface the error in an alert.
    /// - On success with `.requiresApproval`: leave toggle on, offer
    ///   to open System Settings.
    private func handleOpenAtLoginChange(_ newValue: Bool) {
        do {
            try LoginItem.setEnabled(newValue)
        } catch {
            // Revert without re-entering this handler.
            DispatchQueue.main.async {
                openAtLogin = !newValue
            }
            loginAlert = LoginAlert(
                title: newValue ? "Couldn't enable open at login" : "Couldn't disable open at login",
                message: "\(error.localizedDescription)\n\nYou can manage login items manually in System Settings → General → Login Items.",
                openSettings: true
            )
            return
        }
        if newValue && LoginItem.requiresApproval {
            loginAlert = LoginAlert(
                title: "Approval required",
                message: "SSH Manager is registered as a login item, but macOS needs you to enable it in System Settings → General → Login Items.",
                openSettings: true
            )
        }
    }
```

- [ ] **Step 4: Wire the alert and the `.onAppear` resync**

The view's `body` currently ends with the existing `.alert("Error", ...)` block at lines 49–56. Add the login alert and the `.onAppear` *after* the existing alert. Find this section:

```swift
        .alert("Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }
```

and replace it with:

```swift
        .alert("Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .alert(item: $loginAlert) { alert in
            if alert.openSettings {
                return Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    primaryButton: .default(Text("Open Settings")) {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    },
                    secondaryButton: .cancel(Text("OK"))
                )
            } else {
                return Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("OK")))
            }
        }
        .onAppear {
            // Resync in case the user changed the setting in System Settings
            // while our window was closed.
            let truth = LoginItem.isEnabled
            if openAtLogin != truth {
                openAtLogin = truth
            }
        }
    }
```

Note: `Alert(title:message:primaryButton:secondaryButton:)` is the older SwiftUI alert API. We use it deliberately because `.alert(item:)` with two buttons in the modern API is awkward to wire — the older API is still supported on macOS 13.

- [ ] **Step 5: Verify imports**

The file already starts with `import SwiftUI`. SwiftUI re-exports nothing for `NSWorkspace`; check whether the file (or the existing project pattern) already brings in AppKit. If `NSWorkspace` doesn't resolve, add `import AppKit` directly after `import SwiftUI` at the top of the file.

Run: `swift build`
Expected: build succeeds.

If you see `cannot find 'NSWorkspace' in scope`, add `import AppKit` and rebuild.

- [ ] **Step 6: Read the updated file end-to-end**

Read `Sources/SSHManager/UI/ConnectionListView.swift` and confirm:
- `openAtLogin` and `loginAlert` `@State` are declared.
- `LoginAlert` struct is nested inside `ConnectionListView`.
- The header HStack contains the `Toggle("Open at login", ...)` between the `Spacer()` and the `+ Add` button.
- `handleOpenAtLoginChange(_:)` is defined as a private method on the view.
- The `.alert(item: $loginAlert)` modifier is present after the error alert.
- The `.onAppear` resync block is present.

---

### Task 3: Version bump

**Files:**
- Modify: `Resources/Info.plist`

- [ ] **Step 1: Edit `CFBundleShortVersionString`**

In `Resources/Info.plist`, find:

```xml
		<key>CFBundleShortVersionString</key>
		<string>0.3.0</string>
```

Change to:

```xml
		<key>CFBundleShortVersionString</key>
		<string>0.3.1</string>
```

`CFBundleVersion` stays at `1`.

- [ ] **Step 2: Build the .app and verify the version**

Run: `./scripts/build-app.sh`
Expected: script completes; `SSHManager.app` is rebuilt at the project root.

Run: `/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" SSHManager.app/Contents/Info.plist`
Expected: `0.3.1`.

---

### Task 4: Manual smoke test

This task is operator-driven — no code changes. The implementer should not skip it: this is the only way to know the feature works.

- [ ] **Step 1: Install and launch the new build**

Run: `open SSHManager.app`
Expected: the menu-bar icon appears (look for the SSH glyph in the menu bar). If a previous version is already running, quit it from its menu before launching.

- [ ] **Step 2: Open the Connections window**

Click the menu-bar icon → "Connections…" (or whatever the existing entry is called — the app already has this window).
Expected: window opens. The header reads "Connections" on the left and now shows a small "Open at login" checkbox followed by a "+ Add" button on the right. The checkbox is unchecked on first launch.

- [ ] **Step 3: Enable login**

Click the "Open at login" checkbox.
Expected: it ticks. No error alert. If an "Approval required" alert appears, click "Open Settings", confirm the System Settings deep-link opens to the Login Items pane, then enable SSH Manager there.

- [ ] **Step 4: Verify registration**

Run: `osascript -e 'tell application "System Events" to get login items whose name is "SSHManager"'`
or simply open System Settings → General → Login Items and look for "SSHManager".
Expected: SSH Manager is listed and enabled.

- [ ] **Step 5: Reboot test (or log out / log in)**

Optional but recommended. Log out and log back in (or reboot). After login, confirm the menu-bar icon appears automatically without you launching the app.

- [ ] **Step 6: Disable login**

Open the Connections window. Untick the checkbox.
Expected: it unticks; no alert. Re-check System Settings → Login Items: SSH Manager is gone (or disabled).

- [ ] **Step 7: State-resync test**

With the window closed (or hidden behind another app), open System Settings → Login Items and manually disable SSH Manager. Close Settings. Open the Connections window again.
Expected: the checkbox now reads unticked, matching the system truth.

- [ ] **Step 8: Build the installer**

Run: `./scripts/build-pkg.sh`
Expected: `SSHManager-0.3.1.pkg` appears at the project root.

If smoke tests all passed and the .pkg built, the feature is done.

---

## Self-review

**Spec coverage:**
- Spec § "Architecture" → Task 1 creates `LoginItem.swift` with the exact API shape.
- Spec § "User experience" (toggle in header, default OFF, `.controlSize(.small)`) → Task 2 Step 2.
- Spec § "User experience" (error alert + Settings hint) → Task 2 Step 3 (error branch) + Step 4 (`Open Settings` button).
- Spec § "User experience" (`.requiresApproval` deep-link) → Task 2 Step 3 (post-success branch) + Step 4.
- Spec § "Edge cases" (resync on window reappear) → Task 2 Step 4 `.onAppear` block.
- Spec § "Edge cases" (register throw → revert) → Task 2 Step 3 catch branch.
- Spec § "Versioning" (0.3.1) → Task 3.
- Spec § "Smoke test" → Task 4.

**Placeholder scan:** No TBD/TODO. Every code step is shown verbatim. Every command has an expected outcome.

**Type consistency:** `LoginItem.isEnabled`, `LoginItem.requiresApproval`, `LoginItem.setEnabled(_:)` are used in Task 2 with the exact signatures defined in Task 1. `LoginAlert` is defined and consumed in Task 2 only.
