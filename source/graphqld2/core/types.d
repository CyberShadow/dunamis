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

/// Untyped reference for internal storage where entity type doesn't matter.
/// Format: "TypeName:localId" (e.g., "User:123", "Order:a1b2-c3d4")
///
/// Used in EvalContext, DataFetcher internals, and anywhere entity type
/// doesn't need to be known at compile time.
struct AnyRef {
    string nodeId;

    /// Extract the entity type name from nodeId (runtime)
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

    /// Hash for use in associative arrays
    size_t toHash() const nothrow @safe {
        return hashOf(nodeId);
    }
}

/// The query root reference (singleton)
/// Used as the starting point for all queries
enum AnyRef queryRoot = AnyRef("Query:");

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

/// Create an Entity with its nodeId set from a long ID
Entity makeEntity(Entity)(long id) {
    return Entity(Entity._typeName ~ ":" ~ id.to!string);
}

/// Create an Entity with its nodeId set from a string ID
Entity makeEntity(Entity)(string id) {
    return Entity(Entity._typeName ~ ":" ~ id);
}

/// Create an untyped AnyRef from type name and long ID (for internal use)
AnyRef makeAnyRef(string typeName, long id) {
    return AnyRef(encodeNodeId(typeName, id));
}

/// Create an untyped AnyRef from type name and string ID (for internal use)
AnyRef makeAnyRef(string typeName, string id) {
    return AnyRef(encodeNodeId(typeName, id));
}

/// Decode an entity's nodeId to a long (assumes ID portion is numeric)
long decodeAsLong(T)(T entity) if (__traits(hasMember, T, "localId")) {
    return entity.localId.to!long;
}

/// Decode multiple entities to long IDs
long[] decodeAsLongs(T)(T[] entities) if (__traits(hasMember, T, "localId")) {
    return entities.map!(e => decodeAsLong(e)).array;
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

/// Create an Entity with its nodeId set from multiple key values (composite key)
Entity makeCompositeEntity(Entity)(string[] keyValues) {
    return Entity(Entity._typeName ~ ":" ~ encodeCompositeKey(keyValues));
}

/// Convenience overload for two-part composite keys
Entity makeCompositeEntity(Entity, T1, T2)(T1 val1, T2 val2) {
    return makeCompositeEntity!Entity([val1.to!string, val2.to!string]);
}

/// Convenience overload for three-part composite keys
Entity makeCompositeEntity(Entity, T1, T2, T3)(T1 val1, T2 val2, T3 val3) {
    return makeCompositeEntity!Entity([val1.to!string, val2.to!string, val3.to!string]);
}

/// Create an untyped AnyRef from type name and multiple key values (for internal use)
AnyRef makeAnyCompositeRef(string typeName, string[] keyValues) {
    return AnyRef(typeName ~ ":" ~ encodeCompositeKey(keyValues));
}

/// Decode an entity's localId as composite key parts
string[] decodeEntityCompositeKey(T)(T entity) if (__traits(hasMember, T, "localId")) {
    return decodeCompositeKey(entity.localId);
}

// ============================================================================
// Custom Scalar Support
// ============================================================================

/// A custom GraphQL scalar type.
///
/// Custom scalars wrap a D type and provide serialization/deserialization
/// to/from strings for GraphQL transport.
///
/// Example:
/// ---
/// alias Int64 = CustomScalar!(
///     long, "Int64",
///     (long v) => v.to!string,
///     (string s) => s.to!long
/// );
///
/// struct Entity {
///     mixin Col!("bigValue", Int64);
/// }
/// ---
struct CustomScalar(
    _DType,
    string _name,
    alias _serialize,
    alias _deserialize
) {
    /// The underlying D type
    alias DType = _DType;

    /// The GraphQL scalar name
    enum name = _name;

    /// Serialize to string
    alias serialize = _serialize;

    /// Deserialize from string
    alias deserialize = _deserialize;

    /// The wrapped value
    DType value;

    /// Implicit conversion to underlying type
    alias value this;

    /// Constructor from underlying type
    this(DType v) {
        value = v;
    }

    /// Serialize this value
    string toString() const {
        return serialize(value);
    }

    /// Deserialize from string
    static typeof(this) fromString(string s) {
        return typeof(this)(deserialize(s));
    }
}

/// Check if a type is a CustomScalar.
///
/// Example:
/// ---
/// static assert(isCustomScalar!Int64);
/// static assert(!isCustomScalar!long);
/// ---
template isCustomScalar(T) {
    enum isCustomScalar = is(typeof({
        // Must have a name
        enum string n = T.name;
        // Must have underlying DType
        alias D = T.DType;
        // Must have serialize/deserialize
        string s = T.serialize(D.init);
        D v = T.deserialize("");
    }));
}

unittest {
    // Test CustomScalar
    alias TestScalar = CustomScalar!(
        int, "TestInt",
        (int v) => v.to!string,
        (string s) => s.to!int
    );

    static assert(isCustomScalar!TestScalar);
    static assert(!isCustomScalar!int);
    static assert(!isCustomScalar!string);

    static assert(TestScalar.name == "TestInt");
    static assert(is(TestScalar.DType == int));

    auto val = TestScalar(42);
    assert(val.value == 42);
    assert(val == 42);  // implicit conversion
    assert(val.toString() == "42");

    auto parsed = TestScalar.fromString("123");
    assert(parsed.value == 123);
}

// ============================================================================
// Tests
// ============================================================================

// Test entity types for unit tests (minimal: just nodeId and _typeName)
private struct TestUser {
    string nodeId;
    enum _typeName = "User";

    string localId() const {
        auto sep = nodeId.indexOf(':');
        return sep >= 0 ? nodeId[sep + 1 .. $] : "";
    }
}

private struct TestPost {
    string nodeId;
    enum _typeName = "Post";

    string localId() const {
        auto sep = nodeId.indexOf(':');
        return sep >= 0 ? nodeId[sep + 1 .. $] : "";
    }
}

private struct TestOrderItem {
    string nodeId;
    enum _typeName = "OrderItem";

    string localId() const {
        auto sep = nodeId.indexOf(':');
        return sep >= 0 ? nodeId[sep + 1 .. $] : "";
    }
}

unittest {
    // Test AnyRef basics (untyped)
    auto userRef = AnyRef("User:123");
    assert(userRef.typeName == "User");
    assert(userRef.localId == "123");
    assert(userRef.isA("User"));
    assert(!userRef.isA("Post"));
    assert(userRef.isValid);

    // Test Entity with nodeId
    auto user = TestUser("User:456");
    assert(user.nodeId == "User:456");
    assert(user.localId == "456");
    static assert(TestUser._typeName == "User");

    // Test queryRoot
    assert(queryRoot.nodeId == "Query:");
    assert(queryRoot.typeName == "Query");
    assert(!queryRoot.isValid);  // Query root is special

    // Test encoding
    assert(encodeNodeId("User", 42) == "User:42");
    assert(encodeNodeId("Post", "abc-123") == "Post:abc-123");

    // Test makeEntity
    auto entity1 = makeEntity!TestUser(42);
    assert(entity1.nodeId == "User:42");
    static assert(is(typeof(entity1) == TestUser));

    auto entity2 = makeEntity!TestUser("abc-123");
    assert(entity2.nodeId == "User:abc-123");

    // Test untyped makeAnyRef
    auto anyRef = makeAnyRef("User", 42);
    assert(anyRef.nodeId == "User:42");

    // Test decoding
    assert(decodeAsLong(AnyRef("User:123")) == 123);
    assert(decodeAsLong(TestUser("User:123")) == 123);
    assert(decodeAsLongs([AnyRef("User:1"), AnyRef("User:2")]) == [1, 2]);

    // Test equality
    assert(AnyRef("User:1") == AnyRef("User:1"));
    assert(AnyRef("User:1") != AnyRef("User:2"));

    // Test in associative arrays
    int[AnyRef] counts;
    counts[AnyRef("User:1")] = 5;
    assert(counts[AnyRef("User:1")] == 5);
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

    // Test makeCompositeEntity
    auto entity1 = makeCompositeEntity!(TestOrderItem, int, int)(100, 200);
    assert(entity1.nodeId == "OrderItem:100,200");
    assert(entity1.localId == "100,200");
    static assert(is(typeof(entity1) == TestOrderItem));
    assert(decodeEntityCompositeKey(entity1) == ["100", "200"]);

    // Test untyped makeAnyCompositeRef
    auto ref2 = makeAnyCompositeRef("OrderItem", ["order-1", "prod-2"]);
    assert(ref2.nodeId == "OrderItem:order-1,prod-2");

    // Test makeCompositeEntity with string array
    auto entity3 = makeCompositeEntity!TestOrderItem(["order-1", "prod-2"]);
    assert(entity3.nodeId == "OrderItem:order-1,prod-2");
    static assert(is(typeof(entity3) == TestOrderItem));
}
