module graphqld2.executor;

import std.algorithm;
import std.array;
import std.json;
import ae.utils.promise;
import ae.net.asockets : socketManager;

import graphqld2.core;
import graphqld2.relational;

/// Executes expressions against a data source.
/// Uses the two-phase model: plan -> fetch -> evaluate.
///
/// In the new model, the expression itself sets up the root layer
/// (e.g., via rootAll!User() or rootById!User(5)).
class Executor {
    private {
        DataFetcher _fetcher;
        string _sourceId;
    }

    this(DataFetcher fetcher, string sourceId = "default") {
        _fetcher = fetcher;
        _sourceId = sourceId;
    }

    /// Execute an expression that includes its own root (e.g., rootAll!User().fullName()).
    /// Returns a promise that resolves to the computed values.
    Promise!(E.ResultType[]) execute(E)(E expr) {
        alias T = E.ResultType;

        // Phase 1: Plan (synchronous)
        // The expression plans itself, including setting up root layer
        auto planCtx = new PlanContext();
        planCtx.currentSourceId = _sourceId;
        expr.plan(planCtx);

        auto relPlan = planCtx.source!RelationalPlanContext();

        // Debug: show the plan
        debug relPlan.dump();

        // Create result promise
        auto resultPromise = new Promise!(T[]);

        // Capture for closure
        auto layers = relPlan.layers;

        // Phase 2: Fetch data (async)
        _fetcher.fetch(layers).then((JSONValue jsonResult) {
            // Phase 3: Extract root IDs from fetched data
            long[] rootIds;
            if ("layer0" in jsonResult) {
                auto layer0Data = jsonResult["layer0"].array;
                foreach (row; layer0Data) {
                    if ("id" in row) {
                        rootIds ~= row["id"].get!long;
                    }
                }
            }

            // Phase 4: Evaluate with fetched data (synchronous)
            auto evalCtx = new EvalContext();
            evalCtx.currentSourceId = _sourceId;
            evalCtx.currentLayerId = 0;  // Root layer
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
    E.ResultType[] executeSync(E)(E expr) {
        alias T = E.ResultType;

        T[] result;
        bool done = false;
        Exception error;

        execute(expr).then((T[] values) {
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
    auto executor = new Executor(fetcher);

    // Test with rootAll - fetches all users
    string[] result;
    executor.execute(rootAll!User().fullName()).then((string[] names) {
        result = names;
    });

    socketManager.loop();

    assert(result == ["Alice Smith", "Bob Jones"]);
    assert(db.queryCount == 1);
}

unittest {
    import graphqld2.postgres;

    // Test rootById
    struct User {
        mixin Entity!"users";
        static Expr!string firstName() => column!string("first_name");
    }

    auto db = new MockDatabaseConnection();
    db.setResponse("*", `{
        "layer0": [
            {"id": 5, "first_name": "Alice"}
        ]
    }`);

    auto fetcher = new PostgresDataFetcher(db);
    auto executor = new Executor(fetcher);

    auto names = executor.executeSync(rootById!User(5).firstName());
    assert(names == ["Alice"]);
}
