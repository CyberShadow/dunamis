/// Sorting plugin for GraphQL schemas.
///
/// The SortingPlugin automatically adds `orderBy` sorting arguments
/// to all array-returning fields in the Query type.
///
/// Example:
/// ---
/// alias BaseSchema = Schema!Query;
/// alias SortedSchema = SortingPlugin!BaseSchema;
///
/// // users: [User!]! becomes users(orderBy: [UserOrderBy!]): [User!]!
/// ---
module dunamis.graphql.sorting;

import std.traits : ReturnType, Parameters, ParameterDefaults, ParameterIdentifierTuple;
import std.typecons : Nullable;

import dunamis.core.expr : Expr, ExprResultType;
import dunamis.core.sorting : SortDirection;
import dunamis.graphql.plugin;
import dunamis.graphql.schema : isSchema, GqlHidden;

// ============================================================================
// SortingPlugin
// ============================================================================

/// Plugin that adds orderBy sorting arguments to all array-returning fields,
/// including nested HasMany relationships.
///
/// For each entity type E, generates:
/// - enum EOrderByField { id, field1, field2, ... } - all sortable column fields
/// - struct EOrderBy { EOrderByField field; SortDirection direction = SortDirection.ASC; }
///
/// Transforms root Query fields:
///   users: [User!]!
/// Into:
///   users(orderBy: [UserOrderBy!]): [User!]!
///
/// And nested entity fields:
///   User.posts: [Post!]!
/// Into:
///   User.posts(orderBy: [PostOrderBy!]): [Post!]!
///
/// Example:
/// ---
/// struct Query {
///     mixin Table!(User, "users");
///     mixin Table!(Post, "posts");
/// }
///
/// alias BaseSchema = Schema!Query;
/// alias SortedSchema = SortingPlugin!BaseSchema;
///
/// // Query with sorting:
/// // { users(orderBy: [{field: lastName, direction: DESC}]) { posts(orderBy: [{field: title}]) { title } } }
/// ---
template SortingPlugin(alias S) if (isSchema!S) {
    import std.meta : AliasSeq, staticMap;
    import dunamis.graphql.schema : getAllObjectTypes, getGraphQLTypeName, GqlName;
    import dunamis.graphql.transform : isTypeInList;

    // Get all entity types discovered from the schema
    alias _OriginalQuery = S.Query;
    alias _AllEntityTypes = getAllObjectTypes!_OriginalQuery;

    // Generate sorted versions of each entity type.
    template SortedEntity(Entity) {
        @(__traits(getAttributes, Entity))
        @GqlName(getGraphQLTypeName!Entity)
        struct SortedEntity {
            mixin WrapFields!(Entity, EntityTypeMap, SortedArrayField);
        }
    }

    // Map all entity types to their sorted versions
    alias AllEntityTypes = staticMap!(SortedEntity, _AllEntityTypes);

    /// Entity type map: maps discovered entity types to their sorted versions.
    template EntityTypeMap(T) {
        static if (isTypeInList!(T, _AllEntityTypes)) {
            alias EntityTypeMap = SortedEntity!T;
        } else {
            alias EntityTypeMap = T;
        }
    }

    struct SortedQuery {
        mixin WrapFields!(_OriginalQuery, EntityTypeMap, SortedArrayField);
    }

    struct SortedMutation {
        mixin WrapFields!(S.Mutation, EntityTypeMap, SortedArrayField);
    }

    alias Query = SortedQuery;
    alias Mutation = SortedMutation;
}

// ============================================================================
// Helper Templates for OrderBy Type Generation
// ============================================================================

/// Get sortable field names from an entity type.
/// A field is sortable if its D result type supports the `<` operator
/// and it takes no required arguments beyond the entity expression.
/// Enum fields are temporarily excluded pending native DB enum type support.
template getSortableFields(Entity) {
    import dunamis.graphql.schema : hasGqlHidden;
    import std.traits : Parameters;

    /// Check if a method can be called with just Expr!Entity (no extra required args).
    private template isZeroArgField(alias method) {
        alias Params = Parameters!method;
        static if (Params.length <= 1) {
            enum isZeroArgField = true;
        } else {
            // Check that all params beyond the first have defaults
            alias Defaults = ParameterDefaults!method;
            enum isZeroArgField = () {
                static foreach (i; 1 .. Params.length) {
                    static if (is(Defaults[i] == void))
                        return false;
                }
                return true;
            }();
        }
    }

    enum getSortableFields = () {
        string[] fields;
        static foreach (member; __traits(allMembers, Entity)) {{
            static if (!isInternalMember!member) {
                static if (__traits(compiles, __traits(getMember, Entity, member)) &&
                           is(typeof(__traits(getMember, Entity, member)) == function)) {
                    alias method = __traits(getMember, Entity, member);
                    alias ResultT = ExprResultType!(ReturnType!method);
                    // Include if:
                    // - callable with just Expr!Entity (no required extra args)
                    // - not @GqlHidden
                    // - not an enum (temporarily excluded: DB sort order may differ from D)
                    // - result type supports `<` (excludes ForeignKey, Nullable, entities, arrays)
                    static if (isZeroArgField!method && !hasGqlHidden!method
                            && !hasEnumReturn!method
                            && is(typeof(ResultT.init < ResultT.init))) {
                        fields ~= member;
                    }
                }
            }
        }}
        return fields;
    }();
}

/// Check if a method returns an enum type (Expr!SomeEnum or Expr!(Nullable!SomeEnum))
private template hasEnumReturn(alias method) {
    import std.traits : ReturnType;
    import std.typecons : Nullable;
    import dunamis.core.expr : ExprResultType;
    alias ResultT = ExprResultType!(ReturnType!method);
    static if (is(ResultT == Nullable!U, U)) {
        enum hasEnumReturn = is(U == enum);
    } else {
        enum hasEnumReturn = is(ResultT == enum);
    }
}

// ============================================================================
// Code Template for Sorted Array Fields
// ============================================================================

/// Eponymous code template for SortedArrayField.
/// Builds the complete mixin string including OrderBy types, helper functions,
/// and the sorted method. All metadata stays encapsulated — no leaks.
template SortedArrayFieldCode(SourceQuery, string fieldName, alias TypeMap) {
    import std.conv : to;
    import dunamis.graphql.forward : ForwardFieldImpl;

    private alias Impl = ForwardFieldImpl!(SourceQuery, fieldName, TypeMap);
    private alias _ElementType = ArrayFieldElementType!(Impl.srcFn);

    // .imported references for generated code
    private enum string _I = ".imported!q{dunamis.graphql.forward}.ForwardFieldImpl!(SourceQuery, \"" ~ fieldName ~ "\", TypeMap)";
    private enum string _Expr = ".imported!q{dunamis.core.expr}.Expr";
    private enum string _entityCast = ".imported!q{dunamis.graphql.entity_cast}.pluginEntityCast";
    private enum string _sortBy = ".imported!q{dunamis.core.sorting}.sortBy";
    private enum string _SD = ".imported!q{dunamis.core.sorting}.SortDirection";
    private enum string _wrap = ".imported!q{dunamis.graphql.transform}.wrapEntityResult";

    // Field-specific names to avoid conflicts when multiple array fields coexist
    private enum string _enumName = "_OrderByFieldEnum_" ~ fieldName;
    private enum string _structName = "_OrderByStruct_" ~ fieldName;
    private enum string _singleSort = "_applySingleSort_" ~ fieldName;
    private enum string _sorting = "_applySorting_" ~ fieldName;

    enum SortedArrayFieldCode = () {
        string result = "";

        enum sortableFields = getSortableFields!_ElementType;

        // --- OrderBy types and helper functions ---
        static if (sortableFields.length > 0) {
            // Enum
            result ~= "enum " ~ _enumName ~ " {\n";
            static foreach (f; sortableFields) {
                result ~= "    " ~ f ~ ",\n";
            }
            result ~= "}\n\n";

            // Struct
            result ~= "struct " ~ _structName ~ " {\n";
            result ~= "    " ~ _enumName ~ " field;\n";
            result ~= "    " ~ _SD ~ " direction = " ~ _SD ~ ".ASC;\n";
            result ~= "}\n\n";

            // _applySingleSort: wraps source with a single-column SortByExpr.
            // Templated on source type so it works with plugin-wrapped entity types.
            // Local alias needed: is(S : Expr!(E[]), E) pattern matching doesn't work with .imported.
            result ~= "private static auto " ~ _singleSort ~ "(S)(S source, " ~ _enumName ~ " field, " ~ _SD ~ " dir) {\n";
            result ~= "    alias _E = " ~ _Expr ~ ";\n";
            result ~= "    static assert(is(S : _E!(E[]), E), \"Expected Expr!(E[])\");\n";
            result ~= "    static if (is(S : _E!(E[]), E)) {\n";
            result ~= "        _E!(E[]) _result;\n";
            result ~= "        final switch (field) {\n";
            static foreach (member; sortableFields) {
                result ~= "            case " ~ _enumName ~ "." ~ member ~ ":\n";
                result ~= "                if (dir == " ~ _SD ~ ".ASC)\n";
                result ~= "                    _result = " ~ _sortBy ~ "!((a, b) => a." ~ member ~ ".lt(b." ~ member ~ "))(source);\n";
                result ~= "                else\n";
                result ~= "                    _result = " ~ _sortBy ~ "!((a, b) => a." ~ member ~ ".gt(b." ~ member ~ "))(source);\n";
                result ~= "                break;\n";
            }
            result ~= "        }\n";
            result ~= "        return _result;\n";
            result ~= "    }\n";
            result ~= "}\n\n";

            // _applySorting: nests SortByExpr wrappers for multi-column sorting.
            // Applied in reverse so the first spec (highest priority) is the outermost wrapper.
            result ~= "private static auto " ~ _sorting ~ "(S)(S base, " ~ _structName ~ "[] orderBySpecs) {\n";
            result ~= "    alias _E = " ~ _Expr ~ ";\n";
            result ~= "    static assert(is(S : _E!(E[]), E), \"Expected Expr!(E[])\");\n";
            result ~= "    static if (is(S : _E!(E[]), E)) {\n";
            result ~= "        _E!(E[]) result = base;\n";
            result ~= "        if (orderBySpecs is null || orderBySpecs.length == 0) {\n";
            result ~= "            return result;\n";
            result ~= "        }\n";
            result ~= "        foreach_reverse (ob; orderBySpecs) {\n";
            result ~= "            result = " ~ _singleSort ~ "(result, ob.field, ob.direction);\n";
            result ~= "        }\n";
            result ~= "        return result;\n";
            result ~= "    }\n";
            result ~= "}\n\n";
        }

        // --- Build parameter list ---
        string paramList = _Expr ~ "!(typeof(this)) " ~ Impl.srcParamNames[0];
        static foreach (i; 1 .. Impl.SrcParams.length) {{
            paramList ~= ", " ~ _I ~ ".SrcParams[" ~ i.to!string ~ "] " ~ Impl.srcParamNames[i];
            static if (!is(Impl.SrcDefaults[i] == void)) {
                paramList ~= " = " ~ _I ~ ".SrcDefaults[" ~ i.to!string ~ "]";
            }
        }}
        static if (sortableFields.length > 0) {
            paramList ~= ", " ~ _structName ~ "[] orderBy = null";
        }

        // --- Build argument list ---
        string argList = _entityCast ~ "!(" ~ _I ~ ".SrcEntity)(" ~ Impl.srcParamNames[0] ~ ")";
        static foreach (i; 1 .. Impl.SrcParams.length) {
            argList ~= ", " ~ Impl.srcParamNames[i];
        }

        // --- Generate method ---
        // Sorting is applied AFTER wrapEntityResult so SortByExpr wraps the
        // entity-cast MapExpr, keeping it visible to the optimizer unwrapping loop.
        static if (sortableFields.length > 0) {
            result ~= "@(__traits(getAttributes, " ~ _I ~ ".srcFn)) " ~
                      "static auto " ~ fieldName ~ "(" ~ paramList ~ ") { " ~
                      "return " ~ _sorting ~ "(" ~ _wrap ~ "!(TypeMap)(" ~
                      _I ~ ".srcFn(" ~ argList ~ ")), orderBy); }";
        } else {
            result ~= "@(__traits(getAttributes, " ~ _I ~ ".srcFn)) " ~
                      "static auto " ~ fieldName ~ "(" ~ paramList ~ ") { " ~
                      "return " ~ _wrap ~ "!(TypeMap)(" ~
                      _I ~ ".srcFn(" ~ argList ~ ")); }";
        }

        return result;
    }();
}

/// Mixin template to create a sorted version of an array-returning field.
/// Zero-leak: delegates to SortedArrayFieldCode eponymous template.
mixin template SortedArrayField(SourceQuery, string fieldName, alias TypeMap) {
    mixin(SortedArrayFieldCode!(SourceQuery, fieldName, TypeMap));
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
        mixin Col!("firstName", string);
        mixin Col!("lastName", string);
    }

    static struct Query {
        mixin Table!(User, "users");

        // Non-array field - should remain unchanged
        static auto apiVersion(Expr!Query q) {
            return constant("1.0", q);
        }
    }

    alias BaseSchema = Schema!Query;
    alias SortedSchema = SortingPlugin!BaseSchema;

    // Verify it's a valid schema
    static assert(isSchema!SortedSchema);

    // Verify SDL shows sorting arguments on array field
    enum sdl = generateSchemaSDL!SortedSchema;

    // Array field should have orderBy arg
    static assert(sdl.canFind("users("), "users should have arguments: " ~ sdl);
    static assert(sdl.canFind("orderBy:"), "should have orderBy arg: " ~ sdl);

    // Non-array field should remain unchanged
    static assert(sdl.canFind("apiVersion:"), "apiVersion should exist: " ~ sdl);
    static assert(!sdl.canFind("apiVersion("), "apiVersion should not have args: " ~ sdl);
}

unittest {
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import dunamis.graphql.schema : Schema, generateSchemaSDL;
    import std.algorithm : canFind;

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("firstName", string);
        mixin Col!("lastName", string);

        @GqlHidden mixin Col!("internalField", string);
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    // Test that sortable fields are correctly detected
    enum sortableFields = getSortableFields!User;
    static assert(sortableFields.length >= 2, "Should have at least firstName, lastName");

    // Verify hidden fields are not included
    import std.algorithm : canFind;
    static assert(!sortableFields.canFind("internalField"), "Hidden field should not be sortable");
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

    alias SortedSchema = SortingPlugin!(Schema!Query);

    // Set up mock data
    db = new MockDB!();
    db.setTableData("users", `[
        {"id": 1, "name": "Charlie"},
        {"id": 2, "name": "Alice"},
        {"id": 3, "name": "Bob"}
    ]`);

    // Query with sorting by name ASC
    auto query = compileQuery!SortedSchema(`{
        users(orderBy: [{field: name, direction: ASC}]) {
            name
        }
    }`);

    auto result = awaitSync(new Executor().execute(query));

    // Should return in alphabetical order: Alice, Bob, Charlie
    assert(result["users"].array.length == 3, "Should have 3 users");
    assert(result["users"][0]["name"].str == "Alice", "First should be Alice");
    assert(result["users"][1]["name"].str == "Bob", "Second should be Bob");
    assert(result["users"][2]["name"].str == "Charlie", "Third should be Charlie");
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

    alias SortedSchema = SortingPlugin!(Schema!Query);

    db = new MockDB!();
    db.setTableData("users", `[
        {"id": 1, "name": "Charlie"},
        {"id": 2, "name": "Alice"},
        {"id": 3, "name": "Bob"}
    ]`);

    // Query with sorting by name DESC
    auto query = compileQuery!SortedSchema(`{
        users(orderBy: [{field: name, direction: DESC}]) {
            name
        }
    }`);

    auto result = awaitSync(new Executor().execute(query));

    // Should return in reverse alphabetical order: Charlie, Bob, Alice
    assert(result["users"][0]["name"].str == "Charlie", "First should be Charlie");
    assert(result["users"][1]["name"].str == "Bob", "Second should be Bob");
    assert(result["users"][2]["name"].str == "Alice", "Third should be Alice");
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

    alias SortedSchema = SortingPlugin!(Schema!Query);

    db = new MockDB!();
    db.setTableData("users", `[
        {"id": 1, "name": "Charlie"},
        {"id": 2, "name": "Alice"},
        {"id": 3, "name": "Bob"}
    ]`);

    // Query without orderBy - should return in default (insertion) order
    auto query = compileQuery!SortedSchema(`{
        users {
            name
        }
    }`);

    auto result = awaitSync(new Executor().execute(query));

    // Should return all users (order may vary)
    assert(result["users"].array.length == 3, "Should have all 3 users");
}

// Test nested HasMany sorting - SDL should show orderBy args on nested fields
unittest {
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import dunamis.graphql.schema : Schema, generateSchemaSDL;
    import std.algorithm : canFind;

    static MockDB!() db;

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

    alias SortedSchema = SortingPlugin!(Schema!Query);

    // Verify SDL shows sorting arguments on NESTED array fields
    enum sdl = generateSchemaSDL!SortedSchema;

    // Root Query fields should have sorting
    static assert(sdl.canFind("users("), "Query.users should have arguments: " ~ sdl);

    // User.posts (HasMany) should have sorting
    static assert(sdl.canFind("posts(orderBy:"), "User.posts should have orderBy arg: " ~ sdl);
}

// Test nested HasMany sorting - runtime execution
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

    alias SortedSchema = SortingPlugin!(Schema!Query);

    // Set up mock data
    db = new MockDB!();
    db.setTableData("users", `[
        {"id": 1, "name": "Alice"}
    ]`);
    db.setTableData("posts", `[
        {"id": 1, "title": "Zebra", "author_id": 1},
        {"id": 2, "title": "Apple", "author_id": 1},
        {"id": 3, "title": "Mango", "author_id": 1}
    ]`);

    // Query with nested sorting: sort posts by title ASC
    auto query = compileQuery!SortedSchema(`{
        users {
            name
            posts(orderBy: [{field: title, direction: ASC}]) {
                title
            }
        }
    }`);

    auto result = awaitSync(new Executor().execute(query));

    string debugInfo = "Result: " ~ result.to!string;

    // Should have 1 user
    assert(result["users"].array.length == 1, "Should have 1 user. " ~ debugInfo);

    // Posts should be sorted alphabetically
    auto posts = result["users"][0]["posts"].array;
    assert(posts.length == 3, "Should have 3 posts. " ~ debugInfo);
    assert(posts[0]["title"].str == "Apple", "First should be Apple. " ~ debugInfo);
    assert(posts[1]["title"].str == "Mango", "Second should be Mango. " ~ debugInfo);
    assert(posts[2]["title"].str == "Zebra", "Third should be Zebra. " ~ debugInfo);
}

// Test multiple entity types with nested HasMany (User -> Post -> Comment chain)
unittest {
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import dunamis.graphql.schema : Schema, generateSchemaSDL;
    import std.algorithm : canFind;

    // Wrap in struct to allow forward references between types
    struct TestSchema {
        static MockDB!() db;

        @DemoEntity!(db, "comments")
        struct Comment {
            mixin DemoId;
            mixin Col!("text", string);
        }

        @DemoEntity!(db, "posts")
        struct Post {
            mixin DemoId;
            mixin Col!("title", string);
            mixin HasMany!("comments", Comment, "post_id");
        }

        @DemoEntity!(db, "users")
        struct User {
            mixin DemoId;
            mixin Col!("name", string);
            mixin HasMany!("posts", Post, "author_id");
        }

        struct Query {
            mixin Table!(User, "users");
            mixin Table!(Post, "posts");
        }
    }

    alias Query = TestSchema.Query;

    // This should compile without infinite recursion
    alias SortedSchema = SortingPlugin!(Schema!Query);

    // Verify it's a valid schema
    static assert(isSchema!SortedSchema);

    // Verify SDL is generated correctly
    enum sdl = generateSchemaSDL!SortedSchema;

    // Root fields should have sorting
    static assert(sdl.canFind("users(orderBy:"), "Query.users should have orderBy: " ~ sdl);
    static assert(sdl.canFind("posts(orderBy:"), "Query.posts should have orderBy: " ~ sdl);

    // Nested HasMany should have sorting
    // User.posts and Post.comments
    static assert(sdl.canFind("comments(orderBy:"), "HasMany fields should have orderBy: " ~ sdl);
}

// Test that verifies firstName is correctly converted to first_name SQL column
unittest {
    import std.algorithm : canFind;
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
        mixin Col!("firstName", string);  // firstName -> first_name in SQL
        mixin Col!("lastName", string);   // lastName -> last_name in SQL
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    alias SortedSchema = SortingPlugin!(Schema!Query);

    // Set up mock data
    db = new MockDB!();
    db.setTableData("users", `[
        {"id": 1, "first_name": "Charlie", "last_name": "Zebra"},
        {"id": 2, "first_name": "Alice", "last_name": "Young"},
        {"id": 3, "first_name": "Bob", "last_name": "Xavier"}
    ]`);

    // Query with sorting by firstName ASC
    auto query = compileQuery!SortedSchema(`{
        users(orderBy: [{field: firstName, direction: ASC}]) {
            firstName
            lastName
        }
    }`);

    auto result = awaitSync(new Executor().execute(query));

    // Verify sorting by firstName worked
    assert(result["users"].array.length == 3, "Should have 3 users");
    assert(result["users"][0]["firstName"].str == "Alice", "First by firstName should be Alice");
    assert(result["users"][1]["firstName"].str == "Bob", "Second by firstName should be Bob");
    assert(result["users"][2]["firstName"].str == "Charlie", "Third by firstName should be Charlie");

    // Now test sorting by lastName
    auto query2 = compileQuery!SortedSchema(`{
        users(orderBy: [{field: lastName, direction: DESC}]) {
            firstName
            lastName
        }
    }`);

    auto result2 = awaitSync(new Executor().execute(query2));

    // Verify sorting by lastName DESC worked (Zebra, Young, Xavier)
    assert(result2["users"][0]["lastName"].str == "Zebra", "First by lastName DESC should be Zebra");
    assert(result2["users"][1]["lastName"].str == "Young", "Second by lastName DESC should be Young");
    assert(result2["users"][2]["lastName"].str == "Xavier", "Third by lastName DESC should be Xavier");
}
