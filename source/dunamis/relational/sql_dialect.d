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
    /// For case-insensitive matching:
    ///   - PostgreSQL uses ILIKE
    ///   - MySQL/SQLite use LOWER() wrapper
    string likeOp(string operandSql, string pattern, bool caseInsensitive);

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
    ///   PostgreSQL: "users.id = ANY($1)"
    ///   SQLite/MySQL: "users.id IN ({{IDS}})"
    string rootIdFilter(string table);

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
}
