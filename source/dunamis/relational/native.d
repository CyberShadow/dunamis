/// Native SQL expressions: expressions which a SQL dialect may compute
/// natively (e.g. PostgreSQL's range containment, or the upper bound of a
/// range), and which are computed in memory where it cannot (other dialects
/// and data sources, and the naive path).
module dunamis.relational.native;

import dunamis.core.datasource : DataSource;
import dunamis.core.expr : ExprBase;
import dunamis.relational.query_node : QueryNodeId;
import dunamis.relational.sql_dialect : SqlDialect;

/// Interface for expressions a SQL dialect may compute natively (for the SQL
/// optimizer's pattern matching), e.g. ones implemented by a database
/// package for its own dialect. The expression's result type (its
/// `resultType`) may be any type its data source's query results decode.
///
/// The expression is a function of its operands: column reads of the rows
/// of a query, constants, or expressions which can be computed in SQL
/// themselves (e.g. other native expressions, or comparisons). Where the
/// dialect of the query has a native form of the expression (`hasNativeSql`)
/// and all its operands can be rendered as SQL (a column as the column, a
/// constant as its literal, see `sqlLiteral`), the expression is rendered as
/// `nativeSql` renders it on the operands' SQL, wherever the SQL optimizer
/// puts expressions:
/// - (of a `bool` expression) in a query's WHERE clause, as (part of) a
///   filter predicate pushed into it;
/// - in its SELECT clause, as a computed column read instead of evaluating
///   the expression;
/// - in its ORDER BY clause, as the key of a sort pushed into it (a
///   comparison of the expression on the two items compared);
/// - as an operand of other expressions computed in SQL (e.g. comparisons,
///   arithmetic or boolean operations) in any of the above.
/// Elsewhere, the expression is evaluated in memory (as its `Expr!T`
/// evaluation), which must agree with the native form (including how it
/// treats and orders NULL values).
interface NativeSqlInfo {
    /// The operands of the expression.
    ExprBase[] nativeOperands();

    /// Whether `dialect` has a native form of the expression.
    bool hasNativeSql(SqlDialect dialect);

    /// The expression in `dialect` (which has a native form of it), on the
    /// SQL of the operands.
    string nativeSql(SqlDialect dialect, string[] operandSql);

    /// An expression of the expression's result type reading its values
    /// from the computed column `alias_` of the query node `queryNodeId`
    /// (a `dunamis.relational.project.ProjectionExpr` of the arguments
    /// given, with the expression as its in-memory form), which the SQL optimizer replaces the expression
    /// with where it puts it into the node's SELECT clause.
    ExprBase projectComputed(QueryNodeId queryNodeId, string alias_, ExprBase input, ExprBase prefetch);
}

/// Interface for data sources whose queries are SQL of a dialect (for
/// optimizations depending on what the dialect supports, such as native
/// SQL expressions). Data sources that do not implement it (e.g. in-memory
/// ones) have no native SQL expressions.
interface SqlDataSource {
    /// The dialect of the data source's queries.
    @property SqlDialect sqlDialect();
}

/// The dialect of the queries of `ds`, or null if it is not a SQL data
/// source.
SqlDialect sqlDialectOf(DataSource ds) {
    if (auto sql = cast(SqlDataSource) ds)
        return sql.sqlDialect;
    return null;
}
