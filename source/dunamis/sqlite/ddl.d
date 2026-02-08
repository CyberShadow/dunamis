module dunamis.sqlite.ddl;

/// SQLite dialect for DDL generation.

import dunamis.relational.ddl;

/// SQLite-specific DDL configuration
struct SQLiteDialect {
    enum name = "SQLite";
    enum supportsAlterTableFK = false;  // FKs must be inline

    /// Map D type names to SQLite types
    static string sqlTypeName(string dType) {
        switch (dType) {
            case "string": return "TEXT";
            case "bool": return "INTEGER";  // SQLite has no native boolean
            case "int": return "INTEGER";
            case "long": return "INTEGER";  // SQLite uses INTEGER for all integers
            case "short": return "INTEGER";
            case "byte": return "INTEGER";
            case "float": return "REAL";
            case "double": return "REAL";
            default: return "TEXT";
        }
    }

    /// SQLite auto-increment requires INTEGER PRIMARY KEY
    static string autoIncrementType(string baseType) {
        return "INTEGER";  // Must be exactly INTEGER for ROWID alias
    }
}

/// Generate DDL for SQLite
alias generateDDL(Query) = dunamis.relational.ddl.generateDDL!(SQLiteDialect, Query);

/// Generate CREATE TABLE for SQLite
alias generateCreateTable(Entity) = dunamis.relational.ddl.generateCreateTable!(SQLiteDialect, Entity);

// ============================================================================
// Tests
// ============================================================================

unittest {
    import std.algorithm : canFind;
    import std.typecons : Nullable;
    import dunamis.relational.schema : Col, BelongsTo, ForeignKey;
    import dunamis.relational.demo : DemoEntity, DemoId, MockDB;

    static MockDB!() db;

    @DemoEntity!(db, "departments")
    static struct Department {
        mixin DemoId;
    }

    @DemoEntity!(db, "employees")
    static struct Employee {
        mixin DemoId;
        mixin Col!("departmentId", ForeignKey!Department);
        mixin BelongsTo!("department", "departmentId");
    }

    enum ddl = generateCreateTable!Employee;

    // SQLite uses INTEGER PRIMARY KEY for auto-increment
    assert(ddl.canFind("INTEGER PRIMARY KEY"), "Should use INTEGER PRIMARY KEY");

    // FK should be inline REFERENCES
    assert(ddl.canFind("REFERENCES departments(id)"), "FK should be inline");

    // Should have NOT NULL for required FK
    assert(ddl.canFind("department_id INTEGER NOT NULL REFERENCES"), "FK should be NOT NULL with inline REFERENCES");
}
