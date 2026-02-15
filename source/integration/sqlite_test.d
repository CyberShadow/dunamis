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

class SQLiteTestRunner : IntegrationTestRunner!(db, MySchema, User) {
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
// Main
// ============================================================================

void main() {
    auto runner = new SQLiteTestRunner();
    runner.run();
}
