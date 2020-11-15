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