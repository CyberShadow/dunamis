module dunamis.core.types;

import std.algorithm;
import std.array;
import std.conv;
import std.string : indexOf;
import std.typecons : Nullable;

// ============================================================================
// Primary Key Support
// ============================================================================

/// Marks a field as part of the primary key.
/// Used on plain fields to identify entity instances.
enum PrimaryKeyAttr;

/// Check if a member has @PrimaryKeyAttr UDA
template hasPrimaryKeyAttr(T, string member) {
    import std.meta : staticIndexOf;
    static if (__traits(compiles, __traits(getAttributes, __traits(getMember, T, member)))) {
        enum hasPrimaryKeyAttr = staticIndexOf!(PrimaryKeyAttr, __traits(getAttributes, __traits(getMember, T, member))) >= 0;
    } else {
        enum hasPrimaryKeyAttr = false;
    }
}

/// Check if any field in the type has @PrimaryKeyAttr
template hasPrimaryKey(T) {
    enum hasPrimaryKey = () {
        static foreach (member; __traits(allMembers, T)) {
            static if (hasPrimaryKeyAttr!(T, member)) {
                return true;
            }
        }
        return false;
    }();
}

/// Get the name of the @PrimaryKey field
template getPrimaryKeyFieldName(T) {
    enum getPrimaryKeyFieldName = () {
        static foreach (member; __traits(allMembers, T)) {
            static if (hasPrimaryKeyAttr!(T, member)) {
                return member;
            }
        }
        assert(false, "No @PrimaryKey field found on " ~ T.stringof);
    }();
}

/// Get the type of the @PrimaryKey field
template getPrimaryKeyType(T) {
    enum _name = getPrimaryKeyFieldName!T;
    alias getPrimaryKeyType = typeof(__traits(getMember, T.init, _name));
}

/// Get ALL @PrimaryKey field names (for composite key support)
template getPrimaryKeyFieldNames(T) {
    enum getPrimaryKeyFieldNames = () {
        string[] names;
        static foreach (member; __traits(allMembers, T)) {
            static if (hasPrimaryKeyAttr!(T, member)) {
                names ~= member;
            }
        }
        return names;
    }();
}

// ============================================================================
// Internal Member Filtering
// ============================================================================

/// Check if a member name is an internal member that should be skipped
/// during type introspection. Filters out D built-in methods and private members.
template isInternalMember(string name) {
    import std.algorithm : startsWith;
    enum isInternalMember =
        // D built-in methods
        name == "toString" ||
        name == "toHash" ||
        name == "opEquals" ||
        name == "opCmp" ||
        name == "opAssign" ||
        name == "factory" ||
        // Module/compiler internals
        name == "Monitor" ||
        name == "__ctor" ||
        name == "__dtor" ||
        name == "__xdtor" ||
        name == "__postblit" ||
        name == "__xpostblit" ||
        // Private members (used by mixins for internal aliases)
        name.startsWith("_");
}

// ============================================================================
// Plain Field Support
// ============================================================================

/// Check if a member is a plain field (struct instance field, not a method).
/// Plain fields are distinguished from computed fields (static methods).
/// Excludes internal members (nodeId, _*, toString, etc.).
template isPlainField(Entity, string fieldName) {
    static if (isInternalMember!fieldName) {
        enum isPlainField = false;
    } else {
        enum isPlainField = () {
            // Must be readable on an instance
            static if (!__traits(compiles, __traits(getMember, Entity.init, fieldName))) {
                return false;
            } else {
                alias member = __traits(getMember, Entity, fieldName);
                // Skip functions/methods
                static if (is(typeof(member) == function) || is(typeof(&member) == delegate)) {
                    return false;
                } else {
                    // It's a field - check if it's actually an instance field (not a type alias, enum, etc.)
                    static if (__traits(compiles, { auto x = __traits(getMember, Entity.init, fieldName); })) {
                        return true;
                    } else {
                        return false;
                    }
                }
            }
        }();
    }
}

/// Get a tuple of all plain field names for an entity.
template getPlainFieldNames(Entity) {
    import std.meta : Filter;

    template isPlainFieldMember(string name) {
        enum isPlainFieldMember = isPlainField!(Entity, name);
    }

    alias getPlainFieldNames = Filter!(isPlainFieldMember, __traits(allMembers, Entity));
}

// ============================================================================
// Plain Method Support
// ============================================================================

/// Check if a member is a plain method (instance method returning non-Expr type).
/// Plain methods are distinguished from:
/// - Computed fields (static methods taking Expr!Entity, returning Expr!T)
/// - Plain fields (struct instance fields)
///
/// A plain method:
/// - Is callable on an entity instance with no arguments
/// - Returns a non-Expr type (scalar, Nullable!scalar, arrays of scalars)
/// - Is not a static method
template isPlainMethod(Entity, string memberName) {
    import dunamis.core.expr : isExpr;

    static if (isInternalMember!memberName) {
        enum isPlainMethod = false;
    } else {
        enum isPlainMethod = () {
            // Must be accessible
            static if (!__traits(compiles, __traits(getMember, Entity, memberName))) {
                return false;
            } else {
                alias member = __traits(getMember, Entity, memberName);

                // Must be a function type
                static if (!is(typeof(member) == function)) {
                    return false;
                }
                // Must NOT be a static function (plain methods are instance methods)
                else static if (__traits(isStaticFunction, member)) {
                    return false;
                } else {
                    import std.traits : Parameters, ReturnType;
                    alias Params = Parameters!member;
                    alias Return = ReturnType!member;

                    // Must take no parameters
                    static if (Params.length != 0) {
                        return false;
                    }
                    // Return type must not be void
                    else static if (is(Return == void)) {
                        return false;
                    }
                    // Return type must not be an Expr (those are computed fields)
                    else static if (isExpr!Return) {
                        return false;
                    }
                    else {
                        return true;
                    }
                }
            }
        }();
    }
}

/// Get a tuple of all plain method names for an entity.
template getPlainMethodNames(Entity) {
    import std.meta : Filter;

    template isPlainMethodMember(string name) {
        enum isPlainMethodMember = isPlainMethod!(Entity, name);
    }

    alias getPlainMethodNames = Filter!(isPlainMethodMember, __traits(allMembers, Entity));
}

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

/// Create an untyped AnyRef from type name and long ID (for internal use)
AnyRef makeAnyRef(string typeName, long id) {
    return AnyRef(encodeNodeId(typeName, id));
}

/// Create an untyped AnyRef from type name and string ID (for internal use)
AnyRef makeAnyRef(string typeName, string id) {
    return AnyRef(encodeNodeId(typeName, id));
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

/// Create an untyped AnyRef from type name and multiple key values (for internal use)
AnyRef makeAnyCompositeRef(string typeName, string[] keyValues) {
    return AnyRef(typeName ~ ":" ~ encodeCompositeKey(keyValues));
}

// ============================================================================
// Custom Scalar Support
// ============================================================================

/// A custom GraphQL scalar type.
///
/// Custom scalars wrap a D type and provide serialization/deserialization
/// to/from JSONValue for GraphQL transport.
///
/// Example:
/// ---
/// import std.json : JSONValue, JSONType;
///
/// alias Int64 = CustomScalar!(
///     long, "Int64",
///     (long v) => JSONValue(v),
///     (JSONValue j) => j.type == JSONType.integer ? j.integer : j.str.to!long
/// );
///
/// struct Entity {
///     mixin Col!("bigValue", Int64);
/// }
/// ---
struct CustomScalar(
    _DType,
    string _name,
    alias _toJson,
    alias _fromJson
) {
    import std.json : JSONValue;

    /// The underlying D type
    alias DType = _DType;

    /// The GraphQL scalar name
    enum name = _name;

    /// Serialize to JSONValue
    alias toJson = _toJson;

    /// Deserialize from JSONValue
    alias fromJson = _fromJson;

    /// The wrapped value
    DType value;

    /// Implicit conversion to underlying type
    alias value this;

    /// Constructor from underlying type
    this(DType v) {
        value = v;
    }

    /// Serialize this value to JSON
    JSONValue toJsonValue() const {
        return toJson(value);
    }

    /// Deserialize from JSONValue
    static typeof(this) fromJsonValue(JSONValue json) {
        return typeof(this)(fromJson(json));
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
    import std.json : JSONValue;
    enum isCustomScalar = is(typeof({
        // Must have a name
        enum string n = T.name;
        // Must have underlying DType
        alias D = T.DType;
        // Must have toJson/fromJson
        JSONValue j = T.toJson(D.init);
        D v = T.fromJson(JSONValue.init);
    }));
}

unittest {
    import std.json : JSONValue, JSONType;

    // Test CustomScalar
    alias TestScalar = CustomScalar!(
        int, "TestInt",
        (int v) => JSONValue(v),
        (JSONValue j) => cast(int) j.integer
    );

    static assert(isCustomScalar!TestScalar);
    static assert(!isCustomScalar!int);
    static assert(!isCustomScalar!string);

    static assert(TestScalar.name == "TestInt");
    static assert(is(TestScalar.DType == int));

    auto val = TestScalar(42);
    assert(val.value == 42);
    assert(val == 42);  // implicit conversion
    assert(val.toJsonValue() == JSONValue(42));

    auto parsed = TestScalar.fromJsonValue(JSONValue(123));
    assert(parsed.value == 123);
}

// ============================================================================
// Type Mappings
// ============================================================================

/// A compile-time mapping from one D type to another for GraphQL representation.
///
/// Allows external types (that you can't modify) to be represented as
/// GraphQL-compatible types.
///
/// Params:
///   _From = The D type to replace (e.g., Date)
///   _To = The replacement type that GraphQL understands (e.g., string, CustomScalar, struct)
///   _serialize = Function: From → To (for output/serialization)
///   _deserialize = Function: To → From (for input/deserialization)
///
/// Example:
/// ---
/// alias DateMapping = TypeMapping!(Date, string,
///     (Date d) => d.toISOExtString,
///     (string s) => Date.fromISOExtString(s),
/// );
/// ---
template TypeMapping(_From, _To, alias _serialize, alias _deserialize) {
    alias SourceType = _From;
    alias TargetType = _To;
    alias toTarget = _serialize;
    alias fromTarget = _deserialize;
}

/// Apply a type mapping's serialize function, recursively handling
/// Nullable and array wrappers. The conversion is applied at the leaf level.
///
/// This is a runtime function used by the compiler to insert conversion
/// expressions via the `use()` combinator.
auto applySerialize(From, To, alias serialize)(From value) {
    static if (is(From == Nullable!U, U) && is(To == Nullable!V, V)) {
        if (value.isNull) return Nullable!V.init;
        return Nullable!V(applySerialize!(U, V, serialize)(value.get));
    } else static if (!is(From == string) && is(From == E1[], E1)
                    && !is(To == string) && is(To == E2[], E2)) {
        E2[] result;
        result.length = value.length;
        foreach (i, ref e; value)
            result[i] = applySerialize!(E1, E2, serialize)(e);
        return result;
    } else {
        return serialize(value);
    }
}

/// Apply a type mapping's deserialize function, recursively handling
/// Nullable and array wrappers.
auto applyDeserialize(To, From, alias deserialize)(To value) {
    import std.typecons : Nullable;
    static if (is(To == Nullable!U, U) && is(From == Nullable!V, V)) {
        if (value.isNull) return Nullable!V.init;
        return Nullable!V(applyDeserialize!(U, V, deserialize)(value.get));
    } else static if (!is(To == string) && is(To == E1[], E1)
                    && !is(From == string) && is(From == E2[], E2)) {
        E2[] result;
        result.length = value.length;
        foreach (i, ref e; value)
            result[i] = applyDeserialize!(E1, E2, deserialize)(e);
        return result;
    } else {
        return deserialize(value);
    }
}

// Type mapping unit tests — uses module-level type to avoid nested struct issues
private struct _TestDate {
    int year, month, day;
}

private string _testDateToString(_TestDate d) {
    import std.conv : to;
    return d.year.to!string ~ "-" ~ d.month.to!string ~ "-" ~ d.day.to!string;
}

private _TestDate _testDateFromString(string) {
    return _TestDate(2024, 1, 15);
}

unittest {
    alias DateMapping = TypeMapping!(_TestDate, string, _testDateToString, _testDateFromString);

    static assert(is(DateMapping.SourceType == _TestDate));
    static assert(is(DateMapping.TargetType == string));

    // applySerialize: direct
    auto d = _TestDate(2024, 1, 15);
    auto s = applySerialize!(_TestDate, string, DateMapping.toTarget)(d);
    assert(s == "2024-1-15");

    // applySerialize: Nullable
    auto nd = Nullable!_TestDate(d);
    auto ns = applySerialize!(Nullable!_TestDate, Nullable!string, DateMapping.toTarget)(nd);
    assert(!ns.isNull);
    assert(ns.get == "2024-1-15");

    // applySerialize: null Nullable
    auto nullD = Nullable!_TestDate.init;
    auto nullS = applySerialize!(Nullable!_TestDate, Nullable!string, DateMapping.toTarget)(nullD);
    assert(nullS.isNull);

    // applySerialize: array
    auto arr = [_TestDate(2024, 1, 15), _TestDate(2024, 6, 30)];
    auto arrS = applySerialize!(_TestDate[], string[], DateMapping.toTarget)(arr);
    assert(arrS.length == 2);
    assert(arrS[0] == "2024-1-15");

    // applyDeserialize: direct
    auto d2 = applyDeserialize!(string, _TestDate, DateMapping.fromTarget)("2024-1-15");
    assert(d2.year == 2024);
}

// ============================================================================
// Tests
// ============================================================================

unittest {
    // Test AnyRef basics (untyped)
    auto userRef = AnyRef("User:123");
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

    // Test untyped makeAnyRef
    auto anyRef = makeAnyRef("User", 42);
    assert(anyRef.nodeId == "User:42");

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

    // Test untyped makeAnyCompositeRef
    auto ref2 = makeAnyCompositeRef("OrderItem", ["order-1", "prod-2"]);
    assert(ref2.nodeId == "OrderItem:order-1,prod-2");
}

// Test isPlainMethod detection
unittest {
    import std.typecons : Nullable;

    struct TestEntity {
        int value;  // Plain field
        Nullable!string nickname;  // Plain field (nullable)

        int doubleValue() => value * 2;  // Plain method
        bool isPositive() => value > 0;  // Plain method
        string displayName() { return nickname.isNull ? "Anonymous" : nickname.get; }  // Plain method

        static int staticMethod() => 42;  // NOT plain method (static, but also no params means not a computed field)

        // Simulated computed field (takes Expr-like first param)
        // We can't easily test this without importing dunamis.core.expr, so we skip
    }

    // Plain methods should be detected
    static assert(isPlainMethod!(TestEntity, "doubleValue"), "doubleValue should be a plain method");
    static assert(isPlainMethod!(TestEntity, "isPositive"), "isPositive should be a plain method");
    static assert(isPlainMethod!(TestEntity, "displayName"), "displayName should be a plain method");

    // Static methods are NOT plain methods (they can't be called on instance)
    static assert(!isPlainMethod!(TestEntity, "staticMethod"), "staticMethod should NOT be a plain method");

    // Fields are NOT methods
    static assert(!isPlainMethod!(TestEntity, "value"), "value is a field, not a method");
    static assert(!isPlainMethod!(TestEntity, "nickname"), "nickname is a field, not a method");

    // Internal members are excluded
    static assert(!isPlainMethod!(TestEntity, "nodeId"), "nodeId is internal");
    static assert(!isPlainMethod!(TestEntity, "toString"), "toString is internal");

    // Test getPlainMethodNames
    enum plainMethods = getPlainMethodNames!TestEntity;
    static assert(plainMethods.length == 3, "Should find 3 plain methods");

    // Verify the method names using CTFE
    enum hasDouble = () {
        foreach (name; plainMethods) if (name == "doubleValue") return true;
        return false;
    }();
    enum hasPositive = () {
        foreach (name; plainMethods) if (name == "isPositive") return true;
        return false;
    }();
    enum hasDisplay = () {
        foreach (name; plainMethods) if (name == "displayName") return true;
        return false;
    }();
    static assert(hasDouble && hasPositive && hasDisplay,
        "Should find doubleValue, isPositive, and displayName");
}
