/**
 * PostgreSQL Integration Test Runner
 *
 * Runs the GraphQL integration test suite against PostgreSQL.
 *
 * Flow:
 *   1. Connect to PostgreSQL
 *   2. Create schema using DDL generator
 *   3. Start HTTP server
 *   4. Seed data using mutations
 *   5. Run tests
 *   6. Exit with status code
 */
module integration.postgres_test;

import core.thread : Thread;
import core.time : msecs;

import std.algorithm;
import std.array;
import std.conv;
import std.json;
import std.process : environment;
import std.stdio;
import std.string : strip, replace;

import ae.net.asockets : socketManager;
import ae.net.sync : ThreadAnchor;
import ae.net.db.psql : PgSqlConnection;
import ae.net.http.server : HttpServer, HttpServerConnection;
import ae.net.http.common : HttpRequest, HttpStatusCode;
import ae.net.http.responseex : HttpResponseEx;
import ae.sys.data : Data;
import ae.sys.dataset : DataVec, joinToGC;
import ae.utils.promise;
import ae.utils.promise.await : async, await;

import graphqld2.core;
import graphqld2.graphql : compileQuery, Schema;
import graphqld2.postgres;
import graphqld2.relational.ddl : generateDDL;
import graphqld2.relational.schema;
import graphqld2.relational.demo;
import graphqld2.relational.mutation : insert;

import integration.test_framework;
import integration.tests;  // Imports test registrations

// ============================================================================
// Schema Definition
// ============================================================================

/// PostgreSQL data source
__gshared PostgresDB!() db;

struct User {
    mixin DemoEntity!(db, "users");
    mixin Col!("firstName", string);
    mixin Col!("lastName", string);
    mixin HasMany!("posts", Post, "author_id");

    static auto fullName(Expr!User u) {
        return u.firstName ~ " " ~ u.lastName;
    }
}

struct Post {
    mixin DemoEntity!(db, "posts");
    mixin Col!("title", string);
    mixin Col!("authorId", ForeignKey!User);
    mixin BelongsTo!("author", "authorId");
}

struct Query {
    mixin Table!(User, "users");
    mixin Table!(Post, "posts");
}

struct Mutation {
    mixin CrudMutations!User;
    mixin CrudMutations!Post;

    static auto createUserWithName(Expr!Mutation parent, string firstName, string lastName) {
        return insert!User([
            "first_name": JSONValue(firstName),
            "last_name": JSONValue(lastName)
        ]);
    }
}

alias MySchema = Schema!(Query, Mutation);

// ============================================================================
// HTTP Server
// ============================================================================

void handleGraphQL(HttpRequest request, HttpServerConnection conn) {
    try {
        auto bodyBytes = request.data[].joinToGC();
        auto bodyStr = cast(string) bodyBytes;
        auto json = std.json.parseJSON(bodyStr);

        auto query = json["query"].str;
        JSONValue variables = "variables" in json ? json["variables"] : JSONValue.emptyObject;

        db.reset();

        auto compiledQuery = compileQuery!MySchema(query, variables);
        auto executor = new Executor();

        executor.execute(compiledQuery).then((JSONValue result) {
            auto response = new HttpResponseEx();
            response.status = HttpStatusCode.OK;
            response.headers["Content-Type"] = "application/json";
            auto responseJson = JSONValue(["data": result]);
            response.data = DataVec(Data(cast(immutable(ubyte)[]) responseJson.toString()));
            conn.sendResponse(response);
        }).except((Exception e) {
            sendError(conn, e.msg);
        });
    } catch (Exception e) {
        sendError(conn, e.msg);
    }
}

void sendError(HttpServerConnection conn, string message) {
    auto response = new HttpResponseEx();
    response.status = HttpStatusCode.BadRequest;
    response.headers["Content-Type"] = "application/json";
    auto errorJson = JSONValue([
        "errors": JSONValue([JSONValue(["message": JSONValue(message)])])
    ]);
    response.data = DataVec(Data(cast(immutable(ubyte)[]) errorJson.toString()));
    conn.sendResponse(response);
}

HttpServer startServer() {
    auto server = new HttpServer();
    server.handleRequest = (HttpRequest request, HttpServerConnection conn) {
        if (request.resource == "/graphql" && request.method == "POST") {
            handleGraphQL(request, conn);
        } else if (request.resource == "/health") {
            auto response = new HttpResponseEx();
            response.status = HttpStatusCode.OK;
            response.data = DataVec(Data(cast(immutable(ubyte)[]) "OK"));
            conn.sendResponse(response);
        } else {
            auto response = new HttpResponseEx();
            response.status = HttpStatusCode.NotFound;
            conn.sendResponse(response);
        }
    };
    server.listen(8080);
    return server;
}

// ============================================================================
// Database Setup
// ============================================================================

void setupDatabase(PgSqlConnection conn) @async {
    writeln("Creating schema from DDL generator...");

    // Generate DDL at compile time
    enum ddl = generateDDL!(Query);
    debug(sql) writeln(ddl);

    // Execute each statement and wait for completion
    foreach (statement; ddl.splitter(";\n").filter!(s => s.strip.length > 0)) {
        auto sql = statement.strip ~ ";";
        debug(sql) writefln("  Executing: %s", sql.replace("\n", " "));
        conn.query(sql).array().await();
    }

    writeln("Schema created.");
}

void seedDatabase() {
    writeln("Seeding data via mutations...");

    // Create users
    auto alice = graphql(`mutation { createUserWithName(firstName: "Alice", lastName: "Smith") { id } }`);
    assertNoErrors(alice);
    auto aliceId = alice["data"]["createUserWithName"]["id"];
    writefln("  Created Alice (id=%s)", aliceId);

    auto bob = graphql(`mutation { createUserWithName(firstName: "Bob", lastName: "Jones") { id } }`);
    assertNoErrors(bob);
    auto bobId = bob["data"]["createUserWithName"]["id"];
    writefln("  Created Bob (id=%s)", bobId);

    // Create posts (GraphQL input object syntax: {key: value} not {"key": value})
    auto post1 = graphql(`mutation { createPost(input: {title: "Hello World", author_id: ` ~ aliceId.toString() ~ `}) { id } }`);
    assertNoErrors(post1);
    writeln("  Created post: Hello World");

    auto post2 = graphql(`mutation { createPost(input: {title: "GraphQL Rocks", author_id: ` ~ aliceId.toString() ~ `}) { id } }`);
    assertNoErrors(post2);
    writeln("  Created post: GraphQL Rocks");

    auto post3 = graphql(`mutation { createPost(input: {title: "D Programming", author_id: ` ~ bobId.toString() ~ `}) { id } }`);
    assertNoErrors(post3);
    writeln("  Created post: D Programming");

    writeln("Seeding complete.");
}

// ============================================================================
// Main
// ============================================================================

void main() {
    writeln();
    writeln("═══════════════════════════════════════════════════════════════");
    writeln("  PostgreSQL Integration Tests");
    writeln("═══════════════════════════════════════════════════════════════");
    writeln();

    // Connect to PostgreSQL
    auto host = environment.get("PGHOST", "localhost");
    auto port = environment.get("PGPORT", "5432").to!ushort;
    auto user = environment.get("PGUSER", environment.get("USER", "postgres"));
    auto database = environment.get("PGDATABASE", user);
    auto password = environment.get("PGPASSWORD", "");

    writefln("Connecting to PostgreSQL at %s:%d/%s...", host, port, database);

    shared bool serverReady = false;
    shared int exitCode = 1;
    __gshared HttpServer server;
    __gshared PgSqlConnection pgConn;

    // Create thread anchor to allow test thread to run code in main thread's event loop
    auto mainThread = new ThreadAnchor();

    // Start test runner thread - it will wait for server to be ready
    auto testThread = new Thread({
        // Wait for server to be ready
        while (!serverReady) {
            Thread.sleep(10.msecs);
        }

        try {
            // Seed data via HTTP
            seedDatabase();
            writeln();

            // Run tests via HTTP
            writeln("Running tests...");
            auto results = runAllTests();
            results.print();
            stdout.flush();  // Ensure output is visible before exit

            exitCode = results.allPassed ? 0 : 1;
        } catch (Exception e) {
            writefln("Test error: %s", e.msg);
            exitCode = 1;
        }

        // Schedule cleanup in main thread's event loop
        mainThread.runAsync({
            if (server !is null) {
                server.close();
            }
            if (pgConn !is null) {
                pgConn.disconnect("Tests complete");
            }
        });
    });
    testThread.start();

    // Run setup in a fiber so we can use await()
    async({
        pgConn = connect(host, port, database, user, password).await();
        writeln("Connected.");
        writeln();

        // Initialize DB wrapper
        db = new PostgresDB!()(pgConn);

        // Setup schema using await
        setupDatabase(pgConn);
        writeln();

        // Start HTTP server
        writeln("Starting HTTP server on port 8080...");
        server = startServer();
        writeln("Server started.");
        writeln();

        // Signal that server is ready for tests
        serverReady = true;
    }).except((Exception e) {
        writefln("Error: %s", e.msg);
        // Schedule cleanup on error too
        mainThread.runAsync({
            if (server !is null) server.close();
            if (pgConn !is null) pgConn.disconnect("Error during setup");
        });
        exitCode = 1;
    });

    // Run event loop - will exit when all connections are closed
    socketManager.loop();

    testThread.join();

    import core.stdc.stdlib : exit;
    exit(exitCode);
}
