module dunamis.postgres.raw;

import std.conv : to;
import std.typecons : Nullable;
import ae.utils.promise : Promise;
import dunamis.core.datasource : DataSource;
import dunamis.core.eval : EvalContext;
import dunamis.core.expr : Expr, ExprBase;
import dunamis.core.optimize : OptimizeContext;
import dunamis.core.types : makeAnyRef;
import dunamis.postgres.fetcher : PostgresSession;
import dunamis.relational.schema : EntityID, makeEntityFromRef;

private abstract class RawPostgresExpr(T) : Expr!T {
    protected DataSource _db;
    protected string _sql;
    this(DataSource db, string sql) { _db = db; _sql = sql; }
    override ExprBase[] dependencies() { return []; }
    override void replaceDependency(size_t, ExprBase) {}
    override DataSource[] dataSources() { return [_db]; }
    override Expr!T optimize(OptimizeContext) { return this; }
}

private class RawIntExpr : RawPostgresExpr!int {
    this(DataSource db, string sql) { super(db, sql); }
    override Promise!(int[]) eval(EvalContext context) {
        auto session = cast(PostgresSession) context.getSession(_db);
        return session.queryLongs(_sql).then((long[] values) =>
            values.length ? [values[0].to!int] : [0]);
    }
}

private class RawNullableIntExpr : RawPostgresExpr!(Nullable!int) {
    this(DataSource db, string sql) { super(db, sql); }
    override Promise!(Nullable!int[]) eval(EvalContext context) {
        auto session = cast(PostgresSession) context.getSession(_db);
        return session.queryLongs(_sql).then((long[] values) =>
            values.length ? [Nullable!int(values[0].to!int)] : [Nullable!int.init]);
    }
}

private class RawEntityExpr(Entity) : RawPostgresExpr!Entity {
    this(DataSource db, string sql) { super(db, sql); }
    override Promise!(Entity[]) eval(EvalContext context) {
        auto session = cast(PostgresSession) context.getSession(_db);
        return session.queryLongs(_sql).then((long[] values) {
            if (!values.length) return [Entity.init];
            return [makeEntityFromRef!Entity(
                makeAnyRef(EntityID!Entity.typeName, values[0].to!string))];
        });
    }
}

private class RawNullableEntityExpr(Entity) : RawPostgresExpr!(Nullable!Entity) {
    this(DataSource db, string sql) { super(db, sql); }
    override Promise!(Nullable!Entity[]) eval(EvalContext context) {
        auto session = cast(PostgresSession) context.getSession(_db);
        return session.queryLongs(_sql).then((long[] values) {
            if (!values.length) return [Nullable!Entity.init];
            auto entity = makeEntityFromRef!Entity(
                makeAnyRef(EntityID!Entity.typeName, values[0].to!string));
            return [Nullable!Entity(entity)];
        });
    }
}

Expr!int rawInt(DataSource db, string sql) { return new RawIntExpr(db, sql); }
Expr!(Nullable!int) rawNullableInt(DataSource db, string sql) {
    return new RawNullableIntExpr(db, sql);
}
Expr!Entity rawEntity(Entity)(DataSource db, string sql) {
    return new RawEntityExpr!Entity(db, sql);
}
Expr!(Nullable!Entity) rawNullableEntity(Entity)(DataSource db, string sql) {
    return new RawNullableEntityExpr!Entity(db, sql);
}
