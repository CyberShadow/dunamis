module graphqld2.executor;

import std.json;
import std.conv;

import graphqld2.plan;
import graphqld2.eval;
import graphqld2.sql;
import graphqld2.schema;

// Note: In production, this would use ae.utils.promise
// For now, we'll define a simple synchronous interface

/// Abstract database interface
interface Database {
    /// Execute a SQL query and return JSON result
    JSONValue query(string sql, long[] params);
}

/// Executes a planned query
class Executor(RootEntity) {
    private Database _db;
    private SqlBuilder _sqlBuilder;

    this(Database db) {
        _db = db;
        _sqlBuilder = new SqlBuilder();
    }

    /// Execute an expression for a set of root entity IDs
    auto execute(E)(E expr, long[] rootIds) {
        alias T = E.ResultType;
        // Phase 1: Plan
        auto planCtx = new PlanContext();
        planCtx.setRoot(RootEntity.stringof, RootEntity._table);
        expr.plan(planCtx);

        // Debug: show the plan
        debug planCtx.dump();

        // Generate SQL
        auto sql = _sqlBuilder.buildQuery(planCtx.layers, rootIds);
        debug {
            import std.stdio : writeln;
            writeln("Generated SQL:\n", sql);
        }

        // Execute query
        auto jsonResult = _db.query(sql, rootIds);

        // Phase 2: Evaluate
        auto evalCtx = new EvalContext(planCtx.layers);
        evalCtx.loadData(jsonResult);
        evalCtx.currentLayerId = 0;
        evalCtx.currentIds = rootIds;

        return expr.eval(evalCtx);
    }
}

/// Convenience function to execute a query
auto execute(RootEntity, T, E : Expr!T)(Database db, E expr, long[] rootIds) {
    auto executor = new Executor!RootEntity(db);
    return executor.execute!(T, E)(expr, rootIds);
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
