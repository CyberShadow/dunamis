/// Schema extension/plugin infrastructure.
///
/// Plugins transform schemas via template composition:
/// ---
/// alias FinalSchema = Plugin1!(Plugin2!BaseSchema);
/// ---
///
/// A plugin is a template that consumes a schema and produces a new schema.
/// This module provides building blocks for writing plugins.
module dynamo.graphql.plugin;

import std.traits : Parameters, ReturnType, hasUDA;

import dynamo.core.expr : Expr, ExprResultType, isExpr;

// Re-export commonly needed schema utilities
public import dynamo.graphql.schema : isSchema, getFields, FieldInfo, isInternalMember;

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
// Field Forwarding
// ============================================================================

/// Mixin template to forward a single field from SourceType.
/// Preserves UDAs from the source field and handles type conversion
/// for the first parameter (Expr!SourceType -> Expr!TargetType).
///
/// Example:
/// ---
/// struct ExtendedQuery {
///     mixin ForwardField!(OriginalQuery, "users");
///     // Now ExtendedQuery.users(Expr!ExtendedQuery) delegates to
///     // OriginalQuery.users(Expr!OriginalQuery) with automatic type casting
/// }
/// ---
mixin template ForwardField(SourceType, string fieldName) {
    import std.traits : Parameters, ParameterDefaults, ParameterIdentifierTuple;
    import std.meta : AliasSeq;
    import std.conv : to;
    import dynamo.core.expr : Expr, ExprResultType, entityCast;

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
    @(__traits(getAttributes, _srcFn))
    mixin("static auto " ~ fieldName ~ "(" ~ _paramListStr ~ ") { " ~
          "return _srcFn(" ~ _argListStr ~ "); }");
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
mixin template ForwardPlainMethod(SourceType, string methodName) {
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
mixin template CopyFields(SourceType) {
    import dynamo.graphql.plugin : getFieldMembers, ForwardField, ForwardPlainMethod, isComputedField;

    static foreach (member; getFieldMembers!SourceType) {
        static if (isComputedField!(SourceType, member)) {
            mixin ForwardField!(SourceType, member);
        } else {
            mixin ForwardPlainMethod!(SourceType, member);
        }
    }
}

/// Mixin template to wrap all fields from SourceType with type substitution and
/// plugin-specific array field handling.
///
/// This is the common skeleton for plugin entity/Query/Mutation wrapping:
/// 1. Copy nodeId + constructor + toString (if present on SourceType)
/// 2. Copy plain fields (struct instance fields)
/// 3. Dispatch fields: arrays → ArrayFieldMixin, computed → ForwardFieldWithTypeMap,
///    plain methods → ForwardPlainMethodWithTypeMap
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
    import dynamo.core.types : isPlainField;
    import dynamo.graphql.plugin : getFieldMembers, isComputedField, isArrayReturningField;
    import dynamo.graphql.transform : ForwardFieldWithTypeMap, ForwardPlainMethodWithTypeMap;

    // 1. Copy entity infrastructure (nodeId)
    static if (__traits(hasMember, SourceType, "nodeId")) {
        typeof(SourceType.nodeId) nodeId;
        this(string id) { nodeId = typeof(nodeId)(id); }
        string toString() const { return nodeId.toString(); }
    }

    // 2. Copy plain fields (struct instance fields)
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
            mixin ForwardFieldWithTypeMap!(SourceType, member, TypeMap);
        } else {
            mixin ForwardPlainMethodWithTypeMap!(SourceType, member, TypeMap);
        }
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
    import dynamo.core.expr : Expr;

    static struct TestQuery {
        static auto foo(Expr!TestQuery q) { return q; }
        static auto bar(Expr!TestQuery q) { return q; }
        // nodeId should be filtered out (internal member)
        int nodeId;
    }

    enum members = getFieldMembers!TestQuery;
    static assert(members.length == 2);
    static assert(members[0] == "foo" || members[1] == "foo");
    static assert(members[0] == "bar" || members[1] == "bar");
}

// Test isArrayReturningField template
unittest {
    import dynamo.relational.schema;
    import dynamo.relational.demo;

    static MockDB!() db;

    static struct User {
        mixin DemoEntity!(db, "users");
        mixin Col!("name", string);
    }

    static struct Query {
        mixin Table!(User, "users");

        // Non-array field
        static auto version_(Expr!Query q) {
            import dynamo.core.expr : constant;
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
    import dynamo.relational.schema;
    import dynamo.relational.demo;

    static MockDB!() db;

    static struct User {
        mixin DemoEntity!(db, "users");
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
    import dynamo.relational.schema;
    import dynamo.relational.demo;
    import dynamo.graphql.schema : Schema, generateSchemaSDL;

    static MockDB!() db;

    static struct User {
        mixin DemoEntity!(db, "users");
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
        alias Config = S.Config;
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
    import dynamo.relational.schema;
    import dynamo.relational.demo;
    import dynamo.graphql.schema : Schema, generateSchemaSDL;
    import dynamo.core.expr : constant;
    import std.algorithm : canFind;

    static MockDB!() db;

    static struct User {
        mixin DemoEntity!(db, "users");
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
    import dynamo.relational.schema;
    import dynamo.relational.demo;
    import dynamo.graphql.schema : Schema, generateSchemaSDL;
    import dynamo.core.expr : constant;
    import std.algorithm : canFind;

    static MockDB!() db;

    static struct User {
        mixin DemoEntity!(db, "users");
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
        alias Config = S.Config;
    }

    alias WithVersion = AddVersionPlugin!BaseSchema;

    static assert(isSchema!WithVersion);

    enum sdl = generateSchemaSDL!WithVersion;
    static assert(sdl.canFind("apiVersion:"));
    static assert(sdl.canFind("users:"));
}

// Test Plugin Composition with CopyFields
unittest {
    import dynamo.relational.schema;
    import dynamo.relational.demo;
    import dynamo.graphql.schema : Schema, generateSchemaSDL;
    import dynamo.core.expr : constant;
    import std.algorithm : canFind;

    static MockDB!() db;

    static struct User {
        mixin DemoEntity!(db, "users");
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
        alias Config = S.Config;
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
        alias Config = S.Config;
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
    import dynamo.graphql.schema : GqlDescription, GqlDeprecated, getGqlDescription, getGqlDeprecated;
    import dynamo.relational.schema;
    import dynamo.relational.demo;
    import std.traits : hasUDA;

    static MockDB!() db;

    static struct User {
        mixin DemoEntity!(db, "users");
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
    import dynamo.core;
    import dynamo.core.expr : constant;
    import dynamo.relational.schema;
    import dynamo.relational.demo;
    import dynamo.relational.eval_context;
    import dynamo.graphql.schema : Schema;
    import dynamo.graphql.compiler : compileQuery;

    static MockDB!() db;

    static struct User {
        mixin DemoEntity!(db, "users");
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
        alias Config = S.Config;
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
    import dynamo.relational.schema;
    import dynamo.relational.demo;
    import dynamo.graphql.schema : Schema, generateSchemaSDL;
    import std.algorithm : canFind;
    import std.typecons : Nullable;

    static MockDB!() db;

    static struct User {
        mixin DemoEntity!(db, "users");
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
                import dynamo.relational.schema : getAll;
                return getAll!User();
            }
        }

        alias Query = PaginatedQuery;
        alias Mutation = S.Mutation;
        alias Config = S.Config;
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
    import dynamo.core.expr : Expr, constant;

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
    import dynamo.core;
    import dynamo.core.expr : constant, entityCast, EntityCastExpr;
    import dynamo.relational.schema;
    import dynamo.relational.demo;
    import dynamo.relational.eval_context;
    import dynamo.graphql.schema : Schema;
    import dynamo.graphql.compiler : compileQuery;

    static MockDB!() db;

    static struct User {
        mixin DemoEntity!(db, "users");
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
        alias Config = S.Config;
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
    import dynamo.core;
    import dynamo.core.expr : singleton, entityCast, EntityCastExpr;
    import dynamo.relational.eval_context;

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
// This exercises EntityCastExpr with actual entities that have nodeId
unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dynamo.core;
    import dynamo.core.expr : constant;
    import dynamo.relational.schema;
    import dynamo.relational.demo;
    import dynamo.relational.eval_context;
    import dynamo.graphql.schema : Schema, generateSchemaSDL;
    import dynamo.graphql.compiler : compileQuery;
    import std.algorithm : canFind;

    static MockDB!() db;

    // Base User entity
    static struct User {
        mixin DemoEntity!(db, "users");
        mixin Col!("name", string);

        static auto greeting(Expr!User u) {
            return constant("Hello, ", u) ~ name(u);
        }
    }

    // Extended User with additional computed field
    static struct ExtendedUser {
        mixin DemoEntity!(db, "users");  // Same table

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
