module graphqld2.relational.ddl;

/// DDL generation infrastructure with dialect-parameterized common logic.
/// Each database package provides a Dialect struct with static methods.

import std.algorithm;
import std.array;
import std.format : format;

import graphqld2.core.types : isCustomScalar;

// ============================================================================
// Column Info Extraction
// ============================================================================

/// Column definition for DDL generation.
struct ColumnDef {
    string name;
    string dType;            // D type name for dialect-specific mapping
    bool nullable;
    bool isPrimaryKey;
    string foreignKeyTable;  // Empty if not a FK
    string foreignKeyColumn; // Empty if not a FK
}

/// Get primary key column names from entity
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

/// Get the base D type name for SQL mapping
template getDTypeName(T) {
    static if (isCustomScalar!T) {
        enum getDTypeName = getDTypeName!(T.DType);
    } else static if (is(T == string)) {
        enum getDTypeName = "string";
    } else static if (is(T == bool)) {
        enum getDTypeName = "bool";
    } else static if (is(T == int)) {
        enum getDTypeName = "int";
    } else static if (is(T == long)) {
        enum getDTypeName = "long";
    } else static if (is(T == short)) {
        enum getDTypeName = "short";
    } else static if (is(T == byte)) {
        enum getDTypeName = "byte";
    } else static if (is(T == float)) {
        enum getDTypeName = "float";
    } else static if (is(T == double)) {
        enum getDTypeName = "double";
    } else {
        enum getDTypeName = "string";  // Fallback
    }
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
                    static if (__traits(hasMember, FieldMeta, "isPrimaryKey")) {
                        enum bool isPK = isInPrimaryKey(FieldMeta.name, pkColumns) || FieldMeta.isPrimaryKey;
                    } else {
                        enum bool isPK = isInPrimaryKey(FieldMeta.name, pkColumns);
                    }

                    static if (FieldMeta.isForeignKey) {
                        columns ~= ColumnDef(
                            FieldMeta.column,
                            getDTypeName!(FieldMeta.type),
                            isPK ? false : FieldMeta.isNullable,
                            isPK,
                            FieldMeta.referencedEntity._table,
                            FieldMeta.referencedColumn
                        );
                    } else {
                        columns ~= ColumnDef(
                            FieldMeta.column,
                            getDTypeName!(FieldMeta.type),
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
        static foreach (member; __traits(allMembers, Entity)) {{
            static if (member.length > 16 && member[0..16] == "_belongsToField_") {
                alias FieldMeta = __traits(getMember, Entity, member);
                if (FieldMeta.foreignKey !in seenColumns) {
                    static if (__traits(hasMember, FieldMeta.parentType, "_colField_id")) {
                        alias ParentIdCol = __traits(getMember, FieldMeta.parentType, "_colField_id");
                        columns ~= ColumnDef(
                            FieldMeta.foreignKey,
                            getDTypeName!(ParentIdCol.type),
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
// Dialect-Parameterized DDL Generation
// ============================================================================

/// Generate CREATE TABLE statement for an entity using the given dialect.
template generateCreateTable(Dialect, Entity) {
    enum generateCreateTable = () {
        string result = "CREATE TABLE " ~ Entity._table ~ " (\n";

        enum columns = getColumnDefs!Entity;
        enum pkColumns = getPrimaryKeyColumns!Entity;
        enum bool isCompositePK = pkColumns.length > 1;

        string[] colDefs;
        string[] pkColNames;
        string[] fkConstraints;

        foreach (col; columns) {
            string sqlType = Dialect.sqlTypeName(col.dType);

            // Handle auto-increment for single-column primary keys
            if (col.isPrimaryKey && !isCompositePK) {
                sqlType = Dialect.autoIncrementType(sqlType);
            }

            string def = "  " ~ col.name ~ " " ~ sqlType;

            if (col.isPrimaryKey) {
                pkColNames ~= col.name;
                if (!isCompositePK) {
                    def ~= " PRIMARY KEY";
                } else if (!col.nullable) {
                    def ~= " NOT NULL";
                }
            } else if (!col.nullable) {
                def ~= " NOT NULL";
            }

            // Handle FK constraints based on dialect
            if (col.foreignKeyTable.length > 0) {
                static if (Dialect.supportsAlterTableFK) {
                    // Will be added via ALTER TABLE later
                } else {
                    // Inline FK constraint
                    def ~= " REFERENCES " ~ col.foreignKeyTable ~ "(" ~ col.foreignKeyColumn ~ ")";
                }
            }

            colDefs ~= def;
        }

        result ~= colDefs.join(",\n");

        // Add composite primary key constraint
        if (isCompositePK && pkColNames.length > 0) {
            result ~= ",\n  PRIMARY KEY (" ~ pkColNames.join(", ") ~ ")";
        }

        result ~= "\n);\n";

        return result;
    }();
}

/// Generate ALTER TABLE statements for FK constraints (for dialects that support it)
template generateForeignKeys(Dialect, Entity) {
    enum generateForeignKeys = () {
        static if (!Dialect.supportsAlterTableFK) {
            return "";  // FKs are inline for this dialect
        } else {
            string result;
            enum columns = getColumnDefs!Entity;
            int fkIndex = 0;

            foreach (col; columns) {
                if (col.foreignKeyTable.length > 0) {
                    result ~= format("ALTER TABLE %s ADD CONSTRAINT %s_fk%d FOREIGN KEY (%s) REFERENCES %s(%s);\n",
                        Entity._table,
                        Entity._table,
                        fkIndex++,
                        col.name,
                        col.foreignKeyTable,
                        col.foreignKeyColumn
                    );
                }
            }

            return result;
        }
    }();
}

/// Generate DDL for all entities reachable from Query using the given dialect.
template generateDDL(Dialect, Query) {
    import graphqld2.graphql.schema : getAllEntityTypes;

    alias AllTypes = getAllEntityTypes!Query;

    enum generateDDL = () {
        string result;
        result ~= "-- Generated " ~ Dialect.name ~ " DDL\n";

        static if (Dialect.supportsAlterTableFK) {
            result ~= "-- Phase 1: Create tables\n\n";
        } else {
            result ~= "\n";
        }

        // Create all tables
        static foreach (Entity; AllTypes) {
            result ~= generateCreateTable!(Dialect, Entity);
            result ~= "\n";
        }

        // Add FK constraints (if dialect uses ALTER TABLE)
        static if (Dialect.supportsAlterTableFK) {
            result ~= "-- Phase 2: Add foreign key constraints\n\n";
            static foreach (Entity; AllTypes) {
                result ~= generateForeignKeys!(Dialect, Entity);
            }
        }

        return result;
    }();
}

// ============================================================================
// Tests
// ============================================================================

unittest {
    import std.typecons : Nullable;
    import graphqld2.relational.schema : Col, BelongsTo, ForeignKey;
    import graphqld2.relational.demo : DemoEntity, MockDB;

    static MockDB!() db;

    static struct Manager {
        mixin DemoEntity!(db, "managers");
    }

    static struct Employee {
        mixin DemoEntity!(db, "employees");
        mixin Col!("managerId", Nullable!(ForeignKey!Manager));
        mixin BelongsTo!("manager", "managerId");
    }

    auto cols = getColumnDefs!Employee;
    bool found = false;
    foreach (col; cols) {
        if (col.name == "manager_id") {
            found = true;
            assert(col.nullable == true, "manager_id should be nullable");
            assert(col.foreignKeyTable == "managers");
            assert(col.dType == "long");
        }
    }
    assert(found, "manager_id column should exist");
}
