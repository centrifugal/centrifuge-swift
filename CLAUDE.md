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

Use this rather than bare `swift test`: without Xcode installed, SwiftPM needs
several flags wired up by hand and the script does that. It prints which mode it
picked. The whole suite runs in either mode.

`GetStateTests` is the only suite needing anything external — the docker-compose
Centrifugo:

```sh
docker compose up -d
```

Everything else runs against `FakeCentrifugoServer`, an in-process fake speaking
the protobuf protocol over Network.framework.

### Why the script exists

`XCTest.framework` ships **only inside Xcode.app**. With just the Command Line
Tools (`xcode-select -p` → `/Library/Developer/CommandLineTools`) it does not
exist anywhere on disk and cannot be installed separately, which is why this
suite uses **swift-testing** — that one does ship with the CLT. It just is not on
the default search path, so `swift test` needs:

- `--disable-xctest` — stop SwiftPM building an XCTest runner.
- `-Xswiftc -F <CLT>/Library/Developer/Frameworks` plus the matching `-Xlinker -F`
  and `-Xlinker -rpath`.
- `-Xswiftc -target $(uname -m)-apple-macos14.0` — `Testing.framework` is built
  for macOS 14, and `Package.swift` deliberately declares no `platforms:` (adding
  one would raise the deployment target for every consumer of the library). Keep
  it a build-time override.
- `-Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays` — the CLT ships
  `_Testing_Foundation.framework` **without** its `.swiftmodule`, so
  `import Testing` alongside `import Foundation` fails to resolve the cross-import
  overlay. Disabling overlays sidesteps a packaging gap, not a code problem.

**Do not conclude the toolchain is broken if bare `swift test` fails with
`no such module 'XCTest'` or `no such module 'Testing'`.** Both are expected
without Xcode; run the script.

### Writing tests

swift-testing only — `import Testing`, `@Test`, `#expect`, `#require`,
`Issue.record`. Do not reintroduce XCTest; it would make the suite unrunnable
without Xcode again. Three things to know:

- **Tests that wait are `async`, and waiting must never block.** swift-testing
  runs even synchronous `@Test` bodies inside a Task on the cooperative thread
  pool, whose width is the core count — so blocking there (`NSCondition`,
  `DispatchSemaphore`, `Thread.sleep`) starves the pool. Use
  `await fulfillment(of:within:)` from `TestSupport.swift`, which suspends on a
  continuation. Never call `Thread.sleep` in a test; `Task.sleep` is fine. This
  is what lets the suite run in parallel at all — an earlier blocking version
  passed locally on ten cores and wedged the CI runner.
- **`Expectation` replaces `XCTestExpectation`.** swift-testing has no
  equivalent: `confirmation(...)` counts callbacks in a scope but does not wait
  for them, and `.timeLimit()` is whole-minutes only. Upstream
  swiftlang/swift-testing#789 (a `confirmation` timeout) is unmerged and issue
  #978 was closed as not planned, so re-check before assuming a built-in exists.
  `Expectation` supports `expectedFulfillmentCount` and `isInverted`;
  over-fulfilment is deliberately not an error.
- **Suites carry `.timeLimit(.minutes(1))`** as a backstop, so a wait that never
  returns for some other reason fails instead of wedging CI. One minute is the
  finest granularity the trait allows.
- **`@Suite(.serialized)` is about resource pressure, not shared state.**
  swift-testing builds a fresh suite instance per test (`deinit` runs before the
  next `init`), so each test already gets its own `FakeCentrifugoServer` on its
  own ephemeral port and its own client — the tests are independent. The trait
  simply bounds how many live WebSocket clients exist at once, which costs
  nothing (the suite runs in ~1.3s either way) in the exact area that broke CI
  twice. Drop it if you ever need the parallelism; nothing depends on ordering.
- **Tests build with `-target …macos14.0`** (set by `scripts/test.sh`). Swift
  concurrency needs 10.15+ and the package's default deployment target is 10.13;
  `@available` cannot go on a `@Test`, so the target is raised for the test build
  only. `Package.swift` stays free of `platforms:`, and CI's separate
  `swift build` still type-checks the library at 10.13.
- **`@available` cannot be used on `@Test` or `@Suite`** — the macros reject it
  outright, whatever version you name. Where the code under test needs a newer OS
  (`NativeWebSocket` is macOS 10.15+), annotate the private helpers and put a
  `guard #available(...) else { return }` at the top of each test.
  `NativeWebSocketTLSChallengeTests` is the worked example.

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
