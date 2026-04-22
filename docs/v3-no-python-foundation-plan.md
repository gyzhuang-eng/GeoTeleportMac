# V3 No-Python Foundation Plan

## Goal

Build a macOS version of GeoTeleportMac that no longer depends on the user's
Python environment or `pymobiledevice3` binary being installed on the system.

V3 means:

- the app UI does not scan for `python3`, `pipx`, or `pymobiledevice3`
- device operations are no longer launched directly from `ContentView`
- the product can evolve toward a bundled native device stack and helper model
- iOS 17+ tunnel handling is owned by the product architecture instead of an
  external Terminal workflow

## Non-Goals

The current V3 foundation work does not try to do the following yet:

- support Android
- support Windows
- redesign the visual style of the product
- add cloud sync, accounts, or remote control
- promise wireless workflows beyond what the future backend can support
- fully replace the backend on day one without an intermediate adapter layer

## What Stays Safe

This branch is intended to isolate V3 exploration from the shipping app.

Important practical meaning:

- current `main` remains the baseline version
- all V3 refactors and experiments happen on `v3-no-python-foundation`
- if V3 becomes unstable, `main` still preserves the current app behavior
- your existing app binary and current branch workflow are not changed unless
  you explicitly merge V3 work back

The branch now also uses an isolated experimental app identity:

- product name: `GeoTeleportMacV3`
- bundle id: `com.test.GeoTeleportMac.v3`
- local defaults keys are namespaced with `v3.`

That reduces the risk of this preview build colliding with the current app on
the same Mac during local testing.

## Current Baseline

The current app is functionally a single-screen SwiftUI shell around external
CLI tooling.

Current coupling in `GeoTeleportMac/ContentView.swift`:

- UI state and device state live in the same view
- dependency discovery is hard-coded to Python install paths
- transport is shell-driven via `Process`
- USB detection uses `ioreg`
- tunnel detection uses `pgrep` against a `pymobiledevice3 remote tunneld`
  process name
- iOS version detection calls `pymobiledevice3 lockdown info`
- location injection calls `pymobiledevice3 developer simulate-location`
- failure recovery is based on parsing CLI stdout/stderr text
- iOS 17+ recovery depends on launching Terminal through AppleScript

This means the current product is not just "using Python"; it is shaped around
Python-specific control flow and error handling.

## Current Baseline Inventory

The present implementation depends on the following external/system-facing
mechanisms:

- `pymobiledevice3` executable discovery by hard-coded paths and `which -a`
- `pymobiledevice3 lockdown info` for iOS version lookup
- `pymobiledevice3 developer simulate-location set` for teleport
- `pgrep -f pymobiledevice3.*remote.*tunneld` for tunnel presence checks
- `ioreg -p IOUSB -w0` for iPhone connection detection
- AppleScript + Terminal for launching the tunnel command
- stdout/stderr text heuristics for user-facing failure diagnosis

This baseline matters because V3 must replace each of these responsibilities,
not just the Python executable itself.

## Progress Snapshot

Current implementation status on branch `v3-no-python-foundation`:

- Phase 0: complete
- Phase 1: complete in practice
- Phase 2: complete in practice
- Phase 3: started, with a working child-process agent scaffold and first
  no-Python probes
- Phase 4: not started

What is already true:

- V3 work is isolated on its own branch
- V3 app identity is isolated from the current app build
- `ContentView` no longer launches `Process` directly for backend work
- legacy CLI behavior now sits behind a backend contract and coordinator/services
- diagnostics, status, and presentation mapping are no longer owned directly by the view
- backend selection now exists as a runtime track:
  - `legacyPreview`
  - `noPythonStub`
- the no-Python track now has a structured agent-style scaffold:
  - typed agent events
  - typed agent failures
  - a stub agent client behind the backend adapter
  - a JSON request/response protocol that can later move to a real child process
  - a child-process transport shell using the app executable in `--v3-agent` mode
  - a first real no-Python capability: system-level USB device detection
  - richer USB summaries from `system_profiler` with `ioreg` fallback
  - basic legacy tunnel process observation owned by the agent path
  - partial backend availability so the UI can distinguish probing from
    injection readiness
  - explicit backend capability reporting for device probe, tunnel observation,
    and location injection
  - short-lived no-Python probe caching so the polling UI does not relaunch the
    agent and heavy USB inspection on every refresh tick
  - structured device metadata in the app model, including device name, probe
    source, serial suffix, and multi-device count
  - an app-level session/health model so UI state is derived from connection
    stage and backend capability, not just raw USB presence
  - an explicit blocker/next-action model so V3 can say what currently prevents
    readiness and what the product should tell the user to do next
  - session-transition logging so diagnostics track state changes rather than
    only repeating raw probe output
  - blocker-transition logging so diagnostics capture when the gating reason
    changes even if the raw transport state does not
  - agent-side session assessment payloads so no-Python probes can explain
    readiness summary, blockers, confidence, and next action before deeper
    transport exists
  - app-model wiring for those assessments so `NO-PY` status cards can render
    agent-derived readiness and confidence directly instead of only generic
    fallback state text
  - tighter no-Python tunnel semantics so observing a legacy tunnel process is
    no longer treated as equivalent to verified product-owned tunnel readiness
  - structured no-Python blocker codes so V3 can distinguish multiple devices,
    missing device-info transport, unknown tunnel requirement, and legacy-only
    tunnel observation as separate readiness stages
  - assessment-driven no-Python session states so the main status title no
    longer has to collapse everything into generic `usbDetected` or
    `injectionUnavailable` phases
  - session-level diagnostic summaries so each state change carries explicit
    guidance about device visibility, tunnel observation, missing capability,
    and next action
  - assessment-driven connection health so `NO-PY` can distinguish partial
    progress from unstable states like multi-device conflicts or unverified
    tunnel-only observations
  - richer session diagnostics that log track, state, device/tunnel readiness,
    blocker codes, next action, and confidence rather than only raw probe facts
  - an explicit readiness-gate model so V3 can state which product-owned layer
    is currently preventing progress: attachment, selection, device-info,
    tunnel ownership, or injection transport
  - agent-side readiness gates so no-Python probes can return the currently
    blocked product layer directly, with the app process only needing to
    integrate device and tunnel assessments rather than infer every gate itself
  - bootstrap-stage availability assessment so backend bring-up is also
    represented as agent-owned gate/next-action/confidence, not only as app
    process availability text
  - gate-aware refresh orchestration so startup, manual refresh, backend
    switching, and timer-driven polling no longer all force the same refresh
    path during no-Python bootstrap
  - scope-aware no-Python session refresh so later gates can run narrower
    device-only or tunnel-only probes instead of always executing the full
    session probe cycle
  - focus-aware no-Python guidance so attachment, selection, and device-info
    probes each produce distinct next actions and session diagnostics instead of
    collapsing into one generic no-Python instruction path
  - agent-owned probe-focus recommendations so the no-Python backend can return
    the currently preferred attachment/selection/device-info focus directly,
    with the app model using agent guidance before falling back to local
    inference
  - agent-owned refresh intent so the no-Python backend can return both the
    preferred probe scope and the preferred attachment/selection/device-info
    focus, with the app model consuming that intent before falling back to
    gate-based refresh orchestration
  - user-visible refresh intent summaries so the status card and top-level
    environment capsule can show whether the next no-Python step is a full
    probe, a device probe, or a tunnel probe instead of leaving that behavior
    implicit in logs only
  - tunnel-probe-specific UI semantics so `tunnelOnly` no longer reuses generic
    device-side status/button wording and instead presents tunnel ownership and
    tunnel verification as first-class product states
  - intent-aware refresh affordances so the top refresh help text and manual
    refresh logs explain whether the next action is bootstrapping, device-side
    readiness, or tunnel ownership verification
  - clearer tunnel-stage boundaries so `tunnelOwnership` and `ready` no longer
    read like nearly identical "almost done" states and instead explain whether
    ownership is still being verified or a ready session boundary is already
    being held
  - tunnel-aware session guidance so the diagnostics tail line and app-level
    next-action text stop collapsing `tunnelOwnership` and `ready` into the
    same generic guidance and instead distinguish "verify ownership" from
    "hold the ready boundary"
  - agent-aligned tunnel diagnostics so tunnel readiness, intent, next action,
    and confidence now flow from tunnel assessment into the status card and
    session diagnostics instead of relying only on app-side fallback wording
  - injection-stage summaries and guidance so `injectionTransport` is now
    presented as its own product boundary, with agent bootstrap guidance reused
    directly instead of collapsing back into generic backend wording
  - a dedicated `device-info transport` service slot that now returns a typed
    probe result, so future metadata transport work has a callable backend
    contract instead of only a passive contract description
  - a stackable `device-info transport` service boundary, so the reserved
    typed-metadata slot and the current USB-bootstrap stub can coexist behind
    one agent-side contract while V3 is still in transition

What is not true yet:

- there is no separate bundled helper binary or XPC transport yet
- there is no working no-Python device transport yet
- teleport still only works through the legacy CLI-backed path
- tunnel management is still a legacy preview flow, not product-owned state

## Guiding Principles

V3 should follow these engineering constraints:

- preserve current user-visible behavior unless there is a deliberate product
  improvement
- do not let `ContentView` own transport or protocol details
- prefer typed state and typed failures over string scraping
- introduce boundaries before replacing implementations
- avoid a big-bang rewrite that leaves the app unusable for weeks
- keep the door open for a future privileged helper if iOS 17+ tunnel handling
  requires it

## Branch Strategy

Recommended branch usage:

- `main`: current working product
- `v3-no-python-foundation`: long-lived integration branch for the architecture
  split
- short-lived feature branches off V3 for discrete backend or refactor work if
  the scope grows

Recommended merge discipline:

- merge only architecture improvements that are stable and intentional
- keep backend experiments off `main` until a complete vertical slice works
- do not mix unrelated product/UI ideas into the V3 branch

## V3 Task Breakdown

### 1. Freeze and map the current behavior

Before replacing the stack, capture the exact user-visible behavior that must
survive the rewrite.

Tasks:

- document all current flows: launch, USB connect, version detect, search,
  coordinate edit, teleport, tunnel-required, success, and failure
- record current command assumptions and outputs for:
  - dependency scan
  - USB detection
  - iOS version lookup
  - tunnel running detection
  - simulate-location execution
- define the minimum supported matrix:
  - macOS version
  - iOS version bands
  - USB-only vs wireless
  - tunnel-required vs direct

Deliverable:

- baseline behavior notes and acceptance criteria for each flow
- sample logs or screenshots for each current major state where helpful

### 2. Split the monolithic view into replaceable layers

`ContentView.swift` currently owns almost every concern. That has to change
before a no-Python backend can be swapped in safely.

Tasks:

- extract UI-only concerns from backend concerns
- introduce an app state model for:
  - hardware presence
  - device identity/version
  - tunnel state
  - action readiness
  - last operation result
- move logging out of the view into a shared diagnostics/log service
- define protocols for backend actions, for example:
  - `DeviceMonitoring`
  - `DeviceSessionProviding`
  - `TunnelManaging`
  - `LocationInjecting`
  - `DiagnosticsProviding`

Deliverable:

- UI can render from interfaces rather than from shell-specific implementation
- `ContentView` stops launching `Process` directly

### 3. Introduce a local agent boundary

V3 should not replace Python by stuffing lower-level device code directly into
the SwiftUI view process. A local agent boundary is needed first.

Tasks:

- define a local `DeviceAgent` responsibility boundary
- choose the communication model between app and agent:
  - XPC
  - local socket
  - child process with structured stdin/stdout
- define structured requests and responses instead of text scraping
- define stable error codes instead of Python traceback matching
- define diagnostic event types for the log panel

Deliverable:

- app talks to a backend contract, not directly to shell commands
- existing CLI behavior can temporarily sit behind that contract as an adapter

### 4. Replace Python-dependent capabilities one by one

This is the actual no-Python migration. The replacement order matters.

Tasks:

- replace dependency scanning with backend availability checks
- replace iOS version lookup with agent-backed device info retrieval
- replace tunnel detection from `pgrep` with a tunnel session model
- replace simulate-location invocation with a backend command API
- replace stdout/stderr parsing with typed backend failures

Suggested migration order:

1. device discovery
2. device info / iOS version
3. tunnel state and lifecycle
4. location injection
5. diagnostics and recovery messaging

Deliverable:

- the app no longer depends on `detectedCliPath`, `which -a`, or shell output
- Python-specific UI copy is gone from core status and readiness paths

### 5. Design and implement the no-Python device backend

This is the core V3 engineering problem.

Tasks:

- choose the backend implementation strategy:
  - native implementation
  - native wrapper around a non-Python device library
  - staged agent that starts non-native now but is isolated for future swap
- define device backend responsibilities:
  - enumerate connected iPhones
  - fetch device properties
  - establish developer connection path
  - manage iOS 17+ tunnel lifecycle
  - send simulate-location set/clear commands
  - return typed diagnostics
- define timeout, retry, disconnect, and reconnect behavior
- define how multi-device selection will work if more than one iPhone is present

Deliverable:

- a backend module that owns device protocol concerns, not the UI

Open questions to resolve before implementation:

- what backend technology is realistically available for iOS developer service
  communication without Python
- whether a third-party native library is acceptable in the shipped product
- whether any part of the tunnel flow will require a helper with elevated
  privileges
- how much of the current one-device assumption should be preserved in V3

### 6. Rework the iOS 17+ tunnel model

This is the largest product risk in V3.

Tasks:

- stop treating tunnel state as "does a process named tunneld exist"
- define whether the product owns:
  - tunnel creation
  - tunnel reuse
  - tunnel health checks
  - tunnel teardown
- define whether tunnel work happens:
  - inside the app process
  - inside the local agent
  - inside a privileged helper
- replace Terminal + AppleScript launch flow with product-controlled behavior
- redesign the yellow tunnel banner around backend state, not copied commands

Deliverable:

- tunnel management becomes a first-class subsystem

Specific design requirements:

- the backend must distinguish `not needed`, `needed but down`, `starting`,
  `active`, and `failed`
- the UI must stop treating tunnel start as a copyable Terminal command
- tunnel errors must tell the user what action is possible next
- the app should be able to decide whether a new teleport action is safe to run
  without inferring from shell noise

### 7. Replace current user-facing status logic

Current statuses are tightly coupled to Python installation and shell failures.

Tasks:

- remove Python-specific status messages from `statusDisplay`
- redesign readiness logic around product-owned backend state
- replace "ENV: READY / MISSING" with backend-specific readiness
- update button gating to depend on:
  - device connected
  - supported device state
  - tunnel ready if required
  - valid coordinates
  - backend operation availability
- keep the single-message status card but switch its source to typed app state

Deliverable:

- user-facing state is product language, not toolchain language

Readiness model to target:

- no supported device
- device connected but not ready
- user action required
- backend working
- ready
- operation succeeded
- operation failed with recovery hint

Session gating model already in use on the V3 branch:

- `DeviceSessionState` tells the app which connection stage it is in
- `ConnectionHealth` tells the app whether that stage is offline, partial,
  degraded, or healthy
- `SessionBlocker` tells the app what is currently preventing readiness
- `nextAction` tells the app what concrete action or implementation gap comes
  next

This keeps status cards, button labels, and diagnostics aligned on one typed
source instead of duplicating near-identical string logic in multiple places.

### 8. Build diagnostics suitable for a product backend

Today diagnostics are mostly timestamped shell logs. V3 needs something more
structured.

Tasks:

- define log categories and event payloads
- separate internal diagnostics from user-facing messages
- add exportable diagnostics for support/debug use
- preserve enough raw backend detail for device protocol debugging
- avoid leaking implementation-specific stack traces into main UI copy

Deliverable:

- the log panel remains useful after shell text disappears

Suggested event categories:

- `app`
- `device`
- `transport`
- `tunnel`
- `location`
- `diagnostics`

### 9. Update packaging and runtime assumptions

Once Python is removed, deployment rules change.

Tasks:

- remove assumptions that a user-managed runtime exists on the machine
- decide whether V3 requires:
  - app-only bundle
  - embedded agent executable
  - helper registration
  - installer package
- prepare for code signing and notarization of every shipped binary
- define how internal backend binaries are versioned with the app

Deliverable:

- a shippable artifact model for the no-Python stack

Artifacts to plan for:

- app bundle contents
- optional agent binary
- optional helper binary
- signing identity requirements
- notarization path
- version coupling between UI app and backend component

### 10. Add a staged delivery plan

V3 should not land as a single destructive rewrite.

Tasks:

- create checkpoints where UI refactors can merge before backend replacement
- keep the app usable while backend abstraction is introduced
- define the cutover point where Python paths, scan UI, and Terminal launch are
  removed completely
- define fallback strategy if the no-Python backend is incomplete

Deliverable:

- an implementation sequence that avoids a long-lived broken branch

## Risks

The main risks are not UI risks.

Technical risks:

- no-Python backend parity may be harder than expected on newer iOS versions
- tunnel lifecycle may require privileges or helper architecture sooner than
  planned
- protocol compatibility may regress when iOS versions move
- current one-file app structure makes refactor mistakes more likely early on

Product risks:

- V3 can consume a lot of time before user-visible value appears if the work is
  not staged carefully
- users may expect "one click" tunnel behavior that is not feasible without
  privileged installation components

Mitigations:

- keep the adapter layer during refactor
- prove one vertical slice before removing the old path
- define supported matrix explicitly
- do not promise broader compatibility than the backend has actually earned

## Exit Criteria Per Phase

### Phase 1 exit

- `ContentView` no longer owns shell execution directly
- backend protocol exists
- current behavior still works through a legacy adapter

### Phase 2 exit

- app communicates with a backend boundary rather than raw shell functions
- state and diagnostics are routed through model/services

### Phase 3 exit

- primary teleport flow works without Python installed on the machine
- no Python-specific readiness UI remains

### Phase 4 exit

- clean-machine install is tested
- signing and packaging requirements are validated
- tunnel-required device flow is verified on target iOS versions

## Concrete Code Areas Affected

Primary current file:

- `GeoTeleportMac/ContentView.swift`

Responsibilities that must move out of the view:

- dependency scanning: `findDependency()`
- generic process execution: `runCaptured(...)`
- tunnel process detection: `checkTunneld()`
- USB polling: `checkUSBConnection()`
- device version lookup: `fetchDeviceIOSVersion()`
- Terminal launch and clipboard flow: `launchTunneldInTerminal(cmd:)`
- teleport execution: `teleport()` and `executeCommand(args:)`
- stderr/stdout interpretation: `humanize(...)`

Likely new modules to introduce:

- `AppModel`
- `DiagnosticsStore`
- `DeviceAgentClient`
- `DeviceBackendProtocol`
- `TunnelStateController`
- `LocationInjectionController`
- `DeviceMonitor`

## Recommended Execution Order

### Phase 0: Foundation

- create V3 branch
- document baseline
- define target architecture

### Phase 1: Refactor without behavior change

- split `ContentView`
- introduce app model and service protocols
- keep existing backend behavior behind an adapter

### Phase 2: Agent boundary

- create local backend client contract
- move shell-driven implementation behind the contract
- stop letting the view call `Process` directly

### Phase 3: No-Python backend

- implement backend capabilities incrementally
- migrate readiness, status, and diagnostics
- remove Python-specific UI and workflow

### Phase 4: Packaging hardening

- sign all shipped components
- verify clean-machine install path
- verify tunnel behavior on supported iOS versions

## Definition of Done for V3

V3 is done when all of the following are true:

- a clean Mac can run the app without installing Python or `pymobiledevice3`
- the SwiftUI app no longer contains Python path scanning logic
- the app no longer launches Terminal to bridge core product behavior
- tunnel handling is represented as product-owned state
- location injection is performed through a backend contract, not raw shell text
- failure handling uses structured backend results instead of Python traceback
  heuristics

## Immediate Next Step

Current next step after the completed foundation work:

- keep Phase 3 moving by replacing more of the no-Python stub with real session
  readiness signals
- keep the typed blocker/next-action model as the single source for user
  guidance and UI gating
- push agent observations upward into product-owned readiness state before
  attempting location injection replacement

## Immediate Work Queue

The next concrete engineering tasks should be:

1. add a typed metadata artifact/result model behind the reserved
   `device-info.transport.typed-metadata` slot so the stack can return more
   than slot identity and probe summaries
2. keep improving no-Python session readiness beyond raw USB presence by
   promoting agent-side device-info signals into typed metadata readiness
3. replace more legacy-derived tunnel assumptions with typed agent-side session
   state and eventually product-owned tunnel lifecycle
4. connect future no-Python injection work to the existing
   blocker/capability/gate model rather than adding a parallel flow
5. keep shrinking `ContentView` until it only renders and dispatches actions
6. only then remove the remaining legacy preview-specific fallback paths

## Latest Progress Notes

- reserved `device-info.transport.typed-metadata` slot now returns a real typed
  metadata artifact/result instead of only slot identity and probe summaries
- typed metadata is now promoted into a typed metadata session with distinct
  `seedOnly` and `resolvedIdentity` states
- no-Python USB/device-info enrichment now carries `iosVersion` into the typed
  metadata path, so tunnel requirement is no longer blocked on USB identity
  alone
- tunnel assessment is now split into typed requirement, lifecycle, session,
  and health results rather than a single legacy-derived tunnel summary
- no-Python tunnel requirement can now resolve to `required` vs `notRequired`
  from typed metadata instead of staying at `tunnelUnknown`
- product-owned tunnel state is now controller-backed rather than inferred only
  from scattered `pgrep` checks
- product-owned tunnel lifecycle now distinguishes:
  `requiredInactive`, `starting`, `active`, and `failed`
- tunnel failure is now represented by a dedicated `tunnelFailed` blocker/code
  instead of sharing the generic `tunnelRequired` path
- the no-Python path no longer depends on the legacy Terminal tunnel banner as
  its primary tunnel UX; tunnel ownership is surfaced through session state and
  status-card summaries
- the product-owned tunnel controller now launches a backend-managed
  `pymobiledevice3 remote tunneld` attempt, persists pid/log metadata across
  short-lived child-process agent invocations, and retries failed startups on a
  cooldown
- tunnel health is now a typed result with:
  `pending`, `verified`, and `failed`
- tunnel health no longer relies only on startup log summaries; it now carries
  typed `protocolHint` and `endpointSummary`
- product-owned tunnel health verification currently layers:
  - listener discovery from `lsof`
  - backend TCP connect probes to discovered tunnel listeners
  - startup-log readiness markers as fallback evidence
  - a shallow session-handshake probe that waits for initial readable payload
    after connect
- tunnel health verification now prefers the expected RSD endpoint advertised by
  the tunnel startup logs before generic listener checks, so `verified` means
  the backend connected to the product-relevant tunnel endpoint rather than only
  proving that some TCP listener exists
- expected-RSD probing is now represented as a distinct internal probe result:
  missing advertisement, advertised-but-unverified endpoint, or verified
  endpoint; timeout/failure diagnostics now report that exact stage instead of
  a generic "ready marker" failure
- tunnel protocol hints now distinguish:
  `listenerOnly`, `tcpConnectVerified`, `sessionHandshakeVerified`, and
  `rsdMarkerObserved`, plus expected-RSD connect/handshake verification
- app state, diagnostics, and status-card summaries now surface typed tunnel
  health and protocol hints directly instead of inferring them from freeform
  summary text
- split no-Python blocker ownership by layer instead of letting a single device
  assessment carry every missing transport
- `DeviceAgentAvailability` now carries explicit `blockerCodes`, including
  `injectionTransportMissing`
- device assessment now stays focused on device-side issues such as
  `deviceInfoMissing` and multi-device selection
- tunnel assessment remains focused on tunnel ownership / verification issues
- app-side session blocker and health derivation now consume availability,
  device, and tunnel blocker codes together
- session diagnostics now print bootstrap blocker codes separately from device
  and tunnel blocker codes
- `injectionTransportMissing` is now distinct from the legacy-style
  `injectionMissing` path, so product-owned injection wiring and “feature not
  implemented” are no longer represented by the same no-Python blocker
- device assessment now carries a typed `deviceInfoReadiness` stage so the
  no-Python path can distinguish “USB visibility only” from “USB identity
  observed but typed metadata still missing”
- device assessment now also carries a typed `deviceInfoTransportContract`
  placeholder so future metadata transport work has an explicit contract slot
  instead of being inferred only from UI summaries
- `device-info transport` now returns a typed
  `DeviceAgentDeviceInfoTransportProbeResult` with transport state, contract,
  summary, next action, and confidence instead of only exposing a passive
  contract description
- the no-Python status card, backend diagnostics, and session diagnostics now
  surface that typed device-info probe result directly
- the agent-side `device-info transport` boundary is now stackable through
  `DeviceInfoTransportServiceStack`, so multiple transport implementations can
  coexist behind one contract
- the stack currently contains a reserved typed-metadata slot
  (`device-info.transport.typed-metadata.reserved`) plus the current USB
  bootstrap stub (`device-info.transport.usb-bootstrap.stub`)
- the active device-info slot is now visible in app state and diagnostics, so
  future work can confirm which transport implementation is active without
  code inspection
- the default no-Python agent now depends on the stack instead of a single
  hardcoded device-info service, which means future typed metadata work can be
  added by replacing or extending one service slot rather than reopening the
  full device assessment pipeline

## Resume Checkpoint

If work resumes in a new session, start from this checkpoint:

- branch: `v3-no-python-foundation`
- current build artifact:
  `build/DerivedData/Build/Products/Debug/GeoTeleportMacV3.app`
- current V3 state:
  - child-process no-Python agent boundary is working
  - readiness/blocker/gate/intent/session diagnostics are in place
  - USB probe, typed metadata promotion, and tunnel ownership scaffolding are
    in place
  - device-info transport already has:
    - typed probe result
    - stackable service boundary
    - reserved typed-metadata slot
    - USB bootstrap stub fallback
    - typed metadata artifact/result/session
    - iOS version enrichment threaded into metadata readiness
  - tunnel ownership already has:
    - typed requirement result
    - typed lifecycle/session/health results
    - product-owned tunnel startup controller with persisted attempt state
    - tunnel failure modeled as a dedicated blocker
    - expected-RSD endpoint verification layered ahead of generic
      listener/TCP/session-handshake health probes
- most important next engineering move:
  - harden the expected-RSD endpoint parser/probe against real
    `pymobiledevice3 remote tunneld` output from supported iOS versions, then
    use the verified endpoint as the input for the future no-Python injection
    transport instead of re-discovering tunnel state in a parallel path
