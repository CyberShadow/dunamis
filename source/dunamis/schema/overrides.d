/// Field override plugin for runtime field interception.
///
/// Allows runtime registration of typed field overrides for feature flags,
/// A/B testing, gradual rollouts, or per-deployment customization.
///
/// Example:
/// ---
/// // 1. Apply plugin (typically last)
/// alias FinalSchema = ApplyPlugins!(Schema!(Query, Mutation),
///     FilterPlugin, SortingPlugin, PaginationPlugin,
///     FieldOverridePlugin,
/// );
///
/// // 2. Register overrides
/// auto overrides = new FieldOverrides();
/// overrides.set!(User, "fullName")(
///     (string[] defaults, EvalContext ctx) => defaults
/// );
///
/// // 3. Pass overrides via EvalContext
/// auto ctx = new EvalContext();
/// ctx.setRequestContext(FieldOverrideConfig(overrides));
/// auto result = executor.execute(query, ctx);
/// ---
module dunamis.schema.overrides;

import std.conv : to;
import std.traits : hasUDA, getUDAs, ReturnType;

import ae.utils.promise;

import dunamis.core.eval : EvalContext;
import dunamis.core.optimize : OptimizeContext;
import dunamis.core.expr.base : ExprBase, Expr, ExprResultType;
import dunamis.core.expr.primitives : EntityCastInfo;
import dunamis.schema.plugin : isSchema, OriginalName, RemapTypeAttributes;

// ============================================================================
// Override Expression
// ============================================================================

/// Expression wrapper that checks for runtime field overrides at eval time.
/// Transparent to the optimizer — delegates to the wrapped default expression.
///
/// At eval time, checks EvalContext for a FieldOverrideConfig. If an override
/// is registered for the (typeName, fieldName) pair, calls the override
/// delegate with the default values. Otherwise returns defaults unchanged.
class OverrideExpr(T) : Expr!T, EntityCastInfo {
    private Expr!T _default;
    private string _typeName;
    private string _fieldName;

    this(Expr!T default_, string typeName, string fieldName) {
        _default = default_;
        _typeName = typeName;
        _fieldName = fieldName;
    }

    override ExprBase[] dependencies() {
        return [cast(ExprBase) _default];
    }

    override void replaceDependency(size_t index, ExprBase newDep) {
        if (index == 0) _default = cast(Expr!T) newDep;
    }

    override Expr!T optimize(OptimizeContext ctx) {
        _default = _default.optimize(ctx);
        return this;
    }

    /// EntityCastInfo — allows optimizer to walk through this wrapper.
    @property ExprBase inputExpr() {
        return cast(ExprBase) _default;
    }

    override Promise!(T[]) eval(EvalContext ctx) {
        return _default.eval(ctx).then((T[] defaults) {
            if (!ctx.hasRequestContext!FieldOverrideConfig) return defaults;
            auto config = ctx.getRequestContext!FieldOverrideConfig;
            auto override_ = config.overrides.get!T(_typeName ~ "." ~ _fieldName);
            if (override_ !is null) {
                return override_.fn(defaults, ctx);
            }
            return defaults;
        });
    }
}

/// Create an OverrideExpr wrapping an expression with override lookup metadata.
auto overrideField(E)(E expr, string typeName, string fieldName)
    if (is(E : Expr!T, T))
{
    return new OverrideExpr!(ExprResultType!E)(expr, typeName, fieldName);
}

// ============================================================================
// Field Override Registry
// ============================================================================

/// Struct wrapper for storing FieldOverrides in EvalContext via setRequestContext.
struct FieldOverrideConfig {
    FieldOverrides overrides;
}

/// Type-erased wrapper for an override delegate.
class TypedOverride(T) {
    T[] delegate(T[], EvalContext) fn;
    this(typeof(fn) fn) { this.fn = fn; }
}

/// Runtime registry for field overrides.
///
/// Overrides are keyed by "TypeName.fieldName" and store type-erased delegates.
/// The delegate receives a batch of default values and returns replacements.
///
/// Example:
/// ---
/// auto overrides = new FieldOverrides();
///
/// // Type-safe registration (validates field exists at compile time)
/// overrides.set!(User, "fullName")(
///     (string[] defaults, EvalContext ctx) =>
///         defaults.map!(d => d ~ " (beta)").array
/// );
///
/// // String-based registration (for Query/Mutation or dynamic use)
/// overrides.set!string("Query", "version_",
///     (string[] defaults, EvalContext ctx) => ["2.0"]
/// );
/// ---
class FieldOverrides {
    private Object[string] _overrides;

    /// Register a typed field override using the entity type for name resolution.
    void set(Entity, string fieldName, T)(T[] delegate(T[], EvalContext) fn) {
        string key = getOriginalTypeName!Entity ~ "." ~ fieldName;
        _overrides[key] = new TypedOverride!T(fn);
    }

    /// Register a field override using explicit type and field name strings.
    void set(T)(string typeName, string fieldName, T[] delegate(T[], EvalContext) fn) {
        string key = typeName ~ "." ~ fieldName;
        _overrides[key] = new TypedOverride!T(fn);
    }

    /// Look up an override by key. Returns null if not found or type mismatch.
    TypedOverride!T get(T)(string key) {
        if (auto p = key in _overrides) {
            return cast(TypedOverride!T) *p;
        }
        return null;
    }

    /// Check if an override exists for the given key.
    bool has(string key) {
        return (key in _overrides) !is null;
    }
}

// ============================================================================
// Type Name Resolution
// ============================================================================

/// Get the original type name, resolving through @OriginalName UDA chain.
/// Returns the first @OriginalName value if present, otherwise __traits(identifier).
template getOriginalTypeName(T) {
    static if (hasUDA!(T, OriginalName)) {
        enum getOriginalTypeName = getUDAs!(T, OriginalName)[0].name;
    } else {
        enum getOriginalTypeName = __traits(identifier, T);
    }
}

// ============================================================================
// Code Generation
// ============================================================================

/// Code template that generates an overridable field method.
/// Like ForwardFieldCode but wraps the result in OverrideExpr via overrideField.
template OverridableFieldCode(SourceType, string fieldName, alias TypeMap, string entityName) {
    import dunamis.schema.forward : ForwardFieldImpl;

    private alias Impl = ForwardFieldImpl!(SourceType, fieldName, TypeMap);
    private enum string _I = "dunamis.schema.forward.ForwardFieldImpl!(SourceType, fieldName, TypeMap)";

    private enum string _paramListStr = () {
        string result = "dunamis.core.expr.Expr!(typeof(this)) " ~ Impl.srcParamNames[0];
        static foreach (i; 1 .. Impl.SrcParams.length) {{
            result ~= ", " ~ _I ~ ".SrcParams[" ~ i.to!string ~ "] " ~ Impl.srcParamNames[i];
            static if (!is(Impl.SrcDefaults[i] == void))
                result ~= " = " ~ _I ~ ".SrcDefaults[" ~ i.to!string ~ "]";
        }}
        return result;
    }();

    private enum string _argListStr = () {
        string result = "dunamis.schema.entity_cast.pluginEntityCast!(" ~ _I ~ ".SrcEntity)(" ~ Impl.srcParamNames[0] ~ ")";
        static foreach (i; 1 .. Impl.SrcParams.length)
            result ~= ", " ~ Impl.srcParamNames[i];
        return result;
    }();

    enum OverridableFieldCode =
        "@(__traits(getAttributes, " ~ _I ~ ".srcFn)) " ~
        "static auto " ~ fieldName ~ "(" ~ _paramListStr ~ ") { " ~
        "return dunamis.schema.overrides.overrideField(" ~
        "dunamis.schema.transform.wrapEntityResult!(TypeMap)(" ~
        _I ~ ".srcFn(" ~ _argListStr ~ ")), " ~
        "\"" ~ entityName ~ "\", \"" ~ fieldName ~ "\"); }";
}

// ============================================================================
// Mixin Templates
// ============================================================================

/// Mixin template for a single overridable field.
/// Generates a method that forwards to the source field and wraps in OverrideExpr.
mixin template OverridableFieldMixin(SourceType, string fieldName, alias TypeMap, string entityName) {
    static import dunamis.schema.forward;
    static import dunamis.core.expr;
    static import dunamis.schema.entity_cast;
    static import dunamis.schema.transform;
    static import dunamis.schema.overrides;
    mixin(dunamis.schema.overrides.OverridableFieldCode!(SourceType, fieldName, TypeMap, entityName));
}

/// Mixin template that makes all fields of SourceType overridable.
/// Like WrapFields but wraps ALL computed fields in OverrideExpr.
mixin template OverridableFields(SourceType, alias TypeMap, string entityName) {
    import dunamis.core.types : isPlainField;
    import dunamis.schema.plugin : getFieldMembers, isComputedField, ForwardPlainMethod;

    // 1. Per-layer _normalizedSource (stores immediate source type for entity cast chain)
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

    // 3. Field iteration — all computed fields get override wrapping
    static foreach (member; getFieldMembers!SourceType) {
        static if (isComputedField!(SourceType, member)) {
            mixin OverridableFieldMixin!(SourceType, member, TypeMap, entityName);
        } else {
            mixin ForwardPlainMethod!(SourceType, member, TypeMap);
        }
    }
}

// ============================================================================
// Plugin
// ============================================================================

/// Plugin that makes all fields overridable at runtime via OverrideExpr.
///
/// Apply after other plugins (Filter, Sort, Pagination) so overrides wrap
/// the full pipeline. At eval time, each field checks EvalContext for a
/// registered override and applies it if found.
///
/// Example:
/// ---
/// alias FinalSchema = ApplyPlugins!(Schema!(Query, Mutation),
///     FilterPlugin, SortingPlugin, PaginationPlugin,
///     FieldOverridePlugin,
/// );
/// ---
template FieldOverridePlugin(alias S) if (isSchema!S) {
    import std.meta : staticMap;
    import dunamis.core.discovery : getAllObjectTypes;
    import dunamis.schema.transform : isTypeInList;
    import dunamis.schema.plugin : isSchema;

    alias _OriginalQuery = S.Query;
    alias _AllEntityTypes = getAllObjectTypes!_OriginalQuery;

    /// Overridable version of each discovered entity type.
    template OverridableEntity(Entity) {
        @(RemapTypeAttributes!(EntityTypeMap, __traits(getAttributes, Entity)))
        @OriginalName(__traits(identifier, Entity))
        struct OverridableEntity {
            mixin OverridableFields!(Entity, EntityTypeMap, getOriginalTypeName!Entity);
        }
    }

    alias AllEntityTypes = staticMap!(OverridableEntity, _AllEntityTypes);

    /// Entity type map: maps discovered entity types to their overridable versions.
    template EntityTypeMap(T) {
        static if (isTypeInList!(T, _AllEntityTypes)) {
            alias EntityTypeMap = OverridableEntity!T;
        } else {
            alias EntityTypeMap = T;
        }
    }

    struct OverridableQuery {
        mixin OverridableFields!(_OriginalQuery, EntityTypeMap, "Query");
    }

    struct OverridableMutation {
        mixin OverridableFields!(S.Mutation, EntityTypeMap, "Mutation");
    }

    struct OverridableSubscription {
        mixin OverridableFields!(S.Subscription, EntityTypeMap, "Subscription");
    }

    alias Query = OverridableQuery;
    alias Mutation = OverridableMutation;
    alias Subscription = OverridableSubscription;
}

// ============================================================================
// Unit Tests
// ============================================================================

// Test getOriginalTypeName with and without @OriginalName UDA
unittest {
    static struct Plain {}
    static assert(getOriginalTypeName!Plain == "Plain");

    @OriginalName("Original")
    static struct Wrapped {}
    static assert(getOriginalTypeName!Wrapped == "Original");

    // Multiple @OriginalName — first one wins
    @OriginalName("First")
    @OriginalName("Second")
    static struct Multi {}
    static assert(getOriginalTypeName!Multi == "First");
}

// Test FieldOverrides registry
unittest {
    auto overrides = new FieldOverrides();

    // String-based registration
    overrides.set!string("User", "fullName",
        delegate string[](string[] defaults, EvalContext ctx) {
            string[] result = new string[defaults.length];
            foreach (i, d; defaults)
                result[i] = d ~ " (override)";
            return result;
        }
    );

    // Lookup
    auto override_ = overrides.get!string("User.fullName");
    assert(override_ !is null);
    assert(overrides.has("User.fullName"));
    assert(!overrides.has("User.lastName"));

    // Type mismatch returns null
    auto wrongType = overrides.get!int("User.fullName");
    assert(wrongType is null);
}

// Test OverrideExpr with no overrides set
unittest {
    import ae.utils.promise.await : awaitSync;
    import dunamis.core.expr.primitives : singleton;

    auto expr = singleton("hello");
    auto overrideExpr = overrideField(expr, "User", "fullName");

    auto ctx = new EvalContext();
    auto result = awaitSync(overrideExpr.eval(ctx));

    assert(result.length == 1);
    assert(result[0] == "hello");
}

// Test OverrideExpr with override set
unittest {
    import ae.utils.promise.await : awaitSync;
    import dunamis.core.expr.primitives : singleton;

    auto expr = singleton("hello");
    auto overrideExpr = overrideField(expr, "User", "fullName");

    auto overrides = new FieldOverrides();
    overrides.set!string("User", "fullName",
        delegate string[](string[] defaults, EvalContext ctx) {
            string[] result = new string[defaults.length];
            foreach (i, d; defaults)
                result[i] = d ~ " (overridden)";
            return result;
        }
    );

    auto ctx = new EvalContext();
    ctx.setRequestContext(FieldOverrideConfig(overrides));
    auto result = awaitSync(overrideExpr.eval(ctx));

    assert(result.length == 1);
    assert(result[0] == "hello (overridden)");
}

// Test FieldOverridePlugin schema generation (SDL unchanged)
unittest {
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import dunamis.graphql.schema : Schema, generateSchemaSDL;
    import dunamis.schema.plugin : isSchema;
    import std.algorithm : canFind;

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("name", string);

        static auto greeting(Expr!User u) {
            import dunamis.core.expr : constant;
            return constant("Hello, ", u) ~ name(u);
        }
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    alias BaseSchema = Schema!Query;
    alias WithOverrides = FieldOverridePlugin!BaseSchema;

    static assert(isSchema!WithOverrides);

    // SDL should have the same fields
    enum baseSdl = generateSchemaSDL!BaseSchema;
    enum overrideSdl = generateSchemaSDL!WithOverrides;
    static assert(overrideSdl.canFind("name:"), "Should have name field");
    static assert(overrideSdl.canFind("greeting:"), "Should have greeting field");
    static assert(overrideSdl.canFind("users:"), "Should have users field on Query");
}

// Test FieldOverridePlugin end-to-end: no overrides (passthrough)
unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dunamis.core;
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

        static auto greeting(Expr!User u) {
            import dunamis.core.expr : constant;
            return constant("Hello, ", u) ~ name(u);
        }
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    alias FinalSchema = FieldOverridePlugin!(Schema!Query);

    db = new MockDB!();
    db.setTableData("users", `[
        {"id": 1, "name": "Alice"},
        {"id": 2, "name": "Bob"}
    ]`);

    auto query = compileQuery!FinalSchema(`{ users { name greeting } }`);
    auto result = awaitSync(new Executor().execute(query));

    assert(result["users"][0]["name"].str == "Alice");
    assert(result["users"][0]["greeting"].str == "Hello, Alice");
    assert(result["users"][1]["name"].str == "Bob");
    assert(result["users"][1]["greeting"].str == "Hello, Bob");
}

// Test FieldOverridePlugin end-to-end: with override
unittest {
    import std.json;
    import std.array : array;
    import std.algorithm : map;
    import ae.utils.promise.await : awaitSync;
    import dunamis.core;
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

        static auto greeting(Expr!User u) {
            import dunamis.core.expr : constant;
            return constant("Hello, ", u) ~ name(u);
        }
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    alias FinalSchema = FieldOverridePlugin!(Schema!Query);

    db = new MockDB!();
    db.setTableData("users", `[
        {"id": 1, "name": "Alice"},
        {"id": 2, "name": "Bob"}
    ]`);

    // Register override for greeting field
    auto overrides = new FieldOverrides();
    overrides.set!(User, "greeting")(
        delegate string[](string[] defaults, EvalContext ctx) {
            return defaults.map!(d => d ~ " (beta)").array;
        }
    );

    auto query = compileQuery!FinalSchema(`{ users { name greeting } }`);

    // Execute with overrides
    auto ctx = new EvalContext();
    ctx.setRequestContext(FieldOverrideConfig(overrides));
    auto result = awaitSync(new Executor().execute(query, ctx));

    // name should be unchanged
    assert(result["users"][0]["name"].str == "Alice");
    assert(result["users"][1]["name"].str == "Bob");

    // greeting should be overridden
    assert(result["users"][0]["greeting"].str == "Hello, Alice (beta)");
    assert(result["users"][1]["greeting"].str == "Hello, Bob (beta)");
}

// Test override with EvalContext access (feature flag pattern)
unittest {
    import std.json;
    import std.array : array;
    import std.algorithm : map;
    import ae.utils.promise.await : awaitSync;
    import dunamis.core;
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import dunamis.relational.eval_context;
    import dunamis.graphql.schema : Schema;
    import dunamis.graphql.compiler : compileQuery;

    static struct FeatureFlags { bool betaGreeting; }

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("name", string);

        static auto greeting(Expr!User u) {
            import dunamis.core.expr : constant;
            return constant("Hello, ", u) ~ name(u);
        }
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    alias FinalSchema = FieldOverridePlugin!(Schema!Query);

    db = new MockDB!();
    db.setTableData("users", `[{"id": 1, "name": "Alice"}]`);

    auto overrides = new FieldOverrides();
    overrides.set!(User, "greeting")(
        delegate string[](string[] defaults, EvalContext ctx) {
            auto flags = ctx.getRequestContext!FeatureFlags;
            if (flags.betaGreeting)
                return defaults.map!(d => d ~ " [BETA]").array;
            return defaults;
        }
    );

    auto query = compileQuery!FinalSchema(`{ users { greeting } }`);

    // With feature flag OFF
    {
        auto ctx = new EvalContext();
        ctx.setRequestContext(FeatureFlags(false));
        ctx.setRequestContext(FieldOverrideConfig(overrides));
        auto result = awaitSync(new Executor().execute(query, ctx));
        assert(result["users"][0]["greeting"].str == "Hello, Alice");
    }

    // With feature flag ON
    {
        auto ctx = new EvalContext();
        ctx.setRequestContext(FeatureFlags(true));
        ctx.setRequestContext(FieldOverrideConfig(overrides));
        auto result = awaitSync(new Executor().execute(query, ctx));
        assert(result["users"][0]["greeting"].str == "Hello, Alice [BETA]");
    }
}

// Test FieldOverridePlugin composed with other plugins
unittest {
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import dunamis.graphql.schema : Schema, generateSchemaSDL;
    import dunamis.schema.plugin : isSchema, ApplyPlugins;
    import dunamis.schema.sorting : SortingPlugin;
    import dunamis.schema.filtering : FilterPlugin;
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

    // Apply Filter → Sort → Override
    alias FinalSchema = ApplyPlugins!(Schema!Query,
        FilterPlugin, SortingPlugin, FieldOverridePlugin,
    );

    static assert(isSchema!FinalSchema);

    enum sdl = generateSchemaSDL!FinalSchema;
    // Should have filter and sort arguments (from earlier plugins)
    static assert(sdl.canFind("filter:"), "Should have filter argument");
    static assert(sdl.canFind("orderBy:"), "Should have orderBy argument");
    // Should still have entity fields
    static assert(sdl.canFind("name:"), "Should have name field");
}
