module dynamo.graphql.type_mapping;

import std.meta : AliasSeq;
import std.typecons : Nullable;
import dynamo.graphql.schema : isSchema;

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
        import dynamo.core.expr : ExprResultType, use;
        import dynamo.graphql.transform : wrapEntityResult;
        import dynamo.core.types : applySerialize;

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

/// Forward a computed field with value mapping applied to return type and arguments.
/// Like ForwardFieldWithTypeMap but also:
/// - Maps argument types (deserializes mapped args before forwarding)
/// - Maps return types (serializes after forwarding)
mixin template ForwardFieldWithMappings(SourceType, string fieldName, alias TypeMap, Mappings...) {
    import std.traits : Parameters, ParameterDefaults, ParameterIdentifierTuple;
    import std.conv : to;
    import dynamo.core.expr : Expr, ExprResultType, entityCast;
    import dynamo.core.types : applyDeserialize;

    alias _srcFn = __traits(getMember, SourceType, fieldName);
    alias _SrcParams = Parameters!_srcFn;
    alias _SrcDefaults = ParameterDefaults!_srcFn;
    enum string[] _srcParamNames = [ParameterIdentifierTuple!_srcFn];
    alias _SrcEntity = ExprResultType!(_SrcParams[0]);

    // Create resolved type aliases for each non-self parameter
    static foreach (i; 1 .. _SrcParams.length) {
        mixin("alias _vmParamType" ~ i.to!string ~
              " = ResolveValueType!(_SrcParams[" ~ i.to!string ~ "], Mappings);");
    }

    // Build parameter list with mapped types
    enum string _vm_paramListStr = () {
        string result = "Expr!(typeof(this)) " ~ _srcParamNames[0];
        static foreach (i; 1 .. _SrcParams.length) {{
            result ~= ", _vmParamType" ~ i.to!string ~ " " ~ _srcParamNames[i];
            // Preserve defaults only if type didn't change
            static if (!is(_SrcDefaults[i] == void)) {
                static if (is(ResolveValueType!(_SrcParams[i], Mappings) == _SrcParams[i])) {
                    result ~= " = _SrcDefaults[" ~ i.to!string ~ "]";
                }
            }
        }}
        return result;
    }();

    // Build argument list with entityCast and deserialization
    enum string _vm_argListStr = () {
        string result = "entityCast!(_SrcEntity)(" ~ _srcParamNames[0] ~ ")";
        static foreach (i; 1 .. _SrcParams.length) {{
            result ~= ", ";
            static if (!is(ResolveValueType!(_SrcParams[i], Mappings) == _SrcParams[i])) {
                // Type was mapped → deserialize before forwarding
                result ~= "applyDeserialize!(_vmParamType" ~ i.to!string ~
                          ", _SrcParams[" ~ i.to!string ~
                          "], findLeafMapping!(_SrcParams[" ~ i.to!string ~
                          "], Mappings).fromTarget)(" ~ _srcParamNames[i] ~ ")";
            } else {
                result ~= _srcParamNames[i];
            }
        }}
        return result;
    }();

    // Generate forwarding method: call source, apply result mappings
    @(__traits(getAttributes, _srcFn))
    mixin("static auto " ~ fieldName ~ "(" ~ _vm_paramListStr ~ ") { " ~
          "return applyMappingsToResult!(TypeMap, Mappings)(_srcFn(" ~ _vm_argListStr ~ ")); }");
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
/// import dynamo.core.types : TypeMapping;
///
/// alias MySchema = ExternalTypesPlugin!(
///     Schema!(Query, Mutation),
///     TypeMapping!(Date, string,
///         (Date d) => d.toISOExtString,
///         (string s) => Date.fromISOExtString(s)),
/// );
/// ---
template ExternalTypesPlugin(alias S, NewMappings...) if (isSchema!S) {
    import dynamo.core.expr : Expr, use;
    import dynamo.core.types : isPlainField, isPlainMethod, NoSchemaConfig;
    import dynamo.graphql.schema : getAllEntityTypes, getGraphQLTypeName, GqlName, isInternalMember;
    import dynamo.graphql.transform : isTypeInList;
    import dynamo.graphql.plugin : getFieldMembers, isComputedField;

    // Discover all object types from the inner schema's Query
    alias _OriginalQuery = S.Query;
    alias _AllTypes = getAllEntityTypes!_OriginalQuery;

    // TypeMap: route types to their wrapped versions.
    // - Directly-mapped types (Date→string): identity (serialized at call site)
    // - Entity/POD types in the schema: wrapped with value mapping
    // - Everything else: identity
    template _TypeMap(T) {
        static if (hasDirectMapping!(T, NewMappings)) {
            alias _TypeMap = T; // Directly mapped → don't wrap, serialize at call site
        } else static if (isTypeInList!(T, _AllTypes)) {
            alias _TypeMap = _MappedType!T; // Wrap with value mapping
        } else {
            alias _TypeMap = T; // Not in type list → pass through
        }
    }

    // Create wrapped version of each discovered type.
    // For entity types (with nodeId): all fields are already static Expr methods
    //   (from Schema's NormalizePlugin), so just forward with value mapping.
    // For POD types: normalize plain fields/methods + apply value mapping.
    template _MappedType(T) {
        @GqlName(getGraphQLTypeName!T)
        struct _MappedType {
            // Entity infrastructure
            static if (__traits(hasMember, T, "nodeId")) {
                typeof(T.nodeId) nodeId;
                this(string id) { nodeId = typeof(nodeId)(id); }
                string toString() const { return nodeId.toString(); }
            }

            // Carry _normalizedSource through plugin chain
            static if (__traits(hasMember, T, "_normalizedSource")) {
                typeof(T._normalizedSource) _normalizedSource;
            } else static if (!__traits(hasMember, T, "nodeId")) {
                // POD type: needs _normalizedSource for normalization
                T _normalizedSource;
            }

            // Forward computed fields with value mapping
            static foreach (_m; getFieldMembers!T) {
                static if (isComputedField!(T, _m)) {
                    mixin ForwardFieldWithMappings!(T, _m, _TypeMap, NewMappings);
                }
            }

            // Normalize plain fields with value mapping (POD types)
            static foreach (_m; __traits(allMembers, T)) {
                static if (!isInternalMember!_m && isPlainField!(T, _m)) {
                    // Helper: reads field from _normalizedSource
                    mixin("private static auto _nf_read_" ~ _m ~
                          "(typeof(this) _n) { return _n._normalizedSource." ~ _m ~ "; }");
                    // Public method: read + apply entity/value mappings
                    @(__traits(getAttributes, __traits(getMember, T, _m)))
                    mixin("static auto " ~ _m ~
                          "(Expr!(typeof(this)) _self) { " ~
                          "return applyMappingsToResult!(_TypeMap, NewMappings)(use(&_nf_read_" ~ _m ~ ", _self)); }");
                }
            }

            // Normalize plain methods with value mapping (POD types)
            static foreach (_m; getFieldMembers!T) {
                static if (!isComputedField!(T, _m)) {
                    // Helper: calls method on _normalizedSource
                    mixin("private static auto _nf_call_" ~ _m ~
                          "(typeof(this) _n) { return _n._normalizedSource." ~ _m ~ "(); }");
                    // Public method: call + apply entity/value mappings
                    @(__traits(getAttributes, __traits(getMember, T, _m)))
                    mixin("static auto " ~ _m ~
                          "(Expr!(typeof(this)) _self) { " ~
                          "return applyMappingsToResult!(_TypeMap, NewMappings)(use(&_nf_call_" ~ _m ~ ", _self)); }");
                }
            }
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

    alias Config = NoSchemaConfig;
}

// ============================================================================
// Unit Tests
// ============================================================================

// SDL generation: mapped types in plain methods and computed field args
unittest {
    import std.algorithm : canFind;
    import std.typecons : Nullable;
    import dynamo.core.types : TypeMapping;
    import dynamo.graphql.schema : Schema, generateSchemaSDL;
    import dynamo.relational.demo : DemoEntity, MockDB;
    import dynamo.relational.schema : Col, Table;
    import dynamo.core.expr : Expr;

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

    static struct Event {
        mixin DemoEntity!(db, "events");
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
    import dynamo.core.types : TypeMapping;
    import dynamo.graphql.schema : Schema, generateSchemaSDL;
    import dynamo.relational.demo : DemoEntity, MockDB;
    import dynamo.relational.schema : Col, Table;
    import dynamo.core.expr : Expr;

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

    static struct User {
        mixin DemoEntity!(db, "users");
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
    import dynamo.core;
    import dynamo.core.types : TypeMapping;
    import dynamo.relational.schema;
    import dynamo.relational.demo;
    import dynamo.graphql.schema : Schema;
    import dynamo.graphql.compiler : compileQuery;

    static struct Date {
        int year, month, day;
    }

    alias DateMapping = TypeMapping!(Date, string,
        (Date d) => "2024-01-15",
        (string s) => Date(2024, 1, 15));

    static MockDB!() db;

    static struct Event {
        mixin DemoEntity!(db, "events");
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
    import dynamo.core;
    import dynamo.core.expr : Expr, effect;
    import dynamo.core.types : TypeMapping;
    import dynamo.relational.schema;
    import dynamo.relational.demo;
    import dynamo.relational.eval_context;
    import dynamo.graphql.schema : Schema;
    import dynamo.graphql.compiler : compileQuery;

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

    static struct User {
        mixin DemoEntity!(db, "users");
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
