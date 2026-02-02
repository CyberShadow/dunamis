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
module graphqld2.graphql.pagination;

import std.traits : ReturnType, Parameters, ParameterDefaults, ParameterIdentifierTuple;
import std.typecons : Nullable;

import graphqld2.core.expr : Expr, ExprResultType;
import graphqld2.core.pagination : limit, offset, LimitInfo, OffsetInfo;
import graphqld2.graphql.plugin;
import graphqld2.graphql.schema : isSchema;

// ============================================================================
// PaginationPlugin
// ============================================================================

/// Plugin that adds first/offset pagination arguments to all array-returning fields.
///
/// Transforms:
///   users: [User!]!
/// Into:
///   users(first: Int, offset: Int): [User!]!
///
/// Example:
/// ---
/// struct Query {
///     mixin Table!(User, "users");
///     mixin Table!(Post, "posts");
///
///     static auto apiVersion(Expr!Query q) {
///         return constant("1.0", q);
///     }
/// }
///
/// alias BaseSchema = Schema!Query;
/// alias PaginatedSchema = PaginationPlugin!BaseSchema;
///
/// // Now:
/// //   users(first: Int, offset: Int): [User!]!
/// //   posts(first: Int, offset: Int): [Post!]!
/// //   apiVersion: String!  (unchanged - not an array)
/// ---
template PaginationPlugin(alias S) if (isSchema!S) {
    // Generate PaginatedQuery struct with transformed fields
    struct PaginatedQuery {
        static foreach (member; getFieldMembers!(S.Query)) {
            static if (isArrayReturningField!(__traits(getMember, S.Query, member))) {
                // Array field: add pagination arguments
                mixin PaginatedArrayField!(S.Query, member);
            } else {
                // Non-array field: forward unchanged
                mixin ForwardField!(S.Query, member);
            }
        }
    }

    alias Query = PaginatedQuery;
    alias Mutation = S.Mutation;
}

// ============================================================================
// Mixin Templates for Field Generation
// ============================================================================

/// Mixin template to create a paginated version of an array-returning field.
/// Adds first/offset parameters and wraps the result with limit/offset expressions.
mixin template PaginatedArrayField(SourceQuery, string fieldName) {
    import std.traits : Parameters, ParameterDefaults, ParameterIdentifierTuple;
    import std.meta : AliasSeq;
    import graphqld2.core.expr : Expr, ExprResultType, entityCast;
    import graphqld2.core.pagination : limit, offset;

    // Get the source function and its metadata
    alias _srcFn = __traits(getMember, SourceQuery, fieldName);
    alias _SrcParams = Parameters!_srcFn;
    alias _SrcDefaults = ParameterDefaults!_srcFn;
    enum string[] _srcParamNames = [ParameterIdentifierTuple!_srcFn];

    // Extract the source entity type from first parameter
    alias _SrcFirstParam = _SrcParams[0];
    alias _SrcEntity = ExprResultType!_SrcFirstParam;

    // Build parameter list string at compile time
    // First param: Expr!(typeof(this)) instead of Expr!SourceQuery
    // Rest: same types with defaults preserved
    // Finally: add first and offset params
    enum string _paramListStr = () {
        string result = "Expr!(typeof(this)) " ~ _srcParamNames[0];
        static foreach (i; 1 .. _SrcParams.length) {{
            result ~= ", ";
            result ~= _SrcParams[i].stringof ~ " " ~ _srcParamNames[i];
            // Add default value if present
            static if (!is(_SrcDefaults[i] == void)) {
                result ~= " = " ~ _SrcDefaults[i].stringof;
            }
        }}
        // Add pagination params
        result ~= ", Nullable!int first = Nullable!int.init";
        result ~= ", Nullable!int offset = Nullable!int.init";
        return result;
    }();

    // Build argument list string for calling original function
    // First arg: entityCast to convert Expr!(typeof(this)) -> Expr!SourceQuery
    // Rest: pass through unchanged
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
    // Returns Expr!(_ElementType[]) which is the common base type
    private static Expr!(_ElementType[]) _applyPagination(T)(T base, Nullable!int first, Nullable!int offset) {
        // Apply offset first, then limit
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
          "return _applyPagination(_srcFn(" ~ _argListStr ~ "), first, offset); }");
}

// ============================================================================
// Unit Tests
// ============================================================================

unittest {
    import graphqld2.relational.schema;
    import graphqld2.relational.demo;
    import graphqld2.graphql.schema : Schema, generateSchemaSDL;
    import graphqld2.core.expr : constant;
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
    import graphqld2.core;
    import graphqld2.core.expr : constant;
    import graphqld2.relational.schema;
    import graphqld2.relational.demo;
    import graphqld2.relational.eval_context;
    import graphqld2.graphql.schema : Schema;
    import graphqld2.graphql.compiler : compileQuery;

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
    import graphqld2.core;
    import graphqld2.relational.schema;
    import graphqld2.relational.demo;
    import graphqld2.relational.eval_context;
    import graphqld2.graphql.schema : Schema;
    import graphqld2.graphql.compiler : compileQuery;

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
