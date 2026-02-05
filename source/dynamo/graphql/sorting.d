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
module dynamo.graphql.sorting;

import std.traits : ReturnType, Parameters, ParameterDefaults, ParameterIdentifierTuple;
import std.typecons : Nullable;

import dynamo.core.expr : Expr, ExprResultType;
import dynamo.core.sorting : orderBy, OrderByInfo, SortDirection;
import dynamo.core.sorting : OrderBySpec = OrderBySpec;
import dynamo.graphql.plugin;
import dynamo.graphql.schema : isSchema, GqlHidden;

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
    import dynamo.graphql.schema : getAllEntityTypes, getGraphQLTypeName, GqlName;
    import dynamo.graphql.transform : isTypeInList;

    // Get all entity types discovered from the schema
    alias _OriginalQuery = S.Query;
    alias _AllEntityTypes = getAllEntityTypes!_OriginalQuery;

    // Generate SortedQuery struct with transformed fields
    struct SortedQuery {
        static foreach (member; getFieldMembers!(_OriginalQuery)) {
            static if (isArrayReturningField!(__traits(getMember, _OriginalQuery, member))) {
                // Array field: add sorting arguments
                mixin SortedArrayField!(_OriginalQuery, member);
            } else {
                // Non-array field: forward unchanged
                mixin ForwardField!(_OriginalQuery, member);
            }
        }
    }

    // Generate sorted versions of each entity type.
    // Each sorted entity type:
    // 1. Has @GqlName to preserve the original GraphQL type name
    // 2. Has orderBy arguments on array-returning fields
    // 3. Uses the inner schema's transformed type (for plugin composition)
    template SortedEntity(OriginalEntity) {
        import dynamo.core.types : isPlainField;

        // Get the inner schema's transformed type (e.g., FilteredEntity!User)
        // If the inner schema has EntityTypeMap, use it; otherwise use identity
        static if (__traits(hasMember, S, "EntityTypeMap")) {
            alias Entity = S.EntityTypeMap!OriginalEntity;
        } else {
            alias Entity = OriginalEntity;
        }

        // Use @GqlName to ensure the sorted type has the same GraphQL name as the original
        @GqlName(getGraphQLTypeName!OriginalEntity)
        struct SortedEntity {
            // Copy entity infrastructure from ORIGINAL entity (for nodeId type consistency)
            static if (__traits(hasMember, OriginalEntity, "nodeId")) {
                typeof(OriginalEntity.nodeId) nodeId;
                this(string id) { nodeId = typeof(nodeId)(id); }
                string toString() const { return nodeId.toString(); }
            }

            // Copy plain fields from the TRANSFORMED entity (preserves plugin composition)
            static foreach (member; __traits(allMembers, Entity)) {
                static if (isPlainField!(Entity, member)) {
                    mixin("typeof(__traits(getMember, Entity.init, \"" ~ member ~ "\")) " ~ member ~ ";");
                }
            }

            // Copy all fields from the TRANSFORMED entity (with inner schema's modifications)
            // This ensures sorting is layered on top of filtering, etc.
            static foreach (member; getFieldMembers!Entity) {
                static if (isArrayReturningField!(__traits(getMember, Entity, member))) {
                    mixin SortedEntityArrayField!(Entity, member);
                } else static if (isComputedField!(Entity, member)) {
                    mixin ForwardField!(Entity, member);
                } else {
                    // Plain method (instance method with no Expr parameter)
                    mixin ForwardPlainMethod!(Entity, member);
                }
            }
        }
    }

    // Map all entity types to their sorted versions
    alias AllEntityTypes = staticMap!(SortedEntity, _AllEntityTypes);

    /// Entity type map: maps original entity types to their sorted versions.
    /// Used by the compiler to resolve fields on transformed types.
    template EntityTypeMap(T) {
        static if (isTypeInList!(T, _AllEntityTypes)) {
            alias EntityTypeMap = SortedEntity!T;
        } else static if (__traits(hasMember, S, "EntityTypeMap")) {
            // Delegate to inner schema for non-entity types
            alias EntityTypeMap = S.EntityTypeMap!T;
        } else {
            alias EntityTypeMap = T;  // Identity for non-entity types
        }
    }

    alias Query = SortedQuery;
    alias Mutation = S.Mutation;
}

// ============================================================================
// Helper Templates for OrderBy Type Generation
// ============================================================================

/// Get sortable field names from an entity type (fields with @SqlColumn UDA).
/// Returns an array of field names that can be used in ORDER BY.
template getSortableFields(Entity) {
    import dynamo.relational.schema : hasSqlColumn;
    import dynamo.graphql.schema : hasGqlHidden;

    enum getSortableFields = () {
        string[] fields;
        static foreach (member; __traits(allMembers, Entity)) {{
            static if (!isInternalMember!member) {
                static if (__traits(compiles, __traits(getMember, Entity, member)) &&
                           is(typeof(__traits(getMember, Entity, member)) == function)) {
                    alias method = __traits(getMember, Entity, member);
                    // Include if it's a column and not hidden
                    static if (hasSqlColumn!method && !hasGqlHidden!method) {
                        fields ~= member;
                    }
                }
            }
        }}
        return fields;
    }();
}

/// Generate OrderBy enum, struct, and helper functions at compile time.
/// All types and functions that reference the enum/struct are generated together
/// in a single string mixin to ensure proper symbol visibility in nested mixin contexts.
mixin template GenerateOrderByTypes(Entity, string graphqlEnumName, string graphqlStructName) {
    import std.meta : AliasSeq;
    import dynamo.relational.schema : getSqlColumn;
    import dynamo.core.sorting : orderBy, OrderBySpec;
    import dynamo.core.expr : Expr;

    // Alias for the entity type (accessible in generated code)
    alias _SortEntity = Entity;

    // Build enum, struct, and helper functions in a single string mixin
    // This is necessary because in mixin templates, string-mixin-generated symbols
    // aren't visible to subsequent declarations within the same template
    enum _typesDef = () {
        // Generate enum
        string result = "enum _OrderByFieldEnum {\n";
        static foreach (fieldName; getSortableFields!Entity) {
            result ~= "    " ~ fieldName ~ ",\n";
        }
        result ~= "}\n\n";

        // Generate struct
        result ~= "struct _OrderByStruct {\n";
        result ~= "    _OrderByFieldEnum field;\n";
        result ~= "    SortDirection direction = SortDirection.ASC;\n";
        result ~= "}\n\n";

        // Generate _getColumnName function
        result ~= "private static string _getColumnName(_OrderByFieldEnum field) {\n";
        result ~= "    final switch (field) {\n";
        static foreach (member; getSortableFields!Entity) {{
            static if (__traits(compiles, __traits(getMember, Entity, member)) &&
                       is(typeof(__traits(getMember, Entity, member)) == function)) {
                alias method = __traits(getMember, Entity, member);
                enum sqlCol = getSqlColumn!method;
                static if (sqlCol.length > 0) {
                    result ~= "        case _OrderByFieldEnum." ~ member ~ ": return \"" ~ sqlCol ~ "\";\n";
                } else {
                    result ~= "        case _OrderByFieldEnum." ~ member ~ ": return \"" ~ member ~ "\";\n";
                }
            }
        }}
        result ~= "    }\n";
        result ~= "}\n\n";

        // Generate _applySorting function
        result ~= "private static Expr!(_SortEntity[]) _applySorting(T)(T base, _OrderByStruct[] orderBySpecs) {\n";
        result ~= "    if (orderBySpecs is null || orderBySpecs.length == 0) {\n";
        result ~= "        return base;\n";
        result ~= "    }\n";
        result ~= "    OrderBySpec[] specs;\n";
        result ~= "    foreach (ob; orderBySpecs) {\n";
        result ~= "        string columnName = _getColumnName(ob.field);\n";
        result ~= "        bool isDescending = (ob.direction == SortDirection.DESC);\n";
        result ~= "        specs ~= OrderBySpec(columnName, isDescending ? SortDirection.DESC : SortDirection.ASC);\n";
        result ~= "    }\n";
        result ~= "    return base.orderBy(specs);\n";
        result ~= "}\n";

        return result;
    }();

    // Generate all types and functions together
    mixin(_typesDef);

    // Store graphql names for SDL generation
    enum _orderByEnumGraphqlName = graphqlEnumName;
    enum _orderByStructGraphqlName = graphqlStructName;
}

// ============================================================================
// Mixin Template for Sorted Array Fields
// ============================================================================

/// Mixin for sorted array field on an entity (adds orderBy arguments).
/// Similar to SortedArrayField but for entity types.
/// Uses type aliases instead of stringof to preserve type scope across plugin composition.
mixin template SortedEntityArrayField(Entity, string fieldName) {
    import std.traits : Parameters, ParameterDefaults, ParameterIdentifierTuple;
    import std.meta : AliasSeq;
    import std.conv : to;
    import dynamo.core.expr : Expr, ExprResultType, entityCast;
    import dynamo.core.sorting : orderBy, OrderBySpec, SortDirection;
    import dynamo.relational.schema : getSqlColumn;

    alias _srcFn = __traits(getMember, Entity, fieldName);
    alias _SrcParams = Parameters!_srcFn;
    alias _SrcDefaults = ParameterDefaults!_srcFn;
    enum string[] _srcParamNames = [ParameterIdentifierTuple!_srcFn];

    alias _SrcFirstParam = _SrcParams[0];
    alias _SrcEntity = ExprResultType!_SrcFirstParam;

    // Extract element type from array expression
    alias _ElementType = ArrayFieldElementType!_srcFn;

    // Generate the OrderBy types for this entity's child (GraphQL names for SDL)
    enum _orderByFieldEnumName = __traits(identifier, _ElementType) ~ "OrderByField";
    enum _orderByStructName = __traits(identifier, _ElementType) ~ "OrderBy";

    // Only generate if we have sortable fields
    static if (getSortableFields!_ElementType.length > 0) {
        // Generate both enum and struct with fixed internal names (avoids string-based lookup)
        mixin GenerateOrderByTypes!(_ElementType, _orderByFieldEnumName, _orderByStructName);
        // _OrderByFieldEnum and _OrderByStruct are now defined by the mixin
    }

    // Generate type aliases for each parameter to preserve type scope
    static foreach (i; 1 .. _SrcParams.length) {
        mixin("alias _ParamType" ~ i.to!string ~ " = _SrcParams[" ~ i.to!string ~ "];");
    }

    // Build parameter list using type aliases
    enum string _paramListStr = () {
        string result = "Expr!(typeof(this)) " ~ _srcParamNames[0];
        static foreach (i; 1 .. _SrcParams.length) {{
            result ~= ", ";
            result ~= "_ParamType" ~ i.to!string ~ " " ~ _srcParamNames[i];
            static if (!is(_SrcDefaults[i] == void)) {
                result ~= " = _SrcDefaults[" ~ i.to!string ~ "]";
            }
        }}
        // Add orderBy param using fixed internal type name
        static if (getSortableFields!_ElementType.length > 0) {
            result ~= ", _OrderByStruct[] orderBy = null";
        }
        return result;
    }();

    // Build argument list - cast wrapper entity back to original
    enum string _argListStr = () {
        string result = "entityCast!_SrcEntity(" ~ _srcParamNames[0] ~ ")";
        static foreach (i; 1 .. _SrcParams.length) {
            result ~= ", " ~ _srcParamNames[i];
        }
        return result;
    }();

    // Generate the sorted method
    // Helper functions (_applySorting, _getColumnName) are generated by GenerateOrderByTypes
    static if (getSortableFields!_ElementType.length > 0) {
        @(__traits(getAttributes, _srcFn))
        mixin("static auto " ~ fieldName ~ "(" ~ _paramListStr ~ ") { " ~
              "return _applySorting(_srcFn(" ~ _argListStr ~ "), orderBy); }");
    } else {
        // No sortable fields - just forward the field without orderBy
        @(__traits(getAttributes, _srcFn))
        mixin("static auto " ~ fieldName ~ "(" ~ _paramListStr ~ ") { " ~
              "return _srcFn(" ~ _argListStr ~ "); }");
    }
}

/// Mixin template to create a sorted version of an array-returning field.
/// Adds orderBy parameter and wraps the result with orderBy expressions.
mixin template SortedArrayField(SourceQuery, string fieldName) {
    import std.traits : Parameters, ParameterDefaults, ParameterIdentifierTuple;
    import std.meta : AliasSeq;
    import std.conv : to;
    import dynamo.core.expr : Expr, ExprResultType, entityCast;
    import dynamo.core.sorting : orderBy, OrderBySpec, SortDirection;
    import dynamo.relational.schema : getSqlColumn;

    // Get the source function and its metadata
    alias _srcFn = __traits(getMember, SourceQuery, fieldName);
    alias _SrcParams = Parameters!_srcFn;
    alias _SrcDefaults = ParameterDefaults!_srcFn;
    enum string[] _srcParamNames = [ParameterIdentifierTuple!_srcFn];

    // Extract the source entity type from first parameter
    alias _SrcFirstParam = _SrcParams[0];
    alias _SrcEntity = ExprResultType!_SrcFirstParam;

    // Extract element type from array expression
    alias _ElementType = ArrayFieldElementType!_srcFn;

    // Generate the OrderBy types for this entity (GraphQL names for SDL)
    enum _orderByFieldEnumName = __traits(identifier, _ElementType) ~ "OrderByField";
    enum _orderByStructName = __traits(identifier, _ElementType) ~ "OrderBy";

    // Only generate enum if we have sortable fields
    static if (getSortableFields!_ElementType.length > 0) {
        // Generate both enum and struct with fixed internal names (avoids string-based lookup)
        mixin GenerateOrderByTypes!(_ElementType, _orderByFieldEnumName, _orderByStructName);
        // _OrderByFieldEnum and _OrderByStruct are now defined by the mixin
    }

    // Generate type aliases for each parameter to preserve type scope
    // Using aliases instead of stringof ensures types from outer scopes resolve correctly
    static foreach (i; 1 .. _SrcParams.length) {
        mixin("alias _ParamType" ~ i.to!string ~ " = _SrcParams[" ~ i.to!string ~ "];");
    }

    // Build parameter list string at compile time
    // First param: Expr!(typeof(this)) instead of Expr!SourceQuery
    // Rest: same types with defaults preserved (using type aliases)
    // Finally: add orderBy param
    enum string _paramListStr = () {
        string result = "Expr!(typeof(this)) " ~ _srcParamNames[0];
        static foreach (i; 1 .. _SrcParams.length) {{
            result ~= ", ";
            // Use type alias instead of stringof to preserve type scope
            result ~= "_ParamType" ~ i.to!string ~ " " ~ _srcParamNames[i];
            // Add default value using alias to _SrcDefaults
            static if (!is(_SrcDefaults[i] == void)) {
                result ~= " = _SrcDefaults[" ~ i.to!string ~ "]";
            }
        }}
        // Add orderBy param using fixed internal type name
        static if (getSortableFields!_ElementType.length > 0) {
            result ~= ", _OrderByStruct[] orderBy = null";
        }
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

    // Generate the sorted method
    // Helper functions (_applySorting, _getColumnName) are generated by GenerateOrderByTypes
    static if (getSortableFields!_ElementType.length > 0) {
        @(__traits(getAttributes, _srcFn))
        mixin("static auto " ~ fieldName ~ "(" ~ _paramListStr ~ ") { " ~
              "return _applySorting(_srcFn(" ~ _argListStr ~ "), orderBy); }");
    } else {
        // No sortable fields - just forward the method unchanged
        @(__traits(getAttributes, _srcFn))
        mixin("static auto " ~ fieldName ~ "(" ~ _paramListStr ~ ") { " ~
              "return _srcFn(" ~ _argListStr ~ "); }");
    }
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
    import dynamo.relational.schema;
    import dynamo.relational.demo;
    import dynamo.graphql.schema : Schema, generateSchemaSDL;
    import std.algorithm : canFind;

    static MockDB!() db;

    static struct User {
        mixin DemoEntity!(db, "users");
        mixin Col!("firstName", string);
        mixin Col!("lastName", string);

        @GqlHidden mixin Col!("internalField", string);
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    // Test that sortable fields are correctly detected
    enum sortableFields = getSortableFields!User;
    static assert(sortableFields.length >= 3, "Should have at least id, firstName, lastName");

    // Verify hidden fields are not included
    import std.algorithm : canFind;
    static assert(!sortableFields.canFind("internalField"), "Hidden field should not be sortable");
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
    import dynamo.relational.schema;
    import dynamo.relational.demo;
    import dynamo.graphql.schema : Schema, generateSchemaSDL;
    import std.algorithm : canFind;

    static MockDB!() db;

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
    import dynamo.relational.schema;
    import dynamo.relational.demo;
    import dynamo.graphql.schema : Schema, generateSchemaSDL;
    import std.algorithm : canFind;

    // Wrap in struct to allow forward references between types
    struct TestSchema {
        static MockDB!() db;

        struct Comment {
            mixin DemoEntity!(db, "comments");
            mixin Col!("text", string);
        }

        struct Post {
            mixin DemoEntity!(db, "posts");
            mixin Col!("title", string);
            mixin HasMany!("comments", Comment, "post_id");
        }

        struct User {
            mixin DemoEntity!(db, "users");
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
    import dynamo.core;
    import dynamo.relational.schema;
    import dynamo.relational.demo;
    import dynamo.relational.eval_context;
    import dynamo.graphql.schema : Schema;
    import dynamo.graphql.compiler : compileQuery;

    static MockDB!() db;

    static struct User {
        mixin DemoEntity!(db, "users");
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
