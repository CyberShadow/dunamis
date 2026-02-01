module graphqld2.sqlite.dialect;

import graphqld2.relational.sql_dialect;

/// SQLite dialect - uses || for string concatenation (same as PostgreSQL)
class SQLiteDialect : SqlDialect {
    override string binaryOp(string op, string leftSql, string rightSql) {
        auto sqlOp = toSqlOp(op);
        return "(" ~ leftSql ~ " " ~ sqlOp ~ " " ~ rightSql ~ ")";
    }

    override string name() { return "SQLite"; }

    private static string toSqlOp(string op) {
        switch (op) {
            case "~": return "||";   // String concatenation
            case "==": return "=";   // Equality
            case "!=": return "<>";  // Inequality
            case "&&": return "AND"; // Logical and
            case "||": return "OR";  // Logical or
            case "%": return "%";    // Modulo
            default: return op;
        }
    }
}

// Singleton instance
private __gshared SQLiteDialect _instance;

/// Get the SQLite dialect singleton
SqlDialect sqliteDialect() {
    if (_instance is null) {
        _instance = new SQLiteDialect();
    }
    return _instance;
}

// ============================================================================
// Unit Tests
// ============================================================================

unittest {
    auto dialect = sqliteDialect();

    // String concatenation uses ||
    assert(dialect.binaryOp("~", "'a'", "'b'") == "('a' || 'b')");

    // Arithmetic operators
    assert(dialect.binaryOp("+", "1", "2") == "(1 + 2)");

    // Comparison operators
    assert(dialect.binaryOp("==", "a", "b") == "(a = b)");
    assert(dialect.binaryOp("!=", "a", "b") == "(a <> b)");

    // Logical operators
    assert(dialect.binaryOp("&&", "a", "b") == "(a AND b)");
    assert(dialect.binaryOp("||", "a", "b") == "(a OR b)");
}
