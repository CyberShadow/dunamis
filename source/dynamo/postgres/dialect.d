module dynamo.postgres.dialect;

import dynamo.relational.sql_dialect;

/// PostgreSQL dialect - uses || for string concatenation
class PostgresDialect : SqlDialect {
    override string binaryOp(string op, string leftSql, string rightSql) {
        auto sqlOp = toSqlOp(op);
        return "(" ~ leftSql ~ " " ~ sqlOp ~ " " ~ rightSql ~ ")";
    }

    override string unaryOp(string op, string operandSql) {
        if (op == "!") return "(NOT " ~ operandSql ~ ")";
        return "(" ~ op ~ operandSql ~ ")";
    }

    override string caseWhen(string conditionSql, string trueSql, string falseSql) {
        return "(CASE WHEN " ~ conditionSql ~ " THEN " ~ trueSql ~ " ELSE " ~ falseSql ~ " END)";
    }

    override string isNullOp(string operandSql) {
        return "(" ~ operandSql ~ " IS NULL)";
    }

    override string existsSubquery(string subquery) {
        return "EXISTS (" ~ subquery ~ ")";
    }

    override string notExistsSubquery(string subquery) {
        return "NOT EXISTS (" ~ subquery ~ ")";
    }

    override string name() { return "PostgreSQL"; }

    private static string toSqlOp(string op) {
        switch (op) {
            case "~": return "||";   // String concatenation
            case "==": return "=";   // Equality
            case "!=": return "<>";  // Inequality
            case "&&": return "AND"; // Logical and
            case "||": return "OR";  // Logical or
            case "%": return "%";    // Modulo
            default: return op;      // +, -, *, /, <, >, <=, >= are the same
        }
    }
}

// Singleton instance
private __gshared PostgresDialect _instance;

/// Get the PostgreSQL dialect singleton
SqlDialect postgresDialect() {
    if (_instance is null) {
        _instance = new PostgresDialect();
    }
    return _instance;
}

// ============================================================================
// Unit Tests
// ============================================================================

unittest {
    auto dialect = postgresDialect();

    // String concatenation uses ||
    assert(dialect.binaryOp("~", "'a'", "'b'") == "('a' || 'b')");

    // Arithmetic operators
    assert(dialect.binaryOp("+", "1", "2") == "(1 + 2)");
    assert(dialect.binaryOp("-", "5", "3") == "(5 - 3)");
    assert(dialect.binaryOp("*", "2", "3") == "(2 * 3)");
    assert(dialect.binaryOp("/", "6", "2") == "(6 / 2)");

    // Comparison operators
    assert(dialect.binaryOp("==", "a", "b") == "(a = b)");
    assert(dialect.binaryOp("!=", "a", "b") == "(a <> b)");
    assert(dialect.binaryOp("<", "a", "b") == "(a < b)");
    assert(dialect.binaryOp(">", "a", "b") == "(a > b)");

    // Logical operators
    assert(dialect.binaryOp("&&", "a", "b") == "(a AND b)");
    assert(dialect.binaryOp("||", "a", "b") == "(a OR b)");

    // Unary operators
    assert(dialect.unaryOp("!", "a") == "(NOT a)");
    assert(dialect.unaryOp("-", "5") == "(-5)");

    // Case when
    assert(dialect.caseWhen("a > 0", "'positive'", "'negative'") ==
           "(CASE WHEN a > 0 THEN 'positive' ELSE 'negative' END)");

    // IS NULL
    assert(dialect.isNullOp("a") == "(a IS NULL)");

    // EXISTS / NOT EXISTS
    assert(dialect.existsSubquery("SELECT 1 FROM posts WHERE author_id = users.id") ==
           "EXISTS (SELECT 1 FROM posts WHERE author_id = users.id)");
    assert(dialect.notExistsSubquery("SELECT 1 FROM posts WHERE author_id = users.id") ==
           "NOT EXISTS (SELECT 1 FROM posts WHERE author_id = users.id)");
}
