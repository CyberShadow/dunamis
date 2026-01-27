module graphqld2.postgres.connection;

import std.json;
import ae.utils.promise;

/// Low-level interface for executing SQL queries against a PostgreSQL database.
/// Implementations can be real database connections or mocks for testing.
interface DatabaseConnection {
    /// Execute a SQL query with the given parameters.
    /// Returns a promise that resolves to the JSON result.
    Promise!JSONValue query(string sql, long[] params);
}

/// Mock database connection for testing.
/// Returns canned responses for any query.
class MockDatabaseConnection : DatabaseConnection {
    private {
        JSONValue[string] _responses;
        int _queryCount;
        string[] _executedQueries;
    }

    /// Register a response for a query pattern.
    /// Use "*" as a wildcard to match any query.
    void setResponse(string pattern, string jsonStr) {
        _responses[pattern] = parseJSON(jsonStr);
    }

    /// Register a response as JSONValue
    void setResponse(string pattern, JSONValue response) {
        _responses[pattern] = response;
    }

    /// Get number of queries executed
    @property int queryCount() { return _queryCount; }

    /// Get list of executed SQL queries (for verification in tests)
    @property string[] executedQueries() { return _executedQueries; }

    /// Clear query history
    void clearHistory() {
        _queryCount = 0;
        _executedQueries = [];
    }

    override Promise!JSONValue query(string sql, long[] params) {
        import ae.net.asockets : socketManager, onNextTick;

        _queryCount++;
        _executedQueries ~= sql;

        auto promise = new Promise!JSONValue;

        // Simulate async by fulfilling on next tick
        socketManager.onNextTick({
            // Try exact match first
            if (sql in _responses) {
                promise.fulfill(_responses[sql]);
            } else if ("*" in _responses) {
                // Wildcard match
                promise.fulfill(_responses["*"]);
            } else {
                // Default empty response
                promise.fulfill(parseJSON(`{"layer0": []}`));
            }
        });

        return promise;
    }
}

unittest {
    import ae.net.asockets : socketManager;

    auto db = new MockDatabaseConnection();
    db.setResponse("*", `{"layer0": [{"id": 1, "name": "test"}]}`);

    JSONValue result;
    db.query("SELECT * FROM test", []).then((JSONValue r) {
        result = r;
    });

    socketManager.loop();

    assert(db.queryCount == 1);
    assert("layer0" in result);
}
