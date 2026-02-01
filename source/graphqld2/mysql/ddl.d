module graphqld2.mysql.ddl;

/// MySQL dialect for DDL generation.

import graphqld2.relational.ddl;

/// MySQL-specific DDL configuration
struct MySQLDialect {
    enum name = "MySQL";
    enum supportsAlterTableFK = true;

    /// Map D type names to MySQL types
    static string sqlTypeName(string dType) {
        switch (dType) {
            case "string": return "TEXT";
            case "bool": return "BOOLEAN";  // MySQL 8.0+ (alias for TINYINT(1))
            case "int": return "INT";
            case "long": return "BIGINT";
            case "short": return "SMALLINT";
            case "byte": return "TINYINT";
            case "float": return "FLOAT";
            case "double": return "DOUBLE";
            default: return "TEXT";
        }
    }

    /// MySQL uses AUTO_INCREMENT for auto-increment columns
    static string autoIncrementType(string baseType) {
        // AUTO_INCREMENT is a modifier, not a type replacement
        // But for primary key columns, we just return the base type
        // and add AUTO_INCREMENT in the column definition
        return baseType ~ " AUTO_INCREMENT";
    }
}

/// Generate DDL for MySQL
alias generateDDL(Query) = graphqld2.relational.ddl.generateDDL!(MySQLDialect, Query);

/// Generate CREATE TABLE for MySQL
alias generateCreateTable(Entity) = graphqld2.relational.ddl.generateCreateTable!(MySQLDialect, Entity);

// ============================================================================
// Tests
// ============================================================================

unittest {
    import std.algorithm : canFind;
    import std.typecons : Nullable;
    import graphqld2.relational.schema : Col, BelongsTo, ForeignKey;
    import graphqld2.relational.demo : DemoEntity, MockDB;

    static MockDB!() db;

    static struct Department {
        mixin DemoEntity!(db, "departments");
    }

    static struct Employee {
        mixin DemoEntity!(db, "employees");
        mixin Col!("departmentId", ForeignKey!Department);
        mixin BelongsTo!("department", "departmentId");
    }

    enum ddl = generateCreateTable!Employee;

    // MySQL uses BIGINT AUTO_INCREMENT for id
    assert(ddl.canFind("BIGINT AUTO_INCREMENT PRIMARY KEY"), "Should use BIGINT AUTO_INCREMENT PRIMARY KEY");

    // FK should NOT be inline (MySQL uses ALTER TABLE for FKs)
    assert(!ddl.canFind("REFERENCES"), "MySQL uses ALTER TABLE for FKs");

    // Should have NOT NULL for required FK
    assert(ddl.canFind("department_id BIGINT NOT NULL"), "FK should be NOT NULL without inline REFERENCES");
}
