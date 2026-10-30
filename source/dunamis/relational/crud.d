/// The write fields of relational entities: the `Writes` of the stored
/// entities a `Table` lists (see `dunamis.core.stored.StoredEntities`), with
/// which `CrudMutationPlugin` (dunamis.schema.crud) generates `create<Entity>`,
/// `update<Entity>` and `delete<Entity>` mutations.
///
/// Only entities with single-column `@AutoIncrement` primary keys get them.
/// Users can write custom mutations for other patterns (batch inserts,
/// per-table mutations, etc.) using the building blocks in
/// `dunamis.relational.mutation`.
module dunamis.relational.crud;

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
        import dunamis.core.types : storedLabel;
        return JSONValue(storedLabel(val));
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

// ============================================================================
// CRUD Methods Mixin
// ============================================================================

/// Mixin template that generates create/update/delete methods for an entity
/// (the `Writes` of the stored entities of a `Table`, see
/// `dunamis.core.stored.StoredEntities`).
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
/// The rows created and updated are returned as `NormalizedEntity`s, as
/// `cast_!NormalizedEntity` converts them.
///
/// Only generates methods for entities with single-column @AutoIncrement PKs.
/// Skips methods that already exist on MutationType (conflict detection).
mixin template CrudWrites(OriginalEntity, NormalizedEntity, MutationType, alias cast_) {
    static import std.json;
    static import dunamis.core.expr;
    static import std.traits;
    static import std.typecons;
    static import dunamis.relational.crud;
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
                static if (dunamis.relational.crud._isInputColumn!(OriginalEntity, _m)) {
                    enum _sqlCol = dunamis.relational.crud._inputColumnSqlName!(OriginalEntity, _m);

                    // Type expression: ExprResultType for Col methods, typeof for plain fields
                    static if (dunamis.relational.crud._isColMethod!(OriginalEntity, _m)) {
                        enum _typeExpr = "dunamis.core.expr.ExprResultType!(" ~
                            "std.traits.ReturnType!(__traits(getMember, OriginalEntity, \"" ~ _m ~ "\")))";
                    } else {
                        enum _typeExpr = "typeof(__traits(getMember, OriginalEntity.init, \"" ~ _m ~ "\"))";
                    }

                    // Create input: direct type
                    // The input field carries the entity field's attributes
                    // (e.g. a presentation name).
                    enum _name = "@(__traits(getAttributes, __traits(getMember, OriginalEntity, \"" ~ _m ~ "\"))) ";
                    createStructFields ~= "    " ~ _name ~ _typeExpr ~ " " ~ _m ~ ";\n";

                    // Update input: Nullable-wrapped type
                    updateStructFields ~= "    " ~ _name ~
                        "std.typecons.Nullable!(" ~ _typeExpr ~ ") " ~ _m ~ ";\n";

                    // Create body: always set column
                    createBody ~= "    _cols[\"" ~ _sqlCol ~ "\"] = " ~
                        "dunamis.relational.crud._fieldToJson(input." ~ _m ~ ");\n";

                    // Update body: only set column if not null (absent = don't update)
                    updateBody ~= "    if (!input." ~ _m ~ ".isNull) _cols[\"" ~ _sqlCol ~ "\"] = " ~
                        "dunamis.relational.crud._fieldToJson(input." ~ _m ~ ".get);\n";
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
                    "    return cast_!NormalizedEntity(" ~
                    "dunamis.relational.mutation.insert!OriginalEntity(_cols));\n}\n\n";
            }

            // update<Entity>(parent, id, input) -> update!OE([id], columns)
            static if (!__traits(hasMember, MutationType, "update" ~ typeName)) {
                result ~= "static auto update" ~ typeName ~ "(" ~
                    "dunamis.core.expr.Expr!(typeof(this)) parent, " ~
                    "typeof(__traits(getMember, OriginalEntity, \"" ~ pkFieldName ~ "\")) id, " ~
                    "Update" ~ typeName ~ "Input input) {\n" ~
                    updateBody ~
                    "    return cast_!NormalizedEntity(" ~
                    "dunamis.relational.mutation.update!OriginalEntity(" ~
                    "[dunamis.relational.crud.pkValueToString(id)], _cols).single());\n}\n\n";
            }

            // delete<Entity>(parent, id) -> delete_!OE([id])
            static if (!__traits(hasMember, MutationType, "delete" ~ typeName)) {
                result ~=
                    "static auto delete" ~ typeName ~ "(" ~
                    "dunamis.core.expr.Expr!(typeof(this)) parent, " ~
                    "typeof(__traits(getMember, OriginalEntity, \"" ~ pkFieldName ~ "\")) id) { " ~
                    "return dunamis.relational.mutation.delete_!OriginalEntity(" ~
                    "[dunamis.relational.crud.pkValueToString(id)]); }\n";
            }

            return result;
        }
    }());
}
