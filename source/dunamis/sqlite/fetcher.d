module dunamis.sqlite.fetcher;

import std.algorithm;
import std.array;
import std.conv;
import std.json;
import std.string;

import ae.sys.sqlite3 : SQLite;
import ae.utils.promise : Promise, resolve;

import dunamis.core.types : AnyRef, makeAnyRef;
import dunamis.core.optimize : ExprOptimizer;
import dunamis.core.expr : ExprBase;
import dunamis.core.datasource : DataSource, DataSession, SetupMode;
import dunamis.relational.eval_context;
import std.format : format;
import dunamis.relational.query_node;
import dunamis.relational.sql_optimizer;
import dunamis.sqlite.dialect : sqliteDialect;
import dunamis.relational.sql : toSQL;
import dunamis.sqlite.sql;

// ============================================================================
// SQLite Session (Per-Request)
// ============================================================================

/// Per-request session for SQLite.
/// Holds cached results and per-query state for a single evaluation.
class SQLiteSession : RelationalSession {
    private SQLite _db;
    private SqlOptimizer _sqlOptimizer;
    private QueryNode[] _executedNodes;
    private string _cachedSQL;
    private QueryResult[QueryNode] _cachedResults;
    private QueryResult[string] _cachedResultsByType;

    this(SQLite db, SqlOptimizer sqlOptimizer) {
        _db = db;
        _sqlOptimizer = sqlOptimizer;
    }

    /// Begin a transaction.
    override Promise!void setup(SetupMode mode = SetupMode.query) {
        super.setup(mode);
        _db.exec("BEGIN");
        return resolve();
    }

    /// Commit or rollback the transaction, then fire pending events.
    override Promise!void teardown(SetupMode mode = SetupMode.query, bool success = true) {
        _db.exec(success ? "COMMIT" : "ROLLBACK");
        return super.teardown(mode, success);
    }

    /// Execute raw SQL for session setup.
    override Promise!void execute(string sql) {
        _db.exec(sql);
        return resolve();
    }

    /// Get original expression for fallback evaluation (not used - real DB evaluates SQL)
    override ExprBase getOriginalExpr(string alias_) {
        return null;
    }

    /// Get the generated SQL (for debugging)
    @property string sql() { return _cachedSQL; }

    /// Execute a QueryNode by running SQL against SQLite.
    /// Returns an immediately resolved promise since SQLite is synchronous.
    override Promise!QueryResult executeQueryNode(QueryNode node, QueryResult parentResult) {
        // For child nodes, check if we already have cached results from root CTE execution
        if (!node.isRoot) {
            if (node in _cachedResults) {
                return resolve(_cachedResults[node]);
            }
            return resolve(new QueryResult());
        }

        // Root node: generate CTE for entire tree
        auto allNodes = node.allNodesInTree();
        _executedNodes = allNodes;

        // Generate the full CTE query
        auto sql = toSQL(allNodes, sqliteDialect(), _sqlOptimizer);

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
            writefln("SQLiteDB: Generating SQL for %d nodes:", allNodes.length);
            foreach (n; allNodes) {
                writefln("  - node %d: %s (%s)", n.id, n.typeName, n.table);
            }
            writeln("SQLiteDB: Generated SQL:");
            writeln(sql);
        }

        // Execute synchronously
        string jsonResult;
        foreach (cells, columns; _db.query(sql)) {
            if (cells.length > 0 && cells[0] !is null) {
                jsonResult = cells[0].idup;
            }
            break;  // Only one row expected
        }

        auto result = parseQueryResult(jsonResult, allNodes);
        return resolve(result);
    }

    /// Parse SQLite result into QueryResult.
    private QueryResult parseQueryResult(string jsonStr, QueryNode[] nodes) {
        if (jsonStr.length == 0) {
            return new QueryResult();
        }

        auto jsonData = parseJSON(jsonStr);

        // Parse each layer and cache results
        QueryResult rootResult;
        foreach (node; nodes) {
            auto layerKey = "layer" ~ node.id.value.to!string;
            if (layerKey in jsonData) {
                auto layerRows = jsonData[layerKey].array;
                auto result = new QueryResult();

                if (node.isRoot) {
                    result.loadFromRows(layerRows, node.typeName, node.pkColumns);
                    rootResult = result;
                    // Also cache root result so fetchBelongsTo can find FK columns
                    _cachedResults[node] = result;
                    _cachedResultsByType[node.typeName] = result;
                } else {
                    result.loadFromRows(layerRows, node.typeName, node.pkColumns,
                                                 node.parentFk, node.parentTypeName);
                    _cachedResults[node] = result;
                    _cachedResultsByType[node.typeName] = result;
                }
            }
        }

        return rootResult !is null ? rootResult : new QueryResult();
    }

    // =========================================================================
    // Individual fetch methods (for naive/fallback path)
    // SQLite is synchronous, so results are wrapped in resolve().
    // =========================================================================

    /// Generate SQL to fetch a column value, keyed by PK columns.
    /// For single PK: SELECT pk, column FROM table WHERE pk IN (...)
    /// For composite PK: SELECT pk1, pk2, ..., column FROM table WHERE (pk1=v1 AND pk2=v2) OR ...
    private string buildFetchColumnSQL(string table, string column, string[] validIds) {
        import dunamis.core.types : decodeCompositeKey;
        auto pkColumns = getPkColumnsForTable(table);

        if (pkColumns.length == 1) {
            auto idList = validIds.join(",");
            return format("SELECT %s, %s FROM %s WHERE %s IN (%s)",
                pkColumns[0], column, table, pkColumns[0], idList);
        } else {
            // Composite PK: build OR conditions
            auto dialect = sqliteDialect();
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

    /// Build composite key from result cells (PK columns come first in result)
    private string buildKeyFromCells(Cells)(Cells cells, size_t pkCount) {
        import dunamis.core.types : encodeCompositeKey;
        if (pkCount == 1) {
            return cells[0] !is null ? cells[0].idup : "";
        } else {
            string[] parts;
            foreach (i; 0 .. pkCount) {
                parts ~= cells[i] !is null ? cells[i].idup : "";
            }
            return encodeCompositeKey(parts);
        }
    }

    override Promise!(string[]) fetchColumnString(string table, string column, AnyRef[] refs) {
        if (refs.length == 0) {
            return resolve(cast(string[])[]);
        }

        // Collect unique valid IDs for query
        string[] validIds;
        bool[string] seen;
        foreach (r; refs) {
            if (r.isValid && r.localId.length > 0 && r.localId !in seen) {
                validIds ~= r.localId;
                seen[r.localId] = true;
            }
        }

        if (validIds.length == 0) {
            string[] result;
            result.length = refs.length;
            return resolve(result);
        }

        auto pkColumns = getPkColumnsForTable(table);
        auto sql = buildFetchColumnSQL(table, column, validIds);

        // Build value lookup map
        string[string] values;
        foreach (cells, columns; _db.query(sql)) {
            auto pkCount = pkColumns.length;
            if (cells.length > pkCount) {
                auto key = buildKeyFromCells(cells, pkCount);
                auto value = cells[pkCount] !is null ? cells[pkCount].idup : "";
                values[key] = value;
            }
        }

        // Return in ref order (handles duplicate refs correctly)
        return resolve(refs.map!(r => r.isValid ? values.get(r.localId, "") : "").array);
    }

    override Promise!(long[]) fetchColumnLong(string table, string column, AnyRef[] refs) {
        if (refs.length == 0) {
            return resolve(cast(long[])[]);
        }

        // Collect unique valid IDs for query
        string[] validIds;
        bool[string] seen;
        foreach (r; refs) {
            if (r.isValid && r.localId.length > 0 && r.localId !in seen) {
                validIds ~= r.localId;
                seen[r.localId] = true;
            }
        }

        if (validIds.length == 0) {
            long[] result;
            result.length = refs.length;
            return resolve(result);
        }

        auto pkColumns = getPkColumnsForTable(table);
        auto sql = buildFetchColumnSQL(table, column, validIds);

        // Build value lookup map
        long[string] values;
        foreach (cells, columns; _db.query(sql)) {
            auto pkCount = pkColumns.length;
            if (cells.length > pkCount) {
                auto key = buildKeyFromCells(cells, pkCount);
                auto valueStr = cells[pkCount] !is null ? cells[pkCount].idup : "0";
                values[key] = valueStr.to!long;
            }
        }

        // Return in ref order (handles duplicate refs correctly)
        return resolve(refs.map!(r => r.isValid ? values.get(r.localId, 0L) : 0L).array);
    }

    override Promise!(string[]) fetchAllIdsString(string table, string[] pkColumns) {
        import dunamis.core.types : encodeCompositeKey;

        auto sql = format("SELECT %s FROM %s", pkColumns.join(", "), table);
        string[] result;

        foreach (cells, columns; _db.query(sql)) {
            if (cells.length >= 1 && cells[0] !is null) {
                if (pkColumns.length == 1) {
                    result ~= cells[0].idup;
                } else {
                    string[] parts;
                    foreach (i; 0 .. pkColumns.length) {
                        parts ~= cells[i] !is null ? cells[i].idup : "";
                    }
                    result ~= encodeCompositeKey(parts);
                }
            }
        }

        return resolve(result);
    }

    override Promise!(AnyRef[][]) fetchChildren(string childTable, string childType, string fk, AnyRef[] parentRefs) {
        // Try cached results first (from optimized path)
        if (auto result = childType in _cachedResultsByType) {
            return resolve((*result).getChildRefs(parentRefs));
        }

        // Naive path: query the database directly
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

        AnyRef[][string] childrenByParentId;

        if (validIds.length > 0) {
            auto childPkColumns = getPkColumnsForTable(childTable);
            auto idList = validIds.join(",");
            auto sql = format("SELECT %s, %s FROM %s WHERE %s IN (%s)",
                childPkColumns.join(", "), fk, childTable, fk, idList);

            // Group children by parent FK
            foreach (cells, columns; _db.query(sql)) {
                auto pkCount = childPkColumns.length;
                if (cells.length > pkCount) {
                    auto childId = buildKeyFromCells(cells, pkCount);
                    auto parentId = cells[pkCount] !is null ? cells[pkCount].idup : "";
                    if (parentId.length > 0) {
                        childrenByParentId[parentId] ~= makeAnyRef(childType, childId);
                    }
                }
            }
        }

        // Map to result array (including empty arrays for invalid refs)
        AnyRef[][] result;
        result.reserve(parentRefs.length);
        foreach (parentRef; parentRefs) {
            if (parentRef.isValid && parentRef.localId.length > 0) {
                if (auto children = parentRef.localId in childrenByParentId) {
                    result ~= *children;
                } else {
                    result ~= cast(AnyRef[])[];
                }
            } else {
                result ~= cast(AnyRef[])[];  // Invalid parent ref -> empty children
            }
        }
        return resolve(result);
    }

    override Promise!(AnyRef[]) fetchBelongsTo(string childTable, string fk, string parentType, AnyRef[] childRefs) {
        if (childRefs.length == 0) {
            return resolve(cast(AnyRef[])[]);
        }

        // fk is already the SQL column name (from @SqlColumn UDA via getSqlColumn)
        // Try to get FK values from cached query results first
        // The FK column is included in the main query, so we can avoid an extra query
        foreach (result; _cachedResults.byValue) {
            if (result.hasColumn(fk) && result.containsAnyRef(childRefs)) {
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

        // Naive path fallback: query the database directly
        // Filter to valid refs only
        string[] validIds;
        foreach (r; childRefs) {
            if (r.isValid && r.localId.length > 0) {
                validIds ~= r.localId;
            }
        }

        if (validIds.length == 0) {
            return resolve(childRefs.map!(_ => AnyRef.init).array);
        }

        auto pkColumns = getPkColumnsForTable(childTable);
        auto sql = buildFetchColumnSQL(childTable, fk, validIds);

        // Build id -> fk value map from query results
        string[string] fkByChildId;
        foreach (cells, columns; _db.query(sql)) {
            auto pkCount = pkColumns.length;
            if (cells.length > pkCount) {
                auto key = buildKeyFromCells(cells, pkCount);
                auto fkValue = cells[pkCount] !is null ? cells[pkCount].idup : "";
                fkByChildId[key] = fkValue;
            }
        }

        // Map child refs to parent refs (including invalid refs)
        AnyRef[] result;
        result.reserve(childRefs.length);
        foreach (childRef; childRefs) {
            if (!childRef.isValid || childRef.localId.length == 0) {
                result ~= AnyRef.init;  // Invalid child ref -> null parent
            } else if (auto fkPtr = childRef.localId in fkByChildId) {
                if ((*fkPtr).length > 0) {
                    result ~= makeAnyRef(parentType, *fkPtr);
                } else {
                    result ~= AnyRef.init;
                }
            } else {
                result ~= AnyRef.init;
            }
        }
        return resolve(result);
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
        import std.exception : collectException;

        if (refs.length == 0) {
            return resolve(cast(JSONValue[])[]);
        }

        // Collect unique valid IDs for query
        string[] validIds;
        bool[string] seen;
        foreach (r; refs) {
            if (r.isValid && r.localId.length > 0 && r.localId !in seen) {
                validIds ~= r.localId;
                seen[r.localId] = true;
            }
        }

        if (validIds.length == 0) {
            JSONValue[] result;
            result.length = refs.length;
            foreach (ref r; result) r = JSONValue(null);
            return resolve(result);
        }

        auto pkColumns = getPkColumnsForTable(table);
        auto sql = buildFetchColumnSQL(table, column, validIds);

        // Build value lookup map
        JSONValue[string] values;
        foreach (cells, columns; _db.query(sql)) {
            auto pkCount = pkColumns.length;
            if (cells.length > pkCount) {
                auto key = buildKeyFromCells(cells, pkCount);
                if (cells[pkCount] is null) {
                    values[key] = JSONValue(null);
                } else {
                    auto val = cells[pkCount].idup;
                    // Try to parse as number, otherwise use string
                    long longVal;
                    if (!collectException(val.to!long, longVal)) {
                        values[key] = JSONValue(longVal);
                    } else {
                        values[key] = JSONValue(val);
                    }
                }
            }
        }

        // Return in ref order (handles duplicate refs correctly)
        return resolve(refs.map!(r => r.isValid ? values.get(r.localId, JSONValue(null)) : JSONValue(null)).array);
    }

    // =========================================================================
    // Mutation methods (INSERT/UPDATE/DELETE)
    // =========================================================================

    import dunamis.relational.mutation : InsertInput, UpdateInput;

    /// Execute INSERT and return the new row.
    /// SQLite is synchronous, so we return an immediately resolved promise.
    override Promise!QueryResult executeInsert(string table, string typeName, InsertInput input, string[] pkColumns, bool isAutoIncrement) {
        auto insertSql = generateInsertSQL(table, input);
        _cachedSQL = insertSql;

        // Execute INSERT
        _db.exec(insertSql);

        // Fetch the inserted row — use last_insert_rowid() for auto-increment,
        // otherwise use PK values from input
        string selectSql;
        if (isAutoIncrement) {
            selectSql = generateSelectLastInsertSQL(table);
        } else {
            selectSql = generateSelectByPkSQL(table, pkColumns, input);
        }
        auto result = new QueryResult();

        foreach (cells, columns; _db.query(selectSql)) {
            auto jsonRow = rowToJson(cells, columns);
            result.loadFromRows([jsonRow], typeName, pkColumns);
            break;
        }

        return resolve(result);
    }

    /// Execute UPDATE and return updated rows.
    override Promise!QueryResult executeUpdate(string table, string typeName, UpdateInput input, string[] pkColumns) {
        auto updateSql = generateUpdateSQL(table, input, pkColumns);
        _cachedSQL = updateSql;

        // Execute UPDATE
        _db.exec(updateSql);

        // Fetch the updated rows
        auto selectSql = generateSelectUpdatedSQL(table, input.ids, pkColumns);
        auto result = new QueryResult();

        JSONValue[] rows;
        foreach (cells, columns; _db.query(selectSql)) {
            rows ~= rowToJson(cells, columns);
        }

        if (rows.length > 0) {
            result.loadFromRows(rows, typeName, pkColumns);
        }

        return resolve(result);
    }

    /// Execute DELETE and return count of deleted rows.
    override Promise!int executeDelete(string table, string[] ids, string[] pkColumns) {
        auto deleteSql = generateDeleteSQL(table, ids, pkColumns);
        _cachedSQL = deleteSql;

        // Execute DELETE
        _db.exec(deleteSql);

        // Return the number of changes
        return resolve(_db.changes);
    }

    /// Convert a SQLite row to JSONValue
    private JSONValue rowToJson(scope const(char)[][] cells, scope const(char)[][] columns) {
        import std.exception : collectException;

        JSONValue obj = JSONValue.emptyObject;
        foreach (i, col; columns) {
            if (cells[i] is null) {
                obj[col.idup] = JSONValue(null);
            } else {
                // Try to parse as number, otherwise use string
                auto val = cells[i].idup;
                long longVal;
                double doubleVal;
                if (!collectException(val.to!long, longVal)) {
                    obj[col.idup] = JSONValue(longVal);
                } else if (!collectException(val.to!double, doubleVal)) {
                    obj[col.idup] = JSONValue(doubleVal);
                } else {
                    obj[col.idup] = JSONValue(val);
                }
            }
        }
        return obj;
    }
}

// ============================================================================
// SQLite Data Source (Singleton Factory)
// ============================================================================

/// SQLite data source using ae.sys.sqlite3.
/// Holds the database handle and creates per-request sessions.
///
/// Parameterized by DBConfig for compile-time feature configuration.
class SQLiteDB(DBConfig config = defaultDBConfig) : DataSource {
    /// Configuration accessible at compile time
    enum configuration = config;

    private SQLite _db;
    private SqlOptimizer _sqlOptimizer;

    this(SQLite db) {
        _db = db;
        _sqlOptimizer = new SqlOptimizer(sqliteDialect());
    }

    this(string filename) {
        _db = new SQLite(filename);
        _sqlOptimizer = new SqlOptimizer(sqliteDialect());
    }

    /// Return the SqlOptimizer to enable SQL push-down
    override ExprOptimizer[] requestedOptimizers() {
        return [_sqlOptimizer];
    }

    /// Create a fresh per-request session.
    override DataSession createSession() {
        return new SQLiteSession(_db, _sqlOptimizer);
    }
}

/// Create a SQLiteDB instance from a filename.
SQLiteDB!config createSQLiteDB(DBConfig config = defaultDBConfig)(string filename) {
    return new SQLiteDB!config(filename);
}

/// Create an in-memory SQLiteDB instance.
SQLiteDB!config createInMemorySQLiteDB(DBConfig config = defaultDBConfig)() {
    return new SQLiteDB!config(":memory:");
}
