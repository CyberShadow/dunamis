module dunamis.mysql.dialect;

import std.algorithm : map;
import std.array : array, join;
import std.conv : to;
import std.format : format;
import std.json : JSONValue, JSONType;
import std.string : replace;

import dunamis.relational.sql_dialect;

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

    override string membershipOp(string operandSql, TypeInfo valueType, string[] values) {
        import dunamis.relational.sql_dialect : inListSql;
        return inListSql(operandSql, valueType, values);
    }

    override string likeOp(string operandSql, string pattern, bool caseInsensitive) {
        // Backslash is also the string-literal escape character in MySQL, so
        // double it for the pattern's escapes to reach LIKE intact.
        auto literal = "'" ~ pattern.replace(`\`, `\\`) ~ "'";
        if (caseInsensitive) {
            // Use LOWER() for consistent case-insensitive behavior across collations
            return "(LOWER(" ~ operandSql ~ ") LIKE LOWER(" ~ literal ~ `) ESCAPE '\\')`;
        }
        // Default collations compare case-insensitively; force a binary match.
        return "(" ~ operandSql ~ " LIKE BINARY " ~ literal ~ ` ESCAPE '\\')`;
    }

    override string name() { return "MySQL"; }

    // =========================================================================
    // Query SQL generation vocabulary
    // =========================================================================

    override string escapeSqlString(string s) {
        return "'" ~ s.replace("\\", "\\\\").replace("'", "''") ~ "'";
    }

    override string jsonToSqlLiteral(JSONValue val) {
        final switch (val.type) {
            case JSONType.string:
                return escapeSqlString(val.str);
            case JSONType.integer:
                return val.integer.to!string;
            case JSONType.uinteger:
                return val.uinteger.to!string;
            case JSONType.float_:
                return val.floating.to!string;
            case JSONType.true_:
                return "TRUE";
            case JSONType.false_:
                return "FALSE";
            case JSONType.null_:
                return "NULL";
            case JSONType.array:
                auto elements = val.array.map!(v => jsonToSqlLiteral(v)).array;
                return "JSON_ARRAY(" ~ elements.join(",") ~ ")";
            case JSONType.object:
                return escapeSqlString(val.toString());
        }
    }

    override string rootIdFilter(string table, string[] pkColumns) {
        if (pkColumns.length == 1) {
            return format("%s.%s IN ({{IDS}})", table, pkColumns[0]);
        }
        auto cols = pkColumns.map!(c => table ~ "." ~ c).array.join(", ");
        return format("(%s) IN ({{IDS}})", cols);
    }

    override string jsonObjectFunc() { return "JSON_OBJECT"; }

    override string rowJsonFunc() { return "JSON_OBJECT"; }

    override string emptyJsonArray() { return "JSON_ARRAY()"; }

    override string castToText(string sql) { return "CAST(" ~ sql ~ " AS CHAR)"; }

    override string aggregateLayerJson(int layerId, string orderByClause) {
        if (orderByClause.length > 0) {
            return format("COALESCE((SELECT JSON_ARRAYAGG(row_json ORDER BY %s) FROM layer%d), %s)",
                orderByClause, layerId, emptyJsonArray());
        }
        return format("COALESCE((SELECT JSON_ARRAYAGG(row_json) FROM layer%d), %s)",
            layerId, emptyJsonArray());
    }

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

    // LIKE escapes survive MySQL's backslash string-literal escaping, and
    // case-sensitive matching does not depend on the column collation.
    assert(dialect.likeOp("t.c", `50\%`, false) == `(t.c LIKE BINARY '50\\%' ESCAPE '\\')`);
    assert(dialect.likeOp("t.c", `%a\\b%`, true) == `(LOWER(t.c) LIKE LOWER('%a\\\\b%') ESCAPE '\\')`);
}
