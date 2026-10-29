module dunamis.sqlite.dialect;

import std.algorithm : map;
import std.array : array, join;
import std.conv : to;
import std.format : format;
import std.json : JSONValue, JSONType;
import std.string : replace;

import dunamis.relational.sql_dialect;

/// SQLite dialect - uses || for string concatenation (same as PostgreSQL)
class SQLiteDialect : SqlDialect {
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

    override string membershipOp(string operandSql, TypeInfo valueType, string[] values) {
        import dunamis.relational.sql_dialect : inListSql;
        return inListSql(operandSql, valueType, values);
    }

    override string likeOp(string operandSql, string pattern, bool caseInsensitive) {
        if (caseInsensitive) {
            // Use LOWER() for consistent case-insensitive behavior
            return "(LOWER(" ~ operandSql ~ ") LIKE LOWER('" ~ pattern ~ `') ESCAPE '\')`;
        }
        // SQLite's LIKE is case-insensitive for ASCII; GLOB is case-sensitive.
        return "(" ~ operandSql ~ " GLOB '" ~ likeToGlob(pattern) ~ "')";
    }

    /// Translate a backslash-escaped LIKE pattern to an equivalent GLOB pattern.
    private static string likeToGlob(string pattern) {
        string result;
        for (size_t i = 0; i < pattern.length; i++) {
            char c = pattern[i];
            if (c == '\\' && i + 1 < pattern.length) {
                c = pattern[++i];
                if (c == '*' || c == '?' || c == '[')
                    result ~= "[" ~ c ~ "]";
                else
                    result ~= c;
            } else if (c == '%') {
                result ~= '*';
            } else if (c == '_') {
                result ~= '?';
            } else if (c == '*' || c == '?' || c == '[') {
                result ~= "[" ~ c ~ "]";
            } else {
                result ~= c;
            }
        }
        return result;
    }

    override string name() { return "SQLite"; }

    // =========================================================================
    // Query SQL generation vocabulary
    // =========================================================================

    override string escapeSqlString(string s) {
        return "'" ~ s.replace("'", "''") ~ "'";
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
                return "1";
            case JSONType.false_:
                return "0";
            case JSONType.null_:
                return "NULL";
            case JSONType.array:
                auto elements = val.array.map!(v => jsonToSqlLiteral(v)).array;
                return "json_array(" ~ elements.join(",") ~ ")";
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

    override string jsonObjectFunc() { return "json_object"; }

    override string rowJsonFunc() { return "json_object"; }

    override string emptyJsonArray() { return "json('[]')"; }

    override string castToText(string sql) { return "CAST(" ~ sql ~ " AS TEXT)"; }

    override string aggregateLayerJson(int layerId, string orderByClause) {
        if (orderByClause.length > 0) {
            return format("COALESCE((SELECT json_group_array(json(row_json)) FROM (SELECT * FROM layer%d ORDER BY %s)), %s)",
                layerId, orderByClause, emptyJsonArray());
        }
        return format("COALESCE((SELECT json_group_array(json(row_json)) FROM layer%d), %s)",
            layerId, emptyJsonArray());
    }

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
