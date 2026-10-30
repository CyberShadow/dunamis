/// Native predicates: conditions which a SQL dialect may test natively (e.g.
/// PostgreSQL's range containment), and which are tested in memory where
/// it cannot (other dialects and data sources, and the naive path).
module dunamis.relational.native;

import dunamis.core.datasource : DataSource;
import dunamis.core.expr.base : ExprBase;
import dunamis.relational.sql_dialect : SqlDialect;

/// Interface for conditions a SQL dialect may test natively (for the SQL
/// optimizer's pattern matching), e.g. one implemented by a database
/// package for its own dialect.
///
/// The condition is on its operands: column reads of the rows filtered (as
/// the operands of comparisons are) or constants. Where the condition is
/// part of a filter predicate pushed into a query's WHERE clause, its
/// operands are rendered as SQL (a column as the qualified column, a
/// constant as its literal, see `sqlLiteral`), and the condition as
/// `nativeSql` renders it for the query's dialect; where the dialect has no
/// native form of it (`hasNativeSql`), or its operands are not columns and
/// constants, the predicate is not pushed, and the expression is evaluated
/// in memory (as its `Expr!bool` evaluation, which must agree with the
/// native form).
interface NativePredicateInfo {
    /// The operands of the condition.
    ExprBase[] nativeOperands();

    /// Whether `dialect` has a native form of the condition.
    bool hasNativeSql(SqlDialect dialect);

    /// The condition in `dialect` (which has a native form of it), on the
    /// SQL of the operands.
    string nativeSql(SqlDialect dialect, string[] operandSql);
}

/// Interface for data sources whose queries are SQL of a dialect (for
/// optimizations depending on what the dialect supports, such as native
/// predicates). Data sources that do not implement it (e.g. in-memory ones)
/// have no native predicates.
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
