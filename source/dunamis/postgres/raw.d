module dunamis.postgres.raw;

import std.conv : to;
import std.typecons : Nullable;
import ae.utils.promise : Promise, resolve;
import dunamis.core.datasource : DataSource;
import dunamis.core.eval : EvalContext;
import dunamis.core.expr : Expr, ExprBase;
import dunamis.core.optimize : OptimizeContext;
import dunamis.core.types : makeAnyRef;
import dunamis.postgres.fetcher : PostgresSession;
import dunamis.relational.schema : EntityID, makeEntityFromRef;

/// A value computed by an SQL query (yielding at most one row), the same for
/// every element of the batch of `lengthSource` (e.g. the Query object).
private abstract class RawPostgresExpr(T) : Expr!T {
    protected DataSource _db;
    protected string _sql;
    protected ExprBase _lengthSource;
    this(DataSource db, string sql, ExprBase lengthSource) {
        assert(lengthSource !is null, "Raw SQL expressions require a length source");
        _db = db; _sql = sql; _lengthSource = lengthSource;
    }
    override ExprBase[] dependencies() { return [_lengthSource]; }
    override void replaceDependency(size_t index, ExprBase newDep) {
        if (index == 0) _lengthSource = newDep;
    }
    override DataSource[] dataSources() { return [_db]; }
    override Expr!T optimize(OptimizeContext) { return this; }

    /// The query's value, from its first column's values
    protected abstract T value(long[] values);

    override Promise!(T[]) eval(EvalContext context) {
        import std.array : array;
        import std.range : repeat;
        auto session = cast(PostgresSession) context.getSession(_db);
        return _lengthSource.evalResultLength(context).then((size_t count) {
            if (count == 0) return resolve(cast(T[]) null);
            return session.queryLongs(_sql).then((long[] values) => value(values).repeat(count).array);
        });
    }
}

private class RawIntExpr : RawPostgresExpr!int {
    this(DataSource db, string sql, ExprBase lengthSource) { super(db, sql, lengthSource); }
    override int value(long[] values) {
        return values.length ? values[0].to!int : 0;
    }
}

private class RawNullableIntExpr : RawPostgresExpr!(Nullable!int) {
    this(DataSource db, string sql, ExprBase lengthSource) { super(db, sql, lengthSource); }
    override Nullable!int value(long[] values) {
        return values.length ? Nullable!int(values[0].to!int) : Nullable!int.init;
    }
}

private class RawEntityExpr(Entity) : RawPostgresExpr!Entity {
    this(DataSource db, string sql, ExprBase lengthSource) { super(db, sql, lengthSource); }
    override Entity value(long[] values) {
        if (!values.length) return Entity.init;
        return makeEntityFromRef!Entity(
            makeAnyRef(EntityID!Entity.typeName, values[0].to!string));
    }
}

private class RawNullableEntityExpr(Entity) : RawPostgresExpr!(Nullable!Entity) {
    this(DataSource db, string sql, ExprBase lengthSource) { super(db, sql, lengthSource); }
    override Nullable!Entity value(long[] values) {
        if (!values.length) return Nullable!Entity.init;
        return Nullable!Entity(makeEntityFromRef!Entity(
            makeAnyRef(EntityID!Entity.typeName, values[0].to!string)));
    }
}

/// The value of `sql` (a query yielding at most one row of one integer
/// column) for each element of `lengthSource`'s batch.
Expr!int rawInt(DataSource db, string sql, ExprBase lengthSource) {
    return new RawIntExpr(db, sql, lengthSource);
}
/// ditto
Expr!(Nullable!int) rawNullableInt(DataSource db, string sql, ExprBase lengthSource) {
    return new RawNullableIntExpr(db, sql, lengthSource);
}
/// ditto, the integer being the id of an Entity
Expr!Entity rawEntity(Entity)(DataSource db, string sql, ExprBase lengthSource) {
    return new RawEntityExpr!Entity(db, sql, lengthSource);
}
/// ditto
Expr!(Nullable!Entity) rawNullableEntity(Entity)(DataSource db, string sql, ExprBase lengthSource) {
    return new RawNullableEntityExpr!Entity(db, sql, lengthSource);
}
