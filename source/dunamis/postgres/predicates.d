/// PostgreSQL-native conditions (see `dunamis.relational.native`): filter
/// predicates which queries of PostgreSQL databases test in their WHERE
/// clauses, e.g. range containment, and which are evaluated in memory
/// elsewhere.
module dunamis.postgres.predicates;

import ae.utils.promise : Promise;

import dunamis.core.eval : EvalContext;
import dunamis.core.expr : Expr, ExprBase, evalAs;
import dunamis.core.optimize : OptimizeContext;
import dunamis.postgres.dialect : PostgresDialect;
import dunamis.relational.native : NativePredicateInfo;
import dunamis.relational.sql_dialect : SqlDialect;

/// A condition which PostgreSQL queries test natively, as `render` renders it
/// on the SQL of its operands, and which is evaluated in memory as
/// `inMemory` (see `NativePredicateInfo`).
///
/// The rendering is part of the expression (it holds no other state), so
/// evaluation does not modify it.
final class PostgresConditionExpr : Expr!bool, NativePredicateInfo {
    private ExprBase _inMemory;
    private ExprBase[] _operands;
    private string delegate(const string[]) _render;

    this(Expr!bool inMemory, string delegate(const string[]) render, ExprBase[] operands) {
        assert(inMemory !is null && render !is null, "PostgresConditionExpr: null in-memory form or rendering");
        _inMemory = inMemory;
        _render = render;
        _operands = operands.dup;
    }

    // The operands are for the SQL optimizer's analysis; the in-memory form
    // is what is evaluated (and optimized).
    override ExprBase[] dependencies() {
        return [_inMemory];
    }

    override void replaceDependency(size_t index, ExprBase newDep) {
        if (index == 0)
            _inMemory = newDep;
    }

    override Expr!bool optimize(OptimizeContext ctx) {
        _inMemory = (cast(Expr!bool) _inMemory).optimize(ctx);
        return this;
    }

    override Promise!(bool[]) eval(EvalContext ctx) {
        return evalAs!bool(_inMemory, ctx);
    }

    // NativePredicateInfo implementation
    ExprBase[] nativeOperands() { return _operands; }

    bool hasNativeSql(SqlDialect dialect) {
        return cast(PostgresDialect) dialect !is null;
    }

    string nativeSql(SqlDialect dialect, string[] operandSql) {
        assert(hasNativeSql(dialect), "PostgresConditionExpr: not a PostgreSQL dialect");
        assert(operandSql.length == _operands.length, "PostgresConditionExpr: wrong number of operands");
        return _render(operandSql);
    }
}

/// A condition on `operands` which PostgreSQL queries test as `render`
/// renders it on their SQL (each a column of the rows filtered, or a
/// constant's literal), and which is evaluated in memory as `inMemory`
/// (which must agree with it).
///
/// Example:
/// ---
/// auto isEven = postgresCondition(use((int n) => n % 2 == 0, e.count),
///     (const string[] sql) => "(" ~ sql[0] ~ " % 2 = 0)", e.count);
/// ---
Expr!bool postgresCondition(Expr!bool inMemory, string delegate(const string[]) render, ExprBase[] operands...) {
    return new PostgresConditionExpr(inMemory, render, operands);
}

/// Whether the range `range` (e.g. a column of a PostgreSQL range type)
/// contains the element `element` (a constant), which PostgreSQL queries test
/// as `range @> element::elementType` (`elementType` being the SQL type of
/// the range's elements, e.g. `date`), and which is evaluated in memory as
/// `inMemory`.
Expr!bool rangeContainsElement(R, E)(Expr!R range, Expr!E element, string elementType, Expr!bool inMemory) {
    import std.ascii : isAlphaNum;
    foreach (c; elementType)
        if (!isAlphaNum(c) && c != '_' && c != ' ' && c != '.')
            throw new Exception("rangeContainsElement: invalid SQL type name: " ~ elementType);
    return postgresCondition(inMemory,
        (const string[] sql) => "(" ~ sql[0] ~ " @> " ~ sql[1] ~ "::" ~ elementType ~ ")",
        range, element);
}

// The in-memory form evaluates where the data source has no native form of
// the condition (here, MockDB: not a SQL data source), also in root filters
unittest {
    import std.typecons : Nullable;
    import ae.utils.promise.await : awaitSync;
    import dunamis.core : Executor;
    import dunamis.core.expr : constant, fieldAccess, map, use;
    import dunamis.core.filtering : filterBy;
    import dunamis.relational.demo : DemoEntity, DemoId, MockDB;
    import dunamis.relational.schema : Col, getAll;

    static MockDB!() db;

    @DemoEntity!(db, "spans")
    static struct Span {
        mixin DemoId;
        mixin Col!("low", int);
        mixin Col!("high", int);
    }

    static Expr!bool covers(Expr!Span s, int n) {
        auto point = constant(n, s);
        return rangeContainsElement(s.low, point, "integer", s.low.le(point).and(point.lt(s.high)));
    }

    db = new MockDB!();
    db.setTableData("spans", `[{"id": 1, "low": 0, "high": 5}, {"id": 2, "low": 3, "high": 9}]`);
    foreach (optimize; [false, true]) {
        int[] ids(int n) {
            return awaitSync(new Executor().execute(map!((Expr!Span s) => s.high)(
                filterBy!((Expr!Span s) => covers(s, n))(getAll!Span())), optimize));
        }
        assert(ids(1) == [5] && ids(4) == [5, 9] && ids(7) == [9] && ids(9) == []);
    }
}

// The native form, in PostgreSQL queries only
unittest {
    import dunamis.core.expr : constant, singleton;
    import dunamis.postgres.dialect : postgresDialect;
    import dunamis.relational.native : NativePredicateInfo;
    import dunamis.relational.sql_dialect : SqlDialect;

    auto day = constant("2020-01-01", singleton(0));
    auto contains = cast(NativePredicateInfo) rangeContainsElement(day, day, "date", constant(true, singleton(0)));
    assert(contains.hasNativeSql(postgresDialect()));
    assert(contains.nativeSql(postgresDialect(), ["t.validity", "'2020-01-01'"]) ==
        "(t.validity @> '2020-01-01'::date)");
    assert(!contains.hasNativeSql(null));
    bool threw;
    try rangeContainsElement(day, day, "date; DROP", constant(true, singleton(0)));
    catch (Exception) threw = true;
    assert(threw);
}
