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

import std.conv : to;
import std.json;
import std.stdio;

import ae.utils.promise : Promise;

import ae.net.asockets : socketManager;
import ae.net.sync : ThreadAnchor;
import ae.net.http.server : HttpServer, HttpServerConnection;
import ae.net.http.common : HttpRequest, HttpStatusCode;
import ae.net.http.responseex : HttpResponseEx;
import ae.sys.data : Data;
import ae.sys.dataset : DataVec, joinToGC;

import dunamis.core : EvalContext, Executor;
import dunamis.core.expr.combinators : SubscriptionResultExpr;
import dunamis.core.executor : SubscriptionExecutor, SubscriptionManager;
import dunamis.graphql : compileQuery, GraphQLResult;
import dunamis.relational.eval_context : RelationalSession;
import dunamis.relational.subscription : createSubscriptionHandler;

import integration.test_framework : runAllTests;
import integration.schema : InterleaveBarrier, InterleaveGate, RequestContext, Viewing, seedDatabase;

/**
 * Abstract base class for integration test runners.
 *
 * Template parameters:
 *   db - The module-level database instance (alias)
 *   Schema - The GraphQL schema type (from TestSchema mixin)
 *   FilterLastSchema - The same schema with another plugin order, served for
 *     requests with an `X-Plugin-Order: filter-last` header
 */
abstract class IntegrationTestRunner(alias db, alias Schema, SubEntityType, alias FilterLastSchema) {
    protected HttpServer server;
    protected shared bool serverReady = false;
    protected shared int exitCode = 1;

    /// Manages active subscriptions and dispatches change events.
    private SubscriptionManager _subManager;

    this() {
        _subManager = new SubscriptionManager();
    }

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

            auto orderHeader = "X-Plugin-Order" in request.headers;
            auto compiledQuery = orderHeader && *orderHeader == "filter-last"
                ? compileQuery!FilterLastSchema(query, variables)
                : compileQuery!Schema(query, variables);

            // Branch on operation type (embedded in the expression tree)
            if (cast(SubscriptionResultExpr) compiledQuery) {
                handleSubscription(compiledQuery, conn);
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

            auto executor = new Executor();

            auto evalCtx = new EvalContext();
            evalCtx.setRequestContext(RequestContext(locale));

            // Wire event listener for subscription dispatch
            if (_subManager.hasSubscriptions) {
                auto session = cast(RelationalSession) evalCtx.getSession(db);
                if (session !is null) {
                    session.setEventListener(_subManager.eventListener());
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

    /// Handle an interleaved evaluation: compile and optimize the query once,
    /// optimize the "distractor" query (as another request would), then
    /// evaluate the same tree for each of the "viewings" (or, for a
    /// subscription, deliver each of the "events" user IDs to one
    /// SubscriptionExecutor) concurrently, interleaved by an
    /// InterleaveBarrier. Responds with one {data, errors} per evaluation.
    protected void handleInterleaved(HttpRequest request, HttpServerConnection conn) {
        import dunamis.core.types : AnyRef;
        import dunamis.relational.schema : EntityID, makeEntityFromRef;

        try {
            auto json = std.json.parseJSON(cast(string) request.data[].joinToGC());
            JSONValue variables = "variables" in json ? json["variables"] : JSONValue.emptyObject;
            bool optimize = true;
            if (auto optHeader = "X-Optimize" in request.headers)
                optimize = (*optHeader != "false");

            auto executor = new Executor();
            auto compiled = compileQuery!Schema(json["query"].str, variables);
            SubscriptionExecutor!SubEntityType subExec;
            GraphQLResult tree = compiled;
            if (cast(SubscriptionResultExpr) compiled)
                subExec = new SubscriptionExecutor!SubEntityType(executor, compiled);
            else if (optimize)
                tree = executor.optimize(compiled);
            if ("distractor" in json)
                executor.optimize(compileQuery!Schema(json["distractor"].str));

            auto inputs = (subExec !is null ? json["events"] : json["viewings"]).array;
            auto barrier = new InterleaveBarrier(inputs.length);
            auto results = new JSONValue[inputs.length];
            size_t pending = inputs.length;

            void finish(size_t i, EvalContext ctx, JSONValue data, string failure) {
                JSONValue[] errors;
                foreach (err; ctx.errors)
                    errors ~= err.toJson();
                if (failure !is null)
                    errors ~= JSONValue(["message": JSONValue(failure)]);
                results[i] = JSONValue(["data": data, "errors": JSONValue(errors)]);
                barrier.finish(i);
                if (--pending == 0)
                    sendJsonResponse(conn, JSONValue(["results": JSONValue(results)]));
            }

            void start(size_t i) {
                auto ctx = new EvalContext();
                ctx.setRequestContext(RequestContext("en"));
                ctx.setRequestContext(InterleaveGate(barrier, i));
                Promise!JSONValue evaluation;
                if (subExec !is null) {
                    auto id = inputs[i].integer.to!string;
                    evaluation = subExec.execute(makeEntityFromRef!SubEntityType(
                        AnyRef(EntityID!SubEntityType.typeName ~ ":" ~ id)), ctx);
                } else {
                    ctx.setRequestContext(Viewing(inputs[i]["userId"].integer, inputs[i]["taskId"].integer));
                    evaluation = executor.execute(tree, ctx, false);
                }
                evaluation.then((JSONValue data) {
                    finish(i, ctx, data, null);
                }).except((Exception e) {
                    finish(i, ctx, JSONValue(null), e.msg);
                });
            }
            foreach (i; 0 .. inputs.length)
                start(i);
        } catch (Exception e) {
            sendError(conn, e.msg);
        }
    }

    /// Handle a subscription operation: create executor, register with manager
    private void handleSubscription(GraphQLResult query, HttpServerConnection conn) {
        auto executor = new Executor();
        auto subExec = new SubscriptionExecutor!SubEntityType(executor, query);
        auto reg = createSubscriptionHandler(subExec);
        _subManager.subscribeOnce(reg,
            (JSONValue result) {
                sendJsonResponse(conn, JSONValue(["data": result]));
            },
            (Exception e) {
                sendError(conn, e.msg);
            }
        );
        // Don't send response — connection held open until event fires
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
            } else if (request.resource == "/interleaved" && request.method == "POST") {
                handleInterleaved(request, conn);
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
