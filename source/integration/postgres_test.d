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

import graphqld2.postgres;

import integration.schema;
import integration.test_runner;

// ============================================================================
// Schema Definition
// ============================================================================

/// PostgreSQL data source
__gshared PostgresDB!() db;

mixin TestSchema!db;

// ============================================================================
// Test Runner
// ============================================================================

class PostgresTestRunner : IntegrationTestRunner!(db, MySchema) {
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
        auto testThread = startTestThread(mainThread);

        // Run async setup in a fiber
        async({
            pgConn = connect(host, port, database, user, password).await();
            writeln("Connected.");
            writeln();

            db = new PostgresDB!()(pgConn);

            setupDatabase();
            onDatabaseReady();
        }).except((Exception e) {
            writefln("Error: %s", e.msg);
            mainThread.runAsync({
                if (server !is null) server.close();
                cleanup();
            });
            exitCode = 1;
        });

        runEventLoop(testThread);
    }
}

// ============================================================================
// Main
// ============================================================================

void main() {
    auto runner = new PostgresTestRunner();
    runner.run();
}
