module graphqld2.postgres.fetcher;

import std.json;
import ae.utils.promise;

import graphqld2.core.fetcher;
import graphqld2.relational.types;
import graphqld2.postgres.sql;
import graphqld2.postgres.connection;

/// PostgreSQL implementation of DataFetcher.
/// Uses SqlBuilder to generate PostgreSQL-specific SQL and executes via DatabaseConnection.
class PostgresDataFetcher : DataFetcher {
    private {
        DatabaseConnection _db;
        SqlBuilder _sqlBuilder;
    }

    this(DatabaseConnection db) {
        _db = db;
        _sqlBuilder = new SqlBuilder();
    }

    override Promise!JSONValue fetch(Layer[] layers, long[] rootIds) {
        auto sql = _sqlBuilder.buildQuery(layers, rootIds);

        debug {
            import std.stdio : writeln;
            writeln("Generated SQL:\n", sql);
        }

        return _db.query(sql, rootIds);
    }
}

unittest {
    import ae.net.asockets : socketManager;

    // Create mock database
    auto db = new MockDatabaseConnection();
    db.setResponse("*", `{
        "layer0": [
            {"id": 1, "name": "Alice"},
            {"id": 2, "name": "Bob"}
        ]
    }`);

    // Create fetcher
    auto fetcher = new PostgresDataFetcher(db);

    // Create test layers
    auto layers = [
        Layer(0, "User", "users", ["id", "name"])
    ];

    // Fetch data
    JSONValue result;
    fetcher.fetch(layers, [1L, 2L]).then((JSONValue r) {
        result = r;
    });

    socketManager.loop();

    assert(db.queryCount == 1);
    assert("layer0" in result);
    assert(result["layer0"].array.length == 2);
}
