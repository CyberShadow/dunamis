/// Optional plugin that auto-generates CRUD mutations for entities.
///
/// Discovers entities via `@TableEntity` UDAs on the Query type (from `Table` mixin)
/// and generates `create<Entity>`, `update<Entity>`, `delete<Entity>` methods
/// on the Mutation type.
///
/// Only entities with single-column `@AutoIncrement` primary keys get CRUD methods.
/// Entities with composite keys, non-auto-increment keys, or manually defined
/// mutations are skipped. Users can write custom mutation plugins for other patterns
/// (batch inserts, per-table mutations, etc.) using the building blocks in
/// `dunamis.relational.mutation`.
///
/// Example:
/// ---
/// alias BaseSchema = Schema!(Query, Mutation);
/// alias MySchema = ApplyPlugins!(BaseSchema, CrudMutationPlugin, FilterPlugin, SortingPlugin);
/// ---
module dunamis.graphql.crud;

import dunamis.graphql.schema : isSchema;

// ============================================================================
// Utilities
// ============================================================================

/// Convert a PK value to string for mutation calls.
/// Handles CustomScalar types (accesses .value) and regular types.
string pkValueToString(T)(T val) {
    import std.conv : to;
    import dunamis.core.types : isCustomScalar;
    static if (isCustomScalar!T) {
        return val.value.to!string;
    } else {
        return val.to!string;
    }
}

/// Convert a D value to JSONValue for mutation column data.
/// Handles: strings, integers, floats, bools, CustomScalars, enums, Nullable.
auto _fieldToJson(T)(T val) {
    import std.conv : to;
    import std.json : JSONValue;
    import std.traits : isIntegral, isFloatingPoint, isSomeString;
    import std.typecons : Nullable;
    import dunamis.core.types : isCustomScalar;

    static if (is(T == Nullable!U, U)) {
        if (val.isNull) return JSONValue(null);
        return _fieldToJson(val.get);
    } else static if (isCustomScalar!T) {
        return JSONValue(val.value);
    } else static if (is(T == enum)) {
        return JSONValue(val.to!string);
    } else static if (is(T == bool)) {
        return JSONValue(val);
    } else static if (isSomeString!T) {
        return JSONValue(val);
    } else static if (isIntegral!T) {
        return JSONValue(val);
    } else static if (isFloatingPoint!T) {
        return JSONValue(val);
    } else {
        static assert(false, "Unsupported type for CRUD field conversion: " ~ T.stringof);
    }
}

// ============================================================================
// Column Introspection Helpers
// ============================================================================

/// Check if a member is a non-PK database column suitable for CRUD input.
/// Matches Col fields (have @SqlColumn) and plain fields (struct instance fields).
template _isInputColumn(Entity, string member) {
    import dunamis.relational.schema.attrs : hasSqlColumn, hasPrimaryKeyAttr;
    import dunamis.core.types : isPlainField;

    enum _isInputColumn = () {
        static if (!__traits(compiles, __traits(getMember, Entity, member)))
            return false;
        else static if (__traits(compiles, hasPrimaryKeyAttr!(Entity, member)) &&
                       hasPrimaryKeyAttr!(Entity, member))
            return false;
        else static if (__traits(compiles, hasSqlColumn!(__traits(getMember, Entity, member))) &&
                       hasSqlColumn!(__traits(getMember, Entity, member)))
            return true;
        else static if (isPlainField!(Entity, member))
            return true;
        else
            return false;
    }();
}

/// Check if a column member is a static method (Col mixin) vs a plain field.
template _isColMethod(Entity, string member) {
    static if (__traits(compiles, __traits(isStaticFunction, __traits(getMember, Entity, member)))) {
        enum _isColMethod = __traits(isStaticFunction, __traits(getMember, Entity, member));
    } else {
        enum _isColMethod = false;
    }
}

/// Get the SQL column name for a CRUD input column.
template _inputColumnSqlName(Entity, string member) {
    import dunamis.relational.schema.attrs : hasSqlColumn, getSqlColumn, getPlainFieldColumnName;

    enum _inputColumnSqlName = () {
        static if (__traits(compiles, hasSqlColumn!(__traits(getMember, Entity, member))) &&
                   hasSqlColumn!(__traits(getMember, Entity, member)))
            return getSqlColumn!(__traits(getMember, Entity, member));
        else
            return getPlainFieldColumnName!(Entity, member);
    }();
}

/// Get the GraphQL field name for a CRUD input field.
/// Uses @GqlName if present, otherwise falls back to D field name.
template _inputFieldGqlName(Entity, string member) {
    enum _inputFieldGqlName = () {
        static if (__traits(compiles, __traits(getMember, Entity, member))) {
            import dunamis.graphql.schema.udas : getGqlName;
            static if (__traits(compiles, getGqlName!(__traits(getMember, Entity, member), member)))
                return getGqlName!(__traits(getMember, Entity, member), member);
            else
                return member;
        } else {
            return member;
        }
    }();
}

// ============================================================================
// CRUD Methods Mixin
// ============================================================================

/// Mixin template that generates create/update/delete methods for an entity.
///
/// Uses the CTFE lambda pattern (like FilteredArrayField) to build method strings
/// without leaking intermediate symbols. Template parameters OriginalEntity and
/// NormalizedEntity are in scope at the mixin site.
///
/// Generates input structs and methods:
/// - Create<Entity>Input: one field per non-PK column (direct types)
/// - Update<Entity>Input: one Nullable-wrapped field per non-PK column (optional)
/// - create<Entity>(parent, input): takes Create<Entity>Input
/// - update<Entity>(parent, id, input): takes PK + Update<Entity>Input
/// - delete<Entity>(parent, id): takes PK only
///
/// Only generates methods for entities with single-column @AutoIncrement PKs.
/// Skips methods that already exist on MutationType (conflict detection).
mixin template _CrudMethods(OriginalEntity, NormalizedEntity, MutationType) {
    static import std.json;
    static import dunamis.core.expr;
    static import std.traits;
    static import dunamis.graphql.schema.udas;
    static import std.typecons;
    static import dunamis.graphql.crud;
    static import dunamis.graphql.entity_cast;
    static import dunamis.relational.mutation;
    mixin(() {
        import dunamis.relational.schema.attrs : getEntityTypeName, getPrimaryKeyFieldNames, hasAutoIncrement;

        enum typeName = getEntityTypeName!OriginalEntity;
        enum string[] pkFields = getPrimaryKeyFieldNames!OriginalEntity;

        // Only generate for single-PK auto-increment entities
        static if (pkFields.length != 1 || !hasAutoIncrement!OriginalEntity) {
            return "";
        } else {
            enum pkFieldName = pkFields[0];
            string result = "";

            // Build input struct fields and method bodies
            string createStructFields = "";
            string updateStructFields = "";
            string createBody = "    std.json.JSONValue[string] _cols;\n";
            string updateBody = "    std.json.JSONValue[string] _cols;\n";

            static foreach (_m; __traits(allMembers, OriginalEntity)) {{
                static if (_isInputColumn!(OriginalEntity, _m)) {
                    enum _sqlCol = _inputColumnSqlName!(OriginalEntity, _m);
                    enum _gqlName = _inputFieldGqlName!(OriginalEntity, _m);

                    // Type expression: ExprResultType for Col methods, typeof for plain fields
                    static if (_isColMethod!(OriginalEntity, _m)) {
                        enum _typeExpr = "dunamis.core.expr.ExprResultType!(" ~
                            "std.traits.ReturnType!(__traits(getMember, OriginalEntity, \"" ~ _m ~ "\")))";
                    } else {
                        enum _typeExpr = "typeof(__traits(getMember, OriginalEntity.init, \"" ~ _m ~ "\"))";
                    }

                    // UDA prefix for @GqlName (only when GraphQL name differs from D name)
                    static if (_gqlName != _m) {
                        enum _udaPrefix = "@(dunamis.graphql.schema.udas.GqlName(\"" ~ _gqlName ~ "\")) ";
                    } else {
                        enum _udaPrefix = "";
                    }

                    // Create input: direct type
                    createStructFields ~= "    " ~ _udaPrefix ~ _typeExpr ~ " " ~ _m ~ ";\n";

                    // Update input: Nullable-wrapped type
                    updateStructFields ~= "    " ~ _udaPrefix ~
                        "std.typecons.Nullable!(" ~ _typeExpr ~ ") " ~ _m ~ ";\n";

                    // Create body: always set column
                    createBody ~= "    _cols[\"" ~ _sqlCol ~ "\"] = " ~
                        "dunamis.graphql.crud._fieldToJson(input." ~ _m ~ ");\n";

                    // Update body: only set column if not null (absent = don't update)
                    updateBody ~= "    if (!input." ~ _m ~ ".isNull) _cols[\"" ~ _sqlCol ~ "\"] = " ~
                        "dunamis.graphql.crud._fieldToJson(input." ~ _m ~ ".get);\n";
                }
            }}

            // Generate input structs
            result ~= "struct Create" ~ typeName ~ "Input {\n" ~ createStructFields ~ "}\n\n";
            result ~= "struct Update" ~ typeName ~ "Input {\n" ~ updateStructFields ~ "}\n\n";

            // create<Entity>(parent, input) -> insert!OE(columns)
            static if (!__traits(hasMember, MutationType, "create" ~ typeName)) {
                result ~= "static auto create" ~ typeName ~ "(" ~
                    "dunamis.core.expr.Expr!(typeof(this)) parent, " ~
                    "Create" ~ typeName ~ "Input input) {\n" ~
                    createBody ~
                    "    return dunamis.graphql.entity_cast.pluginEntityCast!NormalizedEntity(" ~
                    "dunamis.relational.mutation.insert!OriginalEntity(_cols));\n}\n\n";
            }

            // update<Entity>(parent, id, input) -> update!OE([id], columns)
            static if (!__traits(hasMember, MutationType, "update" ~ typeName)) {
                result ~= "static auto update" ~ typeName ~ "(" ~
                    "dunamis.core.expr.Expr!(typeof(this)) parent, " ~
                    "typeof(__traits(getMember, OriginalEntity, \"" ~ pkFieldName ~ "\")) id, " ~
                    "Update" ~ typeName ~ "Input input) {\n" ~
                    updateBody ~
                    "    return dunamis.graphql.entity_cast.pluginEntityCast!NormalizedEntity(" ~
                    "dunamis.relational.mutation.update!OriginalEntity(" ~
                    "[dunamis.graphql.crud.pkValueToString(id)], _cols).single());\n}\n\n";
            }

            // delete<Entity>(parent, id) -> delete_!OE([id])
            static if (!__traits(hasMember, MutationType, "delete" ~ typeName)) {
                result ~=
                    "static auto delete" ~ typeName ~ "(" ~
                    "dunamis.core.expr.Expr!(typeof(this)) parent, " ~
                    "typeof(__traits(getMember, OriginalEntity, \"" ~ pkFieldName ~ "\")) id) { " ~
                    "return dunamis.relational.mutation.delete_!OriginalEntity(" ~
                    "[dunamis.graphql.crud.pkValueToString(id)]); }\n";
            }

            return result;
        }
    }());
}

// ============================================================================
// Normalized Entity Extraction
// ============================================================================

/// Extract the normalized entity type from a Query method's return type.
/// Table methods return Expr!(NormalizedEntity[]) — this extracts NormalizedEntity.
template _extractNormalizedEntity(alias QueryType, string member) {
    import std.traits : ReturnType, isSomeString;
    import dunamis.core.expr : ExprResultType;

    alias method = __traits(getMember, QueryType, member);
    alias ResultT = ExprResultType!(ReturnType!method);

    static if (is(ResultT == E[], E) && !isSomeString!ResultT) {
        alias _extractNormalizedEntity = E;
    } else {
        alias _extractNormalizedEntity = ResultT;
    }
}

// ============================================================================
// CrudMutationPlugin
// ============================================================================

/// Plugin that auto-generates CRUD mutations for all entities with `Table` entries
/// in the Query type. Entities are detected via `@TableEntity` UDAs (generated by
/// the `Table` mixin), which store the original (pre-normalization) entity type.
///
/// Must be applied before Filter/Sort/Pagination plugins:
/// ---
/// alias MySchema = ApplyPlugins!(Schema!(Query, Mutation), CrudMutationPlugin, FilterPlugin, SortingPlugin);
/// ---
///
/// The plugin:
/// - Passes Query through unchanged
/// - Forwards all existing Mutation fields
/// - Generates create/update/delete for each entity with single-PK + @AutoIncrement
/// - Skips CRUD generation if the method name already exists on S.Mutation (user override)
template CrudMutationPlugin(alias S) if (isSchema!S) {
    import dunamis.graphql.plugin : WrapFields, IdentityTypeMap, ForwardField;
    import dunamis.relational.schema.attrs : hasTableEntity, extractTableEntity;

    alias Query = S.Query;

    struct CrudMutation {
        // Forward all existing mutation fields from the source schema
        mixin WrapFields!(S.Mutation, IdentityTypeMap, ForwardField);

        // Generate CRUD for each entity discovered from Query's @TableEntity UDAs
        static foreach (_member; __traits(allMembers, S.Query)) {
            static if (__traits(compiles, hasTableEntity!(__traits(getMember, S.Query, _member))) &&
                       hasTableEntity!(__traits(getMember, S.Query, _member))) {
                mixin _CrudMethods!(
                    extractTableEntity!(__traits(getMember, S.Query, _member)),
                    _extractNormalizedEntity!(S.Query, _member),
                    S.Mutation
                );
            }
        }
    }

    alias Mutation = CrudMutation;
}

// ============================================================================
// Unit Tests
// ============================================================================

// Test: SDL generation — CRUD methods appear with input objects
unittest {
    import std.algorithm : canFind;
    import dunamis.relational.schema : Col, Table;
    import dunamis.relational.demo : DemoEntity, DemoId, MockDB;
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
    alias MySchema = CrudMutationPlugin!BaseSchema;

    static assert(isSchema!MySchema);

    enum sdl = generateSchemaSDL!MySchema;

    static assert(sdl.canFind("createUser"), "Missing createUser: " ~ sdl);
    static assert(sdl.canFind("updateUser"), "Missing updateUser: " ~ sdl);
    static assert(sdl.canFind("deleteUser"), "Missing deleteUser: " ~ sdl);

    // Should have input objects, not JSON or individual params
    static assert(!sdl.canFind("JSON"), "Should not have JSON params: " ~ sdl);
    static assert(sdl.canFind("CreateUserInput"), "Missing CreateUserInput type: " ~ sdl);
    static assert(sdl.canFind("UpdateUserInput"), "Missing UpdateUserInput type: " ~ sdl);
    static assert(sdl.canFind("input: CreateUserInput!"), "createUser should take input: CreateUserInput!: " ~ sdl);
}

// Test: composite key exclusion — no CRUD for composite-PK entities
unittest {
    import std.algorithm : canFind;
    import dunamis.relational.schema : Entity, Col, Table, PrimaryKey;
    import dunamis.relational.demo : DemoEntity, DemoId, MockDB;
    import dunamis.graphql.schema : Schema, generateSchemaSDL;

    static MockDB!() db;

    // Single-PK auto-increment entity (should get CRUD)
    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("name", string);
    }

    // Composite-PK entity (should NOT get CRUD)
    @Entity!(db, "tags", "Tag")
    static struct Tag {
        @PrimaryKey string category;
        @PrimaryKey string name;
    }

    static struct Query {
        mixin Table!(User, "users");
        mixin Table!(Tag, "tags");
    }

    alias MySchema = CrudMutationPlugin!(Schema!Query);

    enum sdl = generateSchemaSDL!MySchema;

    // User should have CRUD
    static assert(sdl.canFind("createUser"), "Missing createUser: " ~ sdl);

    // Tag should NOT have CRUD
    static assert(!sdl.canFind("createTag"), "Unexpected createTag: " ~ sdl);
    static assert(!sdl.canFind("updateTag"), "Unexpected updateTag: " ~ sdl);
    static assert(!sdl.canFind("deleteTag"), "Unexpected deleteTag: " ~ sdl);
}

// Test: conflict resolution — user-defined mutations suppress auto-generated ones
unittest {
    import std.algorithm : canFind;
    import dunamis.core.expr : Expr;
    import dunamis.relational.schema : Col, Table;
    import dunamis.relational.demo : DemoEntity, DemoId, Int64, MockDB;
    import dunamis.relational.mutation : insert;
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

    // Custom createUser — should suppress auto-generated one
    static struct CustomMutation {
        static auto createUser(Expr!CustomMutation parent, string name) {
            import std.json : JSONValue;
            return insert!User(["name": JSONValue(name)]);
        }
    }

    alias MySchema = CrudMutationPlugin!(Schema!(Query, CustomMutation));

    enum sdl = generateSchemaSDL!MySchema;

    // createUser should exist (from custom mutation)
    static assert(sdl.canFind("createUser"), "Missing createUser: " ~ sdl);

    // Custom createUser takes name: String! (individual param), not input object
    static assert(sdl.canFind("name: String!"), "Custom createUser should take name: String!: " ~ sdl);

    // updateUser and deleteUser should still be auto-generated
    static assert(sdl.canFind("updateUser"), "Missing updateUser: " ~ sdl);
    static assert(sdl.canFind("deleteUser"), "Missing deleteUser: " ~ sdl);
}

// Test: plugin composition — CrudMutationPlugin + FilterPlugin + SortingPlugin
unittest {
    import std.algorithm : canFind;
    import dunamis.relational.schema : Col, Table;
    import dunamis.relational.demo : DemoEntity, DemoId, MockDB;
    import dunamis.graphql.schema : Schema, generateSchemaSDL;
    import dunamis.graphql.plugin : ApplyPlugins;
    import dunamis.graphql.filtering : FilterPlugin;
    import dunamis.graphql.sorting : SortingPlugin;

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
    alias MySchema = ApplyPlugins!(BaseSchema, CrudMutationPlugin, FilterPlugin, SortingPlugin);

    static assert(isSchema!MySchema);

    enum sdl = generateSchemaSDL!MySchema;

    // CRUD methods should survive through plugin chain
    static assert(sdl.canFind("createUser"), "Missing createUser after plugin chain: " ~ sdl);
    static assert(sdl.canFind("updateUser"), "Missing updateUser after plugin chain: " ~ sdl);
    static assert(sdl.canFind("deleteUser"), "Missing deleteUser after plugin chain: " ~ sdl);

    // Filter/sort args should also be present on query
    static assert(sdl.canFind("filter:"), "Missing filter arg: " ~ sdl);
    static assert(sdl.canFind("orderBy:"), "Missing orderBy arg: " ~ sdl);
}

// Test: runtime execution — insert via CrudMutationPlugin with MockDB
unittest {
    import ae.utils.promise.await : awaitSync;
    import dunamis.core.eval : EvalContext;
    import dunamis.relational.schema : Col, Table;
    import dunamis.relational.demo : DemoEntity, DemoId, MockDB;
    import dunamis.graphql.schema : Schema;

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("name", string);
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    alias MySchema = CrudMutationPlugin!(Schema!Query);

    // Initialize MockDB
    db = new MockDB!();
    db.setTableData("users", `[]`);

    // Call createUser with input object
    auto mutationExpr = MySchema.Mutation.createUser(null,
        MySchema.Mutation.CreateUserInput("Alice"));

    auto ctx = new EvalContext();
    auto result = awaitSync(mutationExpr.eval(ctx));

    // Should return one entity
    assert(result.length == 1);
}
