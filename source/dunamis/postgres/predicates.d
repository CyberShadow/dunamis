/// PostgreSQL-native expressions (see `dunamis.relational.native`):
/// expressions which queries of PostgreSQL databases compute natively, e.g.
/// range containment or a range's bounds, wherever the SQL optimizer puts
/// expressions (WHERE, SELECT, ORDER BY clauses, operands of other
/// expressions computed in SQL), and which are evaluated in memory
/// elsewhere.
module dunamis.postgres.predicates;

import ae.utils.promise : Promise;

import dunamis.core.eval : EvalContext;
import dunamis.core.expr : Expr, ExprBase, evalAs;
import dunamis.core.optimize : OptimizeContext;
import dunamis.postgres.dialect : PostgresDialect;
import dunamis.relational.native : NativeSqlInfo;
import dunamis.relational.query_node : QueryNodeId;
import dunamis.relational.sql_dialect : SqlDialect;
import dunamis.relational.sql_fragment : Sql, SqlName, sql;

/// An expression of type `T` which PostgreSQL queries compute natively, as
/// `render` renders it on the SQL of its operands, and which is evaluated in
/// memory as `inMemory` (see `NativeSqlInfo`).
///
/// The rendering is part of the expression (it holds no other state), so
/// evaluation does not modify it. The operands are dependencies of the
/// expression (optimized with it, so that the SQL optimizer sees them as it
/// sees the operands of other expressions), but only the in-memory form is
/// evaluated.
final class PostgresSqlExpr(T) : Expr!T, NativeSqlInfo {
    private ExprBase _inMemory;
    private ExprBase[] _operands;
    private Sql delegate(const Sql[]) _render;

    this(Expr!T inMemory, Sql delegate(const Sql[]) render, ExprBase[] operands) {
        assert(inMemory !is null && render !is null, "PostgresSqlExpr: null in-memory form or rendering");
        _inMemory = inMemory;
        _render = render;
        _operands = operands.dup;
    }

    override ExprBase[] dependencies() {
        return [_inMemory] ~ _operands;
    }

    override void replaceDependency(size_t index, ExprBase newDep) {
        if (index == 0)
            _inMemory = newDep;
        else if (index <= _operands.length)
            _operands[index - 1] = newDep;
    }

    override Expr!T optimize(OptimizeContext ctx) {
        _inMemory = (cast(Expr!T) _inMemory).optimize(ctx);
        foreach (ref operand; _operands)
            operand = operand.optimizeBase(ctx);
        return this;
    }

    override Promise!(T[]) eval(EvalContext ctx) {
        return evalAs!T(_inMemory, ctx);
    }

    // NativeSqlInfo implementation
    ExprBase[] nativeOperands() { return _operands; }

    bool hasNativeSql(SqlDialect dialect) {
        return cast(PostgresDialect) dialect !is null;
    }

    Sql nativeSql(SqlDialect dialect, const(Sql)[] operands) {
        assert(hasNativeSql(dialect), "PostgresSqlExpr: not a PostgreSQL dialect");
        assert(operands.length == _operands.length, "PostgresSqlExpr: wrong number of operands");
        return _render(operands);
    }

    ExprBase projectComputed(QueryNodeId queryNodeId, string alias_, ExprBase input, ExprBase prefetch) {
        import dunamis.relational.project : PrefetchExpr, ProjectedColumn, ProjectionExpr;
        return new ProjectionExpr!T(queryNodeId, ProjectedColumn.computed(alias_), input, cast(PrefetchExpr) prefetch,
            _inMemory);
    }
}

/// A condition (see `PostgresSqlExpr`).
alias PostgresConditionExpr = PostgresSqlExpr!bool;

/// An expression of type `T` on `operands` which PostgreSQL queries compute
/// as `render` renders it on their SQL (each a column of the rows of the
/// query, a constant's literal, or the SQL of another expression computed in
/// SQL), and which is evaluated in memory as `inMemory` (which must agree with
/// it, also on NULL values and their order).
///
/// Example:
/// ---
/// // The end of a `daterange` column (null if the range is null or has no end)
/// auto end = postgresSql(use((Nullable!Period p) => p.isNull ? Nullable!string.init : p.get.end, e.period),
///     (const Sql[] operands) => sql(i"upper($(operands[0]))::text"), e.period);
/// ---
Expr!T postgresSql(T)(Expr!T inMemory, Sql delegate(const Sql[]) render, ExprBase[] operands...) {
    return new PostgresSqlExpr!T(inMemory, render, operands);
}


/// A condition on `operands` which PostgreSQL queries test as `render`
/// renders it (see `postgresSql`), and which is evaluated in memory as
/// `inMemory` (which must agree with it).
///
/// Example:
/// ---
/// auto isEven = postgresCondition(use((int n) => n % 2 == 0, e.count),
///     (const Sql[] operands) => sql(i"($(operands[0]) % 2 = 0)"), e.count);
/// ---
Expr!bool postgresCondition(Expr!bool inMemory, Sql delegate(const Sql[]) render, ExprBase[] operands...) {
    return new PostgresSqlExpr!bool(inMemory, render, operands);
}


/// Whether the range `range` (e.g. a column of a PostgreSQL range type)
/// contains the element `element` (a constant), which PostgreSQL queries test
/// as `range @> element::elementType` (`elementType` being the SQL type of
/// the range's elements, e.g. `date`), and which is evaluated in memory as
/// `inMemory`.
Expr!bool rangeContainsElement(R, E)(Expr!R range, Expr!E element, string elementType, Expr!bool inMemory) {
    checkSqlTypeName(elementType, "rangeContainsElement");
    return postgresCondition(inMemory,
        (const Sql[] operands) => sql(i"($(operands[0]) @> $(operands[1])::$(SqlName(elementType)))"),
        range, element);
}

/// The upper bound of the range `range` (e.g. a column of a PostgreSQL range
/// type), cast to the SQL type `sqlType` (e.g. `text`, for a value read as a
/// string), which PostgreSQL queries compute as `upper(range)::sqlType`
/// (NULL if the range is NULL, empty, or unbounded above), and which is
/// evaluated in memory as `inMemory`.
Expr!T rangeUpperBound(T, R)(Expr!R range, string sqlType, Expr!T inMemory) {
    checkSqlTypeName(sqlType, "rangeUpperBound");
    return postgresSql(inMemory, (const Sql[] operands) => sql(i"upper($(operands[0]))::$(SqlName(sqlType))"), range);
}

/// ditto, of the lower bound (`lower(range)::sqlType`)
Expr!T rangeLowerBound(T, R)(Expr!R range, string sqlType, Expr!T inMemory) {
    checkSqlTypeName(sqlType, "rangeLowerBound");
    return postgresSql(inMemory, (const Sql[] operands) => sql(i"lower($(operands[0]))::$(SqlName(sqlType))"), range);
}

/// Reject SQL type names which are not plain (possibly qualified or
/// multi-word) identifiers, as they are pasted into SQL (as `SqlName`s).
private void checkSqlTypeName(string typeName, string what) {
    import std.ascii : isAlphaNum;
    foreach (c; typeName)
        if (!isAlphaNum(c) && c != '_' && c != ' ' && c != '.')
            throw new Exception(what ~ ": invalid SQL type name: " ~ typeName);
}

version (unittest) {
    import std.typecons : Nullable;
    import dunamis.relational.demo : DemoEntity, DemoId, MockDB;
    import dunamis.relational.schema : Col;

    private MockDB!() spanDb;

    @DemoEntity!(spanDb, "spans")
    private struct Span {
        mixin DemoId;
        mixin Col!("low", int);
        mixin Col!("high", int);
    }

    /// Whether the span [low, high) covers `n` (natively: an int4range's
    /// containment).
    private Expr!bool covers(Expr!Span s, int n) {
        import dunamis.core.expr : constant;
        auto point = constant(n, s);
        return rangeContainsElement(s.low, point, "integer", s.low.le(point).and(point.lt(s.high)));
    }

    /// The span's width (natively: `high - low`).
    private Expr!int width(Expr!Span s) {
        import dunamis.core.expr : use;
        return postgresSql(use((int low, int high) => high - low, s.low, s.high),
            (const Sql[] operands) => sql(i"($(operands[1]) - $(operands[0]))"), s.low, s.high);
    }
}

// The in-memory form evaluates where the data source has no native form of
// the expression (here, MockDB: not a SQL data source): as a filter (also of
// a root collection), as a value, as a sort key, and as an operand of
// other operations
unittest {
    import ae.utils.promise.await : awaitSync;
    import dunamis.core : Executor;
    import dunamis.core.expr : map;
    import dunamis.core.filtering : filterBy;
    import dunamis.core.sorting : sortBy;
    import dunamis.relational.schema : getAll;

    spanDb = new MockDB!();
    spanDb.setTableData("spans", `[{"id": 1, "low": 0, "high": 5}, {"id": 2, "low": 3, "high": 9},
        {"id": 3, "low": 4, "high": 6}]`);
    foreach (optimize; [false, true]) {
        int[] highs(int n) {
            return awaitSync(new Executor().execute(map!((Expr!Span s) => s.high)(
                filterBy!((Expr!Span s) => covers(s, n))(getAll!Span())), optimize));
        }
        assert(highs(1) == [5] && highs(4) == [5, 9, 6] && highs(7) == [9] && highs(9) == []);

        // Values, and operands of other operations
        auto widths = awaitSync(new Executor().execute(map!((Expr!Span s) => width(s))(getAll!Span()), optimize));
        assert(widths == [5, 6, 2]);
        auto doubled = awaitSync(new Executor().execute(
            map!((Expr!Span s) => width(s) * 2)(getAll!Span()), optimize));
        assert(doubled == [10, 12, 4]);
        auto wide = awaitSync(new Executor().execute(map!((Expr!Span s) => s.high)(
            filterBy!((Expr!Span s) => width(s).gt(3))(getAll!Span())), optimize));
        assert(wide == [5, 9]);

        // Sort keys
        auto byWidth = awaitSync(new Executor().execute(map!((Expr!Span s) => s.high)(
            sortBy!((Expr!Span a, Expr!Span b) => width(a).gt(width(b)))(getAll!Span())), optimize));
        assert(byWidth == [9, 5, 6]);
    }
}

// The native form, in PostgreSQL queries only
unittest {
    import dunamis.core.expr : constant, singleton;
    import dunamis.postgres.dialect : postgresDialect;
    import dunamis.relational.native : NativeSqlInfo;

    auto day = constant("2020-01-01", singleton(0));
    auto contains = cast(NativeSqlInfo) rangeContainsElement(day, day, "date", constant(true, singleton(0)));
    assert(contains.hasNativeSql(postgresDialect()));
    assert(contains.nativeSql(postgresDialect(), [sql(i"t.validity"), sql(i"$("2020-01-01")")]).render(postgresDialect()) ==
        "(t.validity @> '2020-01-01'::date)");
    assert(!contains.hasNativeSql(null));
    bool threw;
    try rangeContainsElement(day, day, "date; DROP", constant(true, singleton(0)));
    catch (Exception) threw = true;
    assert(threw);

    auto end = cast(NativeSqlInfo) rangeUpperBound(day, "text", constant(Nullable!string.init, singleton(0)));
    assert(end.nativeSql(postgresDialect(), [sql(i"t.validity")]).render(postgresDialect()) == "upper(t.validity)::text");
    assert(cast(Expr!(Nullable!string)) end !is null);
}
