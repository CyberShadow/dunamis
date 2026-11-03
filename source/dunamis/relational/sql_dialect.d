module dunamis.relational.sql_dialect;

import std.json : JSONValue;
import std.typecons : Nullable, nullable;

import dunamis.relational.sql_fragment : Sql, SqlName, SqlValue, sql;

public import dunamis.core.expr.operators : ArrayPredicate;

/// SQL dialect interface for database-specific SQL generation.
/// Each database provides its own implementation in its package.
///
/// Methods fall into two groups:
///   1. Operator push-down (used by SqlOptimizer): binaryOp, unaryOp, etc.
///   2. Query SQL generation (used by relational.sql): escapeSqlString, toSQL vocabulary, etc.
interface SqlDialect {
    /// The SQL of the binary operation `op` (a D operator which has an SQL
    /// operator, see `sqlBinaryOperator`) on `left` and `right`.
    ///
    /// For most operators (arithmetic, comparison), it is the SQL operator.
    /// For string concatenation (~), databases differ:
    ///   - PostgreSQL/SQLite: (left || right)
    ///   - MySQL: CONCAT(left, right)
    Sql binaryOp(string op, Sql left, Sql right);

    /// The SQL of the unary operation `op` (a D operator which has an SQL
    /// operator, see `isSqlUnaryOperator`) on `operand`: "(NOT operand)"
    /// for logical NOT (!), "(-operand)" for negation (-).
    Sql unaryOp(string op, Sql operand);

    /// Generate a CASE WHEN expression for conditional logic.
    /// Returns: (CASE WHEN condition THEN whenTrue ELSE whenFalse END)
    Sql caseWhen(Sql condition, Sql whenTrue, Sql whenFalse);

    /// Generate SQL for IS NULL check.
    /// Returns: (operand IS NULL)
    Sql isNullOp(Sql operand);

    /// Generate SQL for EXISTS subquery.
    /// Returns: EXISTS (subquery)
    Sql existsSubquery(Sql subquery);

    /// Generate SQL for NOT EXISTS subquery.
    /// Returns: NOT EXISTS (subquery)
    Sql notExistsSubquery(Sql subquery);

    /// Generate SQL for LIKE pattern matching of `operand` with `pattern`,
    /// a LIKE pattern using backslash as the escape character (see
    /// escapeLikePattern), which is a value of the SQL.
    /// Case-sensitive matching must be case-sensitive regardless of the
    /// database's default LIKE semantics (SQLite and MySQL's default
    /// collations match case-insensitively).
    /// For case-insensitive matching:
    ///   - PostgreSQL uses ILIKE
    ///   - MySQL/SQLite use LOWER() wrapper
    Sql likeOp(Sql operand, string pattern, bool caseInsensitive);

    /// Generate SQL for a membership test (see `isAmong`): whether the
    /// operand is among `values`, of the type `valueType` (as
    /// ConstantInfo.valueAsString represents them; there is at least one).
    ///   PostgreSQL: operand = ANY('{"v1","v2"}') (one array literal)
    ///   SQLite/MySQL: operand IN (v1, v2) (see `inListSql`)
    Sql membershipOp(Sql operand, TypeInfo valueType, string[] values);

    /// Generate SQL for an array predicate (see `arrayPredicate`) on the
    /// array `operand` and the operand `values` (of the type `valueType`,
    /// as ArrayPredicateInfo.valuesAsStrings represents them), or return
    /// null if the dialect has no arrays (then it is evaluated in memory).
    ///   PostgreSQL: operand @> '{"v1","v2"}', '{...}' && operand,
    ///   'v' = ANY(operand), ...
    Nullable!Sql arrayPredicateOp(Sql operand, ArrayPredicate predicate, TypeInfo valueType,
        Nullable!string[] values);

    /// Get the dialect name for debugging
    string name();

    // =========================================================================
    // Query SQL generation vocabulary
    // =========================================================================

    /// The SQL identifier `name` (a bare name), quoted (see `Ident`).
    ///   PostgreSQL/SQLite: "name" (double quotes doubled)
    ///   MySQL: `name` (backquotes doubled)
    string quoteIdentifier(string name);

    /// The SQL string literal of `s` (see `SqlValue.literal`).
    /// Uses single-quote doubling; MySQL additionally escapes backslashes.
    string escapeSqlString(string s);

    /// The SQL literal of a JSON value (see `SqlValue.literal`).
    /// Handles strings, integers, floats, booleans, nulls, arrays, and objects.
    /// Boolean and array syntax varies by dialect.
    string jsonToSqlLiteral(JSONValue val);

    /// The placeholder of the statement's parameter `number` (from 1), of
    /// the value `value` (see `Sql.render`): of PostgreSQL, `$1`; of SQLite
    /// and MySQL, `?`. (The sessions send the values with their types.)
    string parameter(size_t number, ref const SqlValue value);

    /// SQL expression for filtering the root rows of `table` by their keys
    /// (of the columns `pkColumns`): the values `ids` (of single-column
    /// keys; see `dunamis.relational.keys`).
    ///   PostgreSQL: "users.id = ANY($1)" (single PK: one array)
    ///   SQLite/MySQL: "users.id IN (?,?)" (single PK)
    ///   Composite: "(table.col1, table.col2) IN (ids)" (all dialects)
    Sql rootIdFilter(string table, string[] pkColumns, const(SqlValue)[] ids);

    /// Name of the top-level JSON object constructor function.
    ///   PostgreSQL: "json_build_object"
    ///   SQLite: "json_object"
    ///   MySQL: "JSON_OBJECT"
    Sql jsonObjectFunc();

    /// Name of the per-row JSON object function used inside CTEs,
    /// or empty if the dialect handles row-to-JSON at aggregation time.
    ///   PostgreSQL: "" (uses row_to_json in aggregation)
    ///   SQLite: "json_object"
    ///   MySQL: "JSON_OBJECT"
    Sql rowJsonFunc();

    /// SQL literal for an empty JSON array.
    ///   PostgreSQL: "'[]'::json"
    ///   SQLite: "json('[]')"
    ///   MySQL: "JSON_ARRAY()"
    Sql emptyJsonArray();

    /// Build the complete SQL expression for aggregating all rows of a CTE layer
    /// into a JSON array. Encapsulates aggregation function, ORDER BY strategy
    /// (subquery wrapper vs inline), row expression, and COALESCE wrapping.
    ///
    /// orderByClause is empty if no ordering is needed, otherwise "col1, col2 DESC".
    ///
    ///   PostgreSQL: "(SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM layer0 t)"
    ///   SQLite: "COALESCE((SELECT json_group_array(json(row_json)) FROM layer0), json('[]'))"
    ///   MySQL: "COALESCE((SELECT JSON_ARRAYAGG(row_json) FROM layer0), JSON_ARRAY())"
    Sql aggregateLayerJson(int layerId, Sql orderByClause);

    /// Cast an SQL expression to the dialect's text type, so that columns
    /// read as D strings (e.g. enum, date or numeric-string columns) are
    /// projected as text.
    ///   PostgreSQL: "expr::text"
    ///   SQLite: "CAST(expr AS TEXT)"
    ///   MySQL: "CAST(expr AS CHAR)"
    Sql castToText(Sql expr);

    /// A term of an ORDER BY clause ordering by the SQL expression `expr`,
    /// in descending order if `descending`, with NULL last in ascending
    /// order and first in descending order, as PostgreSQL orders it (and
    /// as `dunamis.core.sorting.compareValues` does).
    ///   PostgreSQL: "expr", "expr DESC"
    ///   SQLite/MySQL: "(expr IS NULL), expr", "(expr IS NULL) DESC, expr DESC"
    Sql orderByTerm(Sql expr, bool descending);
}

/// The name of the CTE of the layer `layerId` of a query (see
/// `SqlDialect.aggregateLayerJson`).
SqlName layerName(int layerId) {
    import std.conv : to;
    return SqlName("layer" ~ layerId.to!string);
}

/// The values `values`, comma-separated (e.g. an IN list).
Sql valueList(const(SqlValue)[] values) {
    Sql[] items;
    foreach (ref value; values)
        items ~= sql(i"$(value)");
    return Sql.join!","(items);
}

/// The column `column` of the table (or alias) `table` (if not empty), as
/// the schema names them (see `SqlName`).
Sql qualifiedColumn(string table, string column) {
    return table.length ? sql(i"$(SqlName(table)).$(SqlName(column))") : sql(i"$(SqlName(column))");
}

/// Whether constants of the type `type` are rendered as bare SQL numbers.
bool isSqlNumericType(TypeInfo type) {
    return type == typeid(int) || type == typeid(long) ||
        type == typeid(float) || type == typeid(double) ||
        type == typeid(uint) || type == typeid(ulong) ||
        type == typeid(short) || type == typeid(ushort);
}

/// The SQL operator of the D binary operator `op`, the same in all
/// dialects (but for `~`, string concatenation, which is `||` in standard
/// SQL), or null if there is none (then the operation is not computed in
/// SQL).
Nullable!Sql sqlBinaryOperator(string op) {
    switch (op) {
        case "~": return nullable(sql(i"||"));
        case "==": return nullable(sql(i"="));
        case "!=": return nullable(sql(i"<>"));
        case "&&": return nullable(sql(i"AND"));
        case "||": return nullable(sql(i"OR"));
        case "<": return nullable(sql(i"<"));
        case "<=": return nullable(sql(i"<="));
        case ">": return nullable(sql(i">"));
        case ">=": return nullable(sql(i">="));
        case "+": return nullable(sql(i"+"));
        case "-": return nullable(sql(i"-"));
        case "*": return nullable(sql(i"*"));
        case "/": return nullable(sql(i"/"));
        case "%": return nullable(sql(i"%"));
        case "&": return nullable(sql(i"&"));
        case "|": return nullable(sql(i"|"));
        case "<<": return nullable(sql(i"<<"));
        case ">>": return nullable(sql(i">>"));
        default: return Nullable!Sql.init;
    }
}

/// Whether the D unary operator `op` has an SQL operator (see
/// `SqlDialect.unaryOp`).
bool isSqlUnaryOperator(string op) {
    return op == "!" || op == "-";
}

/// A membership test (see SqlDialect.membershipOp) as `operand IN (...)`
/// of the values (see `SqlValue.ofConstant`).
Sql inListSql(Sql operand, TypeInfo valueType, string[] values) {
    Sql[] literals;
    foreach (value; values)
        literals ~= sql(i"$(SqlValue.ofConstant(valueType, value))");
    return sql(i"($(operand) IN ($(Sql.join!", "(literals))))");
}

unittest {
    import std.typecons : BlackHole;
    static class TestDialect : BlackHole!SqlDialect {
        override string escapeSqlString(string s) {
            import std.array : replace;
            return "'" ~ s.replace("'", "''") ~ "'";
        }
    }
    auto d = new TestDialect;
    assert(inListSql(sql(i"t.id"), typeid(int), ["1", "2"]).renderInline(d) == "(t.id IN (1, 2))");
    assert(inListSql(sql(i"t.name"), typeid(string), ["a", "it's"]).renderInline(d) == "(t.name IN ('a', 'it''s'))");
    assert(inListSql(sql(i"t.flag"), typeid(bool), ["true"]).renderInline(d) == "(t.flag IN (TRUE))");
    assert(sqlBinaryOperator("==").get.renderInline(d) == "=" && sqlBinaryOperator("^^").isNull);
}
