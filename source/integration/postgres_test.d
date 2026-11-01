/**
 * PostgreSQL Integration Test Runner
 *
 * Runs the GraphQL integration test suite against PostgreSQL.
 */
module integration.postgres_test;

import std.algorithm;
import std.array;
import std.conv;
import std.process : environment;
import std.stdio;
import std.string : strip, replace;

import ae.net.sync : ThreadAnchor;
import ae.net.db.psql : PgSqlConnection;
import ae.utils.promise.await : async, await;

import dunamis.core.datasource : SetupMode;
import dunamis.postgres;

import integration.schema;
import integration.test_runner;

// ============================================================================
// Schema Definition
// ============================================================================

/// PostgreSQL data source
__gshared PostgresDB!() db;

/// The event loop's thread (that of the server and of the data source)
private __gshared ThreadAnchor eventLoopThread;

mixin TestSchema!db;

// ============================================================================
// Test Runner
// ============================================================================

class PostgresTestRunner : IntegrationTestRunner!(db, MySchema, User, FilterLastSchema) {
    private PgSqlConnection pgConn;

    override string testName() {
        return "PostgreSQL Integration Tests";
    }

    override void setupDatabase() @async {
        writeln("Creating schema from DDL generator...");

        // Generate DDL at compile time
        enum ddl = generateDDL!(Query);
        debug(sql) writeln(ddl);

        // Execute each statement and wait for completion
        foreach (statement; ddl.splitter(";\n").filter!(s => s.strip.length > 0)) {
            auto sql = statement.strip ~ ";";
            debug(sql) writefln("  Executing: %s", sql.replace("\n", " "));
            pgConn.query(sql).array().await();
        }

        writeln("Schema created.");
        writeln();
    }

    override void cleanup() {
        if (pgConn !is null) {
            pgConn.disconnect("Tests complete");
        }
    }

    void run() {
        printBanner();

        auto host = environment.get("PGHOST", "localhost");
        auto port = environment.get("PGPORT", "5432").to!ushort;
        auto user = environment.get("PGUSER", environment.get("USER", "postgres"));
        auto database = environment.get("PGDATABASE", user);
        auto password = environment.get("PGPASSWORD", "");

        writefln("Connecting to PostgreSQL at %s:%d/%s...", host, port, database);

        auto mainThread = new ThreadAnchor();
        eventLoopThread = mainThread;
        auto testThread = startTestThread(mainThread);

        // Run async setup in a fiber
        async({
            pgConn = connect(host, port, database, user, password).await();
            writeln("Connected.");
            writeln();

            // Each request session gets a connection of its own, so that
            // requests can be evaluated concurrently (as in production).
            db = new PostgresDB!()(() => connect(host, port, database, user, password),
                true, 8);

            setupDatabase();
            onDatabaseReady();
        }).except((Exception e) {
            writefln("Error: %s", e.msg);
            assert(0, e.msg);
        });

        runEventLoop(testThread);
    }
}

// Tests needing concurrent request sessions
static this() {
    import integration.test_framework : registerTest;
    import integration.tests : testInterleavedEvaluationsOfOneTree, testProceduresAndAtomicMutationFields,
        testNestedEvaluationsOfDifferentTrees, testCompositeKeyEntityOfMutation;
    registerTest("Interleaved evaluations of one optimized tree", "postgres",
        &testInterleavedEvaluationsOfOneTree);
    registerTest("Procedures and atomic mutation fields", "postgres",
        &testProceduresAndAtomicMutationFields);
    registerTest("Nested evaluations of different trees", "postgres",
        &testNestedEvaluationsOfDifferentTrees);
    registerTest("Composite-key entity of a mutation field", "postgres",
        &testCompositeKeyEntityOfMutation);
    registerTest("Sessions resolving relation names", "postgres",
        &testSessionRelations);
    registerTest("Sessions derived with other settings", "postgres",
        &testDerivedSessionSettings);
    registerTest("Conditional collections (onlyIf) of root collections", "postgres",
        &testOnlyIfRootCollection);
    registerTest("Naive-path fetches by string keys", "postgres",
        &testNaiveFetchesByStringKeys);
    registerTest("Sorts by nullable and enum columns are pushed into queries", "postgres",
        &testNullableAndEnumSortsPushed);
    import integration.postgres_ordering : testSortsByTextSelectedColumns;
    registerTest("Sorts by columns selected as text, in the database's order", "postgres",
        &testSortsByTextSelectedColumns);
    import integration.postgres_keys : testKeysNeedingQuotes;
    registerTest("Keys needing quotes: rows, parents and children", "postgres",
        &testKeysNeedingQuotes);
    import integration.postgres_batching : testStatementCountsOfComputedFields;
    registerTest("Statement counts of computed fields do not depend on the data", "postgres",
        &testStatementCountsOfComputedFields);
}

/// Run `fn` in a fiber of the event loop's thread (where the data source's
/// sessions live), and wait for it; rethrows its failure as a test failure.
package void onEventLoop(void delegate() fn) {
    import core.atomic : atomicLoad, atomicStore;
    import core.thread : Thread;
    import core.time : msecs;
    import integration.test_framework : assertTrue;

    shared bool done;
    __gshared string failure;
    failure = null;
    eventLoopThread.runAsync({
        // (On a stack as large as procedures': compiling a query takes more
        // than ae's default fiber stack, with large filter input types.)
        import dunamis.core.expr.effects : defaultProcedureStackSize;
        async(fn, defaultProcedureStackSize).then(() { atomicStore(done, true); }).except((Exception e) {
            failure = e.toString();
            atomicStore(done, true);
        });
    });
    while (!atomicLoad(done))
        Thread.sleep(1.msecs);
    assertTrue(failure is null, failure);
}

/// A session derived with other settings (PostgresSession.withSettings),
/// in a scope of the request (EvalContext.createScope): its statements see
/// its settings, the request's (sent at the same time) the request's; it
/// sees the request's uncommitted writes; the request's atomic sections
/// cover its work; a failing statement of it fails its evaluation, and the
/// request's atomic section is undone.
void testDerivedSessionSettings() {
    onEventLoop(() {
        import dunamis.core.datasource : DataSource;
        import dunamis.core.eval : EvalContext;
        import dunamis.core.expr : Expr, evaluateNested, map, singleton, use;
        import integration.test_framework : assertTrue;

        auto ctx = new EvalContext();
        auto session = cast(PostgresSession) ctx.getSession(db);
        session.setSetting("dunamis_test.mode", "request");
        session.setup().await;
        scope (exit) session.teardown(SetupMode.query, false).await;  // (leave no users behind)

        auto derived = session.withSettings(["dunamis_test.mode": "scoped"]);
        auto scope_ = ctx.createScope([cast(DataSource) db: derived]);
        enum modeSql = "SELECT current_setting('dunamis_test.mode')";

        // Statements of both, sent at the same time
        auto a = derived.queryStrings(modeSql);
        auto b = session.queryStrings(modeSql);
        auto c = derived.queryStrings(modeSql);
        auto d = session.queryStrings(modeSql);
        assertTrue(a.await == ["scoped"] && b.await == ["request"] && c.await == ["scoped"] && d.await == ["request"],
            "Statements saw the wrong settings");

        // Nested evaluations, in the scope and next to it in the request
        auto modeLength = (Expr!Query q) => rawInt(db,
            "SELECT length(current_setting('dunamis_test.mode'))::bigint", q);
        auto inScope = evaluateNested(modeLength(Query().singleton()), scope_);
        auto inRequest = evaluateNested(modeLength(Query().singleton()), ctx);
        auto inNestedScope = evaluateNested(modeLength(Query().singleton()), scope_.createScope());
        assertTrue(inScope.await == "scoped".length, "The scope's evaluation saw the request's settings");
        assertTrue(inRequest.await == "request".length, "The request's evaluation saw the scope's settings");
        assertTrue(inNestedScope.await == "scoped".length, "A scope of the scope saw the request's settings");

        // Relational reads in the scope see the request's uncommitted writes
        auto userCount = () => evaluateNested(use((string[] names) => cast(int) names.length,
            map!((Expr!User u) => u.firstName)(Query().singleton().users())), scope_).await;
        auto before = userCount();
        session.execute("INSERT INTO users (first_name, last_name, age) VALUES ('Derived', 'Uncommitted', 1)").await;
        assertTrue(userCount() == before + 1, "The scope did not see the request's write");

        // The request's atomic sections cover the derived session's work
        auto token = session.beginAtomic().await;
        derived.execute("INSERT INTO users (first_name, last_name, age) VALUES ('Derived', 'Undone', 1)").await;
        assertTrue(userCount() == before + 2, "The scope did not see its own write");
        session.endAtomic(token, false).await;
        assertTrue(userCount() == before + 1, "The atomic section did not undo the scope's write");

        // A failing statement fails the evaluation; undoing the section
        // recovers the request, with its settings
        token = session.beginAtomic().await;
        string error;
        try
            evaluateNested(rawInt(db, "SELECT (1 / 0)::bigint", Query().singleton()), scope_).await;
        catch (Exception e)
            error = e.msg;
        assertTrue(error !is null, "The failing statement did not fail its evaluation");
        session.endAtomic(token, false).await;
        assertTrue(session.queryStrings(modeSql).await == ["request"], "The request's settings were not restored");
        assertTrue(derived.queryStrings(modeSql).await == ["scoped"], "The derived session failed after the error");
        assertTrue(userCount() == before + 1, "The request's work before the section was lost");
    });
}

/// A session resolving the names of relations (PostgresSession.withRelations,
/// in a scope of the request): the queries of the optimized path (root and
/// child layers, joins, per-parent windows, and the subqueries of
/// relationship filters) and of the naive path read the relations the names
/// resolve to; the request's session reads the tables.
void testSessionRelations() {
    onEventLoop(() {
        import std.algorithm.sorting : sort;
        import std.json : JSONType, JSONValue;
        import dunamis.core.datasource : DataSource;
        import dunamis.core.eval : EvalContext;
        import dunamis.core.expr : Expr, evaluateNested;
        import dunamis.core.types : AnyRef, queryRoot;
        import dunamis.graphql : compileQuery;
        import integration.test_framework : assertTrue;

        auto ctx = new EvalContext();
        auto session = cast(PostgresSession) ctx.getSession(db);
        // (Setup actions run in the session's transaction, after its setup)
        session.setSetting("dunamis_test.mode", "request");
        string[] setupSaw;
        session.addSetupAction(() => session.queryStrings("SELECT current_setting('dunamis_test.mode')")
            .then((string[] values) { setupSaw = values; }));
        session.setup().await;
        scope (exit) session.teardown(SetupMode.query, false).await;
        assertTrue(setupSaw == ["request"], "The setup action did not run after the setup statements");

        // The relations: the users named Alice, the posts with an even ID
        session.execute("CREATE FUNCTION pg_temp.users_named(p_name text) RETURNS SETOF users " ~
            "LANGUAGE sql STABLE AS $$ SELECT * FROM users WHERE first_name = p_name $$").await;
        session.execute("CREATE FUNCTION pg_temp.even_posts() RETURNS SETOF posts " ~
            "LANGUAGE sql STABLE AS $$ SELECT * FROM posts WHERE id % 2 = 0 $$").await;
        size_t resolved;
        auto scoped = session.withRelations((string name) {
            resolved++;
            return name == "users" ? "pg_temp.users_named('Alice')" : name == "posts" ? "pg_temp.even_posts()" : null;
        });
        assertTrue(scoped.relationSource("users") == "pg_temp.users_named('Alice')" &&
            scoped.relationSource("tasks") == "tasks" && session.relationSource("users") == "users",
            "Wrong relation sources");
        auto scope_ = ctx.createScope([cast(DataSource) db: scoped]);

        long[] ids(string sql) {
            auto values = session.queryLongs(sql).await;
            values.sort();
            return values;
        }
        long[] idsIn(JSONValue v, string[] path) {
            long[] result;
            void walk(JSONValue v, string[] path) {
                if (v.type == JSONType.array)
                    foreach (item; v.array)
                        walk(item, path);
                else if (!path.length) {
                    if (v.type == JSONType.integer)
                        result ~= v.integer;
                    else if (v.type == JSONType.string)
                        result ~= v.str.to!long;
                } else if (v.type == JSONType.object)
                    walk(v[path[0]], path[1 .. $]);
            }
            walk(v, path);
            result.sort();
            return result;
        }
        enum alice = "SELECT id::bigint FROM users WHERE first_name = 'Alice'";
        enum alicePosts = "SELECT p.id::bigint FROM posts p JOIN users u ON u.id = p.author_id " ~
            "WHERE u.first_name = 'Alice' AND p.id % 2 = 0";
        auto expectAlice = ids(alice), expectPosts = ids(alicePosts);
        assertTrue(expectAlice.length && expectPosts.length, "Expected Alice's even posts");
        auto expectTasks = ids("SELECT t.assignee_id::bigint FROM tasks t JOIN users u ON u.id = t.assignee_id " ~
            "WHERE u.first_name = 'Alice'");
        auto expectWithPosts = ids("SELECT DISTINCT p.author_id::bigint FROM (" ~ alicePosts.replace("p.id::bigint", "p.*") ~ ") p");

        foreach (optimized; [true, false]) {
            JSONValue run(string query) {
                auto compiled = compileQuery!MySchema(query);
                if (optimized)
                    return evaluateNested(compiled, scope_).await;
                auto s = scope_.createScope();
                s.setValues!AnyRef(null, [queryRoot]);
                return compiled.eval(s).await[0];
            }
            auto mode = optimized ? "optimized: " : "naive: ";
            // Root rows, children, joined parents
            auto users = run(`{ users { id posts { id } } }`);
            assertTrue(idsIn(users, ["users", "id"]) == expectAlice, mode ~ "root rows: " ~ users.toString());
            assertTrue(idsIn(users, ["users", "posts", "id"]) == expectPosts, mode ~ "children: " ~ users.toString());
            // (The assignees which are not in the relation have no columns)
            auto tasks = run(`{ tasks { assignee { firstName } } }`);
            string[] names;
            foreach (task; tasks["tasks"].array)
                if (task["assignee"].type == JSONType.object && task["assignee"]["firstName"].type == JSONType.string && task["assignee"]["firstName"].str.length)
                    names ~= task["assignee"]["firstName"].str;
            assertTrue(names.length == expectTasks.length && names.all!(n => n == "Alice"),
                mode ~ "joined: " ~ tasks.toString());
            // Per-parent windows (each Alice's first even post)
            auto firsts = run(`{ users { posts(first: 1) { id } } }`);
            auto firstIds = idsIn(firsts, ["users", "posts", "id"]);
            assertTrue(firstIds.length == expectWithPosts.length && firstIds.all!(id => expectPosts.canFind(id)),
                mode ~ "windows: " ~ firsts.toString());
            // Relationship filters (their subqueries)
            auto withPosts = run(`{ users(filter: {posts: {some: {title: {notEqualTo: "-"}}}}) { id } }`);
            assertTrue(idsIn(withPosts, ["users", "id"]) == expectWithPosts, mode ~ "some: " ~ withPosts.toString());
            auto byAuthor = run(`{ posts(filter: {author: {firstName: {equalTo: "Alice"}}}) { id } }`);
            assertTrue(idsIn(byAuthor, ["posts", "id"]) == expectPosts, mode ~ "belongs-to filter: " ~ byAuthor.toString());
        }
        assertTrue(resolved > 0, "The resolver was not called");

        // The request's session reads the tables
        auto all = evaluateNested(compileQuery!MySchema(`{ users { id } }`), ctx).await;
        assertTrue(idsIn(all, ["users", "id"]) == ids("SELECT id::bigint FROM users"), "The request read the relations");
    });
}

/// A filter over a conditional collection (onlyIf) of a root collection is
/// pushed into its SQL query (and applied there); where the condition does
/// not hold, it is empty.
void testOnlyIfRootCollection() {
    onEventLoop(() {
        import dunamis.core.eval : EvalContext;
        import dunamis.core.expr : Expr, constant, evaluateNested, map, onlyIf, singleton;
        import dunamis.core.filtering : filterBy;
        import integration.test_framework : assertTrue;

        auto ctx = new EvalContext();
        auto session = cast(PostgresSession) ctx.getSession(db);
        session.setup().await;
        scope (exit) session.teardown(SetupMode.query, false).await;

        string[] sent;
        session.statementObserver = (const(char)[] sql) { sent ~= sql.idup; };
        scope (exit) session.statementObserver = null;
        foreach (condition; [true, false]) {
            auto q = Query().singleton();
            sent = null;
            auto names = evaluateNested(map!((Expr!User u) => u.firstName)(
                filterBy!((Expr!User u) => u.firstName.eq("Alice"))(onlyIf(constant(condition, q), Query.users(q)))),
                ctx).await;
            assertTrue(condition ? names.length && names.all!(n => n == "Alice") : !names.length, "onlyIf(" ~ condition.to!string ~ "): " ~ names.to!string);
            // (The filter is in the query's WHERE clause)
            if (condition)
                assertTrue(sent.any!(sql => sql.canFind("WHERE") && sql.canFind("Alice")),
                    "The filter over onlyIf was not pushed into the query: " ~ sent.to!string);
        }
    });
}

/// Root sorts by a nullable column and by an enum column (by the positions
/// of its labels, which the database stores as text here) are in the query's
/// ORDER BY clause, rather than done in memory.
void testNullableAndEnumSortsPushed() {
    onEventLoop(() {
        import dunamis.core.eval : EvalContext;
        import dunamis.core.expr : evaluateNested;
        import dunamis.graphql.compiler : compileQuery;
        import integration.test_framework : assertTrue;

        auto ctx = new EvalContext();
        auto session = cast(PostgresSession) ctx.getSession(db);
        session.setup().await;
        scope (exit) session.teardown(SetupMode.query, false).await;

        string[] sent;
        session.statementObserver = (const(char)[] sql) { sent ~= sql.idup; };
        scope (exit) session.statementObserver = null;
        // (One sort each: of several, only the innermost is pushed)
        evaluateNested(compileQuery!MySchema(`{ tasks(orderBy: [{field: status, direction: DESC}]) { id } }`), ctx).await;
        evaluateNested(compileQuery!MySchema(`{ tasks(orderBy: [{field: priority, direction: ASC}]) { id } }`), ctx).await;
        assertTrue(sent.any!(sql => sql.canFind("ORDER BY") && sql.canFind("CASE tasks.status WHEN 'pending' THEN 0") &&
            sql.canFind("WHEN 'done' THEN 2")), "The enum sort was not pushed into the query: " ~ sent.to!string);
        assertTrue(sent.any!(sql => sql.canFind("ORDER BY") && sql.canFind("tasks.priority")),
            "The nullable sort was not pushed into the query: " ~ sent.to!string);
    });
}

/// The naive path's fetches by the refs' keys (of columns, and of children
/// by their foreign key) quote the keys: string keys, also with quotes,
/// select their rows.
void testNaiveFetchesByStringKeys() {
    onEventLoop(() {
        import dunamis.core.eval : EvalContext;
        import dunamis.core.types : AnyRef;
        import integration.test_framework : assertTrue;

        auto ctx = new EvalContext();
        auto session = cast(PostgresSession) ctx.getSession(db);
        session.setup().await;
        scope (exit) session.teardown(SetupMode.query, false).await;

        session.execute("CREATE TEMP TABLE strkey_parents (code text PRIMARY KEY, label text)").await;
        session.execute("CREATE TEMP TABLE strkey_children (id integer PRIMARY KEY, parent_code text)").await;
        session.execute("INSERT INTO strkey_parents VALUES ('a-1', 'first'), ('o''k', 'second'), ('a', 'other')").await;
        session.execute("INSERT INTO strkey_children VALUES (1, 'a-1'), (2, 'o''k'), (3, 'a')").await;
        session.notePkColumns("strkey_parents", ["code"]);

        auto parents = [AnyRef("StrParent:a-1"), AnyRef("StrParent:o'k")];
        auto labels = session.fetchColumnString("strkey_parents", "label", parents).await;
        assertTrue(labels == ["first", "second"], "Columns by string keys: " ~ labels.to!string);
        auto children = session.fetchChildren("strkey_children", "StrChild", "parent_code", parents).await;
        assertTrue(children == [[AnyRef("StrChild:1")], [AnyRef("StrChild:2")]],
            "Children by string keys: " ~ children.to!string);
    });
}

// ============================================================================
// Main
// ============================================================================

void main() {
    auto runner = new PostgresTestRunner();
    runner.run();
}
