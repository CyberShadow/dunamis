/**
 * SQLite Integration Test Runner
 *
 * Runs the GraphQL integration test suite against SQLite.
 */
module integration.sqlite_test;

import std.stdio;

import ae.net.sync : ThreadAnchor;
import ae.sys.sqlite3 : SQLite;

import graphqld2.sqlite;

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

class SQLiteTestRunner : IntegrationTestRunner!(db, MySchema) {
    private SQLite sqlite;

    override string testName() {
        return "SQLite Integration Tests";
    }

    override void setupDatabase() {
        writeln("Creating in-memory SQLite database...");
        sqlite = new SQLite(":memory:");
        db = new SQLiteDB!()(sqlite);

        writeln("Creating schema...");
        sqlite.exec("CREATE TABLE users (
            id INTEGER PRIMARY KEY,
            first_name TEXT NOT NULL,
            last_name TEXT NOT NULL
        )");

        sqlite.exec("CREATE TABLE posts (
            id INTEGER PRIMARY KEY,
            title TEXT NOT NULL,
            author_id INTEGER NOT NULL REFERENCES users(id)
        )");

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
