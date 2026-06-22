# Herdr iOS — agent guide

Native iOS (SwiftUI) client for [Herdr](https://herdr.dev), a terminal-native agent
multiplexer. The app today runs fully on an in-memory **Mock** transport; the SSH
transport is scaffolded but not wired (see below).

## Layout

Two layers, cleanly separated so the whole UI runs on the Mock and SSH is a drop-in swap.

- **`Sources/HerdrKit/`** — platform-independent core. Foundation + Swift Concurrency
  only, no SwiftUI, no third-party deps. Builds and unit-tests with `swift test` on
  macOS or Linux. Subdirs: `Models/`, `Protocol/` (NDJSON JSON-RPC codec; all wire
  method strings live in `Method.swift`), `Transport/`, `Client/` (actor that
  correlates replies and demuxes events), `Mock/`.
- **`App/Herdr/`** — the SwiftUI app target. State via `@Observable`; a single
  `SessionModel` is the source of truth, injected through the environment.
  `AppModel` boots on `MockTransport` — swapping to `SSHTransport` is a one-line change.
- **`Tests/HerdrKitTests/`** — unit tests for the core (codec + client).

## Build & test

```sh
swift build                 # build HerdrKit core
swift test                  # core unit tests — no Apple SDK needed

xcodegen generate           # regenerate Herdr.xcodeproj from project.yml (REQUIRED before building the app)
xcodebuild -project Herdr.xcodeproj -scheme Herdr \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build
```

Requires Xcode 15+ / iOS 17 deployment target. `xcodegen` is at `/opt/homebrew/bin/xcodegen`.

## Conventions & gotchas

- **`project.yml` is the source of truth**, not `Herdr.xcodeproj`. Edit `project.yml`
  then re-run `xcodegen generate`. The `.xcodeproj` is generated — don't hand-edit it,
  and treat it as disposable.
- **App target is a single module.** Don't mark app-target types/members `public` —
  it's unnecessary and a `public` member exposing an `internal` type (e.g. `Host`,
  `Credential`) is a compile error. `public` belongs in `HerdrKit` (a real library),
  not in `App/Herdr`.
- **`HerdrKit` has zero external dependencies** — keep it that way so it stays
  Linux-testable. Apple-SDK and third-party code (Citadel) belong in the app target.
- The ID types (`PaneID`, etc.) conform to `ExpressibleByStringLiteral`, so
  `.map(SomeID.init)` is ambiguous — use `.map { SomeID($0) }`.

## SSH transport

`App/Herdr/Connection/SSHTransport.swift` is implemented with **Citadel** (SwiftNIO
SSH). Herdr has no network API — its socket is a local Unix domain socket
(`~/.config/herdr/herdr.sock`), so the client SSHes in and bridges a `withExec`
channel running `socat - UNIX-CONNECT:<path> || nc -U <path>`, writing
`NDJSON.frame(request)` to stdin and feeding stdout through `LineBuffer` →
`IncomingMessage.decode`. Auth uses `SSHClient.connect` (password or RSA key).

The socket path is **auto-detected** unless `Host.socketPath` is a non-blank
override: a one-shot `executeCommand` probe mirrors Herdr's documented resolution
order (`$HERDR_SOCKET_PATH` → `~/.config/herdr/herdr.sock` → named sessions under
`~/.config/herdr/sessions/*/`) and picks the first live socket. So `Host.socketPath`
defaults to `""` (auto) — don't reintroduce a hardcoded default.

Package deps live in `project.yml`: `Citadel`, plus `NIOCore` (for `ByteBuffer`)
and `Crypto` (for the `Insecure` namespace Citadel extends) — both are Citadel
transitive deps that `SSHTransport` imports directly, so they're linked
explicitly. Re-run `xcodegen generate` after touching `project.yml`.

Known limitations (intentional, tracked in README): key auth is OpenSSH ed25519
or RSA (ECDSA not wired). Host keys are pinned **trust-on-first-use** — a custom
`NIOSSHClientServerAuthenticationDelegate` records the key on first connect and
rejects a mismatch later; the pinned key lives on `Host.knownHostKey`
(`ConnectionStore.pinHostKey`). This is why `NIOSSH` is linked explicitly in
`project.yml` — same fork/range Citadel pins, since it has no NIOSSH re-export.
Verify method strings against <https://herdr.dev/docs/socket-api/>.
