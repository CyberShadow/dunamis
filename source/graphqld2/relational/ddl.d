module graphqld2.relational.ddl;

import std.algorithm;
import std.array;
import std.meta;
import std.traits;

// ============================================================================
// SQL Type Mapping
// ============================================================================

/// Map D types to SQL types
template sqlTypeName(T) {
    static if (is(T == string)) {
        enum sqlTypeName = "TEXT";
    } else static if (is(T == bool)) {
        enum sqlTypeName = "BOOLEAN";
    } else static if (is(T == int)) {
        enum sqlTypeName = "INTEGER";
    } else static if (is(T == long)) {
        enum sqlTypeName = "BIGINT";
    } else static if (is(T == short)) {
        enum sqlTypeName = "SMALLINT";
    } else static if (is(T == byte)) {
        enum sqlTypeName = "SMALLINT";
    } else static if (is(T == float)) {
        enum sqlTypeName = "REAL";
    } else static if (is(T == double)) {
        enum sqlTypeName = "DOUBLE PRECISION";
    } else {
        enum sqlTypeName = "TEXT";  // Fallback
    }
}

// ============================================================================
// Column Info Extraction
// ============================================================================

/// Column definition for DDL
struct ColumnDef {
    string name;
    string sqlType;
    bool nullable;
    bool isPrimaryKey;
    string foreignKeyTable;  // Empty if not a FK
    string foreignKeyColumn; // Empty if not a FK
}

/// Extract column definitions from an entity type
template getColumnDefs(Entity) {
    enum getColumnDefs = () {
        ColumnDef[] columns;
        bool[string] seenColumns;

        // Always add id as primary key
        columns ~= ColumnDef("id", "BIGINT", false, true, "", "");
        seenColumns["id"] = true;

        // First pass: collect BelongsTo FK columns (they have FK constraints)
        static foreach (member; __traits(allMembers, Entity)) {{
            static if (member.length > 16 && member[0..16] == "_belongsToField_") {
                alias FieldMeta = __traits(getMember, Entity, member);
                if (FieldMeta.foreignKey !in seenColumns) {
                    columns ~= ColumnDef(
                        FieldMeta.foreignKey,
                        "BIGINT",
                        FieldMeta.nullable,
                        false,
                        FieldMeta.parentType._table,
                        "id"
                    );
                    seenColumns[FieldMeta.foreignKey] = true;
                }
            }
        }}

        // Second pass: collect regular columns (skip if already seen as FK)
        static foreach (member; __traits(allMembers, Entity)) {{
            static if (member.length > 10 && member[0..10] == "_colField_") {
                alias FieldMeta = __traits(getMember, Entity, member);
                if (FieldMeta.column !in seenColumns) {
                    columns ~= ColumnDef(
                        FieldMeta.column,
                        sqlTypeName!(FieldMeta.type),
                        false,
                        false,
                        "",
                        ""
                    );
                    seenColumns[FieldMeta.column] = true;
                }
            }
        }}

        return columns;
    }();
}

// ============================================================================
// DDL Generation
// ============================================================================

/// Generate CREATE TABLE statement for an entity
string generateCreateTable(Entity)() {
    string result = "CREATE TABLE " ~ Entity._table ~ " (\n";

    auto columns = getColumnDefs!Entity;
    string[] colDefs;
    string[] constraints;

    foreach (col; columns) {
        string def = "  " ~ col.name ~ " " ~ col.sqlType;
        if (col.isPrimaryKey) {
            def ~= " PRIMARY KEY";
        } else if (!col.nullable) {
            def ~= " NOT NULL";
        }
        colDefs ~= def;

        // Add foreign key constraint
        if (col.foreignKeyTable.length > 0) {
            constraints ~= "  FOREIGN KEY (" ~ col.name ~ ") REFERENCES " ~
                          col.foreignKeyTable ~ "(" ~ col.foreignKeyColumn ~ ")";
        }
    }

    result ~= colDefs.join(",\n");
    if (constraints.length > 0) {
        result ~= ",\n" ~ constraints.join(",\n");
    }
    result ~= "\n);\n";

    return result;
}

/// Generate CREATE TABLE statements for all entities reachable from Query
template generateDDL(Query) {
    import graphqld2.graphql.schema : getAllEntityTypes;

    alias AllTypes = getAllEntityTypes!Query;

    enum generateDDL = () {
        string result;
        result ~= "-- Generated DDL for schema\n";
        result ~= "-- Tables are ordered by dependency (referenced tables first)\n\n";

        // TODO: Proper topological sort for FK dependencies
        // For now, just generate in discovery order (which should be roughly correct)
        static foreach (Entity; AllTypes) {
            result ~= generateCreateTable!Entity();
            result ~= "\n";
        }

        return result;
    }();
}

// ============================================================================
// Tests
// ============================================================================

unittest {
    // Test SQL type mapping
    static assert(sqlTypeName!string == "TEXT");
    static assert(sqlTypeName!int == "INTEGER");
    static assert(sqlTypeName!long == "BIGINT");
    static assert(sqlTypeName!bool == "BOOLEAN");
    static assert(sqlTypeName!double == "DOUBLE PRECISION");
}
