module dunamis.relational.ddl;

/// DDL generation infrastructure with dialect-parameterized common logic.
/// Each database package provides a Dialect struct with static methods.

import std.algorithm;
import std.array;
import std.format : format;

import dunamis.core.types : isCustomScalar;
import dunamis.relational.schema : EntityID;

// ============================================================================
// Column Info Extraction
// ============================================================================

/// Column definition for DDL generation.
struct ColumnDef {
    string name;
    string dType;            // D type name for dialect-specific mapping
    bool nullable;
    bool isPrimaryKey;
    bool isAutoIncrement;
    string foreignKeyTable;  // Empty if not a FK
    string foreignKeyColumn; // Empty if not a FK
}

/// Get the base D type name for SQL mapping
template getDTypeName(T) {
    import std.typecons : Nullable;
    static if (is(T == Nullable!U, U)) {
        // Unwrap Nullable to get base type
        enum getDTypeName = getDTypeName!U;
    } else static if (isCustomScalar!T) {
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
    } else static if (is(T == enum)) {
        // Enums are stored as strings
        enum getDTypeName = "string";
    } else {
        enum getDTypeName = "string";  // Fallback
    }
}

/// Extract column definitions from an entity type.
/// Scans for methods with @SqlColumn UDA and plain struct fields.
template getColumnDefs(Entity) {
    import std.traits : hasUDA, getUDAs, ReturnType;
    import std.meta : staticIndexOf;
    import std.typecons : Nullable;
    import dunamis.relational.schema : SqlColumn, PrimaryKey;
    import dunamis.relational.schema : ForeignKeyRef, hasForeignKeyRef, extractForeignKeyRef;
    import dunamis.relational.schema : BelongsToFK, hasBelongsToFK, getBelongsToFK;
    import dunamis.relational.schema : BelongsToParent, hasBelongsToParent, extractBelongsToParent;
    import dunamis.relational.schema : getSqlColumn, isPlainField, getPlainFieldColumnName;
    import dunamis.core.types : hasPrimaryKeyAttr, hasAutoIncrementAttr, AutoIncrement;
    import dunamis.core.expr : ExprResultType;

    enum getColumnDefs = () {
        ColumnDef[] columns;
        bool[string] seenColumns;

        // Zeroth pass: @PrimaryKey plain fields (so id column comes first)
        static foreach (member; __traits(allMembers, Entity)) {{
            static if (isPlainField!(Entity, member) && hasPrimaryKeyAttr!(Entity, member)) {
                enum columnName = getPlainFieldColumnName!(Entity, member);
                if (columnName !in seenColumns) {
                    alias FieldType = typeof(__traits(getMember, Entity.init, member));
                    enum bool isNullable = is(FieldType == Nullable!U, U);

                    columns ~= ColumnDef(
                        columnName,
                        getDTypeName!FieldType,
                        false,   // PK is never nullable
                        true,    // isPrimaryKey
                        hasAutoIncrementAttr!(Entity, member),
                        "",      // foreignKeyTable
                        ""       // foreignKeyColumn
                    );
                    seenColumns[columnName] = true;
                }
            }
        }}

        // Collect all columns from methods with @SqlColumn UDA
        static foreach (member; __traits(allMembers, Entity)) {{
            static if (is(typeof(__traits(getMember, Entity, member)) == function)) {
                alias fieldMethod = __traits(getMember, Entity, member);

                // Check for @SqlColumn UDA (indicates a column field)
                static if (hasUDA!(fieldMethod, SqlColumn)) {
                    enum columnName = getUDAs!(fieldMethod, SqlColumn)[0].name;

                    if (columnName !in seenColumns) {
                        // Check if primary key (via @PrimaryKey UDA)
                        enum bool isPK = hasUDA!(fieldMethod, PrimaryKey);

                        // Get the D type from method return type
                        alias ColType = ExprResultType!(ReturnType!fieldMethod);

                        // Check if nullable (return type is Nullable!T)
                        enum bool isNullable = is(ColType == Nullable!U, U);

                        // Check if FK column
                        // Check if auto-increment (via @AutoIncrement UDA)
                        enum bool isAutoInc = hasUDA!(fieldMethod, AutoIncrement);

                        static if (hasForeignKeyRef!fieldMethod) {
                            alias FkEntity = extractForeignKeyRef!fieldMethod;
                            columns ~= ColumnDef(
                                columnName,
                                getDTypeName!ColType,
                                isPK ? false : isNullable,
                                isPK,
                                isAutoInc,
                                EntityID!FkEntity.table,
                                "id"  // Default FK column
                            );
                        } else {
                            columns ~= ColumnDef(
                                columnName,
                                getDTypeName!ColType,
                                isPK ? false : isNullable,
                                isPK,
                                isAutoInc,
                                "",
                                ""
                            );
                        }
                        seenColumns[columnName] = true;
                    }
                }
            }
        }}

        // Collect non-PK plain fields (struct instance fields)
        static foreach (member; __traits(allMembers, Entity)) {{
            static if (isPlainField!(Entity, member) && !hasPrimaryKeyAttr!(Entity, member)) {
                enum columnName = getPlainFieldColumnName!(Entity, member);
                if (columnName !in seenColumns) {
                    alias FieldType = typeof(__traits(getMember, Entity.init, member));

                    // Check if nullable
                    enum bool isNullable = is(FieldType == Nullable!U, U);

                    columns ~= ColumnDef(
                        columnName,
                        getDTypeName!FieldType,
                        isNullable,
                        false,  // isPrimaryKey
                        false,  // isAutoIncrement
                        "",     // foreignKeyTable
                        ""      // foreignKeyColumn
                    );
                    seenColumns[columnName] = true;
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
        string result = "CREATE TABLE " ~ EntityID!Entity.table ~ " (\n";

        enum columns = getColumnDefs!Entity;

        // Count primary key columns to detect composite keys
        size_t pkCount = 0;
        foreach (col; columns) {
            if (col.isPrimaryKey)
                pkCount++;
        }
        bool isCompositePK = pkCount > 1;

        string[] colDefs;
        string[] pkColNames;
        string[] fkConstraints;

        foreach (col; columns) {
            string sqlType;

            // For PK columns in composite keys, use PK-safe type if dialect provides one
            // (e.g., MySQL needs VARCHAR(255) instead of TEXT for PK columns)
            static if (__traits(hasMember, Dialect, "primaryKeySqlTypeName")) {
                sqlType = col.isPrimaryKey
                    ? Dialect.primaryKeySqlTypeName(col.dType)
                    : Dialect.sqlTypeName(col.dType);
            } else {
                sqlType = Dialect.sqlTypeName(col.dType);
            }

            // Handle auto-increment (only for columns with @AutoIncrement UDA)
            if (col.isAutoIncrement) {
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
                        EntityID!Entity.table,
                        EntityID!Entity.table,
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

/// Check if a type is a database entity (has @Entity UDA)
private template isDatabaseEntity(T) {
    import dunamis.relational.schema : hasEntityAttr;
    enum isDatabaseEntity = hasEntityAttr!T;
}

/// Generate DDL for all entities reachable from Query using the given dialect.
/// Only generates tables for types that have the Entity mixin (not POD types).
template generateDDL(Dialect, Query) {
    import dunamis.core.discovery : getAllObjectTypes;
    import std.meta : Filter;

    alias AllTypes = getAllObjectTypes!Query;

    // Filter to only include database entities (types with Entity mixin)
    alias DatabaseEntities = Filter!(isDatabaseEntity, AllTypes);

    enum generateDDL = () {
        string result;
        result ~= "-- Generated " ~ Dialect.name ~ " DDL\n";

        static if (Dialect.supportsAlterTableFK) {
            result ~= "-- Phase 1: Create tables\n\n";
        } else {
            result ~= "\n";
        }

        // Create all tables (only for database entities)
        static foreach (Entity; DatabaseEntities) {
            result ~= generateCreateTable!(Dialect, Entity);
            result ~= "\n";
        }

        // Add FK constraints (if dialect uses ALTER TABLE)
        static if (Dialect.supportsAlterTableFK) {
            result ~= "-- Phase 2: Add foreign key constraints\n\n";
            static foreach (Entity; DatabaseEntities) {
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
    import dunamis.relational.schema : Col, BelongsTo, ForeignKey;
    import dunamis.relational.demo : DemoEntity, DemoId, MockDB;

    static MockDB!() db;

    @DemoEntity!(db, "managers")
    static struct Manager {
        mixin DemoId;
    }

    @DemoEntity!(db, "employees")
    static struct Employee {
        mixin DemoId;
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

// Test that plain fields are included in column definitions
unittest {
    import dunamis.relational.demo : DemoEntity, DemoId, MockDB;

    static MockDB!() db;

    @DemoEntity!(db, "persons")
    static struct Person {
        mixin DemoId;
        string nickname;  // Plain field - automatically detected
    }

    auto cols = getColumnDefs!Person;
    bool foundNickname = false;
    foreach (col; cols) {
        if (col.name == "nickname") {
            foundNickname = true;
            assert(col.dType == "string", "nickname should be string type");
            assert(col.nullable == false, "nickname should be non-nullable");
        }
    }
    assert(foundNickname, "nickname plain field should be in column definitions");
}
