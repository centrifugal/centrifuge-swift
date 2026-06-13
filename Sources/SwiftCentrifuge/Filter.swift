import Foundation

/// A node in a publication tags-filter expression tree, used for server-side
/// publication filtering. Build instances with the ``CentrifugeFilter`` helpers
/// and pass the result via ``CentrifugeSubscriptionConfig/tagsFilter`` or
/// ``CentrifugeSubscription/setTagsFilter(_:)``.
///
/// A filter is either a leaf node (a comparison such as `ticker == "AAPL"`) or a
/// logical node combining child nodes with and/or/not. The server evaluates the
/// filter against each publication's tags and delivers only matching
/// publications. See https://centrifugal.dev/docs/server/publication_filtering.
///
/// Publication filtering must be enabled for the namespace on the server
/// (`allow_tags_filter`) and cannot be combined with delta compression.
public struct CentrifugeFilterNode {
    let node: Centrifugal_Centrifuge_Protocol_FilterNode

    init(_ node: Centrifugal_Centrifuge_Protocol_FilterNode) {
        self.node = node
    }
}

/// Builders for ``CentrifugeFilterNode`` expressions. Comparison helpers create
/// leaf nodes; ``and(_:)``, ``or(_:)`` and ``not(_:)`` combine them.
///
/// ```swift
/// // (ticker == "AAPL") AND (price >= "100") AND (source in ["NASDAQ", "NYSE"])
/// let filter = CentrifugeFilter.and([
///     CentrifugeFilter.eq("ticker", "AAPL"),
///     CentrifugeFilter.gte("price", "100"),
///     CentrifugeFilter.inList("source", ["NASDAQ", "NYSE"]),
/// ])
/// ```
public enum CentrifugeFilter {
    private static func leaf(_ key: String, _ cmp: String, val: String? = nil, vals: [String]? = nil) -> CentrifugeFilterNode {
        var node = Centrifugal_Centrifuge_Protocol_FilterNode()
        node.key = key
        node.cmp = cmp
        if let val { node.val = val }
        if let vals { node.vals = vals }
        return CentrifugeFilterNode(node)
    }

    private static func logical(_ op: String, _ nodes: [CentrifugeFilterNode]) -> CentrifugeFilterNode {
        var node = Centrifugal_Centrifuge_Protocol_FilterNode()
        node.op = op
        node.nodes = nodes.map { $0.node }
        return CentrifugeFilterNode(node)
    }

    /// Tag `key` equals `val`.
    public static func eq(_ key: String, _ val: String) -> CentrifugeFilterNode { leaf(key, "eq", val: val) }

    /// Tag `key` does not equal `val`.
    public static func neq(_ key: String, _ val: String) -> CentrifugeFilterNode { leaf(key, "neq", val: val) }

    /// Tag `key` is one of `vals`.
    public static func inList(_ key: String, _ vals: [String]) -> CentrifugeFilterNode { leaf(key, "in", vals: vals) }

    /// Tag `key` is not one of `vals`.
    public static func notInList(_ key: String, _ vals: [String]) -> CentrifugeFilterNode { leaf(key, "nin", vals: vals) }

    /// Tag `key` exists.
    public static func exists(_ key: String) -> CentrifugeFilterNode { leaf(key, "ex") }

    /// Tag `key` does not exist.
    public static func notExists(_ key: String) -> CentrifugeFilterNode { leaf(key, "nex") }

    /// String tag `key` starts with `val`.
    public static func startsWith(_ key: String, _ val: String) -> CentrifugeFilterNode { leaf(key, "sw", val: val) }

    /// String tag `key` ends with `val`.
    public static func endsWith(_ key: String, _ val: String) -> CentrifugeFilterNode { leaf(key, "ew", val: val) }

    /// String tag `key` contains `val`.
    public static func contains(_ key: String, _ val: String) -> CentrifugeFilterNode { leaf(key, "ct", val: val) }

    /// Numeric tag `key` is greater than `val`.
    public static func gt(_ key: String, _ val: String) -> CentrifugeFilterNode { leaf(key, "gt", val: val) }

    /// Numeric tag `key` is greater than or equal to `val`.
    public static func gte(_ key: String, _ val: String) -> CentrifugeFilterNode { leaf(key, "gte", val: val) }

    /// Numeric tag `key` is less than `val`.
    public static func lt(_ key: String, _ val: String) -> CentrifugeFilterNode { leaf(key, "lt", val: val) }

    /// Numeric tag `key` is less than or equal to `val`.
    public static func lte(_ key: String, _ val: String) -> CentrifugeFilterNode { leaf(key, "lte", val: val) }

    /// All `nodes` must match.
    public static func and(_ nodes: [CentrifugeFilterNode]) -> CentrifugeFilterNode { logical("and", nodes) }

    /// At least one of `nodes` must match.
    public static func or(_ nodes: [CentrifugeFilterNode]) -> CentrifugeFilterNode { logical("or", nodes) }

    /// Inverts `node`.
    public static func not(_ node: CentrifugeFilterNode) -> CentrifugeFilterNode { logical("not", [node]) }
}
