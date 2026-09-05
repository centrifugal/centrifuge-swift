# centrifuge-swift

Swift SDK for Centrifugo / Centrifuge. `Sources/SwiftCentrifuge` is the library;
`Tests/SwiftCentrifugeTests` drives it against an in-process fake server
(`FakeCentrifugoServer`, Network.framework) — no running Centrifugo is needed for
most tests.

## Running tests locally

```sh
make test          # or: ./scripts/test.sh
./scripts/test.sh --filter Reentrancy   # extra args go to `swift test`
```

Use this rather than bare `swift test`. The script picks a mode automatically and
prints which one it used.

**Do not conclude the toolchain is broken if `swift test` fails with
`no such module 'XCTest'`.** That is expected without Xcode, and the reason the
script exists.

### Why

`XCTest.framework` ships **only inside Xcode.app**. With just the Command Line
Tools (`xcode-select -p` → `/Library/Developer/CommandLineTools`) it does not
exist anywhere on disk and cannot be installed separately. `Testing.framework`
(swift-testing) *does* ship with the CLT, so:

| Environment | What runs |
|---|---|
| Xcode installed | Everything — XCTest + swift-testing (`xcrun swift test`) |
| Command Line Tools only | swift-testing suites only; XCTest files compile out |

The XCTest files are each wrapped in `#if canImport(XCTest)`, so the target still
builds when the framework is missing. `./scripts/test.sh` prints a banner saying
how many files were skipped.

**A green local run is not a green suite** while any XCTest files remain. Push and
let CI (macos runner, full Xcode) confirm.

### Writing new tests

Prefer **swift-testing** (`import Testing`, `@Test`, `#expect`, `#require`) so the
test runs locally as well as in CI. `ReentrancyTests.swift` is the reference.
Two things to know:

- swift-testing parallelises by default. These tests bind ports and share
  process-wide state, so annotate suites `@Suite(.serialized)`.
- There is no `XCTestExpectation`. `ReentrancyTests.Signal` is a ~15-line
  `DispatchSemaphore` wrapper that preserves the existing synchronous
  "set up callback → trigger → wait" style. Always give waits a timeout, so a
  deadlock fails the test instead of hanging the run.

Migration of the remaining XCTest suites to swift-testing is tracked separately;
once it lands, the `#if canImport(XCTest)` guards and this section's caveats go
away.

### The flags, if the script ever needs fixing

Without Xcode, `swift test` needs help finding swift-testing:

- `--disable-xctest` — stop SwiftPM building an XCTest runner.
- `-Xswiftc -F <CLT>/Library/Developer/Frameworks` plus the matching `-Xlinker -F`
  and `-Xlinker -rpath` — that directory is not on the default search path.
- `-Xswiftc -target $(uname -m)-apple-macos14.0` — `Testing.framework` is built
  for macOS 14, and `Package.swift` deliberately declares no `platforms:` (adding
  one would raise the deployment target for every consumer of the library). Keep
  it a build-time override.
- `-Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays` — the CLT ships
  `_Testing_Foundation.framework` **without** its `.swiftmodule`, so
  `import Testing` alongside `import Foundation` fails to resolve the cross-import
  overlay. Disabling overlays sidesteps a packaging gap, not a code problem.

## Concurrency invariants

Breaking either of these deadlocks the whole client, so check them when touching
`Client.swift` / `Subscription.swift`.

Delegate callbacks are invoked **inline on the client's serial `syncQueue`**, and
that is deliberate: on the native transport the SDK keeps one read outstanding and
issues the next only after the handler returns, so a slow handler applies
backpressure through the socket to the server. Do **not** "fix" reentrancy by
dispatching callbacks to their own queue — that trades backpressure for an
unbounded backlog. It follows that user code can re-enter any public API, so:

1. **Never `syncQueue.sync`.** A callback already runs on that queue, so a
   synchronous hop from one is a self-deadlock. Public mutators enqueue with
   `async`. `ReentrancyTests.libraryNeverUsesSyncQueueSync` enforces this.
2. **Never call out while holding `subscriptionsLock`.** It is a non-recursive
   `NSLock`, and `getSubscription`/`newSubscription`/`removeSubscription` all take
   it — so a delegate callback made under it deadlocks when the handler touches
   the registry. Iterate over `snapshotSubscriptions()`, or `unlock()` before the
   callout (see `handlePub`/`handleJoin`/`handleLeave`/`handleUnsubscribe`).

The threading contract for users is documented on `CentrifugeClientDelegate` in
`Sources/SwiftCentrifuge/Delegate.swift`; keep the two in sync.

## Release

`CHANGELOG.md` is updated only at release time ("prepare X.Y.Z" commits), not per
PR. Do not add entries for ordinary changes.
