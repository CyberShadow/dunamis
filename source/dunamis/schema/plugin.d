/// Schema extension/plugin infrastructure.
///
/// Plugins transform schemas via template composition:
/// ---
/// alias FinalSchema = ApplyPlugins!(BaseSchema, CrudMutationPlugin, FilterPlugin, SortingPlugin);
/// ---
///
/// A plugin is a template that consumes a schema and produces a new schema.
/// This module provides building blocks for writing plugins.
module dunamis.schema.plugin;

import std.meta : AliasSeq, staticMap;
import std.traits : Parameters, ReturnType, hasUDA;

import dunamis.core.expr : Expr, ExprResultType, isExpr;
import dunamis.core.types : ImplementedBy, Implements, IncludesTypes;

// Re-export commonly needed utilities
public import dunamis.core.types : isInternalMember;

// Re-export field introspection (moved to core/discovery.d to break circular
// .imported dependencies — LDC reports forward reference errors when satellite
// modules loaded via .imported!q{...} import back into plugin.d during mixin
// expansion, because plugin.d is still mid-compilation at that point)
public import dunamis.core.discovery : getFieldMembers, isComputedField;

// ============================================================================
// Schema Check
// ============================================================================

/// Check if a type is a Schema (has Query and Mutation members)
template isSchema(alias T) {
    enum isSchema = __traits(hasMember, T, "Query") && __traits(hasMember, T, "Mutation");
}
// ============================================================================
// Plugin Composition
// ============================================================================

/// Compose plugins left-to-right.
///
/// `ApplyPlugins!(Base, P1, P2, P3)` expands to `P3!(P2!(P1!Base))`.
///
/// Plugins are applied in declaration order — earlier plugins are innermost.
/// This matches the mental model of "first apply P1, then P2, then P3".
///
/// Example:
/// ---
/// alias MySchema = ApplyPlugins!(Schema!(Query, Mutation),
///     CrudMutationPlugin,
///     FilterPlugin,
///     SortingPlugin,
/// );
/// ---
template ApplyPlugins(alias Base, Plugins...) {
    static if (Plugins.length == 0) {
        alias ApplyPlugins = Base;
    } else {
        alias FirstPlugin = Plugins[0];
        alias ApplyPlugins = ApplyPlugins!(FirstPlugin!Base, Plugins[1 .. $]);
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
// Schema-layer UDAs
// ============================================================================

/// UDA that records the original D type name before plugin wrapping.
/// Applied by every wrapper template; the first in the UDA list is canonical.
struct OriginalName { string name; }

/// UDA on a type the schema layer derives from the type `Base` (e.g. the
/// filter input type of an entity), which is named after `Base`: its name is
/// `Base`'s name followed by `suffix`. Recording the base type rather than a
/// finished name lets each consumer name the derived type after its own name
/// of `Base` (`getOriginalTypeName` here; e.g. the GraphQL layer after the
/// GraphQL name of `Base`).
struct NamedAfter(Base) { string suffix; }

/// The D-level name of a schema type: the name recorded by the first
/// `@OriginalName` (the name of the user-declared type a wrapper stands
/// for), the name of a `@NamedAfter` type's base type followed by its
/// suffix, or else the type's own identifier.
template getOriginalTypeName(T) {
    import std.traits : getUDAs;
    static if (hasUDA!(T, OriginalName)) {
        enum string getOriginalTypeName = getUDAs!(T, OriginalName)[0].name;
    } else static if (hasUDA!(T, NamedAfter)) {
        enum string getOriginalTypeName = getOriginalTypeName!(NamedAfterBase!T) ~
            getUDAs!(T, NamedAfter)[0].suffix;
    } else {
        enum string getOriginalTypeName = __traits(identifier, T);
    }
}

/// The base type of a type with a `@NamedAfter` attribute.
template NamedAfterBase(T) {
    import std.traits : getUDAs;
    static if (is(typeof(getUDAs!(T, NamedAfter)[0]) == NamedAfter!Base, Base))
        alias NamedAfterBase = Base;
    else
        static assert(false, T.stringof ~ " has no @NamedAfter attribute");
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
// UDA Remapping for Abstract Types
// ============================================================================

/// Remap type references in @ImplementedBy, @Implements and @IncludesTypes UDAs through a TypeMap.
/// Non-matching attributes are passed through unchanged.
///
/// Every plugin that wraps entity types should use this instead of raw
/// @(__traits(getAttributes, Entity)) to keep abstract type membership
/// declarations consistent with the current plugin level's type system.
///
/// Example:
/// ---
/// template WrappedEntity(Entity) {
///     @(RemapTypeAttributes!(EntityTypeMap, __traits(getAttributes, Entity)))
///     @OriginalName(__traits(identifier, Entity))
///     struct WrappedEntity {
///         mixin WrapFields!(Entity, EntityTypeMap, ...);
///     }
/// }
/// ---
template RemapTypeAttributes(alias TypeMap, Attrs...) {
    static if (Attrs.length == 0) {
        alias RemapTypeAttributes = AliasSeq!();
    } else {
        alias _Rest = RemapTypeAttributes!(TypeMap, Attrs[1..$]);
        static if (is(Attrs[0] == ImplementedBy!M, M...)) {
            alias RemapTypeAttributes = AliasSeq!(ImplementedBy!(staticMap!(TypeMap, M)), _Rest);
        } else static if (is(Attrs[0] == Implements!A, A...)) {
            alias RemapTypeAttributes = AliasSeq!(Implements!(staticMap!(TypeMap, A)), _Rest);
        } else static if (is(Attrs[0] == IncludesTypes!I, I...)) {
            alias RemapTypeAttributes = AliasSeq!(IncludesTypes!(staticMap!(TypeMap, I)), _Rest);
        } else {
            alias RemapTypeAttributes = AliasSeq!(Attrs[0], _Rest);
        }
    }
}

// ============================================================================
// Field Forwarding
// ============================================================================

/// Mixin template to forward a single field from SourceType.
/// Preserves UDAs from the source field and handles type conversion
/// for the first parameter (Expr!SourceType -> Expr!TargetType).
///
/// Zero-leak: no imports, aliases, or enums are mixed into the target struct.
/// All metadata is encapsulated in ForwardFieldImpl/ForwardFieldCode (in forward.d).
mixin template ForwardField(SourceType, string fieldName, alias TypeMap = IdentityTypeMap) {
    static import dunamis.schema.forward;
    static import dunamis.core.expr;
    static import dunamis.schema.entity_cast;
    static import dunamis.schema.transform;
    mixin(dunamis.schema.forward.ForwardFieldCode!(SourceType, fieldName, TypeMap));
}

/// Mixin template to forward a plain method from a source type.
/// Zero-leak: no imports, aliases, or enums are mixed into the target struct.
/// Code generation is encapsulated in ForwardPlainMethodCode (in forward.d).
mixin template ForwardPlainMethod(SourceType, string methodName, alias TypeMap = IdentityTypeMap) {
    static import dunamis.schema.forward;
    static import std.traits;
    mixin(dunamis.schema.forward.ForwardPlainMethodCode!(SourceType, methodName));
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
    import dunamis.schema.plugin : getFieldMembers, ForwardField, ForwardPlainMethod, isComputedField;

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
///     @(RemapTypeAttributes!(EntityTypeMap, __traits(getAttributes, Entity)))
///     @OriginalName(__traits(identifier, Entity))
///     struct SortedEntity {
///         mixin WrapFields!(Entity, EntityTypeMap, SortedArrayField);
///     }
/// }
/// ---
mixin template WrapFields(SourceType, alias TypeMap, alias ArrayFieldMixin) {
    import dunamis.core.types : isPlainField;
    import dunamis.schema.plugin : getFieldMembers, isComputedField, isArrayReturningField,
        ForwardField, ForwardPlainMethod;

    // 1. Per-layer _normalizedSource (stores immediate source type for entity cast chain)
    //    Only present on entity types (which go through NormalizeFields), not Query/Mutation.
    static if (__traits(hasMember, SourceType, "_normalizedSource")) {
        package(dunamis.schema) SourceType _normalizedSource;
    }

    // 2. Copy plain fields (struct instance fields, including @PrimaryKey)
    static foreach (member; __traits(allMembers, SourceType)) {
        static if (isPlainField!(SourceType, member)) {
            mixin("@(__traits(getAttributes, __traits(getMember, SourceType, \"" ~ member ~ "\"))) " ~
                  "typeof(__traits(getMember, SourceType.init, \"" ~ member ~ "\")) " ~ member ~ ";");
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
    static import dunamis.schema.normalize;
    static import dunamis.core.expr;
    static import dunamis.schema.transform;
    static import dunamis.schema.forward;
    static import dunamis.schema.entity_cast;
    mixin(dunamis.schema.normalize.NormalizeFieldsCode!(SourceType, TypeMap));
}

// ============================================================================
// Normalize Plugin
// ============================================================================

/// Internal plugin that normalizes all object types of the schema — its root
/// types (Query, Mutation, Subscription) and all object types reachable from
/// them — to use only static Expr methods. Plain fields and plain methods are
/// converted to computed fields via `use()`, making all field access uniform.
///
/// The root types are normalized like any other object type. They are named
/// after the root operation type they are (`Query`, `Mutation`,
/// `Subscription`) rather than after the user-declared types.
///
/// Used internally by Schema to normalize types before external plugins
/// are applied.
template NormalizePlugin(RawQuery, RawMutation, RawSubscription = void) {
    import std.meta : AliasSeq;
    import dunamis.core.discovery : getAllObjectTypes;
    import dunamis.schema.transform : isTypeInList;

    static if (is(RawSubscription == void)) {
        struct _EmptySubscription {}
        alias _RawSubscription = _EmptySubscription;
    } else {
        alias _RawSubscription = RawSubscription;
    }

    alias _Roots = AliasSeq!(RawQuery, RawMutation, _RawSubscription);

    // Discover all entity and POD types reachable from the roots
    alias _AllTypes = getAllObjectTypes!_Roots;

    // Create normalized version of each object type
    template _NormalizedType(T, string name = __traits(identifier, T)) {
        @(RemapTypeAttributes!(_TypeMap, __traits(getAttributes, T)))
        @OriginalName(name)
        struct _NormalizedType {
            mixin NormalizeFields!(T, _TypeMap);
        }
    }

    // Map all object types (the roots included) to their normalized versions.
    template _TypeMap(T) {
        static if (is(T == RawQuery)) {
            alias _TypeMap = Query;
        } else static if (is(T == RawMutation)) {
            alias _TypeMap = Mutation;
        } else static if (is(T == _RawSubscription)) {
            alias _TypeMap = Subscription;
        } else static if (isTypeInList!(T, _AllTypes)) {
            alias _TypeMap = _NormalizedType!T;
        } else {
            alias _TypeMap = T;
        }
    }

    alias Query = _NormalizedType!(RawQuery, "Query");
    alias Mutation = _NormalizedType!(RawMutation, "Mutation");
    alias Subscription = _NormalizedType!(_RawSubscription, "Subscription");
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
        alias Subscription = S.Subscription;
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
        alias Subscription = S.Subscription;
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
        alias Subscription = S.Subscription;
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
        alias Subscription = S.Subscription;
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
        alias Subscription = S.Subscription;
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
        alias Subscription = S.Subscription;
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
        alias Subscription = S.Subscription;
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

/// Compile-time test: full plugin chain produces no leaked _-prefixed members.
///
/// After the zero-leak mixin template refactoring, no _-prefixed member should
/// pass isPlainField, isPlainMethod, or appear as a non-hidden field in getFields.
unittest {
    import std.algorithm : canFind, startsWith;
    import std.typecons : Nullable;
    import dunamis.core.types : isPlainField, isPlainMethod;
    import dunamis.graphql.schema : Schema, generateSchemaSDL, getFields, FieldInfo;
    import dunamis.schema.filtering : FilterPlugin;
    import dunamis.schema.sorting : SortingPlugin;
    import dunamis.relational.schema : Col, Table, ForeignKey, HasMany, BelongsTo;
    import dunamis.relational.demo : DemoEntity, DemoId, MockDB;

    static MockDB!() db;

    @DemoEntity!(db, "posts")
    static struct Post {
        mixin DemoId;
        mixin Col!("title", string);
    }

    // Entity with all field types: Col, HasMany, plain field, plain method, computed field
    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("firstName", string);
        mixin Col!("lastName", string);
        mixin HasMany!("posts", Post, "author_id");

        Nullable!string nickname;   // plain field
        string displayName() => nickname.isNull ? "Anon" : nickname.get;  // plain method

        static auto fullName(Expr!User u) => u.firstName ~ " " ~ u.lastName;  // computed field
    }

    static struct Query {
        mixin Table!(User, "users");
        mixin Table!(Post, "posts");
    }

    // Full plugin chain: Filter → Sort
    alias FullSchema = SortingPlugin!(FilterPlugin!(Schema!(Query)));

    // Check transformed entity types: no non-hidden field should start with _
    alias EntityTypes = FullSchema.AllEntityTypes;
    static foreach (Entity; EntityTypes) {{
        static foreach (member; __traits(allMembers, Entity)) {{
            static if (member.length > 0 && member[0] == '_') {
                static assert(!isPlainField!(Entity, member),
                    "Leaked _-prefixed plain field '" ~ member ~ "' on " ~ Entity.stringof);
                static assert(!isPlainMethod!(Entity, member),
                    "Leaked _-prefixed plain method '" ~ member ~ "' on " ~ Entity.stringof);
            }
        }}

        // Check getFields: no non-hidden field should start with _
        static foreach (field; getFields!Entity) {{
            static if (!field.hidden) {
                static assert(!field.name.startsWith("_"),
                    "Non-hidden field '" ~ field.name ~ "' starts with _ on " ~ Entity.stringof);
            }
        }}
    }}

    // Check transformed Query type
    alias SortedQuery = FullSchema.Query;
    static foreach (member; __traits(allMembers, SortedQuery)) {{
        static if (member.length > 0 && member[0] == '_') {
            static assert(!isPlainField!(SortedQuery, member),
                "Leaked _-prefixed plain field '" ~ member ~ "' on SortedQuery");
            static assert(!isPlainMethod!(SortedQuery, member),
                "Leaked _-prefixed plain method '" ~ member ~ "' on SortedQuery");
        }
    }}
    static foreach (field; getFields!SortedQuery) {{
        static if (!field.hidden) {
            static assert(!field.name.startsWith("_"),
                "Non-hidden field '" ~ field.name ~ "' starts with _ on SortedQuery");
        }
    }}
}

// Test RemapTypeAttributes
unittest {
    import dunamis.core.types : ImplementedBy, Implements;
    import dunamis.schema.plugin : OriginalName;

    // Mock types
    static struct A {}
    static struct B {}
    static struct MappedA {}
    static struct MappedB {}

    // TypeMap that maps A → MappedA, B → MappedB
    template TestTypeMap(T) {
        static if (is(T == A)) alias TestTypeMap = MappedA;
        else static if (is(T == B)) alias TestTypeMap = MappedB;
        else alias TestTypeMap = T;
    }

    // @ImplementedBy gets remapped
    alias remapped = RemapTypeAttributes!(TestTypeMap, ImplementedBy!(A, B));
    static assert(remapped.length == 1);
    static assert(is(remapped[0] == ImplementedBy!(MappedA, MappedB)));

    // @Implements gets remapped
    alias remapped2 = RemapTypeAttributes!(TestTypeMap, Implements!A);
    static assert(remapped2.length == 1);
    static assert(is(remapped2[0] == Implements!MappedA));

    // Non-matching attributes pass through
    alias remapped3 = RemapTypeAttributes!(TestTypeMap, OriginalName("test"));
    static assert(remapped3.length == 1);

    // Mixed: @ImplementedBy + value UDA
    alias remapped4 = RemapTypeAttributes!(TestTypeMap, ImplementedBy!(A, B), OriginalName("test"));
    static assert(remapped4.length == 2);
    static assert(is(remapped4[0] == ImplementedBy!(MappedA, MappedB)));

    // Empty input
    alias remapped5 = RemapTypeAttributes!(TestTypeMap);
    static assert(remapped5.length == 0);
}

// Test NormalizePlugin remaps @ImplementedBy on abstract types
unittest {
    import dunamis.core.expr : Expr;
    import dunamis.core.types : ImplementedBy, AbstractField, isAbstractType, getImplementedByMembers;
    import dunamis.core.discovery : getAllObjectTypes;
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import dunamis.graphql.schema : Schema;

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("name", string);
    }

    @DemoEntity!(db, "posts")
    static struct Post {
        mixin DemoId;
        mixin Col!("title", string);
    }

    @ImplementedBy!(User, Post)
    static struct Node {
        mixin AbstractField!("id", string);
    }

    static struct TestQuery {
        mixin Table!(User, "users");
        mixin Table!(Post, "posts");

        static auto nodes(Expr!TestQuery q) {
            import dunamis.core.expr.combinators : unionOf;
            return unionOf!Node(users(q), posts(q));
        }
    }

    alias MySchema = Schema!(TestQuery);

    // After normalization, the normalized entity types should be discoverable
    alias AllTypes = getAllObjectTypes!(MySchema.Query);

    // The normalized User/Post types should have @ImplementedBy remapped
    // through the plugin chain. Verify abstract type is still detected.
    static assert(isAbstractType!Node, "Raw Node should be abstract");

    // Verify the schema can generate SDL (exercises _containsByName path)
    import dunamis.graphql.schema : generateSchemaSDL;
    import std.algorithm : canFind;
    enum sdl = generateSchemaSDL!MySchema;
    static assert(sdl.canFind("interface Node"), "Should generate interface Node");
    static assert(sdl.canFind("implements Node"), "User/Post should implement Node");
}
