module graphqld2.mysql.dialect;

import graphqld2.relational.sql_dialect;

/// MySQL dialect - uses CONCAT() for string concatenation
class MySQLDialect : SqlDialect {
    override string binaryOp(string op, string leftSql, string rightSql) {
        // MySQL uses CONCAT() for string concatenation instead of ||
        if (op == "~") {
            return "CONCAT(" ~ leftSql ~ ", " ~ rightSql ~ ")";
        }

        auto sqlOp = toSqlOp(op);
        return "(" ~ leftSql ~ " " ~ sqlOp ~ " " ~ rightSql ~ ")";
    }

    override string name() { return "MySQL"; }

    private static string toSqlOp(string op) {
        switch (op) {
            case "==": return "=";   // Equality
            case "!=": return "<>";  // Inequality
            case "&&": return "AND"; // Logical and
            case "||": return "OR";  // Logical or
            case "%": return "%";    // Modulo (MySQL uses MOD() or %)
            default: return op;
        }
    }
}

// Singleton instance
private __gshared MySQLDialect _instance;

/// Get the MySQL dialect singleton
SqlDialect mysqlDialect() {
    if (_instance is null) {
        _instance = new MySQLDialect();
    }
    return _instance;
}

// ============================================================================
// Unit Tests
// ============================================================================

unittest {
    auto dialect = mysqlDialect();

    // String concatenation uses CONCAT()
    assert(dialect.binaryOp("~", "'a'", "'b'") == "CONCAT('a', 'b')");

    // Arithmetic operators
    assert(dialect.binaryOp("+", "1", "2") == "(1 + 2)");

    // Comparison operators
    assert(dialect.binaryOp("==", "a", "b") == "(a = b)");
    assert(dialect.binaryOp("!=", "a", "b") == "(a <> b)");

    // Logical operators
    assert(dialect.binaryOp("&&", "a", "b") == "(a AND b)");
    assert(dialect.binaryOp("||", "a", "b") == "(a OR b)");
}
