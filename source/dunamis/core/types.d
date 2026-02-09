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
enum PrimaryKey;

/// Marks a primary key field as auto-increment.
/// Used alongside @PrimaryKey to indicate the database generates the value.
/// Affects DDL generation (SERIAL/AUTO_INCREMENT) and INSERT behavior
/// (use LAST_INSERT_ID/last_insert_rowid instead of explicit PK lookup).
enum AutoIncrement;

/// Check if a specific member has @PrimaryKey UDA.
template hasPrimaryKeyAttr(T, string member) {
    import std.meta : staticIndexOf;
    enum hasPrimaryKeyAttr = staticIndexOf!(PrimaryKey, __traits(getAttributes, __traits(getMember, T, member))) >= 0;
}

/// Check if a specific member has @AutoIncrement UDA.
template hasAutoIncrementAttr(T, string member) {
    import std.meta : staticIndexOf;
    enum hasAutoIncrementAttr = staticIndexOf!(AutoIncrement, __traits(getAttributes, __traits(getMember, T, member))) >= 0;
}

/// Check if any @PrimaryKey field in the type also has @AutoIncrement.
/// Uses T.tupleof to avoid forward reference cycles — see hasPrimaryKey for details.
template hasAutoIncrement(T) {
    import std.meta : staticIndexOf;
    enum hasAutoIncrement = () {
        static foreach (field; T.tupleof) {
            static if (staticIndexOf!(PrimaryKey, __traits(getAttributes, field)) >= 0 &&
                       staticIndexOf!(AutoIncrement, __traits(getAttributes, field)) >= 0) {
                return true;
            }
        }
        return false;
    }();
}

/// Check if any field in the type has @PrimaryKey.
///
/// Uses a two-phase approach to avoid DMD forward reference cycles:
///
/// Phase 1: T.tupleof (data fields only). This is safe during mixin expansion because
/// tupleof only enumerates plain data fields without triggering semantic analysis of
/// mixin-generated methods. The problem it avoids: when an entity has a computed field
/// with `static auto` return type (e.g. `static auto fullName(Expr!User u) => ...`),
/// DMD eagerly analyzes the method body for return type deduction. This triggers
/// Expr!User.opDispatch → Col method → column!() → ColumnAccessExpr class vtable →
/// eval() → entityToRef!User → getPrimaryKeyFieldNames!User → __traits(allMembers, User),
/// but User's mixins haven't finished expanding yet → forward reference error.
///
/// Phase 2: __traits(allMembers) fallback. Needed for normalized entity types where
/// NormalizeFields converts PK plain fields into static methods (preserving the
/// @PrimaryKey UDA). These types are always fully constructed, so
/// __traits(allMembers) is safe — the forward reference issue only affects types
/// that are mid-construction.
///
/// A proper compiler-level fix would involve deferring semantic analysis of static
/// method bodies (e.g. by wrapping them in zero-argument templates), but that requires
/// changes to how mixins generate field accessor methods.
template hasPrimaryKey(T) {
    import std.meta : staticIndexOf;
    enum hasPrimaryKey = () {
        // Phase 1: check tupleof (plain data fields) — safe during mixin expansion
        static foreach (field; T.tupleof) {
            static if (staticIndexOf!(PrimaryKey, __traits(getAttributes, field)) >= 0) {
                return true;
            }
        }
        // Phase 2: check allMembers — needed for normalized types where PK is a method
        static foreach (member; __traits(allMembers, T)) {
            static if (hasPrimaryKeyAttr!(T, member)) {
                return true;
            }
        }
        return false;
    }();
}

/// Get @PrimaryKey field names.
/// Uses T.tupleof to avoid forward reference cycles — see hasPrimaryKey for details.
template getPrimaryKeyFieldNames(T) {
    import std.meta : staticIndexOf;
    enum getPrimaryKeyFieldNames = () {
        string[] names;
        static foreach (field; T.tupleof) {
            static if (staticIndexOf!(PrimaryKey, __traits(getAttributes, field)) >= 0) {
                names ~= __traits(identifier, field);
            }
        }
        return names;
    }();
}

// ============================================================================
// Internal Member Filtering
// ============================================================================

/// Check if a member name is an internal member that should be skipped
/// during type introspection. Filters out D built-in methods and compiler internals.
template isInternalMember(string name) {
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
        name == "__xpostblit";
}

// ============================================================================
// Plain Field Support
// ============================================================================

/// Check if a member is a plain field (struct instance field, not a method).
/// Plain fields are distinguished from computed fields (static methods).
/// Excludes internal members (_*, toString, etc.).
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
                    // Skip non-public fields (package/private/protected are internal infrastructure)
                    static if (__traits(compiles, __traits(getVisibility, member))
                            && __traits(getVisibility, member) != "public") {
                        return false;
                    }
                    // It's a field - check if it's actually an instance field (not a type alias, enum, etc.)
                    else static if (__traits(compiles, { auto x = __traits(getMember, Entity.init, fieldName); })) {
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
    string id;

    /// Extract the entity type name (runtime)
    string typeName() const {
        auto sep = id.indexOf(':');
        return sep >= 0 ? id[0 .. sep] : id;
    }

    /// Extract the local ID portion (after the colon)
    string localId() const {
        auto sep = id.indexOf(':');
        return sep >= 0 ? id[sep + 1 .. $] : "";
    }

    /// Check if this ref is for a specific entity type
    bool isA(string type) const {
        return typeName == type;
    }

    /// Check if this is a valid (non-empty) reference
    bool isValid() const {
        return id.length > 0 && id != "Query:";
    }

    /// For debugging
    string toString() const { return id; }

    /// Hash for use in associative arrays
    size_t toHash() const nothrow @safe {
        return hashOf(id);
    }
}

/// The query root reference (singleton)
/// Used as the starting point for all queries
enum AnyRef queryRoot = AnyRef("Query:");

// ============================================================================
// AnyRef Construction
// ============================================================================

/// Create an untyped AnyRef from type name and string ID (for internal use).
/// The ID can be a single key value or a pre-encoded composite key string.
AnyRef makeAnyRef(string typeName, string id) {
    return AnyRef(typeName ~ ":" ~ id);
}

/// Create an untyped AnyRef from type name and composite key parts.
/// Encodes the parts into a single key string.
/// For single-element arrays, produces the same result as makeAnyRef(typeName, keyValues[0]).
AnyRef makeAnyRef(string typeName, string[] keyValues) {
    return AnyRef(typeName ~ ":" ~ encodeCompositeKey(keyValues));
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
    assert(queryRoot.id == "Query:");
    assert(queryRoot.typeName == "Query");
    assert(!queryRoot.isValid);  // Query root is special

    // Test makeAnyRef
    auto anyRef = makeAnyRef("User", "42");
    assert(anyRef.id == "User:42");
    auto compositeRef = makeAnyRef("OrderItem", ["order-1", "prod-2"]);
    assert(compositeRef.id == "OrderItem:order-1,prod-2");

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

    // Test single-element composite key roundtrip matches simple makeAnyRef
    assert(encodeCompositeKey(["123"]) == "123");
    assert(decodeCompositeKey("123") == ["123"]);
    assert(makeAnyRef("User", ["42"]) == makeAnyRef("User", "42"));
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
    static assert(!isPlainMethod!(TestEntity, "id"), "id is not a member of TestEntity");
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
