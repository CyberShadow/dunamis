/**
 * Sorts pushed into PostgreSQL's queries by columns which the queries
 * select as text (numerics read as strings, e.g. decimal custom scalars): the
 * rows come in the order of the column's values, as the database orders them
 * (and as the values' own order has them in memory), not in that of their
 * text.
 */
module integration.postgres_ordering;

import std.conv : to;
import std.json : JSONValue;

import ae.utils.promise.await : await;

import dunamis.core.datasource : SetupMode;
import dunamis.core.eval : EvalContext;
import dunamis.core.executor : Executor;
import dunamis.core.expr : Expr, evaluateNested, fieldAccess, map;
import dunamis.core.sorting : SortDirection, sortByField;
import dunamis.core.types : AnyRef, queryRoot;
import dunamis.postgres : PostgresSession;
import dunamis.relational.sql_fragment : Sql, sql;
import dunamis.relational.schema : Entity, PrimaryKey, Col, Table, getAll;
import dunamis.graphql : Schema, ApplyPlugins, FilterPlugin, SortingPlugin, PaginationPlugin;
import dunamis.graphql.compiler : compileQuery;

import integration.postgres_test : db, onEventLoop;
import integration.test_framework : assertTrue;

/// A decimal number, as its text: a custom scalar ordered by the number.
struct Amount {
    alias DType = string;
    enum name = "Amount";
    static JSONValue toJson(string v) { return JSONValue(v); }
    static string fromJson(JSONValue j) { return j.str; }
    string value;
    alias value this;
    this(string value) { this.value = value; }
    JSONValue toJsonValue() const { return toJson(value); }
    static Amount fromJsonValue(JSONValue json) { return Amount(fromJson(json)); }
    int opCmp(const Amount other) const {
        auto a = value.to!double, b = other.value.to!double;
        return a < b ? -1 : a > b ? 1 : 0;
    }
}

@Entity!(db, "ordered_amounts", "OrderedAmount")
struct OrderedAmount {
    @PrimaryKey int id;
    mixin Col!("amount", Amount);
}

private struct OrderingQuery {
    mixin Table!(OrderedAmount, "orderedAmounts", ["id"]);
}

private alias OrderingSchema = ApplyPlugins!(Schema!OrderingQuery, FilterPlugin, SortingPlugin, PaginationPlugin);

/// The amounts, by their IDs (1 + index)
private immutable string[] amounts = ["9.5", "100", "10", "-2", "-10"];

void testSortsByTextSelectedColumns() {
    onEventLoop(() {
        auto ctx = new EvalContext();
        auto session = cast(PostgresSession) ctx.getSession(db);
        session.setup().await;
        scope (exit) session.teardown(SetupMode.query, false).await;

        session.execute(sql(i"CREATE TEMP TABLE ordered_amounts (id integer PRIMARY KEY, amount numeric)")).await;
        foreach (i, amount; amounts)
            session.execute(sql(i"INSERT INTO ordered_amounts VALUES ($(i + 1), $(amount)::numeric)")).await;

        string[] sent;
        session.statementObserver = (const(char)[] sql) { sent ~= sql.idup; };
        scope (exit) session.statementObserver = null;
        foreach (optimized; [true, false]) {
            auto mode = optimized ? "optimized: " : "naive: ";
            int[] run(Expr!(int[]) expr) {
                if (optimized)
                    return new Executor().execute(expr, ctx).await;
                auto s = ctx.createScope();
                s.setValues!AnyRef(null, [queryRoot]);
                return expr.eval(s).await[0];
            }
            sent = null;
            foreach (direction, expected; ["ASC": [5, 4, 1, 3, 2], "DESC": [2, 3, 1, 4, 5]]) {
                // As SortingPlugin sorts lists (pushed into the root query), and
                // as sortByField does
                auto query = compileQuery!OrderingSchema(`{ orderedAmounts(filter: {id: {greaterThan: 0}}, orderBy: [{field: amount, direction: ` ~
                    direction ~ `}]) { id } }`);
                JSONValue result = optimized ? new Executor().execute(query, ctx).await : {
                    auto s = ctx.createScope();
                    s.setValues!AnyRef(null, [queryRoot]);
                    return query.eval(s).await[0];
                }();
                int[] ids;
                foreach (row; result["orderedAmounts"].array)
                    ids ~= cast(int) row["id"].integer;
                assertTrue(ids == expected, mode ~ direction ~ ": " ~ ids.to!string ~ " " ~ sent.to!string);
            }
        }
    });
}
