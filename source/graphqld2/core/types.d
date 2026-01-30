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
// Composite Key Encoding/Decoding
// ============================================================================

/// Check if a value needs quoting (contains comma, quote, or problematic whitespace)
private bool needsQuoting(string value) {
    if (value.length == 0) return true;
    if (value[0] == ' ' || value[$ - 1] == ' ') return true;
    foreach (c; value) {
        if (c == ',' || c == '"') return true;
    }
    return false;
}

/// Encode a single value for composite key (quote if needed)
private string encodeKeyPart(string value) {
    if (!needsQuoting(value)) return value;
    // Quote and escape internal quotes
    return `"` ~ value.replace(`"`, `""`) ~ `"`;
}

/// Encode multiple values as a composite key string
string encodeCompositeKey(string[] values) {
    return values.map!(v => encodeKeyPart(v)).join(",");
}

/// Decode a composite key string back to individual values
string[] decodeCompositeKey(string encoded) {
    string[] result;
    size_t i = 0;

    while (i < encoded.length) {
        if (encoded[i] == '"') {
            // Quoted value
            i++;  // skip opening quote
            string value;
            while (i < encoded.length) {
                if (encoded[i] == '"') {
                    if (i + 1 < encoded.length && encoded[i + 1] == '"') {
                        // Escaped quote
                        value ~= '"';
                        i += 2;
                    } else {
                        // End of quoted value
                        i++;  // skip closing quote
                        break;
                    }
                } else {
                    value ~= encoded[i];
                    i++;
                }
            }
            result ~= value;
            // Skip comma if present
            if (i < encoded.length && encoded[i] == ',') i++;
        } else {
            // Unquoted value - read until comma or end
            size_t start = i;
            while (i < encoded.length && encoded[i] != ',') i++;
            result ~= encoded[start .. i];
            // Skip comma if present
            if (i < encoded.length && encoded[i] == ',') i++;
        }
    }

    return result;
}

/// Create a Ref from type name and multiple key values (composite key)
Ref makeCompositeRef(string typeName, string[] keyValues) {
    return Ref(typeName ~ ":" ~ encodeCompositeKey(keyValues));
}

/// Convenience overload for two-part composite keys
Ref makeCompositeRef(T1, T2)(string typeName, T1 val1, T2 val2) {
    return makeCompositeRef(typeName, [val1.to!string, val2.to!string]);
}

/// Convenience overload for three-part composite keys
Ref makeCompositeRef(T1, T2, T3)(string typeName, T1 val1, T2 val2, T3 val3) {
    return makeCompositeRef(typeName, [val1.to!string, val2.to!string, val3.to!string]);
}

/// Decode a Ref's localId as composite key parts
string[] decodeCompositeKey(Ref r) {
    return decodeCompositeKey(r.localId);
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

unittest {
    // Test composite key encoding - simple values (no quoting needed)
    assert(encodeCompositeKey(["123", "456"]) == "123,456");
    assert(encodeCompositeKey(["abc", "def", "ghi"]) == "abc,def,ghi");
    assert(encodeCompositeKey(["uuid-123", "uuid-456"]) == "uuid-123,uuid-456");

    // Test composite key encoding - values that need quoting
    assert(encodeCompositeKey(["hello,world", "foo"]) == `"hello,world",foo`);
    assert(encodeCompositeKey(["say \"hi\"", "bar"]) == `"say ""hi""",bar`);
    assert(encodeCompositeKey([" spaces ", "ok"]) == `" spaces ",ok`);
    assert(encodeCompositeKey(["", "empty"]) == `"",empty`);

    // Test composite key decoding - simple values
    assert(decodeCompositeKey("123,456") == ["123", "456"]);
    assert(decodeCompositeKey("abc,def,ghi") == ["abc", "def", "ghi"]);

    // Test composite key decoding - quoted values
    assert(decodeCompositeKey(`"hello,world",foo`) == ["hello,world", "foo"]);
    assert(decodeCompositeKey(`"say ""hi""",bar`) == [`say "hi"`, "bar"]);
    assert(decodeCompositeKey(`" spaces ",ok`) == [" spaces ", "ok"]);

    // Test round-trip
    auto original = ["order-123", "product,special", `quoted"value`];
    auto encoded = encodeCompositeKey(original);
    auto decoded = decodeCompositeKey(encoded);
    assert(decoded == original);

    // Test makeCompositeRef
    auto ref1 = makeCompositeRef("OrderItem", 100, 200);
    assert(ref1.typeName == "OrderItem");
    assert(ref1.localId == "100,200");
    assert(decodeCompositeKey(ref1) == ["100", "200"]);

    auto ref2 = makeCompositeRef("OrderItem", ["order-1", "prod-2"]);
    assert(ref2.nodeId == "OrderItem:order-1,prod-2");
}
