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
import graphqld2.postgres.dialect : postgresDialect;

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
    private QueryResult[int] _cachedResults;  // Store child results from CTE query (by node ID)
    private QueryResult[string] _cachedResultsByType;  // Also index by type name for fetchChildren

    this(PgSqlConnection conn) {
        _conn = conn;
        _sqlOptimizer = new SqlOptimizer(postgresDialect());
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
        _sqlOptimizer = new SqlOptimizer(postgresDialect());
        _cachedResults.clear();
        _cachedResultsByType.clear();
    }

    /// Get the generated SQL (for debugging)
    @property string sql() { return _cachedSQL; }

    /// Execute a QueryNode by running SQL against PostgreSQL.
    override Promise!QueryResult executeQueryNode(QueryNode node, QueryResult parentResult) {
        // For child nodes, check if we already have cached results from root CTE execution
        if (!node.isRoot) {
            if (node.id in _cachedResults) {
                return resolve(_cachedResults[node.id]);
            }
            // Child nodes should be fetched as part of root CTE execution
            // If we get here without cached results, something is wrong
            return resolve(new QueryResult());
        }

        // Root node: generate CTE for entire tree (including all children)
        auto allNodes = node.allNodesInTree();
        _executedNodes = allNodes;

        // Generate the full CTE query for entire node tree
        auto sql = toSQL(allNodes, _sqlOptimizer);
        _cachedSQL = sql;

        debug(sql) {
            import std.stdio : writefln, writeln;
            writefln("PostgresDB: Generating SQL for %d nodes:", allNodes.length);
            foreach (n; allNodes) {
                writefln("  - node %d: %s (%s)", n.id, n.typeName, n.table);
                if (!n.isRoot) {
                    writefln("    parent: %s, FK: %s", n.parentTypeName, n.parentFk);
                }
            }
            writeln("PostgresDB: Generated SQL:");
            writeln(sql);
        }

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
    /// Also caches child results so they can be returned when child nodes are executed.
    private QueryResult parseQueryResult(PgSqlConnection.Row[] rows, QueryNode[] nodes) {
        if (rows.length == 0) {
            return new QueryResult();
        }

        // The result is a JSON object with layer0, layer1, etc.
        auto jsonStr = rows[0].column!string(0);
        auto jsonData = parseJSON(jsonStr);

        // Parse each layer and cache results
        QueryResult rootResult;
        foreach (node; nodes) {
            auto layerKey = "layer" ~ node.id.to!string;
            if (layerKey in jsonData) {
                auto layerRows = jsonData[layerKey].array;
                auto result = new QueryResult();

                if (node.isRoot) {
                    result.loadFromRows(layerRows, node.typeName);
                    rootResult = result;
                } else {
                    result.loadFromRows(layerRows, node.typeName, "id",
                                       node.parentFk, node.parentTypeName);
                    // Cache child results for later retrieval (by node ID and type name)
                    _cachedResults[node.id] = result;
                    _cachedResultsByType[node.typeName] = result;
                }
            }
        }

        // Return the root result
        return rootResult !is null ? rootResult : new QueryResult();
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
        // Check if we have cached results for this child type from CTE execution
        if (auto result = childType in _cachedResultsByType) {
            return (*result).getChildRefs(parentRefs);
        }

        // Fallback to empty arrays if no cached results
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

    // =========================================================================
    // Mutation methods (INSERT/UPDATE/DELETE)
    // =========================================================================

    import graphqld2.relational.mutation : InsertInput, UpdateInput;
    import graphqld2.postgres.sql : generateInsertSQL, generateUpdateSQL, generateDeleteSQL;

    /// Execute INSERT and return the new row.
    /// Values are embedded directly in the SQL (properly escaped).
    override Promise!QueryResult executeInsert(string table, string typeName, InsertInput input) {
        auto sql = generateInsertSQL(table, input);
        _cachedSQL = sql;

        // No parameters needed - values are embedded in SQL
        return _conn.prepare(sql).then((PreparedStatement stmt) {
            return stmt.query().array();
        }).then((PgSqlConnection.Row[] rows) {
            return parseInsertResult(rows, typeName);
        });
    }

    /// Execute UPDATE and return updated rows.
    /// Values are embedded directly in the SQL (properly escaped).
    override Promise!QueryResult executeUpdate(string table, string typeName, UpdateInput input) {
        auto sql = generateUpdateSQL(table, input);
        _cachedSQL = sql;

        // No parameters needed - values are embedded in SQL
        return _conn.prepare(sql).then((PreparedStatement stmt) {
            return stmt.query().array();
        }).then((PgSqlConnection.Row[] rows) {
            return parseUpdateResult(rows, typeName);
        });
    }

    /// Execute DELETE and return count of deleted rows.
    /// IDs are embedded directly in the SQL.
    override Promise!int executeDelete(string table, long[] ids) {
        auto sql = generateDeleteSQL(table, ids);
        _cachedSQL = sql;

        // No parameters needed - IDs are embedded in SQL
        return _conn.prepare(sql).then((PreparedStatement stmt) {
            return stmt.query().array();
        }).then((PgSqlConnection.Row[] rows) {
            if (rows.length > 0) {
                return rows[0].column!int(0);
            }
            return 0;
        });
    }

    /// Parse INSERT result (single row JSON).
    private QueryResult parseInsertResult(PgSqlConnection.Row[] rows, string typeName) {
        auto result = new QueryResult();
        if (rows.length == 0) {
            return result;
        }

        auto jsonStr = rows[0].column!string(0);
        auto jsonData = parseJSON(jsonStr);

        // Single row - wrap in array for loadFromRows
        result.loadFromRows([jsonData], typeName);
        return result;
    }

    /// Parse UPDATE result (JSON array).
    private QueryResult parseUpdateResult(PgSqlConnection.Row[] rows, string typeName) {
        auto result = new QueryResult();
        if (rows.length == 0) {
            return result;
        }

        auto jsonStr = rows[0].column!string(0);
        auto jsonData = parseJSON(jsonStr);

        // json_agg returns an array
        if (jsonData.type == JSONType.array) {
            result.loadFromRows(jsonData.array, typeName);
        }
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
