module dynamo.postgres.fetcher;

import std.algorithm;
import std.array;
import std.conv;
import std.json;
import std.string;

import ae.net.db.psql;
import ae.utils.promise;

alias PreparedStatement = PgSqlConnection.PreparedStatement;

import dynamo.core.types : AnyRef, makeAnyRef;
import dynamo.core.optimize : ExprOptimizer;
import dynamo.core.expr : ExprBase;
import dynamo.relational.eval_context;
import dynamo.relational.query_node;
import dynamo.relational.sql_optimizer;
import dynamo.postgres.dialect : postgresDialect;

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

        // Filter to valid refs only
        string[] validIds;
        foreach (r; refs) {
            if (r.isValid && r.localId.length > 0) {
                validIds ~= r.localId;
            }
        }

        if (validIds.length == 0) {
            // All refs were invalid - return empty strings
            string[] result;
            result.length = refs.length;
            return resolve(result);
        }

        auto sql = "SELECT id, " ~ column ~ " FROM " ~ table ~
                   " WHERE id IN (" ~ validIds.join(",") ~ ")";

        return _conn.prepare(sql).then((PreparedStatement stmt) {
            return stmt.query().array();
        }).then((PgSqlConnection.Row[] rows) {
            // Build lookup map
            string[string] values;
            foreach (row; rows) {
                auto id = row.column!string(0);
                auto val = row.column!string(1);
                values[id] = val;
            }
            // Return in ref order (invalid refs get empty string)
            return refs.map!(r => r.isValid ? values.get(r.localId, "") : "").array;
        });
    }

    override Promise!(long[]) fetchColumnLong(string table, string column, AnyRef[] refs) {
        if (refs.length == 0) return resolve(cast(long[])[]);

        // Filter to valid refs only
        string[] validIds;
        foreach (r; refs) {
            if (r.isValid && r.localId.length > 0) {
                validIds ~= r.localId;
            }
        }

        if (validIds.length == 0) {
            // All refs were invalid - return zeros
            long[] result;
            result.length = refs.length;
            return resolve(result);
        }

        auto sql = "SELECT id, " ~ column ~ " FROM " ~ table ~
                   " WHERE id IN (" ~ validIds.join(",") ~ ")";

        return _conn.prepare(sql).then((PreparedStatement stmt) {
            return stmt.query().array();
        }).then((PgSqlConnection.Row[] rows) {
            // Build lookup map
            long[string] values;
            foreach (row; rows) {
                auto id = row.column!string(0);
                auto val = row.column!long(1);
                values[id] = val;
            }
            // Return in ref order (invalid refs get 0)
            return refs.map!(r => r.isValid ? values.get(r.localId, 0L) : 0L).array;
        });
    }

    override Promise!(long[]) fetchAllIds(string table) {
        auto sql = "SELECT id FROM " ~ table;

        return _conn.prepare(sql).then((PreparedStatement stmt) {
            return stmt.query().array();
        }).then((PgSqlConnection.Row[] rows) {
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

        // Filter to valid parent refs only
        string[] validIds;
        foreach (r; parentRefs) {
            if (r.isValid && r.localId.length > 0) {
                validIds ~= r.localId;
            }
        }

        if (validIds.length == 0) {
            // All refs were invalid - return empty arrays
            return resolve(parentRefs.map!(_ => cast(AnyRef[])[]).array);
        }

        // Naive path: query children grouped by parent FK
        auto sql = "SELECT id, " ~ fk ~ " FROM " ~ childTable ~
                   " WHERE " ~ fk ~ " IN (" ~ validIds.join(",") ~ ")";

        return _conn.prepare(sql).then((PreparedStatement stmt) {
            return stmt.query().array();
        }).then((PgSqlConnection.Row[] rows) {
            // Group children by parent
            AnyRef[][string] childrenByParent;
            foreach (row; rows) {
                auto childId = row.column!string(0);
                auto parentId = row.column!string(1);
                childrenByParent[parentId] ~= makeAnyRef(childType, childId);
            }
            // Return in parent ref order (invalid refs get empty array)
            return parentRefs.map!(p => p.isValid ? childrenByParent.get(p.localId, []) : cast(AnyRef[])[]).array;
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

        // Filter to valid child refs only
        string[] validIds;
        foreach (r; childRefs) {
            if (r.isValid && r.localId.length > 0) {
                validIds ~= r.localId;
            }
        }

        if (validIds.length == 0) {
            // All refs were invalid - return invalid refs
            return resolve(childRefs.map!(_ => AnyRef.init).array);
        }

        // Naive path: query FK values
        auto sql = "SELECT id, " ~ fk ~ " FROM " ~ childTable ~
                   " WHERE id IN (" ~ validIds.join(",") ~ ")";

        return _conn.prepare(sql).then((PreparedStatement stmt) {
            return stmt.query().array();
        }).then((PgSqlConnection.Row[] rows) {
            import std.typecons : Nullable;
            // Build lookup map
            string[string] fkValues;
            foreach (row; rows) {
                auto id = row.column!string(0);
                // FK column may be NULL
                auto fkVal = row.column!(Nullable!string)(1);
                fkValues[id] = fkVal.isNull ? "" : fkVal.get;
            }
            // Return in ref order (invalid refs get AnyRef.init)
            AnyRef[] result;
            result.reserve(childRefs.length);
            foreach (r; childRefs) {
                if (!r.isValid || r.localId.length == 0) {
                    result ~= AnyRef.init;
                } else {
                    auto fkVal = fkValues.get(r.localId, "");
                    if (fkVal.length > 0) {
                        result ~= makeAnyRef(parentType, fkVal);
                    } else {
                        result ~= AnyRef.init;
                    }
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

        // Filter to valid refs only
        string[] validIds;
        foreach (r; refs) {
            if (r.isValid && r.localId.length > 0) {
                validIds ~= r.localId;
            }
        }

        if (validIds.length == 0) {
            // All refs were invalid - return nulls
            JSONValue[] result;
            result.length = refs.length;
            foreach (ref r; result) r = JSONValue(null);
            return resolve(result);
        }

        auto sql = "SELECT id, " ~ column ~ " FROM " ~ table ~
                   " WHERE id IN (" ~ validIds.join(",") ~ ")";

        return _conn.prepare(sql).then((PreparedStatement stmt) {
            return stmt.query().array();
        }).then((PgSqlConnection.Row[] rows) {
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
            // Return in ref order (invalid refs get null)
            JSONValue[] result;
            result.reserve(refs.length);
            foreach (r; refs) {
                result ~= r.isValid ? values.get(r.localId, JSONValue(null)) : JSONValue(null);
            }
            return result;
        });
    }

    // =========================================================================
    // Mutation methods (INSERT/UPDATE/DELETE)
    // =========================================================================

    import dynamo.relational.mutation : InsertInput, UpdateInput;
    import dynamo.postgres.sql : generateInsertSQL, generateUpdateSQL, generateDeleteSQL;

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
    import dynamo.postgres.connection : connect;

    return connect(host, port, database, user, password).then((conn) {
        return new PostgresDB!config(conn);
    });
}

/// Create a PostgresDB instance from a connection string.
Promise!(PostgresDB!config) createPostgresDBFromUri(DBConfig config = defaultDBConfig)(string uri) {
    import dynamo.postgres.connection : connectFromUri;

    return connectFromUri(uri).then((conn) {
        return new PostgresDB!config(conn);
    });
}
