module graphqld2.postgres.fetcher;

import std.algorithm;
import std.array;
import std.conv;
import std.json;
import std.string;

import ae.net.db.psql;
import ae.utils.promise;

alias PreparedStatement = PgSqlConnection.PreparedStatement;

import graphqld2.core.types;
import graphqld2.core.optimize : ExprOptimizer;
import graphqld2.core.expr : ExprBase;
import graphqld2.relational.eval_context;
import graphqld2.relational.query_node;
import graphqld2.relational.sql_optimizer;

/// PostgreSQL data fetcher using ae.net.db.psql.
/// Executes SQL generated from QueryNodes against a PostgreSQL database.
///
/// Parameterized by DBConfig for compile-time feature configuration.
class PostgresDB(DBConfig config = defaultDBConfig) : DataFetcher {
    /// Configuration accessible at compile time
    enum configuration = config;

    private PgSqlConnection _conn;
    private SqlOptimizer _sqlOptimizer;
    private QueryNode[] _executedNodes;
    private string _cachedSQL;

    this(PgSqlConnection conn) {
        _conn = conn;
        _sqlOptimizer = new SqlOptimizer();
    }

    /// Return the SqlOptimizer to enable SQL push-down
    override ExprOptimizer[] requestedOptimizers() {
        return [_sqlOptimizer];
    }

    /// Get original expression for fallback evaluation (not used - real DB evaluates SQL)
    override ExprBase getOriginalExpr(string alias_) {
        return null;
    }

    /// Reset for next query
    void reset() {
        _executedNodes = [];
        _cachedSQL = "";
        _sqlOptimizer = new SqlOptimizer();
    }

    /// Get the generated SQL (for debugging)
    @property string sql() { return _cachedSQL; }

    /// Execute a QueryNode by running SQL against PostgreSQL.
    override Promise!QueryResult executeQueryNode(QueryNode node, QueryResult parentResult) {
        _executedNodes ~= node;

        // For child nodes, we defer to bulk execution
        // For root nodes, we execute the full CTE query
        if (!node.isRoot) {
            // Child nodes are fetched as part of the CTE
            // Return empty for now, will be populated by root execution
            return resolve(new QueryResult());
        }

        // Generate the full CTE query
        auto sql = toSQL(_executedNodes, _sqlOptimizer);
        _cachedSQL = sql;

        // Build parameter value for root filter
        // PostgreSQL Extended Query uses $1, $2, etc. for parameters
        // We need to pass the IDs as a PostgreSQL array
        string[] idValues;
        if (node.rootFilter == FilterType.byId || node.rootFilter == FilterType.byIds) {
            idValues = node.rootFilterRefs.map!(r => r.localId).array;
        }

        // Use prepared statement for parameterized query
        return _conn.prepare(sql).then((PreparedStatement stmt) {
            // Execute with array parameter for $1
            if (idValues.length > 0) {
                // PostgreSQL array as string: {1,2,3}
                return stmt.query("{" ~ idValues.join(",") ~ "}").array();
            } else {
                return stmt.query().array();
            }
        }).then((PgSqlConnection.Row[] rows) {
            return parseQueryResult(rows, _executedNodes);
        });
    }

    /// Parse PostgreSQL result into QueryResult.
    /// The CTE query returns a single row with JSON containing all layers.
    private QueryResult parseQueryResult(PgSqlConnection.Row[] rows, QueryNode[] nodes) {
        if (rows.length == 0) {
            return new QueryResult();
        }

        // The result is a JSON object with layer0, layer1, etc.
        auto jsonStr = rows[0].column!string(0);
        auto jsonData = parseJSON(jsonStr);

        // Parse each layer
        QueryResult[int] results;
        foreach (node; nodes) {
            auto layerKey = "layer" ~ node.id.to!string;
            if (layerKey in jsonData) {
                auto layerRows = jsonData[layerKey].array;
                auto result = new QueryResult();

                if (node.isRoot) {
                    result.loadFromRows(layerRows, node.typeName);
                } else {
                    result.loadFromRows(layerRows, node.typeName, "id",
                                       node.parentFk, node.parentTypeName);
                }
                results[node.id] = result;
            }
        }

        // Return the root result (first node)
        return results.get(nodes[0].id, new QueryResult());
    }

    // =========================================================================
    // Individual fetch methods (for naive/fallback path)
    // =========================================================================

    override string[] fetchColumnString(string table, string column, AnyRef[] refs) {
        // Not used in optimized path - implemented for interface completeness
        string[] result;
        result.length = refs.length;
        return result;
    }

    override long[] fetchColumnLong(string table, string column, AnyRef[] refs) {
        long[] result;
        result.length = refs.length;
        return result;
    }

    override long[] fetchAllIds(string table) {
        // Not used in optimized path - data is fetched via executeQueryNode
        // Returning empty triggers the caller to use the optimized path
        return [];
    }

    override AnyRef[][] fetchChildren(string childTable, string childType, string fk, AnyRef[] parentRefs) {
        return parentRefs.map!(_ => cast(AnyRef[])[]).array;
    }

    override AnyRef[] fetchBelongsTo(string childTable, string fk, string parentType, AnyRef[] childRefs) {
        return childRefs.map!(_ => AnyRef.init).array;
    }

    override JSONValue[] fetchColumnJson(string table, string column, AnyRef[] refs) {
        JSONValue[] result;
        result.length = refs.length;
        foreach (ref r; result) r = JSONValue(null);
        return result;
    }
}

/// Create a PostgresDB instance from connection parameters.
Promise!(PostgresDB!config) createPostgresDB(DBConfig config = defaultDBConfig)(
    string host, ushort port, string database, string user, string password
) {
    import graphqld2.postgres.connection : connect;

    return connect(host, port, database, user, password).then((conn) {
        return new PostgresDB!config(conn);
    });
}

/// Create a PostgresDB instance from a connection string.
Promise!(PostgresDB!config) createPostgresDBFromUri(DBConfig config = defaultDBConfig)(string uri) {
    import graphqld2.postgres.connection : connectFromUri;

    return connectFromUri(uri).then((conn) {
        return new PostgresDB!config(conn);
    });
}
