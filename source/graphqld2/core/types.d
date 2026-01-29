module graphqld2.core.types;

import std.algorithm;
import std.array;
import std.conv;
import std.string : indexOf;

// ============================================================================
// Source Context Registry Mixin
// ============================================================================

/// Mixin that provides a registry for source-specific contexts.
/// Used by OptimizeContext and EvalContext to allow data sources
/// to register their own context types (e.g., RelationalOptimizeContext).
mixin template SourceContextRegistry() {
    private struct SourceKey {
        TypeInfo type;
        string sourceId;
    }

    private Object[SourceKey] _sourceContexts;

    /// Get or create a source-specific context.
    /// Each data source type has its own context.
    T getSourceContext(T)(string sourceId = "default") {
        auto key = SourceKey(typeid(T), sourceId);
        if (auto ctx = key in _sourceContexts) {
            return cast(T) *ctx;
        }
        auto ctx = new T();
        _sourceContexts[key] = ctx;
        return ctx;
    }

    /// Get all source contexts (for iteration)
    Object[SourceKey] allSourceContexts() {
        return _sourceContexts;
    }
}

// ============================================================================
// Core Reference Type
// ============================================================================

/// A reference to any entity via opaque node ID.
/// Format: "TypeName:localId" (e.g., "User:123", "Order:a1b2-c3d4")
///
/// Following the GraphQL Relay specification, all entity references use
/// opaque string node IDs. This simplifies the type system while aligning
/// with GraphQL conventions.
struct Ref {
    string nodeId;

    /// Extract the entity type name
    string typeName() const {
        auto sep = nodeId.indexOf(':');
        return sep >= 0 ? nodeId[0 .. sep] : nodeId;
    }

    /// Extract the local ID portion (after the colon)
    string localId() const {
        auto sep = nodeId.indexOf(':');
        return sep >= 0 ? nodeId[sep + 1 .. $] : "";
    }

    /// Check if this ref is for a specific entity type
    bool isA(string type) const {
        return typeName == type;
    }

    /// Check if this is a valid (non-empty) reference
    bool isValid() const {
        return nodeId.length > 0 && nodeId != "Query:";
    }

    /// For debugging
    string toString() const { return nodeId; }

    /// Equality comparison
    bool opEquals(const Ref other) const {
        return nodeId == other.nodeId;
    }

    /// Hash for use in associative arrays
    size_t toHash() const nothrow @safe {
        return hashOf(nodeId);
    }
}

/// The query root reference (singleton)
/// Used as the starting point for all queries
enum Ref queryRoot = Ref("Query:");

// ============================================================================
// Node ID Encoding/Decoding Utilities
// ============================================================================

/// Encode a native long ID as a node ID
string encodeNodeId(string typeName, long id) {
    return typeName ~ ":" ~ id.to!string;
}

/// Encode a native string ID as a node ID
string encodeNodeId(string typeName, string id) {
    return typeName ~ ":" ~ id;
}

/// Create a Ref from type name and long ID
Ref makeRef(string typeName, long id) {
    return Ref(encodeNodeId(typeName, id));
}

/// Create a Ref from type name and string ID
Ref makeRef(string typeName, string id) {
    return Ref(encodeNodeId(typeName, id));
}

/// Decode a node ID to a long (assumes ID portion is numeric)
long decodeAsLong(Ref r) {
    return r.localId.to!long;
}

/// Decode multiple refs to long IDs
long[] decodeAsLongs(Ref[] refs) {
    return refs.map!(r => decodeAsLong(r)).array;
}

// ============================================================================
// Tests
// ============================================================================

unittest {
    // Test Ref basics
    auto userRef = Ref("User:123");
    assert(userRef.typeName == "User");
    assert(userRef.localId == "123");
    assert(userRef.isA("User"));
    assert(!userRef.isA("Post"));
    assert(userRef.isValid);

    // Test queryRoot
    assert(queryRoot.nodeId == "Query:");
    assert(queryRoot.typeName == "Query");
    assert(!queryRoot.isValid);  // Query root is special

    // Test encoding
    assert(encodeNodeId("User", 42) == "User:42");
    assert(encodeNodeId("Post", "abc-123") == "Post:abc-123");

    // Test makeRef
    auto ref1 = makeRef("User", 42);
    assert(ref1.nodeId == "User:42");

    // Test decoding
    assert(decodeAsLong(Ref("User:123")) == 123);
    assert(decodeAsLongs([Ref("User:1"), Ref("User:2")]) == [1, 2]);

    // Test equality and hashing
    assert(Ref("User:1") == Ref("User:1"));
    assert(Ref("User:1") != Ref("User:2"));

    // Test in associative arrays
    int[Ref] counts;
    counts[Ref("User:1")] = 5;
    assert(counts[Ref("User:1")] == 5);
}
