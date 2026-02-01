module graphqld2.relational.sql_dialect;

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

    /// Get the dialect name for debugging
    string name();
}
