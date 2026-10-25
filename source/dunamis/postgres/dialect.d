module dunamis.postgres.dialect;

import std.algorithm : map;
import std.array : array, join;
import std.conv : to;
import std.format : format;
import std.json : JSONValue, JSONType;
import std.string : replace;

import dunamis.relational.sql_dialect;

/// PostgreSQL dialect - uses || for string concatenation
class PostgresDialect : SqlDialect {
    override string binaryOp(string op, string leftSql, string rightSql) {
        auto sqlOp = toSqlOp(op);
        if (op == "rangeContains")
            rightSql ~= "::date";
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

    override string likeOp(string operandSql, string pattern, bool caseInsensitive) {
        string op = caseInsensitive ? "ILIKE" : "LIKE";
        return "(" ~ operandSql ~ " " ~ op ~ " '" ~ pattern ~ `' ESCAPE '\')`;
    }

    override string name() { return "PostgreSQL"; }

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
                return "TRUE";
            case JSONType.false_:
                return "FALSE";
            case JSONType.null_:
                return "NULL";
            case JSONType.array:
                auto elements = val.array.map!(v => jsonToSqlLiteral(v)).array;
                return "ARRAY[" ~ elements.join(",") ~ "]";
            case JSONType.object:
                return escapeSqlString(val.toString());
        }
    }

    override string rootIdFilter(string table, string[] pkColumns) {
        if (pkColumns.length == 1) {
            return format("%s.%s = ANY($1)", table, pkColumns[0]);
        }
        // Composite PK: use IN ({{IDS}}) with tuple syntax
        auto cols = pkColumns.map!(c => table ~ "." ~ c).array.join(", ");
        return format("(%s) IN ({{IDS}})", cols);
    }

    override string jsonObjectFunc() { return "json_build_object"; }

    override string rowJsonFunc() { return ""; }

    override string emptyJsonArray() { return "'[]'::json"; }

    override string castToText(string sql) { return sql ~ "::text"; }

    override string aggregateLayerJson(int layerId, string orderByClause) {
        if (orderByClause.length > 0) {
            return format("(SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM (SELECT * FROM layer%d ORDER BY %s) t)",
                layerId, orderByClause);
        }
        return format("(SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM layer%d t)",
            layerId);
    }

    private static string toSqlOp(string op) {
        switch (op) {
            case "~": return "||";   // String concatenation
            case "==": return "=";   // Equality
            case "!=": return "<>";  // Inequality
            case "&&": return "AND"; // Logical and
            case "||": return "OR";  // Logical or
            case "%": return "%";    // Modulo
            case "rangeContains": return "@>";
            case "rangeContainedBy": return "<@";
            case "rangeOverlaps": return "&&";
            case "rangeStrictlyLeft": return "<<";
            case "rangeStrictlyRight": return ">>";
            case "rangeNotExtendsRight": return "&<";
            case "rangeNotExtendsLeft": return "&>";
            case "rangeAdjacent": return "-|-";
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
