module dynamo.relational.sql_dialect;

/// SQL dialect interface for database-specific SQL generation.
/// Each database provides its own implementation in its package.
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
}
