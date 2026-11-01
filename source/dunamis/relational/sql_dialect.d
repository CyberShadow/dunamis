module dunamis.relational.sql_dialect;

import std.json : JSONValue;

/// SQL dialect interface for database-specific SQL generation.
/// Each database provides its own implementation in its package.
///
/// Methods fall into two groups:
///   1. Operator push-down (used by SqlOptimizer): binaryOp, unaryOp, etc.
///   2. Query SQL generation (used by relational.sql): escapeSqlString, toSQL vocabulary, etc.
interface SqlDialect {
    /// Convert a D operator to SQL operator/expression.
    /// Returns the SQL representation for the binary operation.
    ///
    /// For most operators (arithmetic, comparison), this returns the operator itself.
    /// For string concatenation (~), databases differ:
    ///   - PostgreSQL/SQLite: ||
    ///   - MySQL: CONCAT(left, right)
    string binaryOp(string op, string leftSql, string rightSql);

    /// Convert a unary operator to SQL expression.
    /// Returns the SQL representation for the unary operation.
    ///
    /// For logical NOT (!), returns "(NOT operand)".
    /// For arithmetic negation (-), returns "(-operand)".
    string unaryOp(string op, string operandSql);

    /// Generate a CASE WHEN expression for conditional logic.
    /// Returns: CASE WHEN condition THEN trueVal ELSE falseVal END
    string caseWhen(string conditionSql, string trueSql, string falseSql);

    /// Generate SQL for IS NULL check.
    /// Returns: (operand IS NULL)
    string isNullOp(string operandSql);

    /// Generate SQL for EXISTS subquery.
    /// Returns: EXISTS (subquery)
    string existsSubquery(string subquery);

    /// Generate SQL for NOT EXISTS subquery.
    /// Returns: NOT EXISTS (subquery)
    string notExistsSubquery(string subquery);

    /// Generate SQL for LIKE pattern matching.
    /// `pattern` is a LIKE pattern using backslash as the escape character
    /// (see escapeLikePattern), with single quotes already doubled; the
    /// dialect quotes it as a string literal.
    /// Case-sensitive matching must be case-sensitive regardless of the
    /// database's default LIKE semantics (SQLite and MySQL's default
    /// collations match case-insensitively).
    /// For case-insensitive matching:
    ///   - PostgreSQL uses ILIKE
    ///   - MySQL/SQLite use LOWER() wrapper
    string likeOp(string operandSql, string pattern, bool caseInsensitive);

    /// Generate SQL for a membership test (see `isAmong`): whether the
    /// operand is among `values`, of the type `valueType` (as
    /// ConstantInfo.valueAsString represents them; there is at least one).
    ///   PostgreSQL: operand = ANY('{"v1","v2"}') (one array literal)
    ///   SQLite/MySQL: operand IN (v1, v2) (see `inListSql`)
    string membershipOp(string operandSql, TypeInfo valueType, string[] values);

    /// Get the dialect name for debugging
    string name();

    // =========================================================================
    // Query SQL generation vocabulary
    // =========================================================================

    /// Escape a string for use in SQL literals.
    /// Uses single-quote doubling; MySQL additionally escapes backslashes.
    string escapeSqlString(string s);

    /// Convert a JSONValue to a properly quoted SQL literal.
    /// Handles strings, integers, floats, booleans, nulls, arrays, and objects.
    /// Boolean and array syntax varies by dialect.
    string jsonToSqlLiteral(JSONValue val);

    /// SQL expression for filtering root entity IDs.
    ///   PostgreSQL: "users.id = ANY($1)" (single PK)
    ///   SQLite/MySQL: "users.id IN ({{IDS}})" (single PK)
    ///   Composite: "(table.col1, table.col2) IN ({{IDS}})" (all dialects)
    string rootIdFilter(string table, string[] pkColumns);

    /// Name of the top-level JSON object constructor function.
    ///   PostgreSQL: "json_build_object"
    ///   SQLite: "json_object"
    ///   MySQL: "JSON_OBJECT"
    string jsonObjectFunc();

    /// Name of the per-row JSON object function used inside CTEs,
    /// or empty string if the dialect handles row-to-JSON at aggregation time.
    ///   PostgreSQL: "" (uses row_to_json in aggregation)
    ///   SQLite: "json_object"
    ///   MySQL: "JSON_OBJECT"
    string rowJsonFunc();

    /// SQL literal for an empty JSON array.
    ///   PostgreSQL: "'[]'::json"
    ///   SQLite: "json('[]')"
    ///   MySQL: "JSON_ARRAY()"
    string emptyJsonArray();

    /// Build the complete SQL expression for aggregating all rows of a CTE layer
    /// into a JSON array. Encapsulates aggregation function, ORDER BY strategy
    /// (subquery wrapper vs inline), row expression, and COALESCE wrapping.
    ///
    /// orderByClause is empty if no ordering is needed, otherwise "col1, col2 DESC".
    ///
    ///   PostgreSQL: "(SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM layer0 t)"
    ///   SQLite: "COALESCE((SELECT json_group_array(json(row_json)) FROM layer0), json('[]'))"
    ///   MySQL: "COALESCE((SELECT JSON_ARRAYAGG(row_json) FROM layer0), JSON_ARRAY())"
    string aggregateLayerJson(int layerId, string orderByClause);

    /// Cast an SQL expression to the dialect's text type, so that columns
    /// read as D strings (e.g. enum, date or numeric-string columns) are
    /// projected as text.
    ///   PostgreSQL: "expr::text"
    ///   SQLite: "CAST(expr AS TEXT)"
    ///   MySQL: "CAST(expr AS CHAR)"
    string castToText(string sql);

    /// A term of an ORDER BY clause ordering by the SQL expression `sql`,
    /// in descending order if `descending`, with NULL last in ascending
    /// order and first in descending order, as PostgreSQL orders it (and
    /// as `dunamis.core.sorting.compareValues` does).
    ///   PostgreSQL: "expr", "expr DESC"
    ///   SQLite/MySQL: "(expr IS NULL), expr", "(expr IS NULL) DESC, expr DESC"
    string orderByTerm(string sql, bool descending);
}

/// SQL text whose rendering depends on the target dialect. Used for
/// fragments generated during optimization, before the dialect is known.
alias DialectSql = string delegate(SqlDialect dialect);

/// Whether constants of the type `type` are rendered as bare SQL numbers.
bool isSqlNumericType(TypeInfo type) {
    return type == typeid(int) || type == typeid(long) ||
        type == typeid(float) || type == typeid(double) ||
        type == typeid(uint) || type == typeid(ulong) ||
        type == typeid(short) || type == typeid(ushort);
}

/// The SQL literal of a constant of the type `type`, given as
/// ConstantInfo.valueAsString represents it: a quoted string (also for
/// types other than strings, booleans and numbers), TRUE/FALSE, or a number.
string sqlLiteral(TypeInfo type, string value) {
    import std.array : replace;

    if (type == typeid(bool))
        return value == "true" ? "TRUE" : "FALSE";
    if (isSqlNumericType(type))
        return value;
    return "'" ~ value.replace("'", "''") ~ "'";
}

/// A membership test (see SqlDialect.membershipOp) as `operand IN (...)`
/// with the values' literals (see `sqlLiteral`).
string inListSql(string operandSql, TypeInfo valueType, string[] values) {
    import std.algorithm.iteration : map;
    import std.array : join;

    return "(" ~ operandSql ~ " IN (" ~ values.map!(v => sqlLiteral(valueType, v)).join(", ") ~ "))";
}

unittest {
    assert(sqlLiteral(typeid(string), "it's") == "'it''s'");
    assert(sqlLiteral(typeid(bool), "true") == "TRUE");
    assert(sqlLiteral(typeid(long), "-3") == "-3");
    assert(inListSql("t.id", typeid(int), ["1", "2"]) == "(t.id IN (1, 2))");
    assert(inListSql("t.name", typeid(string), ["a"]) == "(t.name IN ('a'))");
}
