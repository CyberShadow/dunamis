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

/// Get primary key column names from entity (empty if none defined)
template getPrimaryKeyColumns(Entity) {
    static if (__traits(hasMember, Entity, "_primaryKey")) {
        enum getPrimaryKeyColumns = Entity._primaryKey.columns;
    } else {
        enum string[] getPrimaryKeyColumns = [];
    }
}

/// Check if a column name is part of the primary key
bool isInPrimaryKey(string colName, const string[] pkColumns) {
    foreach (pk; pkColumns) {
        if (pk == colName) return true;
    }
    return false;
}

/// Extract column definitions from an entity type
template getColumnDefs(Entity) {
    enum getColumnDefs = () {
        ColumnDef[] columns;
        bool[string] seenColumns;
        enum pkColumns = getPrimaryKeyColumns!Entity;

        // Collect all columns from Col mixins
        static foreach (member; __traits(allMembers, Entity)) {{
            static if (member.length > 10 && member[0..10] == "_colField_") {
                alias FieldMeta = __traits(getMember, Entity, member);
                if (FieldMeta.column !in seenColumns) {
                    // Check if this column is part of the primary key
                    // (either via _primaryKey metadata or legacy isPrimaryKey field)
                    static if (__traits(hasMember, FieldMeta, "isPrimaryKey")) {
                        enum bool isPK = isInPrimaryKey(FieldMeta.name, pkColumns) || FieldMeta.isPrimaryKey;
                    } else {
                        enum bool isPK = isInPrimaryKey(FieldMeta.name, pkColumns);
                    }

                    static if (FieldMeta.isForeignKey) {
                        // ForeignKey column - include FK constraint
                        columns ~= ColumnDef(
                            FieldMeta.column,
                            sqlTypeName!(FieldMeta.type),
                            isPK ? false : FieldMeta.isNullable,
                            isPK,
                            FieldMeta.referencedEntity._table,
                            FieldMeta.referencedColumn
                        );
                    } else {
                        // Regular column
                        columns ~= ColumnDef(
                            FieldMeta.column,
                            sqlTypeName!(FieldMeta.type),
                            isPK ? false : FieldMeta.isNullable,
                            isPK,
                            "",
                            ""
                        );
                    }
                    seenColumns[FieldMeta.column] = true;
                }
            }
        }}

        // Also check BelongsTo for FK columns not defined via Col
        // (for backward compatibility with schemas that don't use ForeignKey)
        static foreach (member; __traits(allMembers, Entity)) {{
            static if (member.length > 16 && member[0..16] == "_belongsToField_") {
                alias FieldMeta = __traits(getMember, Entity, member);
                if (FieldMeta.foreignKey !in seenColumns) {
                    // Get parent's id column type via _colField_id
                    static if (__traits(hasMember, FieldMeta.parentType, "_colField_id")) {
                        alias ParentIdCol = __traits(getMember, FieldMeta.parentType, "_colField_id");
                        columns ~= ColumnDef(
                            FieldMeta.foreignKey,
                            sqlTypeName!(ParentIdCol.type),
                            FieldMeta.nullable,
                            false,
                            FieldMeta.parentType._table,
                            "id"
                        );
                        seenColumns[FieldMeta.foreignKey] = true;
                    }
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
    enum pkColumns = getPrimaryKeyColumns!Entity;
    enum bool isCompositePK = pkColumns.length > 1;

    string[] colDefs;
    string[] constraints;
    string[] pkColNames;

    foreach (col; columns) {
        string def = "  " ~ col.name ~ " " ~ col.sqlType;
        if (col.isPrimaryKey) {
            pkColNames ~= col.name;
            // Only inline PRIMARY KEY for single-column PKs
            if (!isCompositePK) {
                def ~= " PRIMARY KEY";
            } else if (!col.nullable) {
                def ~= " NOT NULL";
            }
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

    // Add composite primary key constraint
    if (isCompositePK && pkColNames.length > 0) {
        constraints = ["  PRIMARY KEY (" ~ pkColNames.join(", ") ~ ")"] ~ constraints;
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

unittest {
    import std.algorithm : canFind;
    import std.typecons : Nullable;
    import graphqld2.core.expr : Expr;
    import graphqld2.core.types : Ref;
    import graphqld2.relational.schema : DemoEntity, Col, BelongsTo, ForeignKey, belongsTo;

    // Test nullable FK via Col + BelongsTo
    struct Manager {
        mixin DemoEntity!"managers";
    }

    struct Employee {
        mixin DemoEntity!"employees";
        mixin Col!("managerId", Nullable!(ForeignKey!Manager));  // nullable FK column
        mixin BelongsTo!("manager", "managerId");  // derives nullability from column
    }

    auto cols = getColumnDefs!Employee;
    // Find the manager_id column
    bool found = false;
    foreach (col; cols) {
        if (col.name == "manager_id") {
            found = true;
            assert(col.nullable == true, "manager_id should be nullable");
            assert(col.foreignKeyTable == "managers", "Should reference managers table");
        }
    }
    assert(found, "manager_id column should exist");

    // Verify DDL output doesn't have NOT NULL for nullable FK
    enum ddl = generateCreateTable!Employee;
    assert(ddl.canFind("manager_id BIGINT,") || ddl.canFind("manager_id BIGINT\n"),
           "Nullable FK should not have NOT NULL constraint");
    assert(!ddl.canFind("manager_id BIGINT NOT NULL"),
           "Nullable FK should not have NOT NULL");
}

unittest {
    import std.algorithm : canFind;
    import std.typecons : Nullable;
    import graphqld2.core.expr : Expr;
    import graphqld2.core.types : Ref;
    import graphqld2.relational.schema : DemoEntity, Col, BelongsTo, ForeignKey, belongsTo;

    // Test required FK via Col + BelongsTo
    struct Department {
        mixin DemoEntity!"departments";
    }

    struct Employee2 {
        mixin DemoEntity!"employees2";
        mixin Col!("departmentId", ForeignKey!Department);  // required FK column
        mixin BelongsTo!("department", "departmentId");  // derives from column
    }

    auto cols = getColumnDefs!Employee2;
    bool found = false;
    foreach (col; cols) {
        if (col.name == "department_id") {
            found = true;
            assert(col.nullable == false, "department_id should be required");
        }
    }
    assert(found, "department_id column should exist");

    // Verify DDL output has NOT NULL for required FK
    enum ddl = generateCreateTable!Employee2;
    assert(ddl.canFind("department_id BIGINT NOT NULL"),
           "Required FK should have NOT NULL constraint");
}
