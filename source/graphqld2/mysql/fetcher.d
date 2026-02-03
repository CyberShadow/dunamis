module graphqld2.mysql.fetcher;

import std.algorithm;
import std.array;
import std.conv;
import std.json;
import std.string;

import ae.net.db.mysql;
import ae.utils.promise;

import graphqld2.core.types : AnyRef, makeAnyRef;
import graphqld2.core.optimize : ExprOptimizer;
import graphqld2.core.expr : ExprBase;
import graphqld2.relational.eval_context;
import graphqld2.relational.query_node;
import graphqld2.relational.sql_optimizer;
import graphqld2.mysql.dialect : mysqlDialect;
import graphqld2.mysql.sql;

/// MySQL data fetcher using ae.net.db.mysql.
/// Executes SQL generated from QueryNodes against a MySQL database.
///
/// Parameterized by DBConfig for compile-time feature configuration.
class MySQLDB(DBConfig config = defaultDBConfig) : DataFetcher {
    /// Configuration accessible at compile time
    enum configuration = config;

    private MySqlConnection _conn;
    private SqlOptimizer _sqlOptimizer;
    private QueryNode[] _executedNodes;
    private string _cachedSQL;
    private QueryResult[int] _cachedResults;  // Store child results from CTE query (by node ID)
    private QueryResult[string] _cachedResultsByType;  // Also index by type name for fetchChildren

    this(MySqlConnection conn) {
        _conn = conn;
        _sqlOptimizer = new SqlOptimizer(mysqlDialect());
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
        _sqlOptimizer = new SqlOptimizer(mysqlDialect());
        _cachedResults.clear();
        _cachedResultsByType.clear();
    }

    /// Get the generated SQL (for debugging)
    @property string sql() { return _cachedSQL; }

    /// Execute a QueryNode by running SQL against MySQL.
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
        auto sql = graphqld2.mysql.sql.toSQL(allNodes, _sqlOptimizer);

        // Substitute IDs if needed
        if (node.rootFilter == FilterType.byId || node.rootFilter == FilterType.byIds) {
            auto idValues = node.rootFilterRefs.map!(r => r.localId).array;
            sql = sql.replace("{{IDS}}", idValues.join(","));
        } else {
            // No filter - remove the placeholder
            sql = sql.replace("{{IDS}}", "");
        }

        _cachedSQL = sql;

        debug(sql) {
            import std.stdio : writefln, writeln;
            writefln("MySQLDB: Generating SQL for %d nodes:", allNodes.length);
            foreach (n; allNodes) {
                writefln("  - node %d: %s (%s)", n.id, n.typeName, n.table);
                if (!n.isRoot) {
                    writefln("    parent: %s, FK: %s", n.parentTypeName, n.parentFk);
                }
            }
            writeln("MySQLDB: Generated SQL:");
            writeln(sql);
        }

        // Execute query using text protocol
        return _conn.query(sql).array().then((MySqlConnection.Row[] rows) {
            return parseQueryResult(rows, _executedNodes);
        });
    }

    /// Parse MySQL result into QueryResult.
    /// The CTE query returns a single row with JSON containing all layers.
    /// Also caches child results so they can be returned when child nodes are executed.
    private QueryResult parseQueryResult(MySqlConnection.Row[] rows, QueryNode[] nodes) {
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
                    // Also cache root result so fetchBelongsTo can find FK columns
                    _cachedResults[node.id] = result;
                    _cachedResultsByType[node.typeName] = result;
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
    // These return Promises to support async database operations.
    // =========================================================================

    override Promise!(string[]) fetchColumnString(string table, string column, AnyRef[] refs) {
        if (refs.length == 0) return resolve(cast(string[])[]);

        auto ids = refs.map!(r => r.localId).array;
        auto sql = "SELECT id, " ~ column ~ " FROM " ~ table ~
                   " WHERE id IN (" ~ ids.join(",") ~ ")";

        return _conn.query(sql).array().then((MySqlConnection.Row[] rows) {
            // Build lookup map
            string[string] values;
            foreach (row; rows) {
                auto id = row.column!string(0);
                auto val = row.column!string(1);
                values[id] = val;
            }
            // Return in ref order
            return refs.map!(r => values.get(r.localId, "")).array;
        });
    }

    override Promise!(long[]) fetchColumnLong(string table, string column, AnyRef[] refs) {
        if (refs.length == 0) return resolve(cast(long[])[]);

        auto ids = refs.map!(r => r.localId).array;
        auto sql = "SELECT id, " ~ column ~ " FROM " ~ table ~
                   " WHERE id IN (" ~ ids.join(",") ~ ")";

        return _conn.query(sql).array().then((MySqlConnection.Row[] rows) {
            // Build lookup map
            long[string] values;
            foreach (row; rows) {
                auto id = row.column!string(0);
                auto val = row.column!long(1);
                values[id] = val;
            }
            // Return in ref order
            return refs.map!(r => values.get(r.localId, 0L)).array;
        });
    }

    override Promise!(long[]) fetchAllIds(string table) {
        auto sql = "SELECT id FROM " ~ table;

        return _conn.query(sql).array().then((MySqlConnection.Row[] rows) {
            return rows.map!(r => r.column!long(0)).array;
        });
    }

    override Promise!(AnyRef[][]) fetchChildren(string childTable, string childType, string fk, AnyRef[] parentRefs) {
        // Check if we have cached results for this child type from CTE execution
        if (auto result = childType in _cachedResultsByType) {
            return resolve((*result).getChildRefs(parentRefs));
        }

        if (parentRefs.length == 0) {
            return resolve(cast(AnyRef[][])[]);
        }

        // Naive path: query children grouped by parent FK
        auto parentIds = parentRefs.map!(r => r.localId).array;
        auto sql = "SELECT id, " ~ fk ~ " FROM " ~ childTable ~
                   " WHERE " ~ fk ~ " IN (" ~ parentIds.join(",") ~ ")";

        return _conn.query(sql).array().then((MySqlConnection.Row[] rows) {
            // Group children by parent
            AnyRef[][string] childrenByParent;
            foreach (row; rows) {
                auto childId = row.column!string(0);
                auto parentId = row.column!string(1);
                childrenByParent[parentId] ~= makeAnyRef(childType, childId);
            }
            // Return in parent ref order
            return parentRefs.map!(p => childrenByParent.get(p.localId, [])).array;
        });
    }

    override Promise!(AnyRef[]) fetchBelongsTo(string childTable, string fk, string parentType, AnyRef[] childRefs) {
        if (childRefs.length == 0) {
            return resolve(cast(AnyRef[])[]);
        }

        // Try to get FK values from cached query results first
        foreach (result; _cachedResults.byValue) {
            if (result.hasColumn(fk)) {
                // Found the FK column in cached results
                auto fkValues = result.getColumnRaw(fk, childRefs);
                AnyRef[] refs;
                refs.reserve(fkValues.length);
                foreach (fkVal; fkValues) {
                    if (fkVal.type != JSONType.null_) {
                        refs ~= makeAnyRef(parentType, jsonToIdString(fkVal));
                    } else {
                        refs ~= AnyRef.init;
                    }
                }
                return resolve(refs);
            }
        }

        // Naive path: query FK values
        auto ids = childRefs.map!(r => r.localId).array;
        auto sql = "SELECT id, " ~ fk ~ " FROM " ~ childTable ~
                   " WHERE id IN (" ~ ids.join(",") ~ ")";

        return _conn.query(sql).array().then((MySqlConnection.Row[] rows) {
            // Build lookup map
            string[string] fkValues;
            foreach (row; rows) {
                auto id = row.column!string(0);
                auto fkVal = row.column!string(1);
                fkValues[id] = fkVal;
            }
            // Return in ref order
            AnyRef[] result;
            result.reserve(childRefs.length);
            foreach (r; childRefs) {
                auto fkVal = fkValues.get(r.localId, "");
                if (fkVal.length > 0) {
                    result ~= makeAnyRef(parentType, fkVal);
                } else {
                    result ~= AnyRef.init;
                }
            }
            return result;
        });
    }

    /// Convert JSON value to ID string (handles integers and strings)
    private static string jsonToIdString(JSONValue val) {
        if (val.type == JSONType.integer) {
            return val.integer.to!string;
        } else if (val.type == JSONType.string) {
            return val.str;
        } else {
            return "";
        }
    }

    override Promise!(JSONValue[]) fetchColumnJson(string table, string column, AnyRef[] refs) {
        if (refs.length == 0) {
            return resolve(cast(JSONValue[])[]);
        }

        auto ids = refs.map!(r => r.localId).array;
        auto sql = "SELECT id, " ~ column ~ " FROM " ~ table ~
                   " WHERE id IN (" ~ ids.join(",") ~ ")";

        return _conn.query(sql).array().then((MySqlConnection.Row[] rows) {
            // Build lookup map
            JSONValue[string] values;
            foreach (row; rows) {
                auto id = row.column!string(0);
                // Try to get as string first, then as other types
                try {
                    auto val = row.column!string(1);
                    values[id] = JSONValue(val);
                } catch (Exception e) {
                    try {
                        auto val = row.column!long(1);
                        values[id] = JSONValue(val);
                    } catch (Exception e2) {
                        values[id] = JSONValue(null);
                    }
                }
            }
            // Return in ref order
            JSONValue[] result;
            result.reserve(refs.length);
            foreach (r; refs) {
                result ~= values.get(r.localId, JSONValue(null));
            }
            return result;
        });
    }

    // =========================================================================
    // Mutation methods (INSERT/UPDATE/DELETE)
    // =========================================================================

    import graphqld2.relational.mutation : InsertInput, UpdateInput;

    /// Execute INSERT and return the new row.
    /// MySQL doesn't have RETURNING, so we use LAST_INSERT_ID().
    override Promise!QueryResult executeInsert(string table, string typeName, InsertInput input) {
        auto insertSql = generateInsertSQL(table, input);
        _cachedSQL = insertSql;

        auto columns = input.columns;  // Capture for closure

        // Execute INSERT and fetch the inserted row as JSON
        return _conn.query(insertSql).array().then((MySqlConnection.Row[] _) {
            // Fetch the inserted row using LAST_INSERT_ID()
            auto selectSql = generateSelectLastInsertSQL(table, columns);
            return _conn.query(selectSql).array();
        }).then((MySqlConnection.Row[] rows) {
            return parseJsonResult(rows, typeName);
        });
    }

    /// Execute UPDATE and return updated rows.
    override Promise!QueryResult executeUpdate(string table, string typeName, UpdateInput input) {
        auto updateSql = generateUpdateSQL(table, input);
        auto columns = input.columns;  // Capture for closure
        auto ids = input.ids;  // Capture for closure

        if (updateSql.length == 0) {
            // No columns to update - return empty result
            return resolve(new QueryResult());
        }

        _cachedSQL = updateSql;

        // Execute UPDATE and fetch the updated rows as JSON
        return _conn.query(updateSql).array().then((MySqlConnection.Row[] _) {
            // Fetch the updated rows
            auto selectSql = generateSelectUpdatedSQL(table, ids, columns);
            return _conn.query(selectSql).array();
        }).then((MySqlConnection.Row[] rows) {
            return parseJsonResult(rows, typeName);
        });
    }

    /// Execute DELETE and return count of deleted rows.
    override Promise!int executeDelete(string table, long[] ids) {
        auto deleteSql = generateDeleteSQL(table, ids);
        _cachedSQL = deleteSql;

        // Execute DELETE
        auto result = _conn.query(deleteSql);
        return result.array().then((MySqlConnection.Row[] _) {
            // Return affected rows count
            return cast(int)result.affectedRows;
        });
    }

    /// Parse JSON result from SELECT query.
    /// Expects rows with a single column containing JSON.
    private QueryResult parseJsonResult(MySqlConnection.Row[] rows, string typeName) {
        auto result = new QueryResult();
        if (rows.length == 0) {
            return result;
        }

        // Each row has a single column with JSON object
        JSONValue[] jsonRows;
        foreach (row; rows) {
            auto jsonStr = row.column!string(0);
            jsonRows ~= parseJSON(jsonStr);
        }

        result.loadFromRows(jsonRows, typeName);
        return result;
    }
}

/// Create a MySQLDB instance from connection parameters.
Promise!(MySQLDB!config) createMySQLDB(DBConfig config = defaultDBConfig)(
    string host, ushort port, string database, string user, string password
) {
    import graphqld2.mysql.connection : connect;

    return connect(host, port, database, user, password).then((conn) {
        return new MySQLDB!config(conn);
    });
}

/// Create a MySQLDB instance from environment variables.
Promise!(MySQLDB!config) createMySQLDBFromEnv(DBConfig config = defaultDBConfig)() {
    import graphqld2.mysql.connection : connectFromEnv;

    return connectFromEnv().then((conn) {
        return new MySQLDB!config(conn);
    });
}

/// Create a MySQLDB instance from a connection string.
Promise!(MySQLDB!config) createMySQLDBFromUri(DBConfig config = defaultDBConfig)(string uri) {
    import graphqld2.mysql.connection : connectFromUri;

    return connectFromUri(uri).then((conn) {
        return new MySQLDB!config(conn);
    });
}
