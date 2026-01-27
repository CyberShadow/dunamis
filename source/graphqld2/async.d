module graphqld2.async;

import std.json;
import std.conv;
import std.algorithm;
import std.array;

import ae.utils.promise;
import ae.net.asockets : socketManager, onNextTick;

import graphqld2.core;
import graphqld2.relational;
import graphqld2.postgres;

// ============================================================================
// Async Database Interface
// ============================================================================

/// Abstract async database interface
interface AsyncDatabase {
    /// Execute a SQL query and return a promise for the JSON result
    Promise!JSONValue query(string sql, long[] params);
}

// ============================================================================
// Data Source with Request Batching
// ============================================================================

/// A batching data source that accumulates requests and flushes on idle
class BatchingDataSource {
    private {
        AsyncDatabase _db;
        PendingQuery[] _pending;
        bool _flushScheduled;
    }

    this(AsyncDatabase db) {
        _db = db;
    }

    /// Queue a query to be executed. Returns a promise for the result.
    Promise!JSONValue request(string sql, long[] params) {
        auto promise = new Promise!JSONValue;

        _pending ~= PendingQuery(sql, params, promise);

        // Schedule flush on next tick if not already scheduled
        // Note: Using onNextTick instead of addIdleHandler because
        // idle handlers only run when waiting for socket events
        if (!_flushScheduled) {
            _flushScheduled = true;
            socketManager.onNextTick(&flushPending);
        }

        return promise;
    }

    /// Flush all pending queries (called on next tick)
    private void flushPending() {
        _flushScheduled = false;

        if (_pending.length == 0) {
            return;
        }

        // Take all pending queries
        auto queries = _pending;
        _pending = [];

        // Execute each query
        // In a more sophisticated implementation, we could combine compatible queries
        foreach (i, q; queries) {
            executeQuery(q);
        }
    }

    /// Helper to properly capture query in closure
    private void executeQuery(PendingQuery q) {
        auto promise = q.promise;
        _db.query(q.sql, q.params).then((JSONValue result) {
            promise.fulfill(result);
        }, (Exception e) {
            promise.reject(e);
        });
    }

    private struct PendingQuery {
        string sql;
        long[] params;
        Promise!JSONValue promise;
    }
}

// ============================================================================
// Async Executor
// ============================================================================

/// Executes planned queries asynchronously with promise-based results
class AsyncExecutor(RootEntity) {
    private {
        BatchingDataSource _dataSource;
        SqlBuilder _sqlBuilder;
        string _sourceId;
    }

    this(AsyncDatabase db, string sourceId = "default") {
        _dataSource = new BatchingDataSource(db);
        _sqlBuilder = new SqlBuilder();
        _sourceId = sourceId;
    }

    this(BatchingDataSource dataSource, string sourceId = "default") {
        _dataSource = dataSource;
        _sqlBuilder = new SqlBuilder();
        _sourceId = sourceId;
    }

    /// Execute an expression for a set of root entity IDs
    /// Returns a promise that resolves to the computed values
    auto execute(E)(E expr, long[] rootIds) {
        alias T = E.ResultType;

        // Phase 1: Plan (synchronous)
        auto planCtx = new PlanContext();
        planCtx.currentSourceId = _sourceId;

        auto relPlan = planCtx.source!RelationalPlanContext();
        auto rootLayerId = relPlan.setRoot(RootEntity.stringof, RootEntity._table);
        planCtx.currentLayerId = rootLayerId;

        expr.plan(planCtx);

        // Generate SQL
        auto sql = _sqlBuilder.buildQuery(relPlan.layers, rootIds);

        // Create result promise
        auto resultPromise = new Promise!(T[]);

        // Capture layers for the closure
        auto layers = relPlan.layers;

        // Phase 2: Execute query (async) and evaluate
        _dataSource.request(sql, rootIds).then((JSONValue jsonResult) {
            // Evaluate with fetched data (synchronous)
            auto evalCtx = new EvalContext();
            evalCtx.currentSourceId = _sourceId;
            evalCtx.currentLayerId = rootLayerId;
            evalCtx.currentIds = rootIds;

            auto relEval = evalCtx.source!RelationalEvalContext();
            relEval.setLayers(layers);
            relEval.loadData(jsonResult);

            resultPromise.fulfill(expr.eval(evalCtx));
        }, (Exception e) {
            resultPromise.reject(e);
        });

        return resultPromise;
    }
}

// ============================================================================
// Test Implementation
// ============================================================================

/// Mock async database for testing
class MockAsyncDatabase : AsyncDatabase {
    private {
        JSONValue[string] _responses;
        int _queryCount;
    }

    /// Register a response for any query
    void setResponse(string pattern, string jsonStr) {
        _responses[pattern] = parseJSON(jsonStr);
    }

    /// Get number of queries executed
    @property int queryCount() { return _queryCount; }

    override Promise!JSONValue query(string sql, long[] params) {
        _queryCount++;

        auto promise = new Promise!JSONValue;

        // Simulate async by fulfilling on next tick
        socketManager.onNextTick({
            if ("*" in _responses) {
                promise.fulfill(_responses["*"]);
            } else {
                promise.fulfill(parseJSON(`{"layer0": []}`));
            }
        });

        return promise;
    }
}

// ============================================================================
// Integration Tests
// ============================================================================

unittest {
    // Simple async execution test
    struct User {
        mixin Entity!"users";

        static Expr!string firstName() => column!string("first_name");
        static Expr!string lastName() => column!string("last_name");

        static auto fullName() => use(
            (string first, string last) => first ~ " " ~ last,
            firstName(),
            lastName()
        );
    }

    auto db = new MockAsyncDatabase();
    db.setResponse("*", `{
        "layer0": [
            {"id": 1, "first_name": "Alice", "last_name": "Smith"},
            {"id": 2, "first_name": "Bob", "last_name": "Jones"}
        ]
    }`);

    auto executor = new AsyncExecutor!User(db);

    string[] result;
    executor.execute(User.fullName(), [1L, 2L]).then((string[] names) {
        result = names;
    });

    // Run event loop to process promises
    socketManager.loop();

    assert(result == ["Alice Smith", "Bob Jones"]);
    assert(db.queryCount == 1);  // Only one query executed
}

unittest {
    // Test that multiple execute calls batch together
    struct User {
        mixin Entity!"users";
        static Expr!string firstName() => column!string("first_name");
    }

    auto db = new MockAsyncDatabase();
    db.setResponse("*", `{
        "layer0": [
            {"id": 1, "first_name": "Alice"},
            {"id": 2, "first_name": "Bob"}
        ]
    }`);

    // Share the same data source for batching
    auto dataSource = new BatchingDataSource(db);
    auto executor = new AsyncExecutor!User(dataSource);

    string[] result1, result2;

    // Queue two queries before event loop runs
    executor.execute(User.firstName(), [1L]).then((string[] names) {
        result1 = names;
    });

    executor.execute(User.firstName(), [2L]).then((string[] names) {
        result2 = names;
    });

    // Run event loop - both should execute
    socketManager.loop();

    assert(result1 == ["Alice"]);
    assert(result2 == ["Bob"]);
    // Note: Currently 2 queries since we don't combine identical queries yet
    // A future optimization could deduplicate/combine these
}

// ============================================================================
// Convenience Functions
// ============================================================================

/// Execute an expression synchronously by running the event loop
T[] executeSync(RootEntity, E)(AsyncDatabase db, E expr, long[] rootIds) {
    alias T = E.ResultType;

    auto executor = new AsyncExecutor!RootEntity(db);
    T[] result;
    bool done = false;

    executor.execute(expr, rootIds).then((values) {
        result = values;
        done = true;
    }, (Exception e) {
        throw e;
    });

    socketManager.loop();
    assert(done, "Query did not complete");

    return result;
}
