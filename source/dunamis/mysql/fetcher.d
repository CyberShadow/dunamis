module dunamis.mysql.fetcher;

import dunamis.relational.native : SqlDataSource;
import dunamis.relational.sql_dialect : SqlDialect;
import dunamis.relational.sql_fragment : Sql, SqlName, sql;
import std.algorithm;
import std.array;
import std.conv;
import std.json;
import std.string;

import ae.net.db.mysql;
import ae.utils.promise;

import dunamis.core.types : AnyRef, makeAnyRef;
import dunamis.relational.keys : keyOf, keyOfTexts, keyValues, singleKeyValue;
import dunamis.core.optimize : ExprOptimizer;
import dunamis.core.expr : ExprBase;
import dunamis.core.datasource : DataSource, DataSession, SetupMode;
import dunamis.relational.eval_context;
import dunamis.relational.query_node;
import dunamis.relational.sql_optimizer;
import dunamis.mysql.dialect : mysqlDialect;
import dunamis.relational.sql : toSQL;
import dunamis.mysql.sql;

// ============================================================================
// MySQL Session (Per-Request)
// ============================================================================

/// Per-request session for MySQL.
/// Holds cached results and per-query state for a single evaluation.
class MySQLSession : RelationalSession {
    private MySqlConnection _conn;
    private Promise!MySqlConnection delegate() _connFactory;
    private string _cachedSQL;

    /// Create with a connection factory. The factory is called in setup().
    this(Promise!MySqlConnection delegate() connFactory) {
        _connFactory = connFactory;
    }

    /// Acquire connection and begin a transaction.
    override Promise!void setup(SetupMode mode = SetupMode.query) {
        super.setup(mode);
        return _connFactory().then((MySqlConnection conn) {
            _conn = conn;
            return _conn.query("BEGIN").array();
        }).then((MySqlConnection.Row[] _) { });
    }

    /// Commit or rollback the transaction, then fire pending events.
    override Promise!void teardown(SetupMode mode = SetupMode.query, bool success = true) {
        if (_conn is null) return resolve();  // setup failed
        auto sql = success ? "COMMIT" : "ROLLBACK";
        return _conn.query(sql).array().then((MySqlConnection.Row[] _) {
            return super.teardown(mode, success);
        });
    }

    /// Execute raw SQL for session setup.
    override Promise!void execute(Sql statement) {
        return _conn.query(statement.render(mysqlDialect())).array().then((MySqlConnection.Row[] _) { });
    }

    /// Get the generated SQL (for debugging)
    @property string lastSql() { return _cachedSQL; }

    /// Execute a QueryNode by running SQL against MySQL.
    override Promise!QueryResult executeQueryNode(QueryNode node, QueryResult parentResult,
            RootSelection root) {
        // For child nodes, check if we already have cached results from root CTE execution
        if (!node.isRoot) {
            if (auto result = getQueryResult(node.id)) {
                return resolve(result);
            }
            // Child nodes should be fetched as part of root CTE execution
            // If we get here without cached results, something is wrong
            return resolve(new QueryResult());
        }

        // Root node: generate CTE for entire tree (including all children)
        auto allNodes = node.allNodesInTree();

        // Generate the full CTE query for entire node tree (of the root
        // rows' keys, if it selects them by their keys)
        Sql ids;
        if (root.filter == FilterType.byId || root.filter == FilterType.byIds)
            ids = idList(root.refs.map!(r => r.localId).array);
        auto sql = toSQL(allNodes, mysqlDialect(), root.filter, ids).render(mysqlDialect());

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
            return parseQueryResult(rows, allNodes);
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

        // Parse each layer and cache results (root results too, so that
        // fetchBelongsTo can find FK columns)
        return storeLayers(jsonData, nodes);
    }

    // =========================================================================
    // Individual fetch methods (for naive/fallback path)
    // These return Promises to support async database operations.
    // =========================================================================

    /// Generate SQL to fetch a column value, keyed by PK columns.
    private string buildFetchColumnSQL(string table, string column, string[] validIds) {
        auto pkColumns = getPkColumnsForTable(table);
        auto from = SqlName(table), value = SqlName(column);

        if (pkColumns.length == 1) {
            auto pk = SqlName(pkColumns[0]);
            return sql(i"SELECT $(pk), $(value) FROM $(from) WHERE $(pk) IN ($(idList(validIds)))").render(mysqlDialect());
        } else {
            Sql[] conditions;
            foreach (id; validIds) {
                auto parts = keyValues(id);
                Sql[] eqs;
                foreach (i, col; pkColumns)
                    eqs ~= sql(i"$(SqlName(col)) = $(i < parts.length ? parts[i] : "")");
                conditions ~= sql(i"($(Sql.join!" AND "(eqs)))");
            }
            auto where = Sql.join!" OR "(conditions);
            return sql(i"SELECT $(columnList(pkColumns)), $(value) FROM $(from) WHERE $(where)").render(mysqlDialect());
        }
    }

    /// The values of the single-column keys `ids`, as a list of literals.
    private static Sql idList(string[] ids) {
        return Sql.join!","(ids.map!(id => sql(i"$(singleKeyValue(id))")).array);
    }

    /// The columns `columns` (as the schema names them), comma-separated.
    private static Sql columnList(string[] columns) {
        return Sql.join!", "(columns.map!(c => sql(i"$(SqlName(c))")).array);
    }

    /// The key of a row of a result (its key columns come first, see
    /// `dunamis.relational.keys`).
    private static string buildKeyFromRow(MySqlConnection.Row row, size_t pkCount) {
        auto parts = new string[pkCount];
        foreach (i; 0 .. pkCount)
            parts[i] = row.column!string(cast(int) i);
        return keyOfTexts(parts);
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

        return _conn.query(sql).array().then((MySqlConnection.Row[] rows) {
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

        return _conn.query(sql).array().then((MySqlConnection.Row[] rows) {
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

    override Promise!(string[]) fetchAllIdsString(string table, string[] pkColumns, string[] orderBy = null) {
        auto query = sql(i"SELECT $(columnList(pkColumns)) FROM $(SqlName(table))");
        if (orderBy.length)
            query = sql(i"$(query) ORDER BY $(columnList(orderBy))");

        auto numPkCols = pkColumns.length;
        return _conn.query(query.render(mysqlDialect())).array().then((MySqlConnection.Row[] rows) {
            return rows.map!(r => buildKeyFromRow(r, numPkCols)).array;
        });
    }

    override Promise!(AnyRef[][]) fetchChildren(string childTable, string childType, string fk, AnyRef[] parentRefs,
            string[] orderBy = null) {
        // Use a CTE child layer if one holds exactly these children
        if (auto result = storedChildLayer(childType, fk, parentRefs)) {
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
        auto fkColumn = SqlName(fk);
        auto children = sql(i"SELECT $(columnList(childPkColumns)), $(fkColumn) FROM $(SqlName(childTable))");
        auto query = sql(i"$(children) WHERE $(fkColumn) IN ($(idList(validIds)))");
        if (orderBy.length)
            query = sql(i"$(query) ORDER BY $(columnList(orderBy))");

        return _conn.query(query.render(mysqlDialect())).array().then((MySqlConnection.Row[] rows) {
            // Group children by parent
            AnyRef[][string] childrenByParent;
            foreach (row; rows) {
                auto childId = buildKeyFromRow(row, childPkCount);
                auto parentId = keyOfTexts([row.column!string(cast(int) childPkCount)]);
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
        if (auto parents = storedParents(fk, parentType, childRefs))
            return resolve(parents);

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

        return _conn.query(sql).array().then((MySqlConnection.Row[] rows) {
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
                        result ~= makeAnyRef(parentType, keyOfTexts([fkVal]));
                    } else {
                        result ~= AnyRef.init;
                    }
                }
            }
            return result;
        });
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

        return _conn.query(sql).array().then((MySqlConnection.Row[] rows) {
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

    /// Execute INSERT and return the new row.
    /// MySQL doesn't have RETURNING, so we use LAST_INSERT_ID() or PK values.
    override Promise!QueryResult executeInsert(string table, string typeName, InsertInput input, string[] pkColumns, bool isAutoIncrement) {
        auto insertSql = generateInsertSQL(table, input).render(mysqlDialect());
        _cachedSQL = insertSql;

        auto columns = input.columns;  // Capture for closure

        // Execute INSERT and fetch the inserted row as JSON
        return _conn.query(insertSql).array().then((MySqlConnection.Row[] _) {
            // Use LAST_INSERT_ID() for auto-increment, otherwise use PK values from input
            auto selectSql = (isAutoIncrement ? generateSelectLastInsertSQL(table, columns)
                : generateSelectByPkSQL(table, pkColumns, columns, input)).render(mysqlDialect());
            return _conn.query(selectSql).array();
        }).then((MySqlConnection.Row[] rows) {
            return parseJsonResult(rows, typeName, pkColumns);
        });
    }

    /// Execute UPDATE and return updated rows.
    override Promise!QueryResult executeUpdate(string table, string typeName, UpdateInput input, string[] pkColumns) {
        auto updateSql = generateUpdateSQL(table, input, pkColumns).render(mysqlDialect());
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
            auto selectSql = generateSelectUpdatedSQL(table, ids, columns, pkColumns).render(mysqlDialect());
            return _conn.query(selectSql).array();
        }).then((MySqlConnection.Row[] rows) {
            return parseJsonResult(rows, typeName, pkColumns);
        });
    }

    /// Execute DELETE and return count of deleted rows.
    override Promise!int executeDelete(string table, string[] ids, string[] pkColumns) {
        auto deleteSql = generateDeleteSQL(table, ids, pkColumns).render(mysqlDialect());
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
    private QueryResult parseJsonResult(MySqlConnection.Row[] rows, string typeName, string[] pkColumns) {
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

        result.loadFromRows(jsonRows, typeName, pkColumns);
        return result;
    }
}

// ============================================================================
// MySQL Data Source (Singleton Factory)
// ============================================================================

/// MySQL data source using ae.net.db.mysql.
/// Holds a connection factory and creates per-request sessions.
/// Each session acquires its own connection from the factory.
///
/// Parameterized by DBConfig for compile-time feature configuration.
class MySQLDB(DBConfig config = defaultDBConfig) : DataSource, SqlDataSource {
    /// Configuration accessible at compile time
    enum configuration = config;

    private Promise!MySqlConnection delegate() _connFactory;
    private SqlOptimizer _sqlOptimizer;

    /// Create with a connection factory. Each session will call the factory
    /// to acquire its own connection.
    this(Promise!MySqlConnection delegate() connFactory) {
        _connFactory = connFactory;
        _sqlOptimizer = new SqlOptimizer(mysqlDialect());
    }

    /// Create with a shared connection (wrapped as factory).
    /// Only safe when requests are processed serially (e.g., single-threaded tests).
    this(MySqlConnection conn) {
        this(() => resolve(conn));
    }

    /// Return the SqlOptimizer to enable SQL push-down
    /// The dialect of the database's queries
    @property SqlDialect sqlDialect() {
        return mysqlDialect();
    }

    override ExprOptimizer[] requestedOptimizers() {
        return [_sqlOptimizer];
    }

    /// Create a fresh per-request session.
    override DataSession createSession() {
        return new MySQLSession(_connFactory);
    }
}

/// Create a MySQLDB instance from connection parameters.
/// Each session will create its own connection using these parameters.
MySQLDB!config createMySQLDB(DBConfig config = defaultDBConfig)(
    string host, ushort port, string database, string user, string password
) {
    import dunamis.mysql.connection : connect;

    return new MySQLDB!config(() => connect(host, port, database, user, password));
}

/// Create a MySQLDB instance from environment variables.
/// Each session will create its own connection from environment variables.
MySQLDB!config createMySQLDBFromEnv(DBConfig config = defaultDBConfig)() {
    import dunamis.mysql.connection : connectFromEnv;

    return new MySQLDB!config(() => connectFromEnv());
}

/// Create a MySQLDB instance from a connection string.
/// Each session will create its own connection using this URI.
MySQLDB!config createMySQLDBFromUri(DBConfig config = defaultDBConfig)(string uri) {
    import dunamis.mysql.connection : connectFromUri;

    return new MySQLDB!config(() => connectFromUri(uri));
}
