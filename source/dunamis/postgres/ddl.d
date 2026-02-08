module dunamis.postgres.ddl;

/// PostgreSQL dialect for DDL generation.

import dunamis.relational.ddl;

/// PostgreSQL-specific DDL configuration
struct PostgresDialect {
    enum name = "PostgreSQL";
    enum supportsAlterTableFK = true;

    /// Map D type names to PostgreSQL types
    static string sqlTypeName(string dType) {
        switch (dType) {
            case "string": return "TEXT";
            case "bool": return "BOOLEAN";
            case "int": return "INTEGER";
            case "long": return "BIGINT";
            case "short": return "SMALLINT";
            case "byte": return "SMALLINT";
            case "float": return "REAL";
            case "double": return "DOUBLE PRECISION";
            default: return "TEXT";
        }
    }

    /// PostgreSQL uses SERIAL/BIGSERIAL for auto-increment
    static string autoIncrementType(string baseType) {
        if (baseType == "BIGINT") return "BIGSERIAL";
        if (baseType == "INTEGER") return "SERIAL";
        return baseType;
    }
}

/// Generate DDL for PostgreSQL
alias generateDDL(Query) = dunamis.relational.ddl.generateDDL!(PostgresDialect, Query);

/// Generate CREATE TABLE for PostgreSQL
alias generateCreateTable(Entity) = dunamis.relational.ddl.generateCreateTable!(PostgresDialect, Entity);

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
    assert(ddl.canFind("BIGSERIAL PRIMARY KEY"), "Should use BIGSERIAL for id");
    assert(ddl.canFind("department_id BIGINT NOT NULL"), "FK should be NOT NULL without inline REFERENCES");
    assert(!ddl.canFind("REFERENCES"), "PostgreSQL uses ALTER TABLE for FKs");
}
