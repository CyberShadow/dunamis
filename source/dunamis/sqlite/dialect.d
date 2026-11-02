module dunamis.sqlite.dialect;

import std.algorithm : map;
import std.array : array, join;
import std.conv : to;
import std.format : format;
import std.json : JSONValue, JSONType;
import std.string : replace;

import dunamis.relational.sql_dialect;
import dunamis.relational.sql_fragment : Sql, SqlValue, sql;
import std.typecons : Nullable;

/// SQLite dialect - uses || for string concatenation (same as PostgreSQL)
class SQLiteDialect : SqlDialect {
    override Sql binaryOp(string op, Sql left, Sql right) {
        return sql(i"($(left) $(sqlBinaryOperator(op).get) $(right))");
    }

    override Sql unaryOp(string op, Sql operand) {
        assert(isSqlUnaryOperator(op), "No SQL operator of " ~ op);
        return op == "!" ? sql(i"(NOT $(operand))") : sql(i"(-$(operand))");
    }

    override Sql caseWhen(Sql condition, Sql whenTrue, Sql whenFalse) {
        return sql(i"(CASE WHEN $(condition) THEN $(whenTrue) ELSE $(whenFalse) END)");
    }

    override Sql isNullOp(Sql operand) {
        return sql(i"($(operand) IS NULL)");
    }

    override Sql existsSubquery(Sql subquery) {
        return sql(i"EXISTS ($(subquery))");
    }

    override Sql notExistsSubquery(Sql subquery) {
        return sql(i"NOT EXISTS ($(subquery))");
    }

    override Sql membershipOp(Sql operand, TypeInfo valueType, string[] values) {
        return inListSql(operand, valueType, values);
    }

    override Sql likeOp(Sql operand, string pattern, bool caseInsensitive) {
        if (caseInsensitive) {
            // Use LOWER() for consistent case-insensitive behavior
            return sql(i`(LOWER($(operand)) LIKE LOWER($(pattern)) ESCAPE '\')`);
        }
        // SQLite's LIKE is case-insensitive for ASCII; GLOB is case-sensitive.
        return sql(i"($(operand) GLOB $(likeToGlob(pattern)))");
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

    override string quoteIdentifier(string name) {
        return `"` ~ name.replace(`"`, `""`) ~ `"`;
    }

    override string parameter(size_t number, ref const SqlValue value) {
        return "?";
    }

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

    override Sql rootIdFilter(string table, string[] pkColumns, const(SqlValue)[] ids) {
        if (pkColumns.length == 1)
            return sql(i"$(qualifiedColumn(table, pkColumns[0])) IN ($(valueList(ids)))");
        auto columns = Sql.join!", "(pkColumns.map!(c => qualifiedColumn(table, c)).array);
        return sql(i"($(columns)) IN ($(valueList(ids)))");
    }

    override Sql jsonObjectFunc() { return sql(i"json_object"); }

    override Sql rowJsonFunc() { return sql(i"json_object"); }

    override Sql emptyJsonArray() { return sql(i"json('[]')"); }

    override Sql castToText(Sql expr) { return sql(i"CAST($(expr) AS TEXT)"); }
    override Nullable!Sql arrayPredicateOp(Sql operand, ArrayPredicate predicate, TypeInfo valueType,
            Nullable!string[] values) {
        return Nullable!Sql.init;  // (No arrays)
    }
    override Sql orderByTerm(Sql expr, bool descending) {
        // (Ordered by itself, NULL would be the least value)
        return descending ? sql(i"($(expr) IS NULL) DESC, $(expr) DESC") : sql(i"($(expr) IS NULL), $(expr)");
    }

    override Sql aggregateLayerJson(int layerId, Sql orderByClause) {
        auto layer = layerName(layerId);
        if (!orderByClause.empty)
            return sql(i"COALESCE((SELECT json_group_array(json(row_json)) FROM (SELECT * FROM $(layer) ORDER BY $(orderByClause))), $(emptyJsonArray()))");
        return sql(i"COALESCE((SELECT json_group_array(json(row_json)) FROM $(layer)), $(emptyJsonArray()))");
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

    string r(Sql fragment) { return fragment.renderInline(dialect); }
    auto a = sql(i"a"), b = sql(i"b");

    // String concatenation uses ||
    assert(r(dialect.binaryOp("~", sql(i"$("a")"), sql(i"$("b")"))) == "('a' || 'b')");

    // Arithmetic operators
    assert(r(dialect.binaryOp("+", sql(i"$(1)"), sql(i"$(2)"))) == "(1 + 2)");

    // Comparison operators
    assert(r(dialect.binaryOp("==", a, b)) == "(a = b)");
    assert(r(dialect.binaryOp("!=", a, b)) == "(a <> b)");

    // Logical operators
    assert(r(dialect.binaryOp("&&", a, b)) == "(a AND b)");
    assert(r(dialect.binaryOp("||", a, b)) == "(a OR b)");

    // Unary operators
    assert(r(dialect.unaryOp("!", a)) == "(NOT a)");
    assert(r(dialect.unaryOp("-", sql(i"$(5)"))) == "(-5)");

    // Case when
    assert(r(dialect.caseWhen(sql(i"a > 0"), sql(i"$("positive")"), sql(i"$("negative")"))) ==
           "(CASE WHEN a > 0 THEN 'positive' ELSE 'negative' END)");

    // IS NULL
    assert(r(dialect.isNullOp(a)) == "(a IS NULL)");

    // EXISTS / NOT EXISTS
    auto subquery = sql(i"SELECT 1 FROM posts WHERE author_id = users.id");
    assert(r(dialect.existsSubquery(subquery)) == "EXISTS (SELECT 1 FROM posts WHERE author_id = users.id)");
    assert(r(dialect.notExistsSubquery(subquery)) == "NOT EXISTS (SELECT 1 FROM posts WHERE author_id = users.id)");

    // Membership: an IN list
    assert(r(dialect.membershipOp(sql(i"t.name"), typeid(string), [`it's`, `c\d`])) == `(t.name IN ('it''s', 'c\d'))`);

    // LIKE: case-sensitive matching as GLOB
    assert(r(dialect.likeOp(a, `it's 50\%*%`, false)) == `(a GLOB 'it''s 50%[*]*')`);
    assert(r(dialect.likeOp(a, `x\_%`, true)) == `(LOWER(a) LIKE LOWER('x\_%') ESCAPE '\')`);
}
