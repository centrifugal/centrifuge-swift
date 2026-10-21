0.11.0
=====

This release fixes many connection lifecycle, token and delivery issues found during SDK validation, aligning behaviour with centrifuge-js. There are no public API signature changes, but some behaviour changes are worth checking – see the list below.

**Behaviour changes**

* `removeSubscription(sub)` now removes only the given subscription (it used to remove and unsubscribe every subscription of the channel), and does nothing for one already removed. Calling `subscribe()` on a removed subscription reports a `configurationError` through `onError` and does nothing [#145](https://github.com/centrifugal/centrifuge-swift/pull/145)
* Publications, joins and leaves are delivered to a client-side subscription only while it is subscribed; otherwise they go to a server-side subscription of the same channel, if any [#145](https://github.com/centrifugal/centrifuge-swift/pull/145)
* Without a token getter, a static connection or subscription token is kept on state invalidation, and a token expired error ends the connection or subscription as unauthorized with a `configurationError` instead of retrying forever [#145](https://github.com/centrifugal/centrifuge-swift/pull/145)
* Calls made while the client is connecting (publish, rpc, history, ...) now keep waiting across a reconnect (within their timeout) instead of failing with `clientDisconnected` [#145](https://github.com/centrifugal/centrifuge-swift/pull/145)
* A delta publication that can't be applied, or a malformed fossil delta, now disconnects with "bad protocol" (code 2) instead of crashing the app [#145](https://github.com/centrifugal/centrifuge-swift/pull/145), [#146](https://github.com/centrifugal/centrifuge-swift/pull/146)
* Subscription token refresh failures are now reported through `onError` with `subscriptionRefreshError` [#144](https://github.com/centrifugal/centrifuge-swift/pull/144)

**Fixes**

* Connection token is requested before the transport is opened, so a slow token getter no longer causes the server to close an idle connection [#146](https://github.com/centrifugal/centrifuge-swift/pull/146)
* A new transport is created for every connection attempt and closed on teardown; the WebSocket handshake is limited by `timeout`. Fixes the client staying in connecting state forever on dead or half-open links [#145](https://github.com/centrifugal/centrifuge-swift/pull/145)
* Connection and subscription tokens, replies and refreshes are tied to the attempt they were requested for – fixes using a previous user's token after `disconnect()` + `connect()`, and duplicate refresh chains [#145](https://github.com/centrifugal/centrifuge-swift/pull/145)
* Native transport accepts messages larger than 1 MiB [#145](https://github.com/centrifugal/centrifuge-swift/pull/145)
* Starscream transport receives large messages in linear time [#145](https://github.com/centrifugal/centrifuge-swift/pull/145)
* Replies and pings that arrived while the app was frozen in background now win over late timeouts [#145](https://github.com/centrifugal/centrifuge-swift/pull/145)
* Connection token refresh is retried with backoff when the token getter fails, and its completion no longer runs off the client queue [#142](https://github.com/centrifugal/centrifuge-swift/pull/142)
* Pending reply callbacks are resolved exactly once when a disconnect re-enters itself [#143](https://github.com/centrifugal/centrifuge-swift/pull/143)
* Fix deadlocks when calling `setTagsFilter` or `getSubscription` from delegate callbacks; the threading contract is now documented on `CentrifugeClientDelegate` [#140](https://github.com/centrifugal/centrifuge-swift/pull/140)

**Misc**

* Test suite migrated to swift-testing and runnable without Xcode via `make test` [#140](https://github.com/centrifugal/centrifuge-swift/pull/140), [#141](https://github.com/centrifugal/centrifuge-swift/pull/141)

0.7.1
=====

* Document `URLSessionWebSocketTask` in readme
* Fix: add `@unknown default` to `URLSessionTask.State` ext switch

0.7.0
=====

* Add alternative websocket implementation via URLSessionWebSocketTask (should be explicitly enabled)
* Prevent memory leaks when passing token getters

0.6.1
=====

* Make `info` field of `CentrifugePublicationEvent` and `CentrifugeServerPublicationEvent` public.

0.6.0
=====

**Breaking change!** This release changes the semantics of working with connection tokens described in [Centrifugo v5 release post](https://centrifugal.dev/blog/2023/06/29/centrifugo-v5-released#token-behaviour-adjustments-in-sdks).

Previously, returning an empty token string from `CentrifugeConnectionTokenGetter` callback resulted in client disconnection with unauthorized reason.

Now returning an empty string from `CentrifugeConnectionTokenGetter` is a valid scenario which won't result into disconnect on the client side. It's still possible to disconnect client by returning a special `CentrifugeError.unauthorized` from `CentrifugeConnectionTokenGetter`.

And we are putting back `SetToken` method to the SDK – so it's now possible to reset the token to be empty upon user logout.

0.5.5
=====

* Improve logger API: replace String with StaticString [#74](https://github.com/centrifugal/centrifuge-swift/pull/74)

0.5.4
=====

* Add centrifuge logger interface [#73](https://github.com/centrifugal/centrifuge-swift/pull/73)
* Example app: replace CocoaPods with SPM [#72](https://github.com/centrifugal/centrifuge-swift/pull/72)

0.5.3
=====

* Fix: unset refreshRequired flag after getting connection token [commit](https://github.com/centrifugal/centrifuge-swift/commit/c41cea5f5b2b29051937a630a5677f86dd92a377)

0.5.2
=====

* Fix connect when initial connection token not set but provided `tokenGetter` [#71](https://github.com/centrifugal/centrifuge-swift/pull/71)

0.5.1
=====

* Fix crashes caused by non-synchronized memory access upon getting `no ping` disconnect
* Fix issuing duplicate state change events

0.5.0
=====

**Breaking changes**

This release adopts a new iteration of Centrifugal protocol and a new iteration of API. Client now behaves according to the client [SDK API specification](https://centrifugal.dev/docs/transports/client_api). The work has been done according to [Centrifugo v4 roadmap](https://github.com/centrifugal/centrifugo/issues/500).

Check out [Centrifugo v4 release post](https://centrifugal.dev/blog/2022/07/19/centrifugo-v4-released) that covers the reasoning behind changes here.

New release only works with Centrifugo >= v4.0.0 and [Centrifuge](https://github.com/centrifugal/centrifuge) >= 0.25.0. See [Centrifugo v4 migration guide](https://centrifugal.dev/docs/getting-started/migration_v4) for details about the changes in the ecosystem.

Note, that Centrifugo v4 supports clients working over the previous protocol iteration, so you can update Centrifugo to v4 without any changes on the client side (but you need to turn on `use_client_protocol_v1_by_default` option in the configuration of Centrifugo, see Centrifugo v4 migration guide for details).

Several important changes:

* new API according to the new [SDK API specification](https://centrifugal.dev/docs/transports/client_api)
* all core features of Centrifugal client protocol are now supported  
* delegateQueue to which Client submitted events is removed, it's now up to developer to utilize queues for processing callbacks 
* SDK now uses Swift 5.0

0.4.5
=====

* Fix crash accessing serverSubs from non-syncQueue [#65](https://github.com/centrifugal/centrifuge-swift/pull/65)

0.4.4
=====

* Fix possible crash in handleAsyncData method – [#62](https://github.com/centrifugal/centrifuge-swift/pull/62)

0.4.3
=====

* Remove Starscream code that automatically set Origin header

0.4.2
=====

* Embed Starscream 3 – see [discussion](https://github.com/centrifugal/centrifuge-swift/issues/48#issuecomment-965501423) and pr [#53](https://github.com/centrifugal/centrifuge-swift/pull/53).
* Support CentrifugeClientInfo in history publications.

0.4.1
=====

* Use Client's sync queue for Subscription operations (previously each Subscription had its own sync queue). Fixes [#24](https://github.com/centrifugal/centrifuge-swift/issues/24)
* Fix `already subscribed` errors (code 105) on resubscribe after Subscription removing. Fixes [#49](https://github.com/centrifugal/centrifuge-swift/issues/49)

0.4.0
=====

Update to work with Centrifuge >= v0.18.0 and Centrifugo v3.

**Breaking change** in server behavior. Client History API behavior changed in Centrifuge >= v0.18.0 and Centrifugo >= v3.0.0. When using history call it won't return all publications in a stream by default. See Centrifuge [v0.18.0 release notes](https://github.com/centrifugal/centrifuge/releases/tag/v0.18.0) or [Centrifugo v3 migration guide](https://centrifugal.dev/docs/getting-started/migration_v3) for more information and workaround on server-side.

* Protocol definitions updated to the latest version 
* History method now accepts optional `limit`, `since` and `reverse` arguments and returns `CentrifugeHistoryResult`
* presence now returns `CentrifugePresenceResult`
* presenceStats now returns `CentrifugePresenceStatsResult`
* Publish now returns `CentrifugePublishResult`
* When working with Centrifugo v3 or Centrifuge >= v0.18.0 it's now possible to avoid using `?format=protobuf` in connection URL. Client will negotiate Protobuf protocol with a server using WebSocket subprotocol mechanism (in request headers).

0.3.1
=====

* Fix internal error handling in subscription reply – now properly reconnect upon internal error received.

0.3.0
=====

* Message recovery support for client-side subscriptions. See [#39](https://github.com/centrifugal/centrifuge-swift/pull/39). Thanks to Anton Selyanin.

0.2.2
=====

* Add initial WebSocket reconnection delay (mitigating issues with Starscream connect timeout). Thanks to Anton Selyanin.

0.2.1
=====

* Fix refresh token task retain cycle [#38](https://github.com/centrifugal/centrifuge-swift/pull/38)

0.2.0
=====

A couple of new methods added to Client.

* `Client.getSubscription(channel: String) -> CentrifugeSubscription?` to get Subscription from internal client registry
* `Client.removeSubscription(_ sub: CentrifugeSubscription)` to tell Client that Subscription should be removed from internal registry. Subscription will be automatically unsubscribed before removing.

See more details in pull request [#36](https://github.com/centrifugal/centrifuge-swift/pull/36). In short, subscription removing can be helpful if you work with lots of short-living subscriptions to different channels to prevent unlimited internal Subscription registry growth.

0.1.0
=====

* Update client.proto file. Update sendRPC method - [#33](https://github.com/centrifugal/centrifuge-swift/pull/33), thanks [@hitman1711](https://github.com/hitman1711)

0.0.6
=====

* Public fields for `CentrifugePublication`, `CentrifugeClientInfo`, `CentrifugePresenceStats`

0.0.5
=====

* reduce access for private functions (#20)
* rewrite code to escape await logic (#23)
* Feature/subscription weak reference (#25)

0.0.4
=====

* Mark `refresh` and `private sub` completion blocks as escaping
* Fix Starscream dependency to compatible version

0.0.3
=====

* fix client deinit (#10)
* fix unlock issue (#11)
* add SPM product (library) and update dependencies (#15)

0.0.2
=====

* refactor library layout
* fix extensions and subscription channel property access levels.
* Travis CI setup

0.0.1
=====

Initial library release.
