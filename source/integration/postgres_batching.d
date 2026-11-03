/**
 * Database round trips of computed fields, on PostgreSQL.
 *
 * Dunamis evaluates a field once for all the objects of a batch, so the
 * number of statements an evaluation sends depends on its expression (its
 * fields), not on the number of rows it reads. These tests count the
 * statements of evaluations of typical computed-field shapes over data of
 * two sizes, and require the same number for both.
 */
module integration.postgres_batching;

import std.algorithm : sum;
import std.conv : to;
import std.format : format;
import std.json : JSONValue;
import std.typecons : Nullable;

import ae.utils.promise.await : await;

import dunamis.core.datasource : DataSource, SetupMode;
import dunamis.core.eval : EvalContext;
import dunamis.core.expr : Expr, ExprBase, evaluateNested, fieldAccess, map, some, use, useAsync;
import dunamis.core.filtering : filterBy;
import dunamis.core.sorting : SortDirection, sortBy, sortByField;
import dunamis.graphql.schema : Schema;
import dunamis.postgres : PostgresSession;
import dunamis.relational.sql_fragment : Sql, sql;
import dunamis.relational.schema : Entity, PrimaryKey, Col, ForeignKeyCol, BelongsTo, HasMany, Table, getAll,
    getByIds, entityById;
import dunamis.relational.schema.attrs : DecodedBy;
import dunamis.schema.filtering : FilteredBy, FilterPlugin;
import dunamis.schema.plugin : ApplyPlugins;

import integration.postgres_test : db, onEventLoop;
import integration.test_framework : assertTrue;

// ============================================================================
// Schema
// ============================================================================

@Entity!(db, "batching_owners", "BatchingOwner")
struct BatchingOwner {
    @PrimaryKey int id;
    mixin Col!("name", string);
    mixin HasMany!("parents", BatchingParent, "owner_id");
}

@Entity!(db, "batching_parents", "BatchingParent")
struct BatchingParent {
    @PrimaryKey int id;
    mixin Col!("name", string);
    mixin ForeignKeyCol!("ownerId", BatchingOwner, int, "owner_id");
    mixin BelongsTo!("owner", "ownerId");
    mixin HasMany!("children", BatchingChild, "parent_id");
}

@Entity!(db, "batching_children", "BatchingChild")
struct BatchingChild {
    @PrimaryKey int id;
    mixin Col!("flag", bool);
    mixin Col!("amount", int);
    mixin ForeignKeyCol!("parentId", BatchingParent, int, "parent_id");
    mixin BelongsTo!("parent", "parentId");
    mixin ForeignKeyCol!("ownerId", BatchingOwner, Nullable!int, "owner_id");
    mixin BelongsTo!("owner", "ownerId");
    mixin HasMany!("items", BatchingItem, "child_id");
}

@Entity!(db, "batching_items", "BatchingItem")
struct BatchingItem {
    @PrimaryKey int id;
    mixin Col!("flag", bool);
    mixin ForeignKeyCol!("childId", BatchingChild, int, "child_id");
    mixin BelongsTo!("child", "childId");
}

/// A value of the PostgreSQL range type `daterange`, as row_to_json renders
/// it (its canonical text form, `[start,end)`; an empty endpoint unbounded),
/// filtered by containment of a day: natively in PostgreSQL's queries.
@FilteredBy!BatchingPeriodFilter
@DecodedBy!decodeBatchingPeriod
struct BatchingPeriod { Nullable!string start; Nullable!string end; }

BatchingPeriod decodeBatchingPeriod(JSONValue value) {
    import std.algorithm.searching : countUntil;
    BatchingPeriod result;
    auto text = value.str;
    auto comma = text.countUntil(',');
    if (comma >= 0 && text.length >= 2) {
        auto start = text[1 .. cast(size_t) comma], end = text[cast(size_t) comma + 1 .. $ - 1];
        if (start.length) result.start = start;
        if (end.length) result.end = end;
    }
    return result;
}

bool batchingPeriodContains(Nullable!string start, Nullable!string end, string day) {
    return (start.isNull || start.get <= day) && (end.isNull || day < end.get);
}

struct BatchingPeriodFilter {
    Nullable!string containsElement;
    Nullable!bool isNull;

    Expr!bool condition(V)(Expr!V period, ExprBase lengthSource) const {
        import dunamis.core.expr : constant;
        import dunamis.postgres.predicates : rangeContainsElement;
        if (containsElement.isNull)
            return null;
        auto day = constant(containsElement.get, lengthSource);
        return rangeContainsElement(period, day, "date",
            use(&batchingPeriodContains, V.start(period), V.end(period), day));
    }
}

@Entity!(db, "batching_terms", "BatchingTerm")
struct BatchingTerm {
    @PrimaryKey int id;
    mixin Col!("validity", Nullable!BatchingPeriod);
}

/// The number of days of a period (0 if it is null or unbounded).
int batchingPeriodDays(Nullable!BatchingPeriod period) {
    import std.datetime.date : Date;
    if (period.isNull || period.get.start.isNull || period.get.end.isNull)
        return 0;
    return cast(int) (Date.fromISOExtString(period.get.end.get) - Date.fromISOExtString(period.get.start.get)).total!"days";
}

/// The end of a period (null if it is null or unbounded above).
Nullable!string batchingPeriodEnd(Nullable!BatchingPeriod period) {
    return period.isNull ? Nullable!string.init : period.get.end;
}

/// The number of days of a term's validity (0 if it has none), computed
/// natively in PostgreSQL's queries (see `dunamis.postgres.predicates`).
Expr!int termDays(Expr!BatchingTerm t) {
    import dunamis.postgres.predicates : postgresSql;
    import dunamis.relational.sql_fragment : Sql, sql;
    return postgresSql(use(&batchingPeriodDays, t.validity),
        (const Sql[] operands) => sql(i"COALESCE(upper($(operands[0])) - lower($(operands[0])), 0)"), t.validity);
}

/// The end of a term's validity (null if it has none), natively
/// `upper(validity)::text`.
Expr!(Nullable!string) termEnd(Expr!BatchingTerm t) {
    import dunamis.postgres.predicates : rangeUpperBound;
    return rangeUpperBound(t.validity, "text", use(&batchingPeriodEnd, t.validity));
}

struct BatchingTermQuery {
    mixin Table!(BatchingTerm, "terms");
}

alias BatchingTermSchema = ApplyPlugins!(Schema!BatchingTermQuery, FilterPlugin);

alias Parent = BatchingParent;
alias Child = BatchingChild;
alias Item = BatchingItem;
alias Owner = BatchingOwner;

// The data: `n` parents, each with `k` children, each with `k` items. Parent
// p (1-based) belongs to owner p % 2 + 1; child (p, j) has the id (p-1)*k+j,
// is flagged for even j, has the amount id*10, and belongs to the parent's
// owner except for j = 1; item (c, m) has the id (c-1)*k+m and is flagged for
// odd m. Term t (1 <= t <= n) is valid from 2020-01-01 for t days; term
// n + 1 has no validity.
private Sql[] dataStatements(int n, int k) {
    auto childRow = sql(i"(p - 1) * $(k) + j, j % 2 = 0, ((p - 1) * $(k) + j) * 10, p, CASE WHEN j = 1 THEN NULL ELSE p % 2 + 1 END");
    return [
        sql(i"CREATE TABLE batching_owners (id int PRIMARY KEY, name text NOT NULL)"),
        sql(i"CREATE TABLE batching_parents (id int PRIMARY KEY, name text NOT NULL, owner_id int NOT NULL)"),
        sql(i"CREATE TABLE batching_children (id int PRIMARY KEY, flag boolean NOT NULL, amount int NOT NULL, parent_id int NOT NULL, owner_id int)"),
        sql(i"CREATE TABLE batching_items (id int PRIMARY KEY, flag boolean NOT NULL, child_id int NOT NULL)"),
        sql(i"CREATE TABLE batching_terms (id int PRIMARY KEY, validity daterange)"),
        sql(i"INSERT INTO batching_owners SELECT g, 'o' || g FROM generate_series(1, 2) g"),
        sql(i"INSERT INTO batching_parents SELECT g, 'p' || g, g % 2 + 1 FROM generate_series(1, $(n)) g"),
        sql(i"INSERT INTO batching_children SELECT $(childRow) FROM generate_series(1, $(n)) p, generate_series(1, $(k)) j"),
        sql(i"INSERT INTO batching_items SELECT (c - 1) * $(k) + m, m % 2 = 1, c FROM generate_series(1, $(n * k)) c, generate_series(1, $(k)) m"),
        sql(i"INSERT INTO batching_terms SELECT g, daterange('2020-01-01', DATE '2020-01-01' + g) FROM generate_series(1, $(n)) g UNION ALL SELECT $(n) + 1, NULL"),
    ];
}

// ============================================================================
// Computed fields of the shapes measured
// ============================================================================

/// map + filterBy on child columns + use, over a HasMany
Expr!int flaggedAmountSum(Expr!Parent p) {
    return use((int[] amounts) => amounts.sum,
        map!((Expr!Child c) => c.amount)(filterBy!((Expr!Child c) => c.flag)(p.children)));
}

/// A filtered HasMany mapped without reading a column (as selectFirst does)
Expr!(Nullable!int) firstFlaggedChild(Expr!Parent p) {
    return use((int[] ids) => ids.length ? Nullable!int(ids[0]) : Nullable!int.init,
        map!((Expr!Child c) => fieldAccess!"id"(c))(filterBy!((Expr!Child c) => c.flag)(p.children)));
}

/// A filtered HasMany passed to `use` as entities
Expr!int flaggedChildCount(Expr!Parent p) {
    return use((Child[] children) => cast(int) children.length, filterBy!((Expr!Child c) => c.flag)(p.children));
}

/// A computed field of the children, calling another computed field of theirs
Expr!int flaggedItemCount(Expr!Child c) {
    return use((int[] ids) => cast(int) ids.length,
        map!((Expr!Item i) => fieldAccess!"id"(i))(filterBy!((Expr!Item i) => i.flag)(c.items)));
}

/// ditto
Expr!int childScore(Expr!Child c) {
    return use((int amount, int flaggedItems) => amount + flaggedItems, c.amount, flaggedItemCount(c));
}

/// ditto
Expr!(int[]) childScores(Expr!Parent p) {
    return map!childScore(p.children);
}

/// A map over a HasMany reached through a BelongsTo
Expr!(string[]) siblingNames(Expr!Parent p) {
    return map!((Expr!Parent q) => q.name)(p.owner.parents);
}

/// ditto, of each child (HasMany → BelongsTo → HasMany)
Expr!(int[][]) cousinAmounts(Expr!Parent p) {
    return map!((Expr!Child c) => map!((Expr!Child d) => d.amount)(c.parent.children))(p.children);
}

/// Columns of entities reached through BelongsTo from the children
Expr!(string[]) childOwnerOfParentNames(Expr!Parent p) {
    return map!((Expr!Child c) => c.parent.owner.name)(p.children);
}

/// A nullable BelongsTo of the children, passed to `use`
Expr!(int[]) childOwnerIds(Expr!Parent p) {
    return map!((Expr!Child c) => use((Nullable!Owner o) => o.isNull ? 0 : o.get.id, c.owner))(p.children);
}

/// A column of entities built by `use` from the children's values
Expr!(string[]) ownerNamesOfUseEntities(Expr!Parent p) {
    return map!((Expr!Child c) => use((int id) => Owner(id), c.parent.ownerId).name)(p.children);
}

/// A column of entities built by `entityById` from the children's values
Expr!(string[]) ownerNamesOfEntitiesById(Expr!Parent p) {
    return map!((Expr!Child c) => entityById!Owner(c.parent.ownerId).name)(p.children);
}

/// A filter on a column of the children's parent (a BelongsTo in the predicate)
Expr!(int[]) childrenOfOwnerOne(Expr!Parent p) {
    return map!((Expr!Child c) => fieldAccess!"id"(c))(
        filterBy!((Expr!Child c) => c.parent.ownerId.eq(1).and(c.flag))(p.children));
}

/// A filter whose predicate tests the children's own HasMany (some)
Expr!(int[]) childrenWithFlaggedItems(Expr!Parent p) {
    return map!((Expr!Child c) => c.amount)(
        filterBy!((Expr!Child c) => some!((Expr!Item i) => i.flag)(c.items))(p.children));
}

/// A HasMany sorted in memory by a column (as SortingPlugin's orderBy does)
Expr!(int[]) childAmountsDescending(Expr!Parent p) {
    return map!((Expr!Child c) => c.amount)(sortByField!("amount", SortDirection.DESC)(p.children));
}

/// ditto, sorted by a comparison of a computed field
Expr!(int[]) childIdsByScore(Expr!Parent p) {
    return map!((Expr!Child c) => fieldAccess!"id"(c))(
        sortBy!((Expr!Child a, Expr!Child b) => childScore(a).gt(childScore(b)))(p.children));
}

/// The input of `useAsync`, a filtered HasMany's column
Expr!int asyncFlaggedAmountSum(Expr!Parent p) {
    return useAsync!sumsOf([cast(DataSource) db],
        map!((Expr!Child c) => c.amount)(filterBy!((Expr!Child c) => c.flag)(p.children)));
}

private int[] sumsOf(EvalContext ctx, int[][] amounts) {
    int[] result;
    foreach (a; amounts)
        result ~= a.sum;
    return result;
}

/// A batch function evaluating a nested expression for all its items
Expr!(string) asyncOwnerName(Expr!Parent p) {
    return useAsync!ownerNamesOf([cast(DataSource) db], p.ownerId);
}

private string[] ownerNamesOf(EvalContext ctx, int[] ownerIds) {
    auto names = evaluateNested(map!((Expr!Owner o) => o.name)(getByIds!Owner(ownerIds)), ctx).await;
    return names;
}

// ============================================================================
// Test
// ============================================================================

/// Reference results, computed from the data's definition.
private struct Data {
    int n, k;

    int[] childIds(int p) {
        int[] ids;
        foreach (j; 1 .. k + 1)
            ids ~= (p - 1) * k + j;
        return ids;
    }
    bool flagged(int c) { return ((c - 1) % k + 1) % 2 == 0; }
    int flaggedItems(int c) { return (k + 1) / 2; }
    int score(int c) { return c * 10 + flaggedItems(c); }
}

/// Evaluate `root` over the parents, counting the statements it sends.
private R[] measure(R)(Expr!R delegate(Expr!Parent) field, PostgresSession session, EvalContext ctx,
        out string[] statements) {
    string[] sent;
    session.statementObserver = (const(char)[] sql) { sent ~= sql.idup; };
    scope (exit) session.statementObserver = null;
    auto result = evaluateNested(map!((Expr!Parent p) => field(p))(getAll!Parent()), ctx).await;
    statements = sent;
    return result;
}

private struct Shape {
    string name;
    size_t delegate(PostgresSession, EvalContext, Data, out string[]) run;
}

/// A shape evaluating `field` over every parent: checks the result, and
/// returns the number of statements sent.
private Shape shape(R)(string name, Expr!R function(Expr!Parent) field, R delegate(Data, int) expected) {
    return Shape(name, (PostgresSession session, EvalContext ctx, Data data, out string[] statements) {
        auto result = measure!R((Expr!Parent p) => field(p), session, ctx, statements);
        assertTrue(result.length == data.n, name ~ ": " ~ result.length.to!string ~ " results");
        foreach (i, r; result)
            assertTrue(r == expected(data, cast(int) i + 1),
                format("%s: parent %d: %s, expected %s", name, i + 1, r, expected(data, cast(int) i + 1)));
        return statements.length;
    });
}

/// A root collection filtered (and windowed) by a predicate reading a
/// column, mapped to what reads no column of the rows: the predicate's
/// column makes the rows a query of their own, into which the filter and the
/// window are pushed, and from which the root collection reads its rows.
private void checkRootFilterWithoutColumns(PostgresSession session, EvalContext ctx, Data data) {
    import dunamis.core.pagination : limit;
    string[] sent;
    session.statementObserver = (const(char)[] sql) { sent ~= sql.idup; };
    scope (exit) session.statementObserver = null;
    auto ids = evaluateNested(map!((Expr!Parent p) => fieldAccess!"id"(p))(
        limit(filterBy!((Expr!Parent p) => p.name.ne("p1"))(getAll!Parent()), 2)), ctx).await;
    int[] expected;
    foreach (id; 2 .. data.n + 1)
        if (expected.length < 2)
            expected ~= id;
    assertTrue(ids == expected, "Root filter without columns: " ~ ids.to!string);
    assertTrue(sent.length == 1, "Root filter without columns: " ~ sent.length.to!string ~ " statements: " ~
        sent.to!string);
}

/// A root collection filtered by membership tests (`isAmong`) of a column and
/// of the primary key column: one statement, in whose WHERE clause they are
/// (as `= ANY(...)`), rather than a read of the whole table filtered in D.
private void checkRootMembershipFilter(PostgresSession session, EvalContext ctx, Data data) {
    import std.algorithm.searching : canFind;
    import dunamis.core.expr : isAmong;
    import dunamis.relational.schema : column;

    string[] sent;
    session.statementObserver = (const(char)[] sql) { sent ~= sql.idup; };
    scope (exit) session.statementObserver = null;
    auto ids = evaluateNested(map!((Expr!Parent p) => fieldAccess!"id"(p))(
        filterBy!((Expr!Parent p) => isAmong(p.name, ["p1", "p3", "p99"]).and(
            isAmong(column!int(p, "id"), [3, 1, 2]).and(isAmong(p.name, ["p2"]).not())))(getAll!Parent())), ctx).await;
    int[] expected;
    foreach (id; [1, 3])
        if (id <= data.n)
            expected ~= id;
    assertTrue(ids == expected, "Root membership filter: " ~ ids.to!string);
    assertTrue(sent.length == 1, "Root membership filter: " ~ sent.length.to!string ~ " statements: " ~
        sent.to!string);
    // (The values are the statement's parameters: one array each)
    assertTrue(sent[0].canFind(`.name = ANY($`) && sent[0].canFind(`.id = ANY($`) &&
        sent[0].canFind(`NOT (batching_parents.name = ANY($`),
        "Root membership filter not in the WHERE clause: " ~ sent[0]);
}

/// A root collection filtered by a condition PostgreSQL tests natively (a
/// range containment, see `dunamis.postgres.predicates`), declared by a
/// value type's filter (`@FilteredBy`): one statement, in whose WHERE clause
/// it is (as `@>`), rather than a read of the whole table filtered in D.
private void checkRootNativePredicateFilter(PostgresSession session, EvalContext ctx, Data data) {
    import std.algorithm.searching : canFind;
    import dunamis.graphql.compiler : compileQuery;

    string[] sent;
    session.statementObserver = (const(char)[] sql) { sent ~= sql.idup; };
    scope (exit) session.statementObserver = null;
    auto result = evaluateNested(compileQuery!BatchingTermSchema(
        `{ terms(filter: {validity: {containsElement: "2020-01-03"}}) { id validity { end } } }`), ctx).await;
    int[] ids;
    string[] ends;
    foreach (term; result["terms"].array) {
        ids ~= cast(int) term["id"].integer;
        ends ~= term["validity"]["end"].str;
    }
    int[] expected;
    string[] expectedEnds;
    foreach (t; 3 .. data.n + 1) {
        expected ~= t;
        expectedEnds ~= format("2020-01-%02d", 1 + t);
    }
    assertTrue(ids == expected && ends == expectedEnds, "Root native predicate filter: " ~ result.toString());
    assertTrue(sent.length == 1, "Root native predicate filter: " ~ sent.length.to!string ~ " statements: " ~
        sent.to!string);
    assertTrue(sent[0].canFind(`batching_terms.validity @> $`) && sent[0].canFind(`::date`),
        "Root native predicate filter not in the WHERE clause: " ~ sent[0]);
}

/// Several maps over the same relationship, reading different columns (and
/// relationships of its rows): one layer selects its rows (and one each
/// those of the relationships of its rows), reading all the columns,
/// rather than one layer per map.
private void checkSameRowLayers(PostgresSession session, EvalContext ctx, Data data) {
    import std.algorithm.searching : count;

    string[] sent;
    session.statementObserver = (const(char)[] sql) { sent ~= sql.idup; };
    scope (exit) session.statementObserver = null;
    auto result = evaluateNested(map!((Expr!Parent p) => use(
        (int[] amounts, bool[] flags, bool[][] itemFlags, int[][] itemIds) =>
            format("%s %s %s %s", amounts, flags, itemFlags, itemIds),
        map!((Expr!Child c) => c.amount)(p.children),
        map!((Expr!Child c) => c.flag)(p.children),
        map!((Expr!Child c) => map!((Expr!Item i) => i.flag)(c.items))(p.children),
        map!((Expr!Child c) => map!((Expr!Item i) => fieldAccess!"id"(i))(c.items))(p.children)))(
        getAll!Parent()), ctx).await;
    foreach (p; 1 .. data.n + 1) {
        int[] amounts;
        bool[] flags;
        bool[][] itemFlags;
        int[][] itemIds;
        foreach (c; data.childIds(p)) {
            amounts ~= c * 10;
            flags ~= data.flagged(c);
            bool[] f;
            int[] ids;
            foreach (m; 1 .. data.k + 1) {
                f ~= m % 2 == 1;
                ids ~= (c - 1) * data.k + m;
            }
            itemFlags ~= f;
            itemIds ~= ids;
        }
        auto expected = format("%s %s %s %s", amounts, flags, itemFlags, itemIds);
        assertTrue(result[p - 1] == expected, format("Same-row layers: parent %d: %s, expected %s",
            p, result[p - 1], expected));
    }
    assertTrue(sent.length == 1, "Same-row layers: " ~ sent.length.to!string ~ " statements: " ~ sent.to!string);
    assertTrue(sent[0].count("FROM batching_children") == 1 && sent[0].count("FROM batching_items") == 1,
        "Same-row layers: one layer each expected: " ~ sent[0]);
}

/// Expressions PostgreSQL computes natively (see `NativeSqlInfo`), in each
/// position the SQL optimizer puts expressions: one statement each, in
/// whose SELECT, WHERE or ORDER BY clause they are, rather than in-memory
/// evaluations.
private void checkNativeSqlExpressions(PostgresSession session, EvalContext ctx, Data data) {
    import std.algorithm.searching : canFind, findSplitAfter;
    import std.algorithm.iteration : smap = map, sfilter = filter;
    import std.range : iota, retro;
    import std.array : array;

    string[] sent;
    session.statementObserver = (const(char)[] sql) { sent ~= sql.idup; };
    scope (exit) session.statementObserver = null;
    void expectOne(string what, string sql) {
        assertTrue(sent.length == 1, what ~ ": " ~ sent.length.to!string ~ " statements: " ~ sent.to!string);
        assertTrue(sent[0].canFind(sql), what ~ ": not in the query: " ~ sql ~ ": " ~ sent[0]);
        sent = null;
    }

    // In the SELECT clause: a value (of a custom type), ...
    auto ends = evaluateNested(map!((Expr!BatchingTerm t) => termEnd(t))(getAll!BatchingTerm()), ctx).await;
    Nullable!string[] expectedEnds;
    foreach (t; 1 .. data.n + 1)
        expectedEnds ~= Nullable!string(format("2020-01-%02d", 1 + t));
    expectedEnds ~= Nullable!string.init;
    assertTrue(ends == expectedEnds, "Native SQL value: " ~ ends.to!string);
    expectOne("Native SQL value", "upper(batching_terms.validity)::text AS computed_");

    // ... and an operand of another operation computed in SQL
    auto doubled = evaluateNested(map!((Expr!BatchingTerm t) => termDays(t) * 2)(getAll!BatchingTerm()), ctx).await;
    assertTrue(doubled == iota(1, data.n + 1).smap!(t => 2 * t).array ~ 0, "Native SQL operand: " ~ doubled.to!string);
    expectOne("Native SQL operand",
        "(COALESCE(upper(batching_terms.validity) - lower(batching_terms.validity), 0) * $1) AS computed_");

    // In the WHERE clause: operands of comparisons (and of conjunctions)
    auto ids = evaluateNested(map!((Expr!BatchingTerm t) => fieldAccess!"id"(t))(
        filterBy!((Expr!BatchingTerm t) => termDays(t).gt(2).and(termDays(t).lt(6)))(getAll!BatchingTerm())), ctx).await;
    assertTrue(ids == iota(3, 6).sfilter!(t => t <= data.n).array, "Native SQL in a filter: " ~ ids.to!string);
    assertTrue(sent.length == 1 && sent[0].findSplitAfter("WHERE ")[1].canFind(
        "(COALESCE(upper(batching_terms.validity) - lower(batching_terms.validity), 0) > $1)"),
        "Native SQL not in the WHERE clause: " ~ sent.to!string);
    sent = null;

    // In the ORDER BY clause: a sort comparing it on the items
    auto sorted = evaluateNested(map!((Expr!BatchingTerm t) => fieldAccess!"id"(t))(
        sortBy!((Expr!BatchingTerm a, Expr!BatchingTerm b) => termDays(a).gt(termDays(b)))(getAll!BatchingTerm())),
        ctx).await;
    assertTrue(sorted == iota(1, data.n + 1).retro.array ~ (data.n + 1), "Native SQL sort key: " ~ sorted.to!string);
    expectOne("Native SQL sort key",
        "ORDER BY COALESCE(upper(batching_terms.validity) - lower(batching_terms.validity), 0) DESC");
}

/// A root collection filtered by its primary key (a plain field of the
/// entity, see `PlainFieldInfo`): one statement, in whose WHERE clause the
/// condition is, rather than a read of the whole table filtered in D.
private void checkRootPrimaryKeyFilter(PostgresSession session, EvalContext ctx, Data data) {
    import std.algorithm.searching : canFind, findSplitAfter;
    import std.json : JSONType;
    import std.typecons : tuple;
    import dunamis.graphql.compiler : compileQuery;

    // (Term n + 1 has no validity)
    foreach (q; [
        tuple(`{ terms(filter: {id: {equalTo: 2}}) { validity { end } } }`, (int t) => t == 2),
        tuple(`{ terms(filter: {id: {in: [4, 1, 99]}}) { id validity { end } } }`, (int t) => t == 1 || t == 4),
        tuple(`{ terms(filter: {not: {id: {lessThan: 2}}}) { validity { end } } }`, (int t) => t >= 2),
    ]) {
        auto query = q[0];
        string[] sent;
        session.statementObserver = (const(char)[] sql) { sent ~= sql.idup; };
        scope (exit) session.statementObserver = null;
        auto result = evaluateNested(compileQuery!BatchingTermSchema(query), ctx).await;
        string[] ends, expectedEnds;
        assertTrue(result.type == JSONType.object && "terms" in result,
            "Root primary key filter: " ~ query ~ ": " ~ result.toString());
        foreach (term; result["terms"].array)
            ends ~= term["validity"].type == JSONType.null_ ? "-" : term["validity"]["end"].str;
        foreach (t; 1 .. data.n + 2)
            if (q[1](t))
                expectedEnds ~= t > data.n ? "-" : format("2020-01-%02d", 1 + t);
        assertTrue(ends == expectedEnds, "Root primary key filter: " ~ query ~ ": " ~ result.toString());
        assertTrue(sent.length == 1, "Root primary key filter: " ~ query ~ ": " ~ sent.length.to!string ~
            " statements: " ~ sent.to!string);
        assertTrue(sent[0].findSplitAfter("WHERE ")[1].canFind("batching_terms.id"),
            "Root primary key filter not in the WHERE clause: " ~ query ~ ": " ~ sent[0]);
    }
}

/// A query of more layers than SQL functions take arguments for (see
/// `dunamis.relational.sql.layerGroupSize`) reads all of them.
private void checkManyLayers(PostgresSession session, Data data) {
    import dunamis.relational.query_node : FilterType, QueryNode, QueryNodeId;

    enum tree = uint.max;  // (not one of an optimization's)
    auto root = new QueryNode(QueryNodeId(0, tree), "BatchingParent", "batching_parents", ["id"]);
    root.setRootFilter(FilterType.all);
    root.dataSource = db;
    QueryNode[] children;
    foreach (i; 1 .. 120) {
        auto child = new QueryNode(QueryNodeId(i, tree), "BatchingChild", "batching_children", ["id"]);
        child.setParent(root, "parent_id", "BatchingParent");
        child.addColumn("amount");
        child.dataSource = db;
        children ~= child;
    }
    auto parents = session.executeQueryNode(root, null, root.rootSelection).await;
    assertTrue(parents.allRefs.length == data.n, "Many layers: parents " ~ parents.allRefs.length.to!string);
    foreach (child; children) {
        auto layer = session.executeQueryNode(child, parents, root.rootSelection).await;
        assertTrue(layer.allRefs.length == data.n * data.k,
            "Many layers: layer " ~ child.id.value.to!string ~ " has " ~ layer.allRefs.length.to!string ~ " rows");
    }
}

void testStatementCountsOfComputedFields() {
    onEventLoop(() {
        Shape[] shapes = [
            shape!int("map + filterBy + use over a HasMany", &flaggedAmountSum, (Data d, int p) {
                int s;
                foreach (c; d.childIds(p)) if (d.flagged(c)) s += c * 10;
                return s;
            }),
            shape!(Nullable!int)("filtered HasMany mapped to ids", &firstFlaggedChild, (Data d, int p) {
                foreach (c; d.childIds(p)) if (d.flagged(c)) return Nullable!int(c);
                return Nullable!int.init;
            }),
            shape!int("filtered HasMany passed to use", &flaggedChildCount, (Data d, int p) => d.k / 2),
            shape!(int[])("computed field of children calling another", &childScores, (Data d, int p) {
                int[] r;
                foreach (c; d.childIds(p)) r ~= d.score(c);
                return r;
            }),
            shape!(string[])("map over HasMany under BelongsTo", &siblingNames, (Data d, int p) {
                string[] r;
                foreach (q; 1 .. d.n + 1) if (q % 2 == p % 2) r ~= "p" ~ q.to!string;
                return r;
            }),
            shape!(int[][])("map over HasMany under BelongsTo of children", &cousinAmounts, (Data d, int p) {
                int[] amounts;
                foreach (c; d.childIds(p)) amounts ~= c * 10;
                int[][] r;
                foreach (_; 0 .. d.k) r ~= amounts;
                return r;
            }),
            shape!(string[])("column two BelongsTo hops from children", &childOwnerOfParentNames, (Data d, int p) {
                string[] r;
                foreach (_; 0 .. d.k) r ~= "o" ~ (p % 2 + 1).to!string;
                return r;
            }),
            shape!(int[])("nullable BelongsTo of children passed to use", &childOwnerIds, (Data d, int p) {
                int[] r;
                foreach (j; 1 .. d.k + 1) r ~= j == 1 ? 0 : p % 2 + 1;
                return r;
            }),
            shape!(string[])("column of entities built by use", &ownerNamesOfUseEntities, (Data d, int p) {
                string[] r;
                foreach (_; 0 .. d.k) r ~= "o" ~ (p % 2 + 1).to!string;
                return r;
            }),
            shape!(string[])("column of entities built by entityById", &ownerNamesOfEntitiesById, (Data d, int p) {
                string[] r;
                foreach (_; 0 .. d.k) r ~= "o" ~ (p % 2 + 1).to!string;
                return r;
            }),
            shape!(int[])("filter on a BelongsTo column", &childrenOfOwnerOne, (Data d, int p) {
                int[] r;
                if (p % 2 + 1 == 1) foreach (c; d.childIds(p)) if (d.flagged(c)) r ~= c;
                return r;
            }),
            shape!(int[])("filter testing a HasMany (some)", &childrenWithFlaggedItems, (Data d, int p) {
                int[] r;
                foreach (c; d.childIds(p)) r ~= c * 10;
                return r;
            }),
            shape!(int[])("HasMany sorted by a column", &childAmountsDescending, (Data d, int p) {
                int[] r;
                foreach_reverse (c; d.childIds(p)) r ~= c * 10;
                return r;
            }),
            shape!(int[])("HasMany sorted by a computed field", &childIdsByScore, (Data d, int p) {
                int[] r;
                foreach_reverse (c; d.childIds(p)) r ~= c;
                return r;
            }),
            shape!int("useAsync of a filtered HasMany's column", &asyncFlaggedAmountSum, (Data d, int p) {
                int s;
                foreach (c; d.childIds(p)) if (d.flagged(c)) s += c * 10;
                return s;
            }),
            shape!string("useAsync evaluating a nested expression", &asyncOwnerName,
                (Data d, int p) => "o" ~ (p % 2 + 1).to!string),
        ];

        auto sizes = [Data(2, 2), Data(7, 4)];
        size_t[][] counts = new size_t[][](shapes.length, sizes.length);
        string[][] statementsOfLargest = new string[][](shapes.length);
        // Run `fn` in a request (a session of its own: sessions keep the
        // layers they fetched), committing its work if `commit`.
        void inRequest(void delegate(PostgresSession, EvalContext) fn, bool commit = false) {
            auto ctx = new EvalContext();
            auto session = cast(PostgresSession) ctx.getSession(db);
            session.setup().await;
            bool ok;
            scope (exit) session.teardown(SetupMode.query, commit && ok).await;
            fn(session, ctx);
            ok = true;
        }
        void dropTables(PostgresSession session, EvalContext) {
            session.execute(sql(i"DROP TABLE IF EXISTS batching_owners, batching_parents, batching_children, batching_items, batching_terms")).await;
        }

        foreach (si, data; sizes) {
            inRequest((PostgresSession session, EvalContext) {
                dropTables(session, null);
                foreach (statement; dataStatements(data.n, data.k))
                    session.execute(statement).await;
            }, true);
            scope (exit) inRequest(&dropTables, true);
            foreach (i, s; shapes)
                inRequest((PostgresSession session, EvalContext ctx) {
                    string[] statements;
                    counts[i][si] = s.run(session, ctx, data, statements);
                    if (si + 1 == sizes.length)
                        statementsOfLargest[i] = statements;
                });
            inRequest((PostgresSession session, EvalContext) => checkManyLayers(session, data));
            inRequest((PostgresSession session, EvalContext ctx) => checkRootFilterWithoutColumns(session, ctx, data));
            inRequest((PostgresSession session, EvalContext ctx) => checkRootMembershipFilter(session, ctx, data));
            inRequest((PostgresSession session, EvalContext ctx) => checkRootNativePredicateFilter(session, ctx, data));
            inRequest((PostgresSession session, EvalContext ctx) => checkRootPrimaryKeyFilter(session, ctx, data));
            inRequest((PostgresSession session, EvalContext ctx) => checkNativeSqlExpressions(session, ctx, data));
            inRequest((PostgresSession session, EvalContext ctx) => checkSameRowLayers(session, ctx, data));
        }

        string report;
        bool ok = true;
        foreach (i, s; shapes) {
            bool same = counts[i][0] == counts[i][1];
            ok = ok && same;
            report ~= format("  %-50s %s statements%s\n", s.name, counts[i].to!string, same ? "" : "  <-- depends on the data");
            if (!same)
                foreach (sql; statementsOfLargest[i][0 .. $ < 6 ? $ : 6])
                    report ~= "      " ~ (sql.length > 200 ? sql[0 .. 200] ~ "..." : sql) ~ "\n";
        }
        import std.stdio : write;
        write(report);
        assertTrue(ok, "Statement counts depend on the number of rows:\n" ~ report);
    });
}
