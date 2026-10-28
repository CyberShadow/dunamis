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
    registerTest("Sessions derived with other settings", "postgres",
        &testDerivedSessionSettings);
}

/// Run `fn` in a fiber of the event loop's thread (where the data source's
/// sessions live), and wait for it; rethrows its failure as a test failure.
private void onEventLoop(void delegate() fn) {
    import core.atomic : atomicLoad, atomicStore;
    import core.thread : Thread;
    import core.time : msecs;
    import integration.test_framework : assertTrue;

    shared bool done;
    __gshared string failure;
    failure = null;
    eventLoopThread.runAsync({
        async(fn).then(() { atomicStore(done, true); }).except((Exception e) {
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

// ============================================================================
// Main
// ============================================================================

void main() {
    auto runner = new PostgresTestRunner();
    runner.run();
}
