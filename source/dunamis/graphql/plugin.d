/// Schema extension/plugin infrastructure.
///
/// Plugins transform schemas via template composition:
/// ---
/// alias FinalSchema = Plugin1!(Plugin2!BaseSchema);
/// ---
///
/// A plugin is a template that consumes a schema and produces a new schema.
/// This module provides building blocks for writing plugins.
module dunamis.graphql.plugin;

import std.traits : Parameters, ReturnType, hasUDA;

import dunamis.core.expr : Expr, ExprResultType, isExpr;

// Re-export commonly needed schema utilities
public import dunamis.graphql.schema : isSchema, getFields, FieldInfo, isInternalMember;

// ============================================================================
// Field Introspection
// ============================================================================

/// Get all field member names from a type (excluding internal members).
/// Returns a compile-time array of member names that are valid field methods.
///
/// Example:
/// ---
/// static foreach (member; getFieldMembers!Query) {
///     // member is "users", "posts", etc.
/// }
/// ---
template getFieldMembers(T) {
    enum getFieldMembers = () {
        string[] members;
        static foreach (member; __traits(allMembers, T)) {
            static if (!isInternalMember!member) {
                static if (__traits(compiles, __traits(getMember, T, member)) &&
                           is(typeof(__traits(getMember, T, member)) == function)) {
                    members ~= member;
                }
            }
        }
        return members;
    }();
}

/// Check if a member is a computed field (static method taking Expr!T as first parameter).
/// Computed fields can be forwarded via ForwardField mixin.
/// Plain methods (instance methods with no Expr parameter) should use ForwardPlainMethod instead.
template isComputedField(T, string member) {
    static if (__traits(compiles, __traits(getMember, T, member)) &&
               is(typeof(__traits(getMember, T, member)) == function)) {
        alias fn = __traits(getMember, T, member);
        alias Params = Parameters!fn;
        static if (Params.length >= 1) {
            enum isComputedField = isExpr!(Params[0]);
        } else {
            enum isComputedField = false;
        }
    } else {
        enum isComputedField = false;
    }
}

/// Check if a function returns an array type (wrapped in Expr).
/// Useful for identifying fields that can be paginated.
///
/// Note: String types are NOT considered arrays, even though D's `string`
/// is technically `immutable(char)[]`. This matches GraphQL semantics where
/// String is a scalar, not a list.
///
/// Example:
/// ---
/// alias fn = __traits(getMember, Query, "users");
/// static if (isArrayReturningField!fn) {
///     // This field returns [Entity!]!
/// }
/// ---
template isArrayReturningField(alias fn) {
    static if (is(typeof(fn) == function)) {
        alias Return = ReturnType!fn;
        static if (isExpr!Return) {
            alias ResultType = ExprResultType!Return;
            // Check if it's an array but NOT a string type
            // (string is immutable(char)[] in D, but it's a scalar in GraphQL)
            static if (is(ResultType : U[], U)) {
                import std.traits : isSomeString;
                enum isArrayReturningField = !isSomeString!ResultType;
            } else {
                enum isArrayReturningField = false;
            }
        } else {
            enum isArrayReturningField = false;
        }
    } else {
        enum isArrayReturningField = false;
    }
}

/// Extract the element type from an array-returning field.
/// Only valid when isArrayReturningField is true.
template ArrayFieldElementType(alias fn) {
    static assert(isArrayReturningField!fn, "Not an array-returning field");
    alias Return = ReturnType!fn;
    alias ResultType = ExprResultType!Return;
    static if (is(ResultType : U[], U)) {
        alias ArrayFieldElementType = U;
    }
}

// ============================================================================
// Identity TypeMap
// ============================================================================

/// Identity type map - returns types unchanged.
/// Used as the default TypeMap for forwarding mixins.
template IdentityTypeMap(T) {
    alias IdentityTypeMap = T;
}

// ============================================================================
// Field Forwarding
// ============================================================================

/// Mixin template to forward a single field from SourceType.
/// Preserves UDAs from the source field and handles type conversion
/// for the first parameter (Expr!SourceType -> Expr!TargetType).
///
/// When TypeMap is provided, entity type references in the return value
/// are remapped via wrapEntityResult. With the default IdentityTypeMap,
/// this is a compile-time no-op.
///
/// Example:
/// ---
/// struct ExtendedQuery {
///     mixin ForwardField!(OriginalQuery, "users");
///     // Now ExtendedQuery.users(Expr!ExtendedQuery) delegates to
///     // OriginalQuery.users(Expr!OriginalQuery) with automatic type casting
/// }
/// ---
mixin template ForwardField(SourceType, string fieldName, alias TypeMap = IdentityTypeMap) {
    import std.traits : Parameters, ParameterDefaults, ParameterIdentifierTuple;
    import std.meta : AliasSeq;
    import std.conv : to;
    import dunamis.core.expr : Expr, ExprResultType, entityCast;
    import dunamis.graphql.transform : wrapEntityResult;

    // Get the source function and its metadata
    alias _srcFn = __traits(getMember, SourceType, fieldName);
    alias _SrcParams = Parameters!_srcFn;
    alias _SrcDefaults = ParameterDefaults!_srcFn;
    enum string[] _srcParamNames = [ParameterIdentifierTuple!_srcFn];

    // Extract the source entity type from first parameter
    alias _SrcFirstParam = _SrcParams[0];
    alias _SrcEntity = ExprResultType!_SrcFirstParam;

    // Create type aliases for each parameter to avoid stringof scope issues.
    // This ensures types like NodeInput* are properly referenced.
    static foreach (i; 1 .. _SrcParams.length) {
        mixin("alias _ParamType" ~ i.to!string ~ " = _SrcParams[" ~ i.to!string ~ "];");
    }

    // Build parameter list string at compile time
    // First param: Expr!(typeof(this)) instead of Expr!SourceType
    // Rest: use the generated _ParamTypeN aliases
    enum string _paramListStr = () {
        string result = "Expr!(typeof(this)) " ~ _srcParamNames[0];
        static foreach (i; 1 .. _SrcParams.length) {{
            result ~= ", ";
            result ~= "_ParamType" ~ i.to!string ~ " " ~ _srcParamNames[i];
            // Add default value if present
            static if (!is(_SrcDefaults[i] == void)) {
                result ~= " = _SrcDefaults[" ~ i.to!string ~ "]";
            }
        }}
        return result;
    }();

    // Build argument list string for calling original function
    // First arg: entityCast to convert Expr!(typeof(this)) -> Expr!SourceType
    // Rest: pass through unchanged
    enum string _argListStr = () {
        string result = "entityCast!(_SrcEntity)(" ~ _srcParamNames[0] ~ ")";
        static foreach (i; 1 .. _SrcParams.length) {
            result ~= ", " ~ _srcParamNames[i];
        }
        return result;
    }();

    // Generate the forwarding method with UDAs preserved
    // wrapEntityResult remaps entity types via TypeMap (no-op for IdentityTypeMap)
    @(__traits(getAttributes, _srcFn))
    mixin("static auto " ~ fieldName ~ "(" ~ _paramListStr ~ ") { " ~
          "return wrapEntityResult!(TypeMap)(_srcFn(" ~ _argListStr ~ ")); }");
}

/// Mixin template to forward a plain method from a source type.
/// Plain methods are instance methods that don't take Expr parameters.
///
/// Example:
/// ---
/// struct User {
///     string displayName() { return "name"; }  // Plain method
/// }
///
/// struct FilteredUser {
///     mixin ForwardPlainMethod!(User, "displayName");
///     // Now FilteredUser.displayName() calls User.displayName()
/// }
/// ---
mixin template ForwardPlainMethod(SourceType, string methodName, alias TypeMap = IdentityTypeMap) {
    import std.traits : ReturnType;

    alias _srcMethod = __traits(getMember, SourceType, methodName);
    alias _RetType = ReturnType!_srcMethod;

    // Generate the forwarding method with UDAs preserved
    @(__traits(getAttributes, _srcMethod))
    mixin("_RetType " ~ methodName ~ "() { " ~
          "return (cast(SourceType*) &this)." ~ methodName ~ "(); }");
}

/// Mixin template to copy all fields from SourceType.
/// This creates forwarding methods for every field in the source.
/// Handles both computed fields (via ForwardField) and plain methods (via ForwardPlainMethod).
///
/// Example:
/// ---
/// struct ExtendedQuery {
///     mixin CopyFields!OriginalQuery;
///     // Now has all fields from OriginalQuery
///
///     // Add new fields
///     static auto apiVersion(Expr!ExtendedQuery q) { ... }
/// }
/// ---
mixin template CopyFields(SourceType, alias TypeMap = IdentityTypeMap) {
    import dunamis.graphql.plugin : getFieldMembers, ForwardField, ForwardPlainMethod, isComputedField;

    static foreach (member; getFieldMembers!SourceType) {
        static if (isComputedField!(SourceType, member)) {
            mixin ForwardField!(SourceType, member, TypeMap);
        } else {
            mixin ForwardPlainMethod!(SourceType, member, TypeMap);
        }
    }
}

/// Mixin template to wrap all fields from SourceType with type substitution and
/// plugin-specific array field handling.
///
/// This is the common skeleton for plugin entity/Query/Mutation wrapping:
/// 1. Copy _normalizedSource (if present on SourceType)
/// 2. Copy plain fields (struct instance fields, including @PrimaryKey)
/// 3. Dispatch fields: arrays → ArrayFieldMixin, computed → ForwardField,
///    plain methods → ForwardPlainMethod
///
/// Example:
/// ---
/// template SortedEntity(Entity) {
///     @GqlName(getGraphQLTypeName!Entity)
///     struct SortedEntity {
///         mixin WrapFields!(Entity, EntityTypeMap, SortedArrayField);
///     }
/// }
/// ---
mixin template WrapFields(SourceType, alias TypeMap, alias ArrayFieldMixin) {
    import dunamis.core.types : isPlainField;
    import dunamis.graphql.plugin : getFieldMembers, isComputedField, isArrayReturningField,
        ForwardField, ForwardPlainMethod;

    // 1. Copy _normalizedSource (carries original entity data through plugin chain)
    static if (__traits(hasMember, SourceType, "_normalizedSource")) {
        typeof(SourceType._normalizedSource) _normalizedSource;
    }

    // 2. Copy plain fields (struct instance fields, including @PrimaryKey)
    static foreach (member; __traits(allMembers, SourceType)) {
        static if (isPlainField!(SourceType, member)) {
            mixin("typeof(__traits(getMember, SourceType.init, \"" ~ member ~ "\")) " ~ member ~ ";");
        }
    }

    // 3. Field iteration with dispatch
    static foreach (member; getFieldMembers!SourceType) {
        static if (isArrayReturningField!(__traits(getMember, SourceType, member))) {
            mixin ArrayFieldMixin!(SourceType, member, TypeMap);
        } else static if (isComputedField!(SourceType, member)) {
            mixin ForwardField!(SourceType, member, TypeMap);
        } else {
            mixin ForwardPlainMethod!(SourceType, member, TypeMap);
        }
    }
}

// ============================================================================
// Field Normalization
// ============================================================================

/// Mixin template that normalizes ALL fields of SourceType to static Expr methods.
///
/// Computed fields (static methods taking Expr!SourceType) are forwarded as-is.
/// Plain fields and plain methods are wrapped via `use()` to read from
/// `_normalizedSource`, which carries the original entity data.
///
/// After normalization, every field is a static method `(Expr!Self) -> Expr!T`,
/// so downstream consumers (schema generator, compiler, plugins) only need
/// one code path.
///
/// When TypeMap is provided, entity type references in return values are
/// remapped (e.g., stats() → Expr!NormalizedUserStats). With the default
/// IdentityTypeMap, this is a compile-time no-op.
///
/// Example:
/// ---
/// struct NormalizedUser {
///     mixin NormalizeFields!User;
///     // Now has:
///     //   _normalizedSource: User
///     //   static auto firstName(Expr!NormalizedUser) -> Expr!string  (forwarded)
///     //   static auto nickname(Expr!NormalizedUser) -> Expr!(Nullable!string)  (from plain field)
///     //   static auto displayName(Expr!NormalizedUser) -> Expr!string  (from plain method)
/// }
/// ---
mixin template NormalizeFields(SourceType, alias TypeMap = IdentityTypeMap) {
    import dunamis.core.expr : Expr, use;
    import dunamis.core.types : isPlainField, isPlainMethod, hasPrimaryKeyAttr;
    import dunamis.graphql.plugin : getFieldMembers, isComputedField, ForwardField;
    import dunamis.graphql.transform : wrapEntityResult;

    // Store original struct for data access by normalized methods
    SourceType _normalizedSource;

    // Normalize @PrimaryKey plain fields first (so id appears before other fields)
    static foreach (_nf_member; __traits(allMembers, SourceType)) {
        static if (isPlainField!(SourceType, _nf_member) && hasPrimaryKeyAttr!(SourceType, _nf_member)) {
            mixin("private static auto _nf_read_" ~ _nf_member ~
                  "(typeof(this) _n) { return _n._normalizedSource." ~ _nf_member ~ "; }");
            @(__traits(getAttributes, __traits(getMember, SourceType, _nf_member)))
            mixin("static auto " ~ _nf_member ~
                  "(Expr!(typeof(this)) _self) { return wrapEntityResult!(TypeMap)(use(&_nf_read_" ~ _nf_member ~ ", _self)); }");
        }
    }

    // Forward computed fields (already static Expr methods)
    static foreach (_nf_member; getFieldMembers!SourceType) {
        static if (isComputedField!(SourceType, _nf_member)) {
            mixin ForwardField!(SourceType, _nf_member, TypeMap);
        }
    }

    // Normalize non-PK plain fields → static Expr methods
    static foreach (_nf_member; __traits(allMembers, SourceType)) {
        static if (isPlainField!(SourceType, _nf_member) && !hasPrimaryKeyAttr!(SourceType, _nf_member)) {
            // Helper: reads field from _normalizedSource
            mixin("private static auto _nf_read_" ~ _nf_member ~
                  "(typeof(this) _n) { return _n._normalizedSource." ~ _nf_member ~ "; }");
            // Public method with UDAs preserved from source field
            // wrapEntityResult remaps entity types via TypeMap (no-op for IdentityTypeMap)
            @(__traits(getAttributes, __traits(getMember, SourceType, _nf_member)))
            mixin("static auto " ~ _nf_member ~
                  "(Expr!(typeof(this)) _self) { return wrapEntityResult!(TypeMap)(use(&_nf_read_" ~ _nf_member ~ ", _self)); }");
        }
    }

    // Normalize plain methods → static Expr methods
    static foreach (_nf_member; getFieldMembers!SourceType) {
        static if (!isComputedField!(SourceType, _nf_member)) {
            // Helper: calls method on _normalizedSource
            mixin("private static auto _nf_call_" ~ _nf_member ~
                  "(typeof(this) _n) { return _n._normalizedSource." ~ _nf_member ~ "(); }");
            // Public method with UDAs preserved from source method
            // wrapEntityResult remaps entity types via TypeMap (no-op for IdentityTypeMap)
            @(__traits(getAttributes, __traits(getMember, SourceType, _nf_member)))
            mixin("static auto " ~ _nf_member ~
                  "(Expr!(typeof(this)) _self) { return wrapEntityResult!(TypeMap)(use(&_nf_call_" ~ _nf_member ~ ", _self)); }");
        }
    }
}

// ============================================================================
// Normalize Plugin
// ============================================================================

/// Internal plugin that normalizes entity types (those with @PrimaryKey) to use
/// only static Expr methods. Plain fields and plain methods are converted to
/// computed fields via `use()`, making all field access uniform for entities.
///
/// POD types (structs without @PrimaryKey) are left unchanged — they keep their
/// plain fields/methods and remain compatible with ExternalTypesPlugin.
///
/// Used internally by Schema to normalize types before external plugins
/// are applied.
template NormalizePlugin(RawQuery, RawMutation) {
    import std.meta : staticMap;
    import dunamis.graphql.schema : getAllObjectTypes, getGraphQLTypeName, GqlName;
    import dunamis.graphql.transform : isTypeInList;

    // Discover all entity and POD types reachable from the Query root
    alias _AllTypes = getAllObjectTypes!RawQuery;

    // Create normalized version of each discovered type
    template _NormalizedType(T) {
        @(__traits(getAttributes, T))
        @GqlName(getGraphQLTypeName!T)
        struct _NormalizedType {
            mixin NormalizeFields!(T, _TypeMap);
        }
    }

    // Map entity types (with @PrimaryKey) to normalized versions.
    // POD types pass through unchanged — they keep plain fields/methods
    // and remain compatible with ExternalTypesPlugin type mappings.
    template _TypeMap(T) {
        import dunamis.core.types : hasPrimaryKey;
        static if (isTypeInList!(T, _AllTypes) && hasPrimaryKey!T) {
            alias _TypeMap = _NormalizedType!T;
        } else {
            alias _TypeMap = T;
        }
    }

    // Wrap Query: forward all fields with type remapping
    struct Query {
        mixin WrapFields!(RawQuery, _TypeMap, ForwardField);
    }

    // Wrap Mutation: forward all fields with type remapping
    struct Mutation {
        mixin WrapFields!(RawMutation, _TypeMap, ForwardField);
    }
}

// ============================================================================
// Plugin Helpers
// ============================================================================

/// Helper to check if a type has a specific field by name.
template hasField(T, string fieldName) {
    enum hasField = () {
        static foreach (member; getFieldMembers!T) {
            if (member == fieldName)
                return true;
        }
        return false;
    }();
}

/// Count the number of fields in a type.
template fieldCount(T) {
    enum fieldCount = getFieldMembers!T.length;
}

// ============================================================================
// Unit Tests
// ============================================================================

// Test getFieldMembers template
unittest {
    import dunamis.core.expr : Expr;

    static struct TestQuery {
        static auto foo(Expr!TestQuery q) { return q; }
        static auto bar(Expr!TestQuery q) { return q; }
        // _underscore members should be filtered out (internal member)
        int _internal;
    }

    enum members = getFieldMembers!TestQuery;
    static assert(members.length == 2);
    static assert(members[0] == "foo" || members[1] == "foo");
    static assert(members[0] == "bar" || members[1] == "bar");
}

// Test isArrayReturningField template
unittest {
    import dunamis.relational.schema;
    import dunamis.relational.demo;

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("name", string);
    }

    static struct Query {
        mixin Table!(User, "users");

        // Non-array field
        static auto version_(Expr!Query q) {
            import dunamis.core.expr : constant;
            return constant("1.0", q);
        }
    }

    // Table field returns [User!]! - should be array
    alias usersFn = __traits(getMember, Query, "users");
    static assert(isArrayReturningField!usersFn, "users should be array-returning");

    // Scalar field returns String! - should not be array
    alias versionFn = __traits(getMember, Query, "version_");
    static assert(!isArrayReturningField!versionFn, "version_ should not be array-returning");
}

// Test ArrayFieldElementType
unittest {
    import dunamis.relational.schema;
    import dunamis.relational.demo;

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("name", string);
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    alias usersFn = __traits(getMember, Query, "users");
    static assert(is(ArrayFieldElementType!usersFn == User));
}

// Test Identity Plugin pattern
unittest {
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import dunamis.graphql.schema : Schema, generateSchemaSDL;

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("name", string);
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    alias BaseSchema = Schema!Query;

    // Identity plugin - passes through unchanged
    template IdentityPlugin(alias S) if (isSchema!S) {
        alias Query = S.Query;
        alias Mutation = S.Mutation;
    }

    alias TransformedSchema = IdentityPlugin!BaseSchema;

    // Verify it's still a valid schema
    static assert(isSchema!TransformedSchema);

    // Verify SDL is unchanged
    enum baseSdl = generateSchemaSDL!BaseSchema;
    enum transformedSdl = generateSchemaSDL!TransformedSchema;
    static assert(baseSdl == transformedSdl);
}

// Test CopyFields mixin
unittest {
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import dunamis.graphql.schema : Schema, generateSchemaSDL;
    import dunamis.core.expr : constant;
    import std.algorithm : canFind;

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("name", string);
    }

    static struct OriginalQuery {
        mixin Table!(User, "users");
    }

    // Extended Query using CopyFields
    static struct ExtendedQuery {
        mixin CopyFields!OriginalQuery;

        // Add new field
        static auto apiVersion(Expr!ExtendedQuery q) {
            return constant("1.0", q);
        }
    }

    alias OriginalSchema = Schema!OriginalQuery;
    alias ExtendedSchema = Schema!ExtendedQuery;

    // Verify both are valid schemas
    static assert(isSchema!OriginalSchema);
    static assert(isSchema!ExtendedSchema);

    // Verify original has users field
    enum originalSdl = generateSchemaSDL!OriginalSchema;
    static assert(originalSdl.canFind("users:"));

    // Verify extended has both users and apiVersion
    enum extendedSdl = generateSchemaSDL!ExtendedSchema;
    static assert(extendedSdl.canFind("users:"));
    static assert(extendedSdl.canFind("apiVersion:"));
}

// Test Add Field Plugin
unittest {
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import dunamis.graphql.schema : Schema, generateSchemaSDL;
    import dunamis.core.expr : constant;
    import std.algorithm : canFind;

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("name", string);
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    alias BaseSchema = Schema!Query;

    // Plugin that adds a version field
    template AddVersionPlugin(alias S) if (isSchema!S) {
        struct ExtendedQuery {
            mixin CopyFields!(S.Query);

            static auto apiVersion(Expr!ExtendedQuery q) {
                return constant("2.0", q);
            }
        }

        alias Query = ExtendedQuery;
        alias Mutation = S.Mutation;
    }

    alias WithVersion = AddVersionPlugin!BaseSchema;

    static assert(isSchema!WithVersion);

    enum sdl = generateSchemaSDL!WithVersion;
    static assert(sdl.canFind("apiVersion:"));
    static assert(sdl.canFind("users:"));
}

// Test Plugin Composition with CopyFields
unittest {
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import dunamis.graphql.schema : Schema, generateSchemaSDL;
    import dunamis.core.expr : constant;
    import std.algorithm : canFind;

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("name", string);
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    alias BaseSchema = Schema!Query;

    // Plugin 1: Adds version field using CopyFields
    template AddVersionPlugin(alias S) if (isSchema!S) {
        struct ExtendedQuery {
            mixin CopyFields!(S.Query);

            static auto apiVersion(Expr!ExtendedQuery q) {
                return constant("1.0", q);
            }
        }
        alias Query = ExtendedQuery;
        alias Mutation = S.Mutation;
    }

    // Plugin 2: Adds health check field using CopyFields
    template AddHealthPlugin(alias S) if (isSchema!S) {
        struct ExtendedQuery {
            mixin CopyFields!(S.Query);

            static auto health(Expr!ExtendedQuery q) {
                return constant("ok", q);
            }
        }
        alias Query = ExtendedQuery;
        alias Mutation = S.Mutation;
    }

    // Compose plugins: Schema -> AddVersion -> AddHealth
    alias Composed = AddHealthPlugin!(AddVersionPlugin!BaseSchema);

    static assert(isSchema!Composed);

    enum sdl = generateSchemaSDL!Composed;
    static assert(sdl.canFind("users:"), "Should have original users field");
    static assert(sdl.canFind("apiVersion:"), "Should have apiVersion from first plugin");
    static assert(sdl.canFind("health:"), "Should have health from second plugin");
}

// Test ForwardField preserves UDAs
unittest {
    import dunamis.graphql.schema : GqlDescription, GqlDeprecated, getGqlDescription, getGqlDeprecated;
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import std.traits : hasUDA;

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("name", string);
    }

    static struct OriginalQuery {
        @GqlDescription("List all users")
        @GqlDeprecated("Use usersV2 instead")
        mixin Table!(User, "users");
    }

    static struct ForwardedQuery {
        mixin ForwardField!(OriginalQuery, "users");
    }

    // Check UDAs are preserved on forwarded field
    alias forwardedFn = __traits(getMember, ForwardedQuery, "users");
    static assert(hasUDA!(forwardedFn, GqlDescription));
    static assert(hasUDA!(forwardedFn, GqlDeprecated));
}

// Test query compilation with plugin-transformed schema using CopyFields
unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dunamis.core;
    import dunamis.core.expr : constant;
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import dunamis.relational.eval_context;
    import dunamis.graphql.schema : Schema;
    import dunamis.graphql.compiler : compileQuery;

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("name", string);
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    alias BaseSchema = Schema!Query;

    // Plugin that adds a constant field using CopyFields
    // The EntityCastExpr handles the type conversion automatically
    template AddConstantPlugin(alias S) if (isSchema!S) {
        struct ExtendedQuery {
            // CopyFields now works for runtime compilation thanks to EntityCastExpr
            mixin CopyFields!(S.Query);

            static auto serverTime(Expr!ExtendedQuery q) {
                return constant("2024-01-01T00:00:00Z", q);
            }
        }
        alias Query = ExtendedQuery;
        alias Mutation = S.Mutation;
    }

    alias ExtendedSchema = AddConstantPlugin!BaseSchema;

    // Set up mock data
    db = new MockDB!();
    db.setTableData("users", `[
        {"id": 1, "name": "Alice"}
    ]`);

    // Compile and execute query against transformed schema
    auto query = compileQuery!ExtendedSchema(`{
        users { name }
        serverTime
    }`);

    auto result = awaitSync(new Executor().execute(query));

    // Verify both original and added fields work
    assert(result["users"][0]["name"].str == "Alice");
    assert(result["serverTime"].str == "2024-01-01T00:00:00Z");
}

// Test mock pagination plugin structure (schema-level only)
unittest {
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import dunamis.graphql.schema : Schema, generateSchemaSDL;
    import std.algorithm : canFind;
    import std.typecons : Nullable;

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("name", string);
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    alias BaseSchema = Schema!Query;

    // Mock pagination plugin - adds first/offset arguments to array fields
    // Note: This is a structural test only; actual pagination would require
    // additional expression nodes and optimizer support
    template MockPaginationPlugin(alias S) if (isSchema!S) {
        struct PaginatedQuery {
            // Manually define paginated version of users field
            // In a real plugin, this would be generated for all array fields
            static auto users(
                Expr!PaginatedQuery parent,
                Nullable!int first = Nullable!int.init,
                Nullable!int offset = Nullable!int.init
            ) {
                // For now, just delegate to original (pagination not implemented)
                import dunamis.relational.schema : getAll;
                return getAll!User();
            }
        }

        alias Query = PaginatedQuery;
        alias Mutation = S.Mutation;
    }

    alias PaginatedSchema = MockPaginationPlugin!BaseSchema;

    static assert(isSchema!PaginatedSchema);

    // Verify schema shows pagination arguments
    enum sdl = generateSchemaSDL!PaginatedSchema;
    static assert(sdl.canFind("users("));
    static assert(sdl.canFind("first:"));
    static assert(sdl.canFind("offset:"));
}

// Test hasField and fieldCount helpers
unittest {
    import dunamis.core.expr : Expr, constant;

    static struct TestQuery {
        static auto foo(Expr!TestQuery q) { return constant(1, q); }
        static auto bar(Expr!TestQuery q) { return constant(2, q); }
    }

    static assert(hasField!(TestQuery, "foo"));
    static assert(hasField!(TestQuery, "bar"));
    static assert(!hasField!(TestQuery, "baz"));
    static assert(fieldCount!TestQuery == 2);
}

// Test EntityCastExpr is actually evaluated at runtime
// This test uses a computed field that depends on the parent parameter,
// forcing the EntityCastExpr to be evaluated.
unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dunamis.core;
    import dunamis.core.expr : constant, entityCast, EntityCastExpr;
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import dunamis.relational.eval_context;
    import dunamis.graphql.schema : Schema;
    import dunamis.graphql.compiler : compileQuery;

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("name", string);
    }

    static struct Query {
        mixin Table!(User, "users");

        // Computed field that uses parent as length source
        // This forces the parent expression to be evaluated
        static auto greeting(Expr!Query q) {
            return constant("Hello from Query", q);
        }
    }

    alias BaseSchema = Schema!Query;

    // Plugin that forwards the greeting field via CopyFields
    template ForwardingPlugin(alias S) if (isSchema!S) {
        struct ExtendedQuery {
            mixin CopyFields!(S.Query);

            // Add another field that also uses parent
            static auto version_(Expr!ExtendedQuery q) {
                return constant("1.0", q);
            }
        }
        alias Query = ExtendedQuery;
        alias Mutation = S.Mutation;
    }

    alias ExtendedSchema = ForwardingPlugin!BaseSchema;

    // Set up mock data
    db = new MockDB!();
    db.setTableData("users", `[{"id": 1, "name": "Alice"}]`);

    // Query the forwarded greeting field
    // This will:
    // 1. Call ExtendedQuery.greeting(Expr!ExtendedQuery)
    // 2. Which calls entityCast!Query(parent) creating EntityCastExpr
    // 3. Then calls Query.greeting(EntityCastExpr)
    // 4. Query.greeting uses constant("Hello", q) where q is the EntityCastExpr
    // 5. ConstExpr uses q.evalResultLength() which calls EntityCastExpr.eval()
    auto query = compileQuery!ExtendedSchema(`{ greeting }`);
    auto result = awaitSync(new Executor().execute(query));

    // If EntityCastExpr.eval() wasn't working, this would fail
    assert(result["greeting"].str == "Hello from Query");
}

// Test EntityCastExpr directly
unittest {
    import ae.utils.promise.await : awaitSync;
    import dunamis.core;
    import dunamis.core.expr : singleton, entityCast, EntityCastExpr;
    import dunamis.relational.eval_context;

    // Simple structs to test casting
    static struct From {
        int value;
    }

    static struct To {
        int other;
    }

    // Create a singleton expression of type From
    auto fromExpr = singleton(From(42));

    // Cast it to To
    auto toExpr = entityCast!To(fromExpr);

    // Verify it's an EntityCastExpr
    static assert(is(typeof(toExpr) == EntityCastExpr!(To, From)));

    // Evaluate it
    auto ctx = new EvalContext();
    auto result = awaitSync(toExpr.eval(ctx));

    // Should have one result (singleton produces one item)
    assert(result.length == 1);
    // The value is default-initialized since these aren't entity types
    assert(result[0] == To.init);
}

// Test extending an entity type (not Query/Mutation) with a new computed field
// This exercises EntityCastExpr with actual entities that have @PrimaryKey id
unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dunamis.core;
    import dunamis.core.expr : constant;
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import dunamis.relational.eval_context;
    import dunamis.graphql.schema : Schema, generateSchemaSDL;
    import dunamis.graphql.compiler : compileQuery;
    import std.algorithm : canFind;

    static MockDB!() db;

    // Base User entity
    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("name", string);

        static auto greeting(Expr!User u) {
            return constant("Hello, ", u) ~ name(u);
        }
    }

    // Extended User with additional computed field
    @DemoEntity!(db, "users")  // Same table
    static struct ExtendedUser {
        mixin DemoId;

        // Copy fields from User
        mixin CopyFields!User;

        // Add new computed field
        static auto politeGreeting(Expr!ExtendedUser u) {
            return constant("Dear ", u) ~ name(u) ~ constant(", welcome!", u);
        }
    }

    // Query using ExtendedUser
    static struct Query {
        mixin Table!(ExtendedUser, "users");
    }

    alias MySchema = Schema!Query;

    // Verify schema contains both original and new field
    enum sdl = generateSchemaSDL!MySchema;
    static assert(sdl.canFind("greeting:"), "Should have original greeting field");
    static assert(sdl.canFind("politeGreeting:"), "Should have new politeGreeting field");

    // Set up mock data
    db = new MockDB!();
    db.setTableData("users", `[
        {"id": 1, "name": "Alice"},
        {"id": 2, "name": "Bob"}
    ]`);

    // Query both the original forwarded field and the new field
    auto query = compileQuery!MySchema(`{
        users {
            name
            greeting
            politeGreeting
        }
    }`);

    auto result = awaitSync(new Executor().execute(query));

    // Verify results
    assert(result["users"].array.length == 2);

    // Check Alice
    assert(result["users"][0]["name"].str == "Alice");
    assert(result["users"][0]["greeting"].str == "Hello, Alice");
    assert(result["users"][0]["politeGreeting"].str == "Dear Alice, welcome!");

    // Check Bob
    assert(result["users"][1]["name"].str == "Bob");
    assert(result["users"][1]["greeting"].str == "Hello, Bob");
    assert(result["users"][1]["politeGreeting"].str == "Dear Bob, welcome!");
}

// Test NormalizeFields mixin - schema generation
unittest {
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import dunamis.graphql.schema : Schema, generateSchemaSDL, GqlName, GqlDescription, GqlHidden;
    import std.algorithm : canFind;
    import std.typecons : Nullable;

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("firstName", string);

        // Plain field
        Nullable!string nickname;

        // Plain field with UDA
        @GqlDescription("User's age")
        int age;

        // Plain method
        string displayName() => "display";

        // Plain method with UDA
        @GqlDescription("Is the user active?")
        bool isActive() => true;

        // Computed field
        static auto fullName(Expr!User u) {
            import dunamis.core.expr : constant;
            return constant("full", u);
        }
    }

    // Normalized wrapper
    static struct NormalizedUser {
        mixin NormalizeFields!User;
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    alias MySchema = Schema!Query;
    enum sdl = generateSchemaSDL!MySchema;

    // All fields should appear in schema
    static assert(sdl.canFind("firstName:"), "Forwarded computed field");
    static assert(sdl.canFind("nickname:"), "Normalized plain field");
    static assert(sdl.canFind("age:"), "Normalized plain field with UDA");
    static assert(sdl.canFind("displayName:"), "Normalized plain method");
    static assert(sdl.canFind("isActive:"), "Normalized plain method with UDA");
    static assert(sdl.canFind("fullName:"), "Forwarded computed field");

    // UDA descriptions should be preserved
    static assert(sdl.canFind(`"User's age"`), "Description preserved on plain field");
    static assert(sdl.canFind(`"Is the user active?"`), "Description preserved on plain method");
}

