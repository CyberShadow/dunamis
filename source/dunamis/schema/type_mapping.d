module dunamis.schema.type_mapping;

import std.meta : AliasSeq;
import std.typecons : Nullable;
import dunamis.schema.plugin : isSchema;

// ============================================================================
// Value Mapping Helpers
// ============================================================================

/// Find a direct mapping for type T in the Mappings list.
template findValueMapping(T, Mappings...) {
    static if (Mappings.length == 0) {
        enum found = false;
    } else static if (is(Mappings[0].SourceType == T)) {
        enum found = true;
        alias TargetType = Mappings[0].TargetType;
        alias toTarget = Mappings[0].toTarget;
        alias fromTarget = Mappings[0].fromTarget;
    } else {
        alias rest = findValueMapping!(T, Mappings[1 .. $]);
        enum found = rest.found;
        static if (found) {
            alias TargetType = rest.TargetType;
            alias toTarget = rest.toTarget;
            alias fromTarget = rest.fromTarget;
        }
    }
}

/// Check if T has a direct mapping in Mappings.
template hasDirectMapping(T, Mappings...) {
    enum hasDirectMapping = findValueMapping!(T, Mappings).found;
}

/// Resolve a type through value mappings at every unwrapping level
/// (direct, Nullable, array). Like ResolveType but takes Mappings directly.
template ResolveValueType(T, Mappings...) {
    static if (findValueMapping!(T, Mappings).found) {
        alias ResolveValueType = findValueMapping!(T, Mappings).TargetType;
    } else static if (is(T == Nullable!U, U)) {
        alias Inner = ResolveValueType!(U, Mappings);
        static if (is(Inner == U))
            alias ResolveValueType = T;
        else
            alias ResolveValueType = Nullable!Inner;
    } else static if (!is(T == string) && is(T == E[], E)) {
        alias Inner = ResolveValueType!(E, Mappings);
        static if (is(Inner == E))
            alias ResolveValueType = T;
        else
            alias ResolveValueType = Inner[];
    } else {
        alias ResolveValueType = T;
    }
}

/// Find the leaf-level mapping for type T, looking through Nullable/array wrappers.
/// Returns the mapping's toTarget/fromTarget at the leaf level.
template findLeafMapping(T, Mappings...) {
    static if (findValueMapping!(T, Mappings).found) {
        enum found = true;
        alias toTarget = findValueMapping!(T, Mappings).toTarget;
        alias fromTarget = findValueMapping!(T, Mappings).fromTarget;
    } else static if (is(T == Nullable!U, U)) {
        alias _inner = findLeafMapping!(U, Mappings);
        enum found = _inner.found;
        static if (found) {
            alias toTarget = _inner.toTarget;
            alias fromTarget = _inner.fromTarget;
        }
    } else static if (!is(T == string) && is(T == E[], E)) {
        alias _inner = findLeafMapping!(E, Mappings);
        enum found = _inner.found;
        static if (found) {
            alias toTarget = _inner.toTarget;
            alias fromTarget = _inner.fromTarget;
        }
    } else {
        enum found = false;
    }
}

// ============================================================================
// Result Mapping Helper
// ============================================================================

/// Apply entity TypeMap + value mappings to a result expression.
/// First remaps entity/object types via wrapEntityResult, then serializes
/// any remaining value-mapped types.
template applyMappingsToResult(alias TypeMap, Mappings...) {
    auto applyMappingsToResult(R)(R result) {
        import dunamis.core.expr : ExprResultType, use;
        import dunamis.schema.transform : wrapEntityResult;
        import dunamis.core.types : applySerialize;

        auto typeMapped = wrapEntityResult!(TypeMap)(result);
        alias RT = ExprResultType!(typeof(typeMapped));
        alias Resolved = ResolveValueType!(RT, Mappings);
        static if (!is(Resolved == RT)) {
            alias leaf = findLeafMapping!(RT, Mappings);
            return use(&applySerialize!(RT, Resolved, leaf.toTarget), typeMapped);
        } else {
            return typeMapped;
        }
    }
}

// ============================================================================
// Field Forwarding with Value Mapping
// ============================================================================

/// Top-level template holding metadata for a forwarded field with value mappings.
template ForwardFieldWithMappingsImpl(SourceType, string fieldName, alias TypeMap, Mappings...) {
    import std.traits : Parameters, ParameterDefaults, ParameterIdentifierTuple;
    import dunamis.core.expr : ExprResultType;

    alias srcFn = __traits(getMember, SourceType, fieldName);
    alias SrcParams = Parameters!srcFn;
    alias SrcDefaults = ParameterDefaults!srcFn;
    enum string[] srcParamNames = [ParameterIdentifierTuple!srcFn];
    alias SrcEntity = ExprResultType!(SrcParams[0]);

    /// Whether parameter i was mapped to a different type
    template isParamMapped(size_t i) {
        enum isParamMapped = !is(ResolveValueType!(SrcParams[i], Mappings) == SrcParams[i]);
    }
}

/// Eponymous template that builds the mixin string for a forwarded field with value mappings.
template ForwardFieldWithMappingsCode(SourceType, string fieldName, alias TypeMap, Mappings...) {
    import std.conv : to;

    private alias Impl = ForwardFieldWithMappingsImpl!(SourceType, fieldName, TypeMap, Mappings);
    private enum string _I = "dunamis.schema.type_mapping.ForwardFieldWithMappingsImpl!(SourceType, fieldName, TypeMap, Mappings)";
    private enum string _tm = "dunamis.schema.type_mapping";

    private enum string _paramListStr = () {
        string result = "dunamis.core.expr.Expr!(typeof(this)) " ~ Impl.srcParamNames[0];
        static foreach (i; 1 .. Impl.SrcParams.length) {{
            result ~= ", " ~ _tm ~ ".ResolveValueType!(" ~ _I ~ ".SrcParams[" ~ i.to!string ~ "], Mappings) " ~ Impl.srcParamNames[i];
            // Preserve defaults only if type didn't change
            static if (!is(Impl.SrcDefaults[i] == void)) {
                static if (!Impl.isParamMapped!i) {
                    result ~= " = " ~ _I ~ ".SrcDefaults[" ~ i.to!string ~ "]";
                }
            }
        }}
        return result;
    }();

    private enum string _argListStr = () {
        string result = "dunamis.schema.entity_cast.pluginEntityCast!(" ~ _I ~ ".SrcEntity)(" ~ Impl.srcParamNames[0] ~ ")";
        static foreach (i; 1 .. Impl.SrcParams.length) {{
            result ~= ", ";
            static if (Impl.isParamMapped!i) {
                // Type was mapped → deserialize before forwarding
                result ~= "dunamis.core.types.applyDeserialize!(" ~
                          _tm ~ ".ResolveValueType!(" ~ _I ~ ".SrcParams[" ~ i.to!string ~ "], Mappings), " ~
                          _I ~ ".SrcParams[" ~ i.to!string ~ "], " ~
                          _tm ~ ".findLeafMapping!(" ~ _I ~ ".SrcParams[" ~ i.to!string ~ "], Mappings).fromTarget)(" ~
                          Impl.srcParamNames[i] ~ ")";
            } else {
                result ~= Impl.srcParamNames[i];
            }
        }}
        return result;
    }();

    enum ForwardFieldWithMappingsCode =
        "@(__traits(getAttributes, " ~ _I ~ ".srcFn)) " ~
        "static auto " ~ fieldName ~ "(" ~ _paramListStr ~ ") { " ~
        "return " ~ _tm ~ ".applyMappingsToResult!(TypeMap, Mappings)(" ~
        _I ~ ".srcFn(" ~ _argListStr ~ ")); }";
}

/// Forward a computed field with value mapping applied to return type and arguments.
/// Zero-leak: no imports, aliases, or enums are mixed into the target struct.
mixin template ForwardFieldWithMappings(SourceType, string fieldName, alias TypeMap, Mappings...) {
    static import dunamis.schema.type_mapping;
    static import dunamis.core.expr;
    static import dunamis.schema.entity_cast;
    static import dunamis.core.types;
    mixin(dunamis.schema.type_mapping.ForwardFieldWithMappingsCode!(SourceType, fieldName, TypeMap, Mappings));
}

// ============================================================================
// ExternalTypesPlugin
// ============================================================================

/// Plugin that maps external D types to GraphQL-compatible types.
///
/// This is a pure plugin: type mappings are applied at the type level by
/// creating wrapper types with serialization/deserialization built in.
/// No SchemaConfig or cfg threading needed — downstream consumers (SDL
/// generator, compiler, introspection) see the final mapped types.
///
/// Example:
/// ---
/// import dunamis.core.types : TypeMapping;
///
/// alias MySchema = ExternalTypesPlugin!(
///     Schema!(Query, Mutation),
///     TypeMapping!(Date, string,
///         (Date d) => d.toISOExtString,
///         (string s) => Date.fromISOExtString(s)),
/// );
/// ---
template ExternalTypesPlugin(alias S, NewMappings...) if (isSchema!S) {
    import dunamis.core.discovery : getAllObjectTypes;
    import dunamis.schema.transform : isTypeInList;
    import dunamis.schema.plugin : getFieldMembers, isComputedField, OriginalName;

    // Discover all object types from the inner schema's Query
    alias _OriginalQuery = S.Query;
    alias _AllTypes = getAllObjectTypes!_OriginalQuery;

    // TypeMap: route types to their wrapped versions.
    // - Directly-mapped types (Date→string): identity (serialized at call site)
    // - Normalized types whose source has a mapping: map back to source type
    //   (EntityCastExpr unwraps _normalizedSource, then mapping serializes it)
    // - Object types in the schema: wrapped with value mapping
    // - Everything else: identity
    template _TypeMap(T) {
        static if (hasDirectMapping!(T, NewMappings)) {
            alias _TypeMap = T; // Directly mapped → don't wrap, serialize at call site
        } else static if (_hasSourceMapping!T) {
            alias _TypeMap = typeof(T._normalizedSource); // Unwrap to source for mapping
        } else static if (isTypeInList!(T, _AllTypes)) {
            alias _TypeMap = _MappedType!T; // Wrap with value mapping
        } else {
            alias _TypeMap = T; // Not in type list → pass through
        }
    }

    // Check if T is a normalized type whose _normalizedSource has a value mapping.
    template _hasSourceMapping(T) {
        static if (__traits(hasMember, T, "_normalizedSource")) {
            enum _hasSourceMapping = hasDirectMapping!(typeof(T._normalizedSource), NewMappings);
        } else {
            enum _hasSourceMapping = false;
        }
    }

    // Build the body of _MappedType as a code string to avoid symbol leaks.
    // After NormalizePlugin, all types have only computed fields (static Expr
    // methods), so we only need to forward those with value mapping applied.
    private template _MappedTypeBody(T) {
        private enum string _fwd = "dunamis.schema.type_mapping.ForwardFieldWithMappings";

        enum _MappedTypeBody = () {
            // Static imports for fully-qualified references in generated code
            string result = "static import dunamis.core.expr;\n" ~
                            "static import dunamis.schema.type_mapping;\n" ~
                            "static import dunamis.schema.entity_cast;\n" ~
                            "static import dunamis.core.types;\n";

            // Per-layer _normalizedSource (stores immediate source type)
            result ~= "package(dunamis.schema) T _normalizedSource;\n";

            // Forward computed fields with value mapping
            static foreach (member; getFieldMembers!T) {
                static if (isComputedField!(T, member)) {
                    result ~= "mixin " ~ _fwd ~ "!(T, \"" ~ member ~ "\", _TypeMap, NewMappings);\n";
                }
            }

            return result;
        }();
    }

    // Create wrapped version of each discovered type.
    // After NormalizePlugin, all types have only static Expr methods.
    // Just forward with value mapping applied.
    template _MappedType(T) {
        @(__traits(getAttributes, T))
        @OriginalName(__traits(identifier, T))
        struct _MappedType {
            mixin(_MappedTypeBody!T);
        }
    }

    // Wrap Query: forward all fields with value mapping
    struct Query {
        static foreach (_m; getFieldMembers!_OriginalQuery) {
            static if (isComputedField!(_OriginalQuery, _m)) {
                mixin ForwardFieldWithMappings!(_OriginalQuery, _m, _TypeMap, NewMappings);
            }
        }
    }

    // Wrap Mutation: forward all fields with value mapping
    struct Mutation {
        static foreach (_m; getFieldMembers!(S.Mutation)) {
            static if (isComputedField!(S.Mutation, _m)) {
                mixin ForwardFieldWithMappings!(S.Mutation, _m, _TypeMap, NewMappings);
            }
        }
    }

}

// ============================================================================
// Unit Tests
// ============================================================================

// SDL generation: mapped types in plain methods and computed field args
unittest {
    import std.algorithm : canFind;
    import std.typecons : Nullable;
    import dunamis.core.types : TypeMapping;
    import dunamis.graphql.schema : Schema, generateSchemaSDL;
    import dunamis.relational.demo : DemoEntity, DemoId, MockDB;
    import dunamis.relational.schema : Col, Table;
    import dunamis.core.expr : Expr;

    static struct Date {
        int year, month, day;
    }

    alias DateMapping = TypeMapping!(Date, string,
        function string(Date d) {
            import std.conv : to;
            return d.year.to!string ~ "-" ~ d.month.to!string ~ "-" ~ d.day.to!string;
        },
        function Date(string s) {
            import std.conv : to;
            import std.array : split;
            auto parts = s.split("-");
            return Date(parts[0].to!int, parts[1].to!int, parts[2].to!int);
        });

    static MockDB!() db;

    @DemoEntity!(db, "events")
    static struct Event {
        mixin DemoId;
        mixin Col!("title", string);

        // Plain method returning mapped type
        Date startDate() => Date(2024, 1, 15);

        // Plain method returning Nullable mapped type
        Nullable!Date endDate() => Nullable!Date.init;

        // Computed field taking mapped type as argument
        static auto eventsAfter(Expr!Event e, Date since) {
            return e.title;
        }
    }

    static struct Query {
        mixin Table!(Event, "events");
    }

    // Without mapping: Date appears as an object/input type
    enum sdlWithout = generateSchemaSDL!Query;
    static assert(sdlWithout.canFind("type Date"), "Date is a POD object type without mapping");
    static assert(sdlWithout.canFind("startDate: Date!"));

    // With mapping: Date → String
    alias MappedSchema = ExternalTypesPlugin!(Schema!(Query), DateMapping);
    enum sdlWith = generateSchemaSDL!MappedSchema;
    static assert(sdlWith.canFind("startDate: String!"), "Plain method returning mapped type → String!");
    static assert(sdlWith.canFind("endDate: String"), "Plain method returning Nullable mapped type → nullable String");
    static assert(sdlWith.canFind("since: String!"), "Computed field arg with mapped type → String!");
    static assert(!sdlWith.canFind("type Date"), "Date type should not appear with mapping");
}

// SDL generation: mapped types in POD struct fields
unittest {
    import std.algorithm : canFind;
    import std.typecons : Nullable;
    import dunamis.core.types : TypeMapping;
    import dunamis.graphql.schema : Schema, generateSchemaSDL;
    import dunamis.relational.demo : DemoEntity, DemoId, MockDB;
    import dunamis.relational.schema : Col, Table;
    import dunamis.core.expr : Expr;

    static struct Timestamp {
        long epochMs;
    }

    alias TsMapping = TypeMapping!(Timestamp, string,
        (Timestamp t) => "2024-01-15T00:00:00Z",
        (string s) => Timestamp(0));

    // POD type with mapped fields
    static struct DateRange {
        Timestamp start;
        Nullable!Timestamp end;
    }

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("name", string);

        // Plain method returning POD with mapped-type fields
        DateRange activePeriod() => DateRange(Timestamp(0), Nullable!Timestamp.init);
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    alias MappedSchema = ExternalTypesPlugin!(Schema!(Query), TsMapping);
    enum sdl = generateSchemaSDL!MappedSchema;
    static assert(sdl.canFind("activePeriod: DateRange!"), "Plain method returning POD type");
    static assert(sdl.canFind("type DateRange"), "POD type discovered");
    static assert(sdl.canFind("start: String!"), "POD field with mapped type → String!");
    static assert(sdl.canFind("end: String"), "Nullable POD field with mapped type → nullable String");
    static assert(!sdl.canFind("scalar Timestamp"), "Timestamp scalar should not appear");
}

// Introspection reflects mapped types
unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dunamis.core;
    import dunamis.core.types : TypeMapping;
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import dunamis.graphql.schema : Schema;
    import dunamis.graphql.compiler : compileQuery;

    static struct Date {
        int year, month, day;
    }

    alias DateMapping = TypeMapping!(Date, string,
        (Date d) => "2024-01-15",
        (string s) => Date(2024, 1, 15));

    static MockDB!() db;

    @DemoEntity!(db, "events")
    static struct Event {
        mixin DemoId;
        mixin Col!("title", string);

        Date startDate() => Date(2024, 1, 15);
    }

    static struct Query {
        mixin Table!(Event, "events");
    }

    alias MappedSchema = ExternalTypesPlugin!(Schema!(Query), DateMapping);

    db = new MockDB!();

    auto executor = new Executor();

    auto query = compileQuery!MappedSchema(`{
        __type(name: "Event") {
            fields {
                name
                type { name kind ofType { name } }
            }
        }
    }`);

    auto result = awaitSync(executor.execute(query));
    auto fields = result["__type"]["fields"].array;

    bool foundStartDate = false;
    foreach (f; fields) {
        if (f["name"].str == "startDate") {
            foundStartDate = true;
            // Should be NON_NULL wrapping String (mapped from Date)
            assert(f["type"]["kind"].str == "NON_NULL");
            assert(f["type"]["ofType"]["name"].str == "String");
        }
    }
    assert(foundStartDate, "startDate field should be in introspection");
}

// Input deserialization through mapping
unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dunamis.core;
    import dunamis.core.expr : Expr, effect;
    import dunamis.core.types : TypeMapping;
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import dunamis.relational.eval_context;
    import dunamis.graphql.schema : Schema;
    import dunamis.graphql.compiler : compileQuery;

    static struct Date {
        int year, month, day;
    }

    alias DateMapping = TypeMapping!(Date, string,
        function string(Date d) {
            import std.conv : to;
            return d.year.to!string ~ "-" ~ d.month.to!string ~ "-" ~ d.day.to!string;
        },
        function Date(string s) {
            import std.conv : to;
            import std.array : split;
            auto parts = s.split("-");
            return Date(parts[0].to!int, parts[1].to!int, parts[2].to!int);
        });

    __gshared static Date capturedDate;

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("name", string);

        static auto eventsAfter(Expr!User u, Date since) {
            return effect(() {
                capturedDate = since;
                return "ok";
            }, u);
        }
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    alias MappedSchema = ExternalTypesPlugin!(Schema!(Query), DateMapping);

    db = new MockDB!();
    db.setTableData("users", `[{"id": 1, "name": "Alice"}]`);

    // Pass a string argument that should be deserialized to Date via mapping
    auto query = compileQuery!MappedSchema(`{
        users {
            eventsAfter(since: "2024-6-15")
        }
    }`);

    auto executor = new Executor();
    auto result = awaitSync(executor.execute(query));

    auto users = result["users"].array;
    assert(users.length == 1);
    assert(users[0]["eventsAfter"].str == "ok");
    // Verify the Date was properly deserialized from the string
    assert(capturedDate.year == 2024);
    assert(capturedDate.month == 6);
    assert(capturedDate.day == 15);
}
