/**
 * PostgreSQL Integration Test
 *
 * This test starts an HTTP server that serves GraphQL queries against a PostgreSQL database.
 * Run with: dub run --config=postgres-integration
 *
 * Prerequisites:
 *   - PostgreSQL running with test database and user
 *   - Environment variables: PGHOST, PGPORT, PGUSER, PGDATABASE, PGPASSWORD
 *
 * Test with curl:
 *   curl -X POST http://localhost:8080/graphql \
 *     -H "Content-Type: application/json" \
 *     -d '{"query": "{ users { firstName lastName } }"}'
 */
module integration.postgres_test;

import std.algorithm;
import std.array;
import std.conv;
import std.json;
import std.process : environment;
import std.stdio;

import ae.net.asockets : socketManager;
import ae.net.http.server : HttpServer, HttpServerConnection;
import ae.net.http.common : HttpRequest, HttpResponse, HttpStatusCode;
import ae.net.http.responseex : HttpResponseEx;
import ae.sys.data : Data;
import ae.sys.dataset : DataVec, joinToGC;
import ae.utils.promise;

import graphqld2.core;
import graphqld2.graphql : compileQuery, generateSchemaSDL, GqlHidden;
import graphqld2.postgres;
import graphqld2.relational.schema;
import graphqld2.relational.demo;

/// PostgreSQL data source
static PostgresDB!() db;

// ============================================================================
// Schema Definition
// ============================================================================

struct User {
    mixin DemoEntity!(db, "users");
    mixin Col!("firstName", string);
    mixin Col!("lastName", string);

    static auto fullName(Expr!User u) {
        return u.firstName ~ " " ~ u.lastName;
    }
}

struct Post {
    mixin DemoEntity!(db, "posts");
    mixin Col!("title", string);
    @GqlHidden mixin Col!("authorId", ForeignKey!User);
    mixin BelongsTo!("author", "authorId");
}

struct Query {
    mixin Table!(User, "users");
    mixin Table!(Post, "posts");
}

// ============================================================================
// HTTP Server
// ============================================================================

void handleGraphQL(HttpRequest request, HttpServerConnection conn) {
    try {
        // Parse request body
        auto bodyBytes = request.data[].joinToGC();
        auto bodyStr = cast(string) bodyBytes;
        auto json = parseJSON(bodyStr);

        auto query = json["query"].str;
        JSONValue variables = "variables" in json ? json["variables"] : JSONValue.emptyObject;

        // Compile and execute query (uses static db bound via Entity mixins)
        auto compiledQuery = compileQuery!Query(query, variables);
        auto executor = new Executor();

        executor.execute(compiledQuery).then((JSONValue result) {
            auto response = new HttpResponseEx();
            response.status = HttpStatusCode.OK;
            response.headers["Content-Type"] = "application/json";

            auto responseJson = JSONValue(["data": result]);
            response.data = DataVec(Data(responseJson.toString().asBytes));
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
        "errors": JSONValue([
            JSONValue(["message": JSONValue(message)])
        ])
    ]);
    response.data = DataVec(Data(errorJson.toString().asBytes));
    conn.sendResponse(response);
}

void main() {
    writeln("GraphQL PostgreSQL Integration Test");
    writeln("====================================");
    writeln();
    writeln("Schema:");
    writeln(generateSchemaSDL!Query);
    writeln();

    // Connect to PostgreSQL
    auto host = environment.get("PGHOST", "localhost");
    auto port = environment.get("PGPORT", "5432").to!ushort;
    auto user = environment.get("PGUSER", environment.get("USER", "postgres"));
    auto database = environment.get("PGDATABASE", user);
    auto password = environment.get("PGPASSWORD", "");

    writefln("Connecting to PostgreSQL at %s:%d/%s as %s...", host, port, database, user);

    connect(host, port, database, user, password).then((conn) {
        writeln("Connected to PostgreSQL");
        db = new PostgresDB!()(conn);

        // Start HTTP server
        auto server = new HttpServer();
        server.handleRequest = (HttpRequest request, HttpServerConnection conn) {
            if (request.resource == "/graphql" && request.method == "POST") {
                handleGraphQL(request, conn);
            } else if (request.resource == "/health") {
                auto response = new HttpResponseEx();
                response.status = HttpStatusCode.OK;
                response.data = DataVec(Data("OK".asBytes));
                conn.sendResponse(response);
            } else {
                auto response = new HttpResponseEx();
                response.status = HttpStatusCode.NotFound;
                response.data = DataVec(Data("Not Found".asBytes));
                conn.sendResponse(response);
            }
        };

        auto listenPort = server.listen(8080);
        writefln("HTTP server listening on http://localhost:%d", listenPort);
        writeln();
        writeln("Test with:");
        writeln("  curl -X POST http://localhost:8080/graphql \\");
        writeln("    -H 'Content-Type: application/json' \\");
        writeln("    -d '{\"query\": \"{ users { firstName lastName } }\"}'");
        writeln();
        writeln("Press Ctrl+C to stop.");
        return 0;
    }).except((Exception e) {
        writefln("Failed to connect: %s", e.msg);
    });

    socketManager.loop();
}

private auto asBytes(string s) {
    return cast(immutable(ubyte)[]) s;
}
