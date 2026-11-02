/**
 * SQLite Integration Test Runner
 *
 * Runs the GraphQL integration test suite against SQLite.
 */
module integration.sqlite_test;

import std.algorithm;
import std.array;
import std.stdio;
import std.string : strip;

import ae.net.sync : ThreadAnchor;
import ae.sys.sqlite3 : SQLite;

import std.conv : to;

import dunamis.core.expr : Expr, use;
import dunamis.relational.schema : Entity, PrimaryKey, Col;
import dunamis.sqlite;

import integration.schema;
import integration.test_runner;

// ============================================================================
// Schema Definition
// ============================================================================

/// SQLite data source
__gshared SQLiteDB!() db;

mixin TestSchema!db;

// ============================================================================
// Test Runner
// ============================================================================

class SQLiteTestRunner : IntegrationTestRunner!(db, MySchema, User, FilterLastSchema) {
    private SQLite sqlite;

    override string testName() {
        return "SQLite Integration Tests";
    }

    override void setupDatabase() {
        writeln("Creating in-memory SQLite database...");
        sqlite = new SQLite(":memory:");
        db = new SQLiteDB!()(sqlite);

        writeln("Creating schema from DDL generator...");

        // Generate DDL at compile time
        enum ddl = generateDDL!(Query);
        debug(sql) writeln(ddl);

        // Execute each statement
        foreach (statement; ddl.splitter(";\n").filter!(s => s.strip.length > 0)) {
            auto sql = statement.strip ~ ";";
            debug(sql) writefln("  Executing: %s", sql);
            sqlite.exec(sql);
        }

        writeln("Schema created.");
        writeln();
    }

    override void cleanup() {
        // SQLite in-memory DB is automatically cleaned up
    }

    void run() {
        printBanner();

        auto mainThread = new ThreadAnchor();
        auto testThread = startTestThread(mainThread);

        // SQLite setup is synchronous
        setupDatabase();
        onDatabaseReady();

        runEventLoop(testThread);
    }
}

// ============================================================================
// Native SQL expressions of another dialect
// ============================================================================

/// A data source of its own (an in-memory database of its own), for
/// expressions evaluated directly rather than through the server.
__gshared SQLiteDB!() spanDb;

@Entity!(spanDb, "spans", "Span")
struct Span {
    @PrimaryKey int id;
    mixin Col!("low", int);
    mixin Col!("high", int);
}

/// The width of a span: natively `high - low` in PostgreSQL only.
Expr!int spanWidth(Expr!Span s) {
    import dunamis.postgres.predicates : postgresSql;
    import dunamis.relational.sql_fragment : Sql, sql;
    return postgresSql(use((int low, int high) => high - low, s.low, s.high),
        (const Sql[] operands) => sql(i"($(operands[1]) - $(operands[0]))"), s.low, s.high);
}

/// Expressions computed natively in PostgreSQL's queries only (see
/// `NativeSqlInfo`) are evaluated in memory in SQLite's, in each position
/// the SQL optimizer puts them in PostgreSQL's: values, operands of other
/// operations, filters, sort keys.
void testNativeSqlExpressionsInMemory() {
    import ae.utils.promise.await : awaitSync;
    import dunamis.core : Executor;
    import dunamis.core.expr : map;
    import dunamis.core.filtering : filterBy;
    import dunamis.core.sorting : sortBy;
    import dunamis.relational.schema : getAll;
    import integration.test_framework : assertTrue;

    auto sqlite = new SQLite(":memory:");
    sqlite.exec("CREATE TABLE spans (id INTEGER PRIMARY KEY, low INTEGER NOT NULL, high INTEGER NOT NULL)");
    sqlite.exec("INSERT INTO spans VALUES (1, 0, 5), (2, 3, 9), (3, 4, 6)");
    spanDb = new SQLiteDB!()(sqlite);
    scope (exit) spanDb = null;

    R[] run(R)(Expr!(R[]) query) {
        return awaitSync(new Executor().execute(query));
    }
    auto widths = run(map!((Expr!Span s) => spanWidth(s))(getAll!Span()));
    assertTrue(widths == [5, 6, 2], "Native SQL value in memory: " ~ widths.to!string);
    auto doubled = run(map!((Expr!Span s) => spanWidth(s) * 2)(getAll!Span()));
    assertTrue(doubled == [10, 12, 4], "Native SQL operand in memory: " ~ doubled.to!string);
    auto wide = run(map!((Expr!Span s) => s.high)(filterBy!((Expr!Span s) => spanWidth(s).gt(3))(getAll!Span())));
    assertTrue(wide == [5, 9], "Native SQL filter in memory: " ~ wide.to!string);
    auto sorted = run(map!((Expr!Span s) => s.high)(
        sortBy!((Expr!Span a, Expr!Span b) => spanWidth(a).gt(spanWidth(b)))(getAll!Span())));
    assertTrue(sorted == [9, 5, 6], "Native SQL sort key in memory: " ~ sorted.to!string);
}

static this() {
    import integration.test_framework : registerTest;
    registerTest("Native SQL expressions of another dialect, in memory", "sqlite",
        &testNativeSqlExpressionsInMemory);
}

// ============================================================================
// Main
// ============================================================================

void main() {
    auto runner = new SQLiteTestRunner();
    runner.run();
}
