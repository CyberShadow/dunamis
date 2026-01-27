module graphqld2.executor;

import std.json;
import ae.utils.promise;
import ae.net.asockets : socketManager;

import graphqld2.core;
import graphqld2.relational;

/// Executes expressions against a data source.
/// Uses the two-phase model: plan -> fetch -> evaluate.
class Executor(RootEntity) {
    private {
        DataFetcher _fetcher;
        string _sourceId;
    }

    this(DataFetcher fetcher, string sourceId = "default") {
        _fetcher = fetcher;
        _sourceId = sourceId;
    }

    /// Execute an expression for a set of root entity IDs.
    /// Returns a promise that resolves to the computed values.
    Promise!(E.ResultType[]) execute(E)(E expr, long[] rootIds) {
        alias T = E.ResultType;

        // Phase 1: Plan (synchronous)
        auto planCtx = new PlanContext();
        planCtx.currentSourceId = _sourceId;

        auto relPlan = planCtx.source!RelationalPlanContext();
        auto rootLayerId = relPlan.setRoot(RootEntity.stringof, RootEntity._table);
        planCtx.currentLayerId = rootLayerId;

        expr.plan(planCtx);

        // Debug: show the plan
        debug relPlan.dump();

        // Create result promise
        auto resultPromise = new Promise!(T[]);

        // Capture for closure
        auto layers = relPlan.layers;

        // Phase 2: Fetch data (async)
        _fetcher.fetch(layers, rootIds).then((JSONValue jsonResult) {
            // Phase 3: Evaluate with fetched data (synchronous)
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

    /// Execute synchronously by running the event loop until complete.
    E.ResultType[] executeSync(E)(E expr, long[] rootIds) {
        alias T = E.ResultType;

        T[] result;
        bool done = false;
        Exception error;

        execute(expr, rootIds).then((T[] values) {
            result = values;
            done = true;
        }, (Exception e) {
            error = e;
            done = true;
        });

        socketManager.loop();

        if (error !is null)
            throw error;

        assert(done, "Query did not complete");
        return result;
    }
}

// ============================================================================
// Tests
// ============================================================================

unittest {
    import graphqld2.postgres;

    // Define test entities
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

    // Create mock database and fetcher
    auto db = new MockDatabaseConnection();
    db.setResponse("*", `{
        "layer0": [
            {"id": 1, "first_name": "Alice", "last_name": "Smith"},
            {"id": 2, "first_name": "Bob", "last_name": "Jones"}
        ]
    }`);

    auto fetcher = new PostgresDataFetcher(db);
    auto executor = new Executor!User(fetcher);

    // Test async execution
    string[] result;
    executor.execute(User.fullName(), [1L, 2L]).then((string[] names) {
        result = names;
    });

    socketManager.loop();

    assert(result == ["Alice Smith", "Bob Jones"]);
    assert(db.queryCount == 1);
}

unittest {
    import graphqld2.postgres;

    // Test executeSync
    struct User {
        mixin Entity!"users";
        static Expr!string firstName() => column!string("first_name");
    }

    auto db = new MockDatabaseConnection();
    db.setResponse("*", `{
        "layer0": [
            {"id": 1, "first_name": "Alice"}
        ]
    }`);

    auto fetcher = new PostgresDataFetcher(db);
    auto executor = new Executor!User(fetcher);

    auto names = executor.executeSync(User.firstName(), [1L]);
    assert(names == ["Alice"]);
}
