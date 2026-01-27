module graphqld2.executor;

import std.json;
import std.conv;

import graphqld2.core;
import graphqld2.relational;
import graphqld2.postgres;

/// Abstract database interface
interface Database {
    /// Execute a SQL query and return JSON result
    JSONValue query(string sql, long[] params);
}

/// Executes a planned query for relational data sources
class Executor(RootEntity) {
    private Database _db;
    private SqlBuilder _sqlBuilder;
    private string _sourceId;

    this(Database db, string sourceId = "default") {
        _db = db;
        _sqlBuilder = new SqlBuilder();
        _sourceId = sourceId;
    }

    /// Execute an expression for a set of root entity IDs
    auto execute(E)(E expr, long[] rootIds) {
        alias T = E.ResultType;

        // Phase 1: Plan
        auto planCtx = new PlanContext();
        planCtx.currentSourceId = _sourceId;

        auto relPlan = planCtx.source!RelationalPlanContext();
        auto rootLayerId = relPlan.setRoot(RootEntity.stringof, RootEntity._table);
        planCtx.currentLayerId = rootLayerId;

        expr.plan(planCtx);

        // Debug: show the plan
        debug relPlan.dump();

        // Generate SQL
        auto sql = _sqlBuilder.buildQuery(relPlan.layers, rootIds);
        debug {
            import std.stdio : writeln;
            writeln("Generated SQL:\n", sql);
        }

        // Execute query
        auto jsonResult = _db.query(sql, rootIds);

        // Phase 2: Evaluate
        auto evalCtx = new EvalContext();
        evalCtx.currentSourceId = _sourceId;
        evalCtx.currentLayerId = rootLayerId;
        evalCtx.currentIds = rootIds;

        auto relEval = evalCtx.source!RelationalEvalContext();
        relEval.setLayers(relPlan.layers);
        relEval.loadData(jsonResult);

        return expr.eval(evalCtx);
    }
}

/// Convenience function to execute a query
auto execute(RootEntity, E)(Database db, E expr, long[] rootIds) {
    auto executor = new Executor!RootEntity(db);
    return executor.execute(expr, rootIds);
}

// ============================================================================
// Test Database Implementation
// ============================================================================

/// In-memory test database that returns canned responses
class TestDatabase : Database {
    private JSONValue[string] _responses;

    /// Register a response for a query pattern
    void setResponse(string pattern, JSONValue response) {
        _responses[pattern] = response;
    }

    /// Set response from JSON string
    void setResponse(string pattern, string jsonStr) {
        _responses[pattern] = parseJSON(jsonStr);
    }

    override JSONValue query(string sql, long[] params) {
        // For testing, we'll just return a default response
        // In a real implementation, this would execute the SQL
        if ("*" in _responses)
            return _responses["*"];

        // Return empty layers
        return parseJSON(`{"layer0": [], "layer1": [], "layer2": []}`);
    }
}

// ============================================================================
// Integration Tests
// ============================================================================

unittest {
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

    // Create test database with canned response
    auto db = new TestDatabase();
    db.setResponse("*", `{
        "layer0": [
            {"id": 1, "first_name": "Alice", "last_name": "Smith"},
            {"id": 2, "first_name": "Bob", "last_name": "Jones"}
        ]
    }`);

    // Execute query
    auto executor = new Executor!User(db);
    auto names = executor.execute(User.fullName(), [1L, 2L]);

    assert(names == ["Alice Smith", "Bob Jones"]);
}
