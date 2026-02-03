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

/// Plugin that adds orderBy sorting arguments to all array-returning fields.
///
/// For each entity type E, generates:
/// - enum EOrderByField { id, field1, field2, ... } - all sortable column fields
/// - struct EOrderBy { EOrderByField field; SortDirection direction = SortDirection.ASC; }
///
/// Transforms:
///   users: [User!]!
/// Into:
///   users(orderBy: [UserOrderBy!]): [User!]!
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
/// // { users(orderBy: [{field: lastName, direction: DESC}]) { name } }
/// ---
template SortingPlugin(alias S) if (isSchema!S) {
    // Generate SortedQuery struct with transformed fields
    struct SortedQuery {
        static foreach (member; getFieldMembers!(S.Query)) {
            static if (isArrayReturningField!(__traits(getMember, S.Query, member))) {
                // Array field: add sorting arguments
                mixin SortedArrayField!(S.Query, member);
            } else {
                // Non-array field: forward unchanged
                mixin ForwardField!(S.Query, member);
            }
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

/// Generate an enum type with sortable field names at compile time.
/// The enum is used as the 'field' parameter in OrderBy input.
mixin template GenerateOrderByFieldEnum(Entity, string enumName) {
    import std.meta : AliasSeq;

    // Build enum definition string
    enum _enumDef = () {
        string result = "enum " ~ enumName ~ " {\n";
        static foreach (fieldName; getSortableFields!Entity) {
            result ~= "    " ~ fieldName ~ ",\n";
        }
        result ~= "}";
        return result;
    }();

    mixin(_enumDef);
}

/// Generate the OrderBy input struct for an entity.
/// This struct is used as array elements for the orderBy argument.
mixin template GenerateOrderByStruct(Entity, string structName, string fieldEnumName) {
    // Generate: struct {structName} { {fieldEnumName} field; SortDirection direction = SortDirection.ASC; }
    mixin("struct " ~ structName ~ " { " ~
          fieldEnumName ~ " field; " ~
          "SortDirection direction = SortDirection.ASC; }");
}

// ============================================================================
// Mixin Template for Sorted Array Fields
// ============================================================================

/// Mixin template to create a sorted version of an array-returning field.
/// Adds orderBy parameter and wraps the result with orderBy expressions.
mixin template SortedArrayField(SourceQuery, string fieldName) {
    import std.traits : Parameters, ParameterDefaults, ParameterIdentifierTuple;
    import std.meta : AliasSeq;
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

    // Generate the OrderBy types for this entity
    enum _orderByFieldEnumName = __traits(identifier, _ElementType) ~ "OrderByField";
    enum _orderByStructName = __traits(identifier, _ElementType) ~ "OrderBy";

    // Only generate enum if we have sortable fields
    static if (getSortableFields!_ElementType.length > 0) {
        mixin GenerateOrderByFieldEnum!(_ElementType, _orderByFieldEnumName);
        mixin GenerateOrderByStruct!(_ElementType, _orderByStructName, _orderByFieldEnumName);

        alias _OrderByFieldEnum = mixin(_orderByFieldEnumName);
        alias _OrderByStruct = mixin(_orderByStructName);
    }

    // Build parameter list string at compile time
    // First param: Expr!(typeof(this)) instead of Expr!SourceQuery
    // Rest: same types with defaults preserved
    // Finally: add orderBy param
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
        // Add orderBy param (array of OrderBy structs, nullable)
        static if (getSortableFields!_ElementType.length > 0) {
            result ~= ", " ~ _orderByStructName ~ "[] orderBy = null";
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

    // Helper function to apply sorting
    private static Expr!(_ElementType[]) _applySorting(T)(T base, _OrderByStruct[] orderBySpecs) {
        if (orderBySpecs is null || orderBySpecs.length == 0) {
            return base;
        }

        // Convert to core OrderBySpec array
        OrderBySpec[] specs;
        foreach (ob; orderBySpecs) {
            // Get the SQL column name using generated switch at compile time
            string columnName = _getColumnName(ob.field);
            bool isDescending = (ob.direction == SortDirection.DESC);

            specs ~= OrderBySpec(columnName, isDescending ? SortDirection.DESC : SortDirection.ASC);
        }

        return base.orderBy(specs);
    }

    // Generate column name lookup switch at compile time
    // Note: underscore prefix ensures it's treated as internal
    private static string _getColumnName(_OrderByFieldEnum field) {
        import dynamo.relational.schema : getSqlColumn;

        // Use final switch to handle all enum values
        final switch (field) {
            static foreach (member; getSortableFields!_ElementType) {{
                static if (__traits(compiles, __traits(getMember, _ElementType, member)) &&
                           is(typeof(__traits(getMember, _ElementType, member)) == function)) {
                    alias method = __traits(getMember, _ElementType, member);
                    enum sqlCol = getSqlColumn!method;
                    case mixin(_orderByFieldEnumName ~ "." ~ member):
                        static if (sqlCol.length > 0) {
                            return sqlCol;
                        } else {
                            return member;
                        }
                }
            }}
        }
    }

    // Generate the sorted method with UDAs preserved
    @(__traits(getAttributes, _srcFn))
    mixin("static auto " ~ fieldName ~ "(" ~ _paramListStr ~ ") { " ~
          "return _applySorting(_srcFn(" ~ _argListStr ~ "), orderBy); }");
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
