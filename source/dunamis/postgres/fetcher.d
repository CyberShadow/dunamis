module dunamis.postgres.fetcher;

import std.algorithm;
import std.array;
import std.conv;
import std.json;
import std.string;

import ae.net.db.psql;
import ae.utils.promise;

alias PreparedStatement = PgSqlConnection.PreparedStatement;

import dunamis.core.types : AnyRef, makeAnyRef;
import dunamis.core.optimize : ExprOptimizer;
import dunamis.core.expr : ExprBase;
import dunamis.core.datasource : DataSource, DataSession, SetupMode;
import dunamis.relational.eval_context;
import dunamis.relational.query_node;
import dunamis.relational.sql_optimizer;
import dunamis.postgres.dialect : postgresDialect;
import dunamis.relational.sql : toSQL;

// ============================================================================
// PostgreSQL Session (Per-Request)
// ============================================================================

/// Per-request session for PostgreSQL.
/// Holds cached results and per-query state for a single evaluation.
class PostgresSession : RelationalSession {
    private PgSqlConnection _conn;
    private Promise!PgSqlConnection delegate() _connFactory;
    private Promise!void delegate(bool continuation) _acquireConnection;
    private void delegate() _releaseConnection;
    private bool _hasConnectionPermit;
    private bool _disconnectOnTeardown;
    private size_t _setupDepth;
    private QueryNode[] _executedNodes;
    private string _cachedSQL;
    private QueryResult[QueryNode] _cachedResults;
    private string[] _setupStatements;

    /// Add transaction-local initialization SQL for this request (for
    /// example SET LOCAL application context values).
    void addSetupStatement(string sql) {
        _setupStatements ~= sql;
    }

    /// Create with a connection factory. The factory is called in setup().
    this(Promise!PgSqlConnection delegate() connFactory,
            bool disconnectOnTeardown,
            Promise!void delegate(bool continuation) acquireConnection = null,
            void delegate() releaseConnection = null) {
        _connFactory = connFactory;
        _acquireConnection = acquireConnection;
        _releaseConnection = releaseConnection;
        _disconnectOnTeardown = disconnectOnTeardown;
    }

    /// Acquire connection and begin a transaction.
    override Promise!void setup(SetupMode mode = SetupMode.query) {
        // Executors may be nested while sharing an EvalContext (for example a
        // computed field can execute a selection against the current request
        // session).  The nested executor borrows the active transaction; it
        // must neither replace its connection nor commit it on teardown.
        if (_setupDepth) {
            _setupDepth++;
            return resolve();
        }
        super.setup(mode);
        return acquireConnectionPermit(false).then(() => _connFactory()).then((PgSqlConnection conn) {
            _conn = conn;
            return connection().query("BEGIN").array();
        }).then((PgSqlConnection.Row[] _) {
            return executeSetupStatement(0).then(() {
                _setupDepth = 1;
            });
        }).except((Exception e) {
            discardConnection("Dunamis session setup failed");
            throw e;
        });
    }

    private Promise!void acquireConnectionPermit(bool continuation) {
        if (_hasConnectionPermit)
            return resolve();
        auto acquired = _acquireConnection is null ? resolve() : _acquireConnection(continuation);
        return acquired.then(() {
            _hasConnectionPermit = true;
        });
    }

    private void releaseConnectionPermit() {
        if (!_hasConnectionPermit)
            return;
        _hasConnectionPermit = false;
        if (_releaseConnection !is null)
            _releaseConnection();
    }

    private void discardConnection(string reason) {
        auto conn = _conn;
        _conn = null;
        if (conn !is null && _disconnectOnTeardown)
            conn.disconnect(reason);
        releaseConnectionPermit();
    }

    /// The connection every statement of this session is issued on.
    ///
    /// The session only has one between setup()/resume() and
    /// suspend()/teardown(). Expression evaluation joins all the work it
    /// starts before the request ends (see `dunamis.core.join`), so a
    /// statement outside that window is an engine bug; report it as an
    /// error of the statement instead of dereferencing a null connection.
    private PgSqlConnection connection() {
        if (_conn is null)
            throw new Exception(_setupDepth
                ? "PostgreSQL session used while suspended (it has released its connection)"
                : "PostgreSQL session used outside of a request (it has no connection)");
        return _conn;
    }

    private Promise!void executeSetupStatement(size_t index) {
        if (index >= _setupStatements.length)
            return resolve();
        return execute(_setupStatements[index])
            .then(() => executeSetupStatement(index + 1));
    }

    /// Commit completed work and immediately begin a new transaction carrying
    /// the same request-local settings. External mutation resolvers may call
    /// back into GraphQL on another connection; retaining locks from earlier
    /// top-level fields while waiting for that callback would deadlock.
    Promise!void checkpoint() {
        if (_conn is null || !_setupDepth)
            return resolve();
        auto conn = _conn;
        return conn.query("COMMIT").array().then((PgSqlConnection.Row[] _) {
            return conn.query("BEGIN").array();
        }).then((PgSqlConnection.Row[] _) {
            return executeSetupStatement(0);
        });
    }

    /// End the current read transaction and release its connection while an
    /// expression waits for out-of-process work. Keeping the connection here
    /// can deadlock recursive GraphQL evaluation when every PostgreSQL
    /// connection is held by a parent waiting for its child.
    override Promise!void suspend() {
        if (_conn is null || !_setupDepth)
            return resolve();
        auto conn = _conn;
        return conn.query("COMMIT").array().then((PgSqlConnection.Row[] _) {
            if (_conn is conn)
                discardConnection("Dunamis session suspended");
        });
    }

    /// Reacquire a connection without resetting the logical session's caches
    /// or pending evaluation state.
    override Promise!void resume() {
        if (_conn !is null || !_setupDepth)
            return resolve();
        return acquireConnectionPermit(true).then(() => _connFactory()).then((PgSqlConnection conn) {
            _conn = conn;
            return conn.query("BEGIN").array();
        }).then((PgSqlConnection.Row[] _) {
            return executeSetupStatement(0);
        }).except((Exception e) {
            discardConnection("Dunamis session resume failed");
            throw e;
        });
    }

    /// Commit or rollback the transaction, then fire pending events.
    override Promise!void teardown(SetupMode mode = SetupMode.query, bool success = true) {
        if (_setupDepth > 1) {
            _setupDepth--;
            return resolve();
        }
        if (_conn is null) {
            _setupDepth = 0;
            releaseConnectionPermit();
            return resolve();  // setup failed or already torn down
        }
        auto sql = success ? "COMMIT" : "ROLLBACK";
        auto conn = _conn;
        return conn.query(sql).array().then((PgSqlConnection.Row[] _) {
            return super.teardown(mode, success);
        }).then(() {
            if (_conn is conn)
                discardConnection("Dunamis request complete");
            _setupDepth = 0;
        }).except((Exception e) {
            if (_conn is conn)
                discardConnection("Dunamis request teardown failed");
            _setupDepth = 0;
            throw e;
        });
    }

    /// Execute raw SQL for session setup.
    override Promise!void execute(string sql) {
        return connection().query(sql).array().then((PgSqlConnection.Row[] _) { });
    }

    /// Execute SQL which returns one integer column.  This is intentionally a
    /// small escape hatch for application-specific database shims whose
    /// semantics cannot be expressed as relational query nodes (for example
    /// versioned writes).
    Promise!(long[]) queryLongs(string sql) {
        return connection().query(sql).array().then((PgSqlConnection.Row[] rows) {
            long[] values;
            values.reserve(rows.length);
            foreach (row; rows)
                values ~= row.column!long(0);
            return values;
        });
    }

    /// Execute SQL which returns one text column.
    Promise!(string[]) queryStrings(string sql) {
        return connection().query(sql).array().then((PgSqlConnection.Row[] rows) {
            string[] values;
            values.reserve(rows.length);
            foreach (row; rows)
                values ~= row.column!string(0);
            return values;
        });
    }

    /// Execute SQL which returns one JSON/JSONB column. This is the generic
    /// session-scoped data-request escape hatch for in-process D extensions:
    /// they can request application-specific projections while retaining the
    /// current transaction and request-local database settings, instead of
    /// recursively entering GraphQL over HTTP.
    Promise!(JSONValue[]) queryJson(string sql) {
        return connection().query(sql).array().then((PgSqlConnection.Row[] rows) {
            JSONValue[] values;
            values.reserve(rows.length);
            foreach (row; rows)
                values ~= parseJSON(row.column!string(0));
            return values;
        });
    }

    /// Get the generated SQL (for debugging)
    @property string sql() { return _cachedSQL; }

    /// Execute a QueryNode by running SQL against PostgreSQL.
    override Promise!QueryResult executeQueryNode(QueryNode node, QueryResult parentResult,
            RootSelection root) {
        // For child nodes, check if we already have cached results from root CTE execution
        if (!node.isRoot) {
            if (node in _cachedResults) {
                return resolve(_cachedResults[node]);
            }
            // Child nodes should be fetched as part of root CTE execution
            // If we get here without cached results, something is wrong
            return resolve(new QueryResult());
        }

        // Root node: generate CTE for entire tree (including all children)
        auto allNodes = node.allNodesInTree();
        _executedNodes = allNodes;

        // Generate the full CTE query for entire node tree
        auto sql = toSQL(allNodes, postgresDialect(), root.filter);
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
        if (root.filter == FilterType.byId || root.filter == FilterType.byIds) {
            idValues = root.refs.map!(r => r.localId).array;
        }

        if (idValues.length > 0) {
            // PostgreSQL array as string: {1,2,3}
            return connection().extendedQuery(sql, "{" ~ idValues.join(",") ~ "}").array()
                .then((PgSqlConnection.Row[] rows) => parseQueryResult(rows, allNodes));
        }

        return connection().extendedQuery(sql).array()
            .then((PgSqlConnection.Row[] rows) => parseQueryResult(rows, allNodes));
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
        // Parse each layer and cache results (root results too, so that
        // fetchBelongsTo can find FK columns)
        return loadLayerResults(parseJSON(jsonStr), nodes, _cachedResults);
    }

    // =========================================================================
    // Individual fetch methods (for naive/fallback path)
    // These return Promises to support async database operations.
    // =========================================================================

    /// Generate SQL to fetch a column value, keyed by PK columns.
    private string buildFetchColumnSQL(string table, string column, string[] validIds) {
        import std.format : format;
        import dunamis.core.types : decodeCompositeKey;
        auto pkColumns = getPkColumnsForTable(table);

        if (pkColumns.length == 1) {
            return format("SELECT %s, %s FROM %s WHERE %s IN (%s)",
                pkColumns[0], column, table, pkColumns[0], validIds.join(","));
        } else {
            auto dialect = postgresDialect();
            string[] conditions;
            foreach (id; validIds) {
                auto parts = decodeCompositeKey(id);
                string[] eqs;
                foreach (i, col; pkColumns) {
                    eqs ~= format("%s = %s", col, dialect.escapeSqlString(i < parts.length ? parts[i] : ""));
                }
                conditions ~= "(" ~ eqs.join(" AND ") ~ ")";
            }
            return format("SELECT %s, %s FROM %s WHERE %s",
                pkColumns.join(", "), column, table, conditions.join(" OR "));
        }
    }

    /// Build composite key from a row result (PK columns come first).
    private string buildKeyFromRow(PgSqlConnection.Row row, size_t pkCount) {
        import dunamis.core.types : encodeCompositeKey;
        if (pkCount == 1) {
            return row.column!string(0);
        } else {
            string[] parts;
            foreach (i; 0 .. pkCount) {
                parts ~= row.column!string(cast(int) i);
            }
            return encodeCompositeKey(parts);
        }
    }

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

        auto pkColumns = getPkColumnsForTable(table);
        auto pkCount = pkColumns.length;
        auto sql = buildFetchColumnSQL(table, column, validIds);

        return connection().query(sql).array().then((PgSqlConnection.Row[] rows) {
            // Build lookup map
            string[string] values;
            foreach (row; rows) {
                auto key = buildKeyFromRow(row, pkCount);
                auto val = row.column!string(cast(int) pkCount);
                values[key] = val;
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

        auto pkColumns = getPkColumnsForTable(table);
        auto pkCount = pkColumns.length;
        auto sql = buildFetchColumnSQL(table, column, validIds);

        return connection().query(sql).array().then((PgSqlConnection.Row[] rows) {
            // Build lookup map
            long[string] values;
            foreach (row; rows) {
                auto key = buildKeyFromRow(row, pkCount);
                auto val = row.column!long(cast(int) pkCount);
                values[key] = val;
            }
            // Return in ref order (invalid refs get 0)
            return refs.map!(r => r.isValid ? values.get(r.localId, 0L) : 0L).array;
        });
    }

    override Promise!(string[]) fetchAllIdsString(string table, string[] pkColumns) {
        import dunamis.core.types : encodeCompositeKey;

        auto sql = "SELECT " ~ pkColumns.join(", ") ~ " FROM " ~ table;

        auto numPkCols = pkColumns.length;
        return connection().query(sql).array().then((PgSqlConnection.Row[] rows) {
            return rows.map!((r) {
                if (numPkCols == 1) {
                    return r.column!string(0);
                }
                string[] parts;
                foreach (i; 0 .. numPkCols) {
                    parts ~= r.column!string(cast(int) i);
                }
                return encodeCompositeKey(parts);
            }).array;
        });
    }

    override Promise!(AnyRef[][]) fetchChildren(string childTable, string childType, string fk, AnyRef[] parentRefs,
            string[] orderBy = null) {
        // Use a CTE child layer if one holds exactly these children
        if (auto result = findChildLayer(_cachedResults, childType, fk, parentRefs)) {
            return resolve(result.getChildRefs(parentRefs));
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
        auto childPkColumns = getPkColumnsForTable(childTable);
        auto childPkCount = childPkColumns.length;
        auto sql = "SELECT " ~ childPkColumns.join(", ") ~ ", " ~ fk ~ " FROM " ~ childTable ~
                   " WHERE " ~ fk ~ " IN (" ~ validIds.join(",") ~ ")";
        if (orderBy.length)
            sql ~= " ORDER BY " ~ orderBy.join(", ");

        return connection().query(sql).array().then((PgSqlConnection.Row[] rows) {
            // Group children by parent
            AnyRef[][string] childrenByParent;
            foreach (row; rows) {
                auto childId = buildKeyFromRow(row, childPkCount);
                auto parentId = row.column!string(cast(int) childPkCount);
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
            if (result.hasColumn(fk) && result.containsAllRefs(childRefs)) {
                // Found the FK column in a result that actually contains our refs
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
        auto pkColumns = getPkColumnsForTable(childTable);
        auto pkCount = pkColumns.length;
        auto sql = buildFetchColumnSQL(childTable, fk, validIds);

        return connection().query(sql).array().then((PgSqlConnection.Row[] rows) {
            import std.typecons : Nullable;
            // Build lookup map
            string[string] fkValues;
            foreach (row; rows) {
                auto key = buildKeyFromRow(row, pkCount);
                // FK column may be NULL
                auto fkVal = row.column!(Nullable!string)(cast(int) pkCount);
                fkValues[key] = fkVal.isNull ? "" : fkVal.get;
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

        auto pkColumns = getPkColumnsForTable(table);
        auto pkCount = pkColumns.length;
        auto sql = buildFetchColumnSQL(table, column, validIds);

        return connection().query(sql).array().then((PgSqlConnection.Row[] rows) {
            // Build lookup map
            JSONValue[string] values;
            foreach (row; rows) {
                auto key = buildKeyFromRow(row, pkCount);
                auto valCol = cast(int) pkCount;
                // Try to get as string first, then as other types
                try {
                    auto val = row.column!string(valCol);
                    values[key] = JSONValue(val);
                } catch (Exception e) {
                    try {
                        auto val = row.column!long(valCol);
                        values[key] = JSONValue(val);
                    } catch (Exception e2) {
                        values[key] = JSONValue(null);
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

    import dunamis.relational.mutation : InsertInput, UpdateInput;
    import dunamis.postgres.sql : generateInsertSQL, generateUpdateSQL, generateDeleteSQL;

    /// Execute INSERT and return the new row.
    /// Values are embedded directly in the SQL (properly escaped).
    override Promise!QueryResult executeInsert(string table, string typeName, InsertInput input, string[] pkColumns, bool isAutoIncrement) {
        auto sql = generateInsertSQL(table, input);
        _cachedSQL = sql;

        // No parameters needed - values are embedded in SQL
        return connection().query(sql).array().then((PgSqlConnection.Row[] rows) {
            return parseInsertResult(rows, typeName, pkColumns);
        });
    }

    /// Execute UPDATE and return updated rows.
    /// Values are embedded directly in the SQL (properly escaped).
    override Promise!QueryResult executeUpdate(string table, string typeName, UpdateInput input, string[] pkColumns) {
        auto sql = generateUpdateSQL(table, input, pkColumns);
        _cachedSQL = sql;

        // No parameters needed - values are embedded in SQL
        return connection().query(sql).array().then((PgSqlConnection.Row[] rows) {
            return parseUpdateResult(rows, typeName, pkColumns);
        });
    }

    /// Execute DELETE and return count of deleted rows.
    /// IDs are embedded directly in the SQL.
    override Promise!int executeDelete(string table, string[] ids, string[] pkColumns) {
        auto sql = generateDeleteSQL(table, ids, pkColumns);
        _cachedSQL = sql;

        // No parameters needed - IDs are embedded in SQL
        return connection().query(sql).array().then((PgSqlConnection.Row[] rows) {
            if (rows.length > 0) {
                return rows[0].column!int(0);
            }
            return 0;
        });
    }

    /// Parse INSERT result (single row JSON).
    private QueryResult parseInsertResult(PgSqlConnection.Row[] rows, string typeName, string[] pkColumns) {
        auto result = new QueryResult();
        if (rows.length == 0) {
            return result;
        }

        auto jsonStr = rows[0].column!string(0);
        auto jsonData = parseJSON(jsonStr);

        // Single row - wrap in array for loadFromRows
        result.loadFromRows([jsonData], typeName, pkColumns);
        return result;
    }

    /// Parse UPDATE result (JSON array).
    private QueryResult parseUpdateResult(PgSqlConnection.Row[] rows, string typeName, string[] pkColumns) {
        auto result = new QueryResult();
        if (rows.length == 0) {
            return result;
        }

        auto jsonStr = rows[0].column!string(0);
        auto jsonData = parseJSON(jsonStr);

        // json_agg returns an array
        if (jsonData.type == JSONType.array) {
            result.loadFromRows(jsonData.array, typeName, pkColumns);
        }
        return result;
    }
}

// ============================================================================
// PostgreSQL Data Source (Singleton Factory)
// ============================================================================

/// PostgreSQL data source using ae.net.db.psql.
/// Holds a connection factory and creates per-request sessions.
/// Each session acquires its own connection from the factory.
///
/// Parameterized by DBConfig for compile-time feature configuration.
class PostgresDB(DBConfig config = defaultDBConfig) : DataSource {
    /// Configuration accessible at compile time
    enum configuration = config;

    private Promise!PgSqlConnection delegate() _connFactory;
    private SqlOptimizer _sqlOptimizer;
    private bool _disconnectSessions;
    private size_t _activeConnections;
    private size_t _maxConnections;
    private Promise!void[] _continuationWaiters;
    private Promise!void[] _connectionWaiters;

    /// Create with a connection factory. Each session will call the factory
    /// to acquire its own connection.
    this(Promise!PgSqlConnection delegate() connFactory,
            bool disconnectSessions = true, size_t maxConnections = 64) {
        _connFactory = connFactory;
        _disconnectSessions = disconnectSessions;
        _maxConnections = maxConnections;
        _sqlOptimizer = new SqlOptimizer(postgresDialect());
    }

    /// Create with a shared connection (wrapped as factory).
    /// Only safe when requests are processed serially (e.g., single-threaded tests).
    this(PgSqlConnection conn) {
        this(() => resolve(conn), false, 1);
    }

    /// Return the SqlOptimizer to enable SQL push-down
    override ExprOptimizer[] requestedOptimizers() {
        return [_sqlOptimizer];
    }

    /// Create a fresh per-request session.
    override DataSession createSession() {
        return new PostgresSession(_connFactory,
            _disconnectSessions, &acquireConnection, &releaseConnection);
    }

    private Promise!void acquireConnection(bool continuation) {
        if (_activeConnections < _maxConnections) {
            _activeConnections++;
            return resolve();
        }
        auto waiter = new Promise!void;
        if (continuation)
            _continuationWaiters ~= waiter;
        else
            _connectionWaiters ~= waiter;
        return waiter;
    }

    private void releaseConnection() {
        // A resumed session is already partway through a request and may
        // suspend several times around recursive extension calls. Admit those
        // continuations before starting more top-level work, otherwise a busy
        // server can indefinitely push a single request to the back of the
        // queue at every resume.
        if (_continuationWaiters.length) {
            auto waiter = _continuationWaiters[0];
            _continuationWaiters = _continuationWaiters[1 .. $];
            waiter.fulfill();
        } else if (_connectionWaiters.length) {
            auto waiter = _connectionWaiters[0];
            _connectionWaiters = _connectionWaiters[1 .. $];
            waiter.fulfill();
        } else if (_activeConnections) {
            _activeConnections--;
        }
    }
}

/// Create a PostgresDB instance from connection parameters.
/// Each session will create its own connection using these parameters.
PostgresDB!config createPostgresDB(DBConfig config = defaultDBConfig)(
    string host, ushort port, string database, string user, string password
) {
    import dunamis.postgres.connection : connect;

    return new PostgresDB!config(() => connect(host, port, database, user, password));
}

/// Create a PostgresDB instance from a connection string.
/// Each session will create its own connection using this URI.
PostgresDB!config createPostgresDBFromUri(DBConfig config = defaultDBConfig)(string uri) {
    import dunamis.postgres.connection : connectFromUri;

    return new PostgresDB!config(() => connectFromUri(uri));
}
