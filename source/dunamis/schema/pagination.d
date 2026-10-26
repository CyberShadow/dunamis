/// Pagination plugin for GraphQL schemas.
///
/// The PaginationPlugin automatically adds `first` and `offset` pagination
/// arguments to all array-returning fields in the Query type.
///
/// Example:
/// ---
/// alias BaseSchema = Schema!Query;
/// alias PaginatedSchema = PaginationPlugin!BaseSchema;
///
/// // users: [User!]! becomes users(first: Int, offset: Int): [User!]!
/// ---
module dunamis.schema.pagination;

import std.traits : ReturnType, Parameters, ParameterDefaults, ParameterIdentifierTuple;
import std.typecons : Nullable;

import dunamis.core.expr : Expr, ExprResultType;
import dunamis.core.pagination : limit, offset, LimitInfo, OffsetInfo;
import dunamis.schema.plugin;
// isSchema imported via dunamis.schema.plugin wildcard import above

// ============================================================================
// PaginationPlugin
// ============================================================================

/// Plugin that adds first/offset pagination arguments to all array-returning fields,
/// including nested HasMany relationships.
///
/// Transforms root Query fields:
///   users: [User!]!
/// Into:
///   users(first: Int, offset: Int): [User!]!
///
/// And nested entity fields:
///   User.posts: [Post!]!
/// Into:
///   User.posts(first: Int, offset: Int): [Post!]!
///
/// Example:
/// ---
/// struct Query {
///     mixin Table!(User, "users");
///     mixin Table!(Post, "posts");
/// }
///
/// alias BaseSchema = Schema!Query;
/// alias PaginatedSchema = PaginationPlugin!BaseSchema;
///
/// // Now:
/// //   users(first: Int, offset: Int): [User!]!
/// //   User.posts(first: Int, offset: Int): [Post!]!
/// ---
template PaginationPlugin(alias S) if (isSchema!S) {
    import std.meta : AliasSeq, Filter, staticMap;
    import dunamis.core.discovery : getAllObjectTypes;
    import dunamis.relational.schema.attrs : hasEntityAttr;
    import dunamis.schema.transform : isTypeInList;

    // Get all entity types discovered from the schema
    alias _OriginalQuery = S.Query;
    alias _AllObjectTypes = getAllObjectTypes!_OriginalQuery;
    template IsRelationalEntity(T) {
        enum IsRelationalEntity = hasEntityAttr!T;
    }
    alias _AllEntityTypes = Filter!(IsRelationalEntity, _AllObjectTypes);

    // Generate paginated versions of each entity type.
    template PaginatedEntity(Entity) {
        @(RemapTypeAttributes!(EntityTypeMap, __traits(getAttributes, Entity)))
        @OriginalName(__traits(identifier, Entity))
        struct PaginatedEntity {
            mixin WrapFields!(Entity, EntityTypeMap, PaginatedArrayField);
        }
    }

    // Map all entity types to their paginated versions
    alias AllEntityTypes = staticMap!(PaginatedEntity, _AllEntityTypes);

    /// Entity type map: maps discovered entity types to their paginated versions.
    template EntityTypeMap(T) {
        static if (isTypeInList!(T, _AllEntityTypes)) {
            alias EntityTypeMap = PaginatedEntity!T;
        } else {
            alias EntityTypeMap = T;
        }
    }

    @(RootTypeNameAttributes!(_OriginalQuery))
    struct PaginatedQuery {
        mixin WrapFields!(_OriginalQuery, EntityTypeMap, PaginatedArrayField);
    }

    @(RootTypeNameAttributes!(S.Mutation))
    struct PaginatedMutation {
        mixin WrapFields!(S.Mutation, EntityTypeMap, PaginatedArrayField);
    }

    @(RootTypeNameAttributes!(S.Subscription))
    struct PaginatedSubscription {
        mixin WrapFields!(S.Subscription, EntityTypeMap, PaginatedArrayField);
    }

    alias Query = PaginatedQuery;
    alias Mutation = PaginatedMutation;
    alias Subscription = PaginatedSubscription;
}

/// Eponymous code template for PaginatedArrayField.
/// Builds the complete mixin string including pagination helper and method.
/// All metadata stays encapsulated — no leaks.
template PaginatedArrayFieldCode(SourceQuery, string fieldName, alias TypeMap) {
    import std.conv : to;
    import dunamis.schema.forward : ForwardFieldImpl;

    private alias Impl = ForwardFieldImpl!(SourceQuery, fieldName, TypeMap);

    // .imported references for generated code
    private enum string _I = "dunamis.schema.forward.ForwardFieldImpl!(SourceQuery, \"" ~ fieldName ~ "\", TypeMap)";
    private enum string _Expr = "dunamis.core.expr.Expr";
    private enum string _entityCast = "dunamis.schema.entity_cast.pluginEntityCast";
    private enum string _Nullable = "std.typecons.Nullable";
    private enum string _limit = "dunamis.core.pagination.limit";
    private enum string _offset = "dunamis.core.pagination.offset";
    private enum string _wrap = "dunamis.schema.transform.wrapEntityResult";
    // Element type for explicit return type (needed because limit/offset return different subtypes)
    private enum string _ElemType = "dunamis.schema.plugin.ArrayFieldElementType!(" ~ _I ~ ".srcFn)";

    enum PaginatedArrayFieldCode = () {
        string result = "";

        // _applyPagination helper (template function, invisible to field detection)
        // Uses static assert + static if to extract element type E from Expr!(E[]),
        // matching the pattern used by SortingPlugin's _applySorting.
        result ~= "private static auto _applyPagination(S)(S base, " ~ _Nullable ~ "!int _first, " ~ _Nullable ~ "!int _off) {\n";
        result ~= "    alias _E = " ~ _Expr ~ ";\n";
        result ~= "    static assert(is(S : _E!(E[]), E), \"Expected Expr!(E[])\");\n";
        result ~= "    static if (is(S : _E!(E[]), E)) {\n";
        result ~= "        _E!(E[]) result = base;\n";
        result ~= "        if (!_off.isNull) result = " ~ _offset ~ "(result, cast(size_t) _off.get);\n";
        result ~= "        if (!_first.isNull) result = " ~ _limit ~ "(result, cast(size_t) _first.get);\n";
        result ~= "        return result;\n";
        result ~= "    }\n";
        result ~= "}\n\n";

        // --- Build parameter list ---
        string paramList = _Expr ~ "!(typeof(this)) " ~ Impl.srcParamNames[0];
        static foreach (i; 1 .. Impl.SrcParams.length) {{
            paramList ~= ", " ~ _I ~ ".SrcParams[" ~ i.to!string ~ "] " ~ Impl.srcParamNames[i];
            static if (!is(Impl.SrcDefaults[i] == void)) {
                paramList ~= " = " ~ _I ~ ".SrcDefaults[" ~ i.to!string ~ "]";
            }
        }}
        paramList ~= ", " ~ _Nullable ~ "!int first = " ~ _Nullable ~ "!int.init";
        paramList ~= ", " ~ _Nullable ~ "!int offset = " ~ _Nullable ~ "!int.init";

        // --- Build argument list ---
        string argList = _entityCast ~ "!(" ~ _I ~ ".SrcEntity)(" ~ Impl.srcParamNames[0] ~ ")";
        static foreach (i; 1 .. Impl.SrcParams.length) {
            argList ~= ", " ~ Impl.srcParamNames[i];
        }

        // --- Generate method ---
        // Pagination is applied AFTER wrapEntityResult so limit/offset wrap the
        // entity-cast MapExpr, keeping it visible to the optimizer unwrapping loop.
        result ~= "@(__traits(getAttributes, " ~ _I ~ ".srcFn)) " ~
                  "static auto " ~ fieldName ~ "(" ~ paramList ~ ") { " ~
                  "return _applyPagination(" ~ _wrap ~ "!(TypeMap)(" ~
                  _I ~ ".srcFn(" ~ argList ~ ")), first, offset); }";

        return result;
    }();
}

/// Mixin template to create a paginated version of an array-returning field.
/// Zero-leak: delegates to PaginatedArrayFieldCode eponymous template.
mixin template PaginatedArrayField(SourceQuery, string fieldName, alias TypeMap) {
    static import dunamis.schema.forward;
    static import dunamis.core.expr;
    static import dunamis.schema.entity_cast;
    static import std.typecons;
    static import dunamis.core.pagination;
    static import dunamis.schema.transform;
    static import dunamis.schema.plugin;
    import dunamis.core.discovery : isObjectType;
    import dunamis.schema.plugin : ArrayFieldElementType, ForwardField;
    alias _ElementType = ArrayFieldElementType!(__traits(getMember, SourceQuery, fieldName));
    static if (isObjectType!_ElementType)
        mixin(PaginatedArrayFieldCode!(SourceQuery, fieldName, TypeMap));
    else
        mixin ForwardField!(SourceQuery, fieldName, TypeMap);
}

// ============================================================================
// Unit Tests
// ============================================================================

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

        // Non-array field - should remain unchanged
        static auto apiVersion(Expr!Query q) {
            return constant("1.0", q);
        }
    }

    alias BaseSchema = Schema!Query;
    alias PaginatedSchema = PaginationPlugin!BaseSchema;

    // Verify it's a valid schema
    static assert(isSchema!PaginatedSchema);

    // Verify SDL shows pagination arguments on array field
    enum sdl = generateSchemaSDL!PaginatedSchema;

    // Array field should have pagination args
    static assert(sdl.canFind("users("), "users should have arguments: " ~ sdl);
    static assert(sdl.canFind("first:"), "should have first arg: " ~ sdl);
    static assert(sdl.canFind("offset:"), "should have offset arg: " ~ sdl);

    // Non-array field should remain unchanged
    static assert(sdl.canFind("apiVersion:"), "apiVersion should exist: " ~ sdl);
    static assert(!sdl.canFind("apiVersion("), "apiVersion should not have args: " ~ sdl);
}

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

    alias PaginatedSchema = PaginationPlugin!(Schema!Query);

    // Set up mock data
    db = new MockDB!();
    db.setTableData("users", `[
        {"id": 1, "name": "Alice"},
        {"id": 2, "name": "Bob"},
        {"id": 3, "name": "Carol"},
        {"id": 4, "name": "Dave"},
        {"id": 5, "name": "Eve"}
    ]`);

    // Query with pagination
    auto query = compileQuery!PaginatedSchema(`{
        users(first: 2, offset: 1) {
            name
        }
    }`);

    auto result = awaitSync(new Executor().execute(query));

    import std.conv : to;
    // Debug output
    string debugInfo = "Result: " ~ result.to!string ~ "\n";
    debugInfo ~= "Users count: " ~ result["users"].array.length.to!string ~ "\n";
    if (result["users"].array.length > 0) {
        debugInfo ~= "First user: " ~ result["users"][0].to!string ~ "\n";
    }

    // Should return Bob and Carol (skip 1, take 2)
    assert(result["users"].array.length == 2, "Should have 2 users. " ~ debugInfo);
    assert(result["users"][0]["name"].str == "Bob", "First should be Bob. " ~ debugInfo);
    assert(result["users"][1]["name"].str == "Carol", "Second should be Carol. " ~ debugInfo);
}

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
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    alias PaginatedSchema = PaginationPlugin!(Schema!Query);

    db = new MockDB!();
    db.setTableData("users", `[
        {"id": 1, "name": "Alice"},
        {"id": 2, "name": "Bob"},
        {"id": 3, "name": "Carol"}
    ]`);

    // Query without pagination args - should return all
    auto query = compileQuery!PaginatedSchema(`{
        users {
            name
        }
    }`);

    auto result = awaitSync(new Executor().execute(query));

    // Should return all users
    assert(result["users"].array.length == 3, "Should have all 3 users");
}

// Test nested HasMany pagination - SDL should show pagination args on nested fields
unittest {
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import dunamis.graphql.schema : Schema, generateSchemaSDL;
    import std.algorithm : canFind;

    static MockDB!() db;

    // For circular references (User -> Post -> User), we need forward declaration pattern.
    // In D, we can use a mixin template with string for deferred resolution.

    // Simple test case: User has posts (no back-reference to avoid circular issue)
    @DemoEntity!(db, "posts")
    static struct Post {
        mixin DemoId;
        mixin Col!("title", string);
    }

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("name", string);
        mixin HasMany!("posts", Post, "author_id");
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    alias PaginatedSchema = PaginationPlugin!(Schema!Query);

    // Verify SDL shows pagination arguments on NESTED array fields
    enum sdl = generateSchemaSDL!PaginatedSchema;

    // Debug: print SDL
    // pragma(msg, "=== PAGINATED SDL ===");
    // pragma(msg, sdl);

    // Root Query fields should have pagination
    static assert(sdl.canFind("users("), "Query.users should have arguments: " ~ sdl);

    // User.posts (HasMany) should have pagination
    // Look for the pattern in the User type definition
    // The User type should have: posts(first: Int, offset: Int): [Post!]!
    static assert(sdl.canFind("posts(first: Int"), "User.posts should have first arg: " ~ sdl);
}

// Test nested HasMany pagination - runtime execution with per-parent pagination
unittest {
    import std.json;
    import std.conv : to;
    import ae.utils.promise.await : awaitSync;
    import dunamis.core;
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import dunamis.relational.eval_context;
    import dunamis.graphql.schema : Schema, GqlHidden;
    import dunamis.graphql.compiler : compileQuery;

    // Wrap in struct to allow forward references
    struct TestSchema {
        static MockDB!() db;

        @DemoEntity!(db, "posts")
        struct Post {
            mixin DemoId;
            mixin Col!("title", string);
            @GqlHidden mixin Col!("authorId", long, "author_id");
        }

        @DemoEntity!(db, "users")
        struct User {
            mixin DemoId;
            mixin Col!("name", string);
            mixin HasMany!("posts", Post, "author_id");
        }

        struct Query {
            mixin Table!(User, "users");
        }
    }

    alias db = TestSchema.db;
    alias Query = TestSchema.Query;

    alias PaginatedSchema = PaginationPlugin!(Schema!Query);

    // Set up mock data: 2 users, 5 posts each
    db = new MockDB!();
    db.setTableData("users", `[
        {"id": 1, "name": "Alice"},
        {"id": 2, "name": "Bob"}
    ]`);
    db.setTableData("posts", `[
        {"id": 1, "title": "Alice Post 1", "author_id": 1},
        {"id": 2, "title": "Alice Post 2", "author_id": 1},
        {"id": 3, "title": "Alice Post 3", "author_id": 1},
        {"id": 4, "title": "Alice Post 4", "author_id": 1},
        {"id": 5, "title": "Alice Post 5", "author_id": 1},
        {"id": 6, "title": "Bob Post 1", "author_id": 2},
        {"id": 7, "title": "Bob Post 2", "author_id": 2},
        {"id": 8, "title": "Bob Post 3", "author_id": 2},
        {"id": 9, "title": "Bob Post 4", "author_id": 2},
        {"id": 10, "title": "Bob Post 5", "author_id": 2}
    ]`);

    // Query with nested pagination: get first 2 posts for each user
    auto query = compileQuery!PaginatedSchema(`{
        users {
            name
            posts(first: 2) {
                title
            }
        }
    }`);

    auto result = awaitSync(new Executor().execute(query));

    // Debug output
    string debugInfo = "Result: " ~ result.to!string;

    // Should have 2 users
    assert(result["users"].array.length == 2, "Should have 2 users. " ~ debugInfo);

    // Each user should have at most 2 posts (per-parent pagination)
    foreach (i, user; result["users"].array) {
        auto posts = user["posts"].array;
        assert(posts.length == 2,
            "User " ~ i.to!string ~ " should have 2 posts, got " ~ posts.length.to!string ~ ". " ~ debugInfo);
    }

    // Check specific posts - Alice's first 2 posts
    auto alicePosts = result["users"][0]["posts"].array;
    assert(alicePosts[0]["title"].str == "Alice Post 1",
        "First post should be 'Alice Post 1'. " ~ debugInfo);
    assert(alicePosts[1]["title"].str == "Alice Post 2",
        "Second post should be 'Alice Post 2'. " ~ debugInfo);

    // Check Bob's first 2 posts
    auto bobPosts = result["users"][1]["posts"].array;
    assert(bobPosts[0]["title"].str == "Bob Post 1",
        "First post should be 'Bob Post 1'. " ~ debugInfo);
    assert(bobPosts[1]["title"].str == "Bob Post 2",
        "Second post should be 'Bob Post 2'. " ~ debugInfo);
}

// Test nested pagination with offset - skip first N posts per user
unittest {
    import std.json;
    import std.conv : to;
    import ae.utils.promise.await : awaitSync;
    import dunamis.core;
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import dunamis.relational.eval_context;
    import dunamis.graphql.schema : Schema, GqlHidden;
    import dunamis.graphql.compiler : compileQuery;

    // Wrap in struct to allow forward references
    struct TestSchema {
        static MockDB!() db;

        @DemoEntity!(db, "posts")
        struct Post {
            mixin DemoId;
            mixin Col!("title", string);
            @GqlHidden mixin Col!("authorId", long, "author_id");
        }

        @DemoEntity!(db, "users")
        struct User {
            mixin DemoId;
            mixin Col!("name", string);
            mixin HasMany!("posts", Post, "author_id");
        }

        struct Query {
            mixin Table!(User, "users");
        }
    }

    alias db = TestSchema.db;
    alias Query = TestSchema.Query;

    alias PaginatedSchema = PaginationPlugin!(Schema!Query);

    db = new MockDB!();
    db.setTableData("users", `[
        {"id": 1, "name": "Alice"}
    ]`);
    db.setTableData("posts", `[
        {"id": 1, "title": "Post 1", "author_id": 1},
        {"id": 2, "title": "Post 2", "author_id": 1},
        {"id": 3, "title": "Post 3", "author_id": 1},
        {"id": 4, "title": "Post 4", "author_id": 1},
        {"id": 5, "title": "Post 5", "author_id": 1}
    ]`);

    // Query with offset: skip first 2, take next 2
    auto query = compileQuery!PaginatedSchema(`{
        users {
            name
            posts(first: 2, offset: 2) {
                title
            }
        }
    }`);

    auto result = awaitSync(new Executor().execute(query));

    string debugInfo = "Result: " ~ result.to!string;

    // Should have 1 user
    assert(result["users"].array.length == 1, "Should have 1 user. " ~ debugInfo);

    // User should have 2 posts (skip 2, take 2 from 5 total)
    auto posts = result["users"][0]["posts"].array;
    assert(posts.length == 2, "Should have 2 posts. " ~ debugInfo);

    // Posts should be Post 3 and Post 4 (skipped first 2)
    assert(posts[0]["title"].str == "Post 3",
        "First post should be 'Post 3'. " ~ debugInfo);
    assert(posts[1]["title"].str == "Post 4",
        "Second post should be 'Post 4'. " ~ debugInfo);
}
