module dunamis.postgres.dialect;

import std.algorithm : map;
import std.array : array, join;
import std.conv : to;
import std.format : format;
import std.json : JSONValue, JSONType;
import std.string : replace;

import dunamis.relational.sql_dialect;
import dunamis.relational.sql_fragment : Sql, SqlName, SqlValue, sql;
import std.typecons : Nullable, nullable;

/// PostgreSQL dialect - uses || for string concatenation
class PostgresDialect : SqlDialect {
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
        // One array (whose type PostgreSQL infers from the operand's)
        auto array = SqlValue.array(values.map!(v => SqlValue.ofConstant(valueType, v)).array);
        return sql(i"($(operand) = ANY($(array)))");
    }

    override Sql likeOp(Sql operand, string pattern, bool caseInsensitive) {
        return caseInsensitive
            ? sql(i`($(operand) ILIKE $(pattern) ESCAPE '\')`)
            : sql(i`($(operand) LIKE $(pattern) ESCAPE '\')`);
    }

    override string name() { return "PostgreSQL"; }

    // =========================================================================
    // Query SQL generation vocabulary
    // =========================================================================

    override string quoteIdentifier(string name) {
        return `"` ~ name.replace(`"`, `""`) ~ `"`;
    }

    override string parameter(size_t number, ref const SqlValue value) {
        import std.conv : to;
        // (The parameters' types are those of their values, which the
        // session sends with them, see dunamis.postgres.fetcher)
        return "$" ~ number.to!string;
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

    override Sql rootIdFilter(string table, string[] pkColumns, const(SqlValue)[] ids) {
        // (Of a single-column key, one array of the keys)
        if (pkColumns.length == 1)
            return sql(i"$(qualifiedColumn(table, pkColumns[0])) = ANY($(SqlValue.array(ids)))");
        // Composite PK: tuple syntax
        auto columns = Sql.join!", "(pkColumns.map!(c => qualifiedColumn(table, c)).array);
        return sql(i"($(columns)) IN ($(valueList(ids)))");
    }

    override Sql jsonObjectFunc() { return sql(i"json_build_object"); }

    override Sql rowJsonFunc() { return Sql.init; }

    override Sql emptyJsonArray() { return sql(i"'[]'::json"); }

    override Sql castToText(Sql expr) { return sql(i"$(expr)::text"); }
    override Nullable!Sql arrayPredicateOp(Sql operand, ArrayPredicate predicate, TypeInfo valueType,
            Nullable!string[] values) {
        // (Arrays' and values' types PostgreSQL infers from the operand)
        SqlValue[] elements;
        foreach (v; values)
            elements ~= v.isNull ? SqlValue.init
                : isSqlNumericType(valueType) ? SqlValue.ofConstant(valueType, v.get) : SqlValue.of(v.get);
        auto array = SqlValue.array(elements);
        Sql value() {
            // (NULL, a number, or else a string)
            auto v = values[0];
            auto sqlValue = v.isNull ? SqlValue.init
                : isSqlNumericType(valueType) ? SqlValue.ofConstant(valueType, v.get) : SqlValue.of(v.get);
            return sql(i"$(sqlValue)");
        }
        final switch (predicate) {
            case ArrayPredicate.contains: return nullable(sql(i"($(operand) @> $(array))"));
            case ArrayPredicate.containedBy: return nullable(sql(i"($(operand) <@ $(array))"));
            case ArrayPredicate.overlaps: return nullable(sql(i"($(operand) && $(array))"));
            case ArrayPredicate.anyEqualTo: return nullable(sql(i"($(value()) = ANY($(operand)))"));
            case ArrayPredicate.anyNotEqualTo: return nullable(sql(i"($(value()) <> ANY($(operand)))"));
        }
    }

    override Sql orderByTerm(Sql expr, bool descending) { return descending ? sql(i"$(expr) DESC") : expr; }

    override Sql aggregateLayerJson(int layerId, Sql orderByClause) {
        auto layer = layerName(layerId);
        if (!orderByClause.empty)
            return sql(i"(SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM (SELECT * FROM $(layer) ORDER BY $(orderByClause)) t)");
        return sql(i"(SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM $(layer) t)");
    }
}

// Parameters: placeholders (typed by their values, see dunamis.postgres.fetcher)
unittest {
    auto d = postgresDialect();
    auto bound = sql(i"SELECT $(1), $(5_000_000_000L), $(1.5), $(true), $("x"), $(null)").render(d);
    assert(bound.text == "SELECT $1, $2, $3, $4, $5, $6", bound.text);
    assert(bound.params.length == 6);
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
    string r(Sql fragment) { return fragment.renderInline(dialect); }
    auto a = sql(i"a"), b = sql(i"b");

    // String concatenation uses ||
    assert(r(dialect.binaryOp("~", sql(i"$("a")"), sql(i"$("b")"))) == "('a' || 'b')");

    // Arithmetic operators
    assert(r(dialect.binaryOp("+", sql(i"$(1)"), sql(i"$(2)"))) == "(1 + 2)");
    assert(r(dialect.binaryOp("-", a, b)) == "(a - b)");
    assert(r(dialect.binaryOp("*", a, b)) == "(a * b)");
    assert(r(dialect.binaryOp("/", a, b)) == "(a / b)");

    // Comparison operators
    assert(r(dialect.binaryOp("==", a, b)) == "(a = b)");
    assert(r(dialect.binaryOp("!=", a, b)) == "(a <> b)");
    assert(r(dialect.binaryOp("<", a, b)) == "(a < b)");
    assert(r(dialect.binaryOp(">", a, b)) == "(a > b)");

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

    // Membership: one array literal
    assert(r(dialect.membershipOp(sql(i"t.id"), typeid(int), ["1", "-2"])) == "(t.id = ANY('{1,-2}'))");
    assert(r(dialect.membershipOp(sql(i"t.name"), typeid(string), [`it's`, `a"b`, `c\d`, "x,y"])) ==
           `(t.name = ANY('{"it''s","a\"b","c\\d","x,y"}'))`);

    // LIKE: the pattern is a string literal (backslashes are not escapes
    // of PostgreSQL's string literals)
    assert(r(dialect.likeOp(a, `it's 50\%%`, false)) == `(a LIKE 'it''s 50\%%' ESCAPE '\')`);
    assert(r(dialect.likeOp(a, `x\_%`, true)) == `(a ILIKE 'x\_%' ESCAPE '\')`);
}

// Array predicates: PostgreSQL's array operators, with array literals (and
// values) whose types PostgreSQL infers from the array operand
unittest {
    auto dialect = new PostgresDialect();
    alias N = Nullable!string;
    string r(Nullable!Sql fragment) { return fragment.get.renderInline(dialect); }
    assert(r(dialect.arrayPredicateOp(sql(i"t.ids"), ArrayPredicate.contains, typeid(int), [N("1"), N("2")])) ==
           "(t.ids @> '{1,2}')");
    assert(r(dialect.arrayPredicateOp(sql(i"t.ids"), ArrayPredicate.containedBy, typeid(int), [N("1"), N()])) ==
           "(t.ids <@ '{1,NULL}')");
    assert(r(dialect.arrayPredicateOp(sql(i"t.tags"), ArrayPredicate.overlaps, typeid(string),
           [N(`it's`), N(`a"b`)])) == `(t.tags && '{"it''s","a\"b"}')`);
    assert(r(dialect.arrayPredicateOp(sql(i"t.tags"), ArrayPredicate.anyEqualTo, typeid(string), [N(`it's`)])) ==
           "('it''s' = ANY(t.tags))");
    assert(r(dialect.arrayPredicateOp(sql(i"t.ids"), ArrayPredicate.anyNotEqualTo, typeid(int), [N("3")])) ==
           "(3 <> ANY(t.ids))");
    assert(r(dialect.arrayPredicateOp(sql(i"t.ids"), ArrayPredicate.contains, typeid(int), [])) == "(t.ids @> '{}')");
}
