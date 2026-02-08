/**
 * MySQL Integration Test Runner
 *
 * Runs the GraphQL integration test suite against MySQL.
 */
module integration.mysql_test;

import std.algorithm;
import std.array;
import std.conv;
import std.process : environment;
import std.stdio;
import std.string : strip, replace;

import ae.net.sync : ThreadAnchor;
import ae.net.db.mysql : MySqlConnection;
import ae.utils.promise.await : async, await;

import dunamis.mysql;

import integration.schema;
import integration.test_runner;

// ============================================================================
// Schema Definition
// ============================================================================

/// MySQL data source
__gshared MySQLDB!() db;

mixin TestSchema!db;

// ============================================================================
// Test Runner
// ============================================================================

class MySQLTestRunner : IntegrationTestRunner!(db, MySchema) {
    private MySqlConnection mysqlConn;

    override string testName() {
        return "MySQL Integration Tests";
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
            mysqlConn.query(sql).array().await();
        }

        writeln("Schema created.");
        writeln();
    }

    override void cleanup() {
        if (mysqlConn !is null) {
            mysqlConn.disconnect("Tests complete");
        }
    }

    void run() {
        printBanner();

        auto host = environment.get("MYSQL_HOST", "localhost");
        auto port = environment.get("MYSQL_TCP_PORT", "3306").to!ushort;
        auto user = environment.get("MYSQL_USER", environment.get("USER", "root"));
        auto database = environment.get("MYSQL_DATABASE", user);
        auto password = environment.get("MYSQL_PWD", "");

        writefln("Connecting to MySQL at %s:%d/%s...", host, port, database);

        auto mainThread = new ThreadAnchor();
        auto testThread = startTestThread(mainThread);

        // Run async setup in a fiber
        async({
            mysqlConn = connect(host, port, database, user, password).await();
            writeln("Connected.");
            writeln();

            db = new MySQLDB!()(mysqlConn);

            setupDatabase();
            onDatabaseReady();
        }).except((Exception e) {
            writefln("Error: %s", e.msg);
            assert(0, e.msg);
        });

        runEventLoop(testThread);
    }
}

// ============================================================================
// Main
// ============================================================================

void main() {
    auto runner = new MySQLTestRunner();
    runner.run();
}
