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
module dynamo.graphql.pagination;

import std.traits : ReturnType, Parameters, ParameterDefaults, ParameterIdentifierTuple;
import std.typecons : Nullable;

import dynamo.core.expr : Expr, ExprResultType;
import dynamo.core.pagination : limit, offset, LimitInfo, OffsetInfo;
import dynamo.graphql.plugin;
import dynamo.graphql.schema : isSchema;

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
    import std.meta : AliasSeq, staticMap;
    import dynamo.graphql.schema : getAllEntityTypes, getGraphQLTypeName, GqlName;
    import dynamo.graphql.transform : isTypeInList;

    // Get all entity types discovered from the schema
    alias _OriginalQuery = S.Query;
    alias _AllEntityTypes = getAllEntityTypes!_OriginalQuery;

    // Generate paginated versions of each entity type.
    template PaginatedEntity(Entity) {
        @GqlName(getGraphQLTypeName!Entity)
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

    struct PaginatedQuery {
        mixin WrapFields!(_OriginalQuery, EntityTypeMap, PaginatedArrayField);
    }

    struct PaginatedMutation {
        mixin WrapFields!(S.Mutation, EntityTypeMap, PaginatedArrayField);
    }

    alias Query = PaginatedQuery;
    alias Mutation = PaginatedMutation;

    alias Config = S.Config;
}

/// Mixin template to create a paginated version of an array-returning field.
/// Adds first/offset parameters and wraps the result with limit/offset expressions.
/// Uses type aliases instead of stringof to preserve type scope across plugin composition.
mixin template PaginatedArrayField(SourceQuery, string fieldName, alias TypeMap) {
    import std.traits : Parameters, ParameterDefaults, ParameterIdentifierTuple;
    import std.meta : AliasSeq;
    import std.conv : to;
    import dynamo.core.expr : Expr, ExprResultType, entityCast;
    import dynamo.core.pagination : limit, offset;
    import dynamo.graphql.transform : wrapEntityResult;

    // Get the source function and its metadata
    alias _srcFn = __traits(getMember, SourceQuery, fieldName);
    alias _SrcParams = Parameters!_srcFn;
    alias _SrcDefaults = ParameterDefaults!_srcFn;
    enum string[] _srcParamNames = [ParameterIdentifierTuple!_srcFn];

    // Extract the source entity type from first parameter
    alias _SrcFirstParam = _SrcParams[0];
    alias _SrcEntity = ExprResultType!_SrcFirstParam;

    // Generate type aliases for each parameter to preserve type scope
    static foreach (i; 1 .. _SrcParams.length) {
        mixin("alias _ParamType" ~ i.to!string ~ " = _SrcParams[" ~ i.to!string ~ "];");
    }

    // Build parameter list string using type aliases
    enum string _paramListStr = () {
        string result = "Expr!(typeof(this)) " ~ _srcParamNames[0];
        static foreach (i; 1 .. _SrcParams.length) {{
            result ~= ", ";
            result ~= "_ParamType" ~ i.to!string ~ " " ~ _srcParamNames[i];
            static if (!is(_SrcDefaults[i] == void)) {
                result ~= " = _SrcDefaults[" ~ i.to!string ~ "]";
            }
        }}
        // Add pagination params
        result ~= ", Nullable!int first = Nullable!int.init";
        result ~= ", Nullable!int offset = Nullable!int.init";
        return result;
    }();

    // Build argument list string for calling original function
    enum string _argListStr = () {
        string result = "entityCast!(_SrcEntity)(" ~ _srcParamNames[0] ~ ")";
        static foreach (i; 1 .. _SrcParams.length) {
            result ~= ", " ~ _srcParamNames[i];
        }
        return result;
    }();

    // Extract element type from array expression
    alias _ElementType = ArrayFieldElementType!_srcFn;

    // Helper function to apply pagination (avoids type inference issues in mixin)
    private static Expr!(_ElementType[]) _applyPagination(T)(T base, Nullable!int first, Nullable!int offset) {
        if (offset.isNull && first.isNull) {
            return base;
        } else if (offset.isNull) {
            return base.limit(cast(size_t) first.get);
        } else if (first.isNull) {
            return base.offset(cast(size_t) offset.get);
        } else {
            return base.offset(cast(size_t) offset.get).limit(cast(size_t) first.get);
        }
    }

    // Generate the paginated method with UDAs preserved
    @(__traits(getAttributes, _srcFn))
    mixin("static auto " ~ fieldName ~ "(" ~ _paramListStr ~ ") { " ~
          "return wrapEntityResult!(TypeMap)(_applyPagination(_srcFn(" ~ _argListStr ~ "), first, offset)); }");
}

// ============================================================================
// Unit Tests
// ============================================================================

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
    import dynamo.core;
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
    import dynamo.relational.schema;
    import dynamo.relational.demo;
    import dynamo.graphql.schema : Schema, generateSchemaSDL;
    import std.algorithm : canFind;

    static MockDB!() db;

    // For circular references (User -> Post -> User), we need forward declaration pattern.
    // In D, we can use a mixin template with string for deferred resolution.

    // Simple test case: User has posts (no back-reference to avoid circular issue)
    static struct Post {
        mixin DemoEntity!(db, "posts");
        mixin Col!("title", string);
    }

    static struct User {
        mixin DemoEntity!(db, "users");
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
    import dynamo.core;
    import dynamo.relational.schema;
    import dynamo.relational.demo;
    import dynamo.relational.eval_context;
    import dynamo.graphql.schema : Schema, GqlHidden;
    import dynamo.graphql.compiler : compileQuery;

    // Wrap in struct to allow forward references
    struct TestSchema {
        static MockDB!() db;

        struct Post {
            mixin DemoEntity!(db, "posts");
            mixin Col!("title", string);
            @GqlHidden mixin Col!("authorId", long, "author_id");
        }

        struct User {
            mixin DemoEntity!(db, "users");
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
    import dynamo.core;
    import dynamo.relational.schema;
    import dynamo.relational.demo;
    import dynamo.relational.eval_context;
    import dynamo.graphql.schema : Schema, GqlHidden;
    import dynamo.graphql.compiler : compileQuery;

    // Wrap in struct to allow forward references
    struct TestSchema {
        static MockDB!() db;

        struct Post {
            mixin DemoEntity!(db, "posts");
            mixin Col!("title", string);
            @GqlHidden mixin Col!("authorId", long, "author_id");
        }

        struct User {
            mixin DemoEntity!(db, "users");
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
