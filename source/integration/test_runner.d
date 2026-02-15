/**
 * Abstract Integration Test Runner
 *
 * Base class for running GraphQL integration tests against different databases.
 * Handles HTTP server setup, test execution coordination, and cleanup.
 *
 * Usage:
 *   1. Define module-level `db` variable and `mixin TestSchema!db`
 *   2. Create a subclass that implements setupDatabase() and cleanup()
 *   3. Call run() from main()
 */
module integration.test_runner;

import core.thread : Thread;
import core.time : msecs;

import std.json;
import std.stdio;

import ae.net.asockets : socketManager;
import ae.net.sync : ThreadAnchor;
import ae.net.http.server : HttpServer, HttpServerConnection;
import ae.net.http.common : HttpRequest, HttpStatusCode;
import ae.net.http.responseex : HttpResponseEx;
import ae.sys.data : Data;
import ae.sys.dataset : DataVec, joinToGC;

import dunamis.core : EvalContext, Executor;
import dunamis.core.executor : SubscriptionExecutor;
import dunamis.core.datasource : ChangeEvent;
import dunamis.graphql : compileQuery;
import dunamis.relational.eval_context : RelationalSession;
import dunamis.relational.schema : makeEntityFromRef, EntityID;
import dunamis.core.types : makeAnyRef;

import integration.test_framework : runAllTests;
import integration.schema : RequestContext, seedDatabase;

/**
 * Abstract base class for integration test runners.
 *
 * Template parameters:
 *   db - The module-level database instance (alias)
 *   Schema - The GraphQL schema type (from TestSchema mixin)
 */
abstract class IntegrationTestRunner(alias db, alias Schema, SubEntityType) {
    protected HttpServer server;
    protected shared bool serverReady = false;
    protected shared int exitCode = 1;

    /// Subscription support: SubEntityType is the raw (non-normalized) entity type
    /// used by EventSourceExpr in the subscription's expression tree.
    private SubscriptionExecutor!SubEntityType _subExecutor;
    private HttpServerConnection _pendingSubConn;

    /// Override to set up the database connection and schema
    abstract void setupDatabase();

    /// Override to clean up database resources (called in main thread's event loop)
    abstract void cleanup();

    /// Override to return the test suite name for the banner
    abstract string testName();

    /// Handle GraphQL requests
    protected void handleGraphQL(HttpRequest request, HttpServerConnection conn) {
        try {
            auto bodyBytes = request.data[].joinToGC();
            auto bodyStr = cast(string) bodyBytes;
            auto json = std.json.parseJSON(bodyStr);

            auto query = json["query"].str;
            JSONValue variables = "variables" in json ? json["variables"] : JSONValue.emptyObject;

            // Detect subscription operations
            if (query.length >= 12 && query[0..12] == "subscription") {
                handleSubscription(query, variables, conn);
                return;
            }

            // Check for optimization preference via header (defaults to true)
            bool optimize = true;
            if (auto optHeader = "X-Optimize" in request.headers) {
                optimize = (*optHeader != "false");
            }

            // Extract request context from headers
            string locale = "en";
            if (auto localeHeader = "X-Locale" in request.headers) {
                locale = *localeHeader;
            }

            auto compiledQuery = compileQuery!Schema(query, variables);
            auto executor = new Executor();

            auto evalCtx = new EvalContext();
            evalCtx.setRequestContext(RequestContext(locale));

            // Wire event listener for subscription dispatch
            if (_subExecutor !is null) {
                auto session = cast(RelationalSession) evalCtx.getSession(db);
                if (session !is null) {
                    session.setEventListener(&dispatchEvent);
                }
            }

            executor.execute(compiledQuery, evalCtx, optimize).then((JSONValue result) {
                auto response = new HttpResponseEx();
                response.status = HttpStatusCode.OK;
                response.headers["Content-Type"] = "application/json";

                JSONValue responseJson;
                if (evalCtx.hasErrors) {
                    // Partial success: include both data and errors
                    responseJson = JSONValue.emptyObject;
                    responseJson["data"] = result;
                    JSONValue[] errorArr;
                    foreach (err; evalCtx.errors) {
                        errorArr ~= err.toJson();
                    }
                    responseJson["errors"] = JSONValue(errorArr);
                } else {
                    responseJson = JSONValue(["data": result]);
                }

                response.data = DataVec(Data(cast(immutable(ubyte)[]) responseJson.toString()));
                conn.sendResponse(response);
            }).except((Exception e) {
                sendError(conn, e.msg);
            });
        } catch (Exception e) {
            sendError(conn, e.msg);
        }
    }

    /// Handle a subscription operation: compile, create executor, hold connection open
    private void handleSubscription(string query, JSONValue variables, HttpServerConnection conn) {
        auto compiledQuery = compileQuery!Schema(query, variables);
        auto executor = new Executor();
        _subExecutor = new SubscriptionExecutor!SubEntityType(executor, compiledQuery);
        _pendingSubConn = conn;
        // Don't send response — connection held open until event fires
    }

    /// Dispatch a change event to the pending subscription
    private void dispatchEvent(ChangeEvent event) {
        if (_subExecutor is null || _pendingSubConn is null) return;

        enum subTable = EntityID!SubEntityType.table;
        enum subTypeName = EntityID!SubEntityType.typeName;

        if (event.table != subTable || event.kind != ChangeEvent.Kind.created) return;

        // Construct entity from event ID and evaluate subscription
        auto entity = makeEntityFromRef!SubEntityType(
            makeAnyRef(subTypeName, event.ids[0]));

        auto conn = _pendingSubConn;
        auto subExec = _subExecutor;
        _pendingSubConn = null;
        _subExecutor = null;

        subExec.execute(entity).then((JSONValue result) {
            sendJsonResponse(conn, JSONValue(["data": result]));
        }).except((Exception e) {
            sendError(conn, e.msg);
        });
    }

    /// Send a JSON response with status 200
    protected void sendJsonResponse(HttpServerConnection conn, JSONValue json) {
        auto response = new HttpResponseEx();
        response.status = HttpStatusCode.OK;
        response.headers["Content-Type"] = "application/json";
        response.data = DataVec(Data(cast(immutable(ubyte)[]) json.toString()));
        conn.sendResponse(response);
    }

    /// Send error response
    protected void sendError(HttpServerConnection conn, string message) {
        auto response = new HttpResponseEx();
        response.status = HttpStatusCode.BadRequest;
        response.headers["Content-Type"] = "application/json";
        auto errorJson = JSONValue([
            "errors": JSONValue([JSONValue(["message": JSONValue(message)])])
        ]);
        response.data = DataVec(Data(cast(immutable(ubyte)[]) errorJson.toString()));
        conn.sendResponse(response);
    }

    /// Start the HTTP server
    protected HttpServer startServer() {
        auto s = new HttpServer();
        s.handleRequest = (HttpRequest request, HttpServerConnection conn) {
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
        s.listen(8080);
        return s;
    }

    /// Print the test banner
    protected void printBanner() {
        writeln();
        writeln("═══════════════════════════════════════════════════════════════");
        writefln("  %s", testName());
        writeln("═══════════════════════════════════════════════════════════════");
        writeln();
    }

    /// Create and start the test runner thread
    protected Thread startTestThread(ThreadAnchor mainThread) {
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
                stdout.flush();

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
                cleanup();
            });
        });
        testThread.isDaemon = true; // Don't wait for a response that will never arrive if the server thread crashes
        testThread.start();
        return testThread;
    }

    /// Called after setupDatabase() completes to start serving
    protected void onDatabaseReady() {
        writeln("Starting HTTP server on port 8080...");
        server = startServer();
        writeln("Server started.");
        writeln();
        serverReady = true;
    }

    /// Run the event loop and wait for completion
    protected void runEventLoop(Thread testThread) {
        socketManager.loop();
        testThread.join();

        import core.stdc.stdlib : exit;
        exit(exitCode);
    }
}
