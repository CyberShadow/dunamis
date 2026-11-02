module dunamis.sqlite.fetcher;

import dunamis.relational.native : SqlDataSource;
import dunamis.relational.sql_dialect : SqlDialect;
import dunamis.relational.sql_fragment : Sql, SqlName, sql;
import std.algorithm;
import std.array;
import std.conv;
import std.json;
import std.string;

import ae.sys.sqlite3 : SQLite;
import ae.utils.promise : Promise, resolve;

import dunamis.core.types : AnyRef, makeAnyRef;
import dunamis.relational.keys : keyOf, keyOfTexts, keyValues, singleKeyValue;
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
    private string _cachedSQL;

    this(SQLite db) {
        _db = db;
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
    override Promise!void execute(Sql statement) {
        _db.exec(statement.render(sqliteDialect()));
        return resolve();
    }

    /// Get the generated SQL (for debugging)
    @property string lastSql() { return _cachedSQL; }

    /// Execute a QueryNode by running SQL against SQLite.
    /// Returns an immediately resolved promise since SQLite is synchronous.
    override Promise!QueryResult executeQueryNode(QueryNode node, QueryResult parentResult,
            RootSelection root) {
        // For child nodes, check if we already have cached results from root CTE execution
        if (!node.isRoot) {
            if (auto result = getQueryResult(node.id)) {
                return resolve(result);
            }
            return resolve(new QueryResult());
        }

        // Root node: generate CTE for entire tree
        auto allNodes = node.allNodesInTree();

        // Generate the full CTE query (of the root rows' keys, if it
        // selects them by their keys)
        Sql ids;
        if (root.filter == FilterType.byId || root.filter == FilterType.byIds)
            ids = idList(root.refs.map!(r => r.localId).array);
        auto sql = toSQL(allNodes, sqliteDialect(), root.filter, ids).render(sqliteDialect());

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

        // Parse each layer and cache results (root results too, so that
        // fetchBelongsTo can find FK columns)
        return storeLayers(jsonData, nodes);
    }

    // =========================================================================
    // Individual fetch methods (for naive/fallback path)
    // SQLite is synchronous, so results are wrapped in resolve().
    // =========================================================================

    /// Generate SQL to fetch a column value, keyed by PK columns.
    /// For single PK: SELECT pk, column FROM table WHERE pk IN (...)
    /// For composite PK: SELECT pk1, pk2, ..., column FROM table WHERE (pk1=v1 AND pk2=v2) OR ...
    private string buildFetchColumnSQL(string table, string column, string[] validIds) {
        auto pkColumns = getPkColumnsForTable(table);
        auto from = SqlName(table), value = SqlName(column);

        if (pkColumns.length == 1) {
            auto pk = SqlName(pkColumns[0]);
            return sql(i"SELECT $(pk), $(value) FROM $(from) WHERE $(pk) IN ($(idList(validIds)))").render(sqliteDialect());
        } else {
            // Composite PK: build OR conditions
            Sql[] conditions;
            foreach (id; validIds) {
                auto parts = keyValues(id);
                Sql[] eqs;
                foreach (i, col; pkColumns)
                    eqs ~= sql(i"$(SqlName(col)) = $(i < parts.length ? parts[i] : "")");
                conditions ~= sql(i"($(Sql.join!" AND "(eqs)))");
            }
            auto where = Sql.join!" OR "(conditions);
            return sql(i"SELECT $(columnList(pkColumns)), $(value) FROM $(from) WHERE $(where)").render(sqliteDialect());
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

    /// Build composite key from result cells (PK columns come first in result)
    private string buildKeyFromCells(Cells)(Cells cells, size_t pkCount) {
        auto parts = new string[pkCount];
        foreach (i; 0 .. pkCount)
            parts[i] = cells[i] !is null ? cells[i].idup : "";
        return keyOfTexts(parts);
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

    override Promise!(string[]) fetchAllIdsString(string table, string[] pkColumns, string[] orderBy = null) {
        auto query = sql(i"SELECT $(columnList(pkColumns)) FROM $(SqlName(table))");
        if (orderBy.length)
            query = sql(i"$(query) ORDER BY $(columnList(orderBy))");
        string[] result;

        foreach (cells, columns; _db.query(query.render(sqliteDialect()))) {
            if (cells.length >= 1 && cells[0] !is null)
                result ~= buildKeyFromCells(cells, pkColumns.length);
        }

        return resolve(result);
    }

    override Promise!(AnyRef[][]) fetchChildren(string childTable, string childType, string fk, AnyRef[] parentRefs,
            string[] orderBy = null) {
        // Use a CTE child layer if one holds exactly these children
        if (auto result = storedChildLayer(childType, fk, parentRefs)) {
            return resolve(result.getChildRefs(parentRefs));
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
            auto fkColumn = SqlName(fk);
            auto children = sql(i"SELECT $(columnList(childPkColumns)), $(fkColumn) FROM $(SqlName(childTable))");
            auto query = sql(i"$(children) WHERE $(fkColumn) IN ($(idList(validIds)))");
            if (orderBy.length)
                query = sql(i"$(query) ORDER BY $(columnList(orderBy))");

            // Group children by parent FK
            foreach (cells, columns; _db.query(query.render(sqliteDialect()))) {
                auto pkCount = childPkColumns.length;
                if (cells.length > pkCount) {
                    auto childId = buildKeyFromCells(cells, pkCount);
                    auto parentId = cells[pkCount] !is null ? cells[pkCount].idup : "";
                    if (parentId.length > 0) {
                        childrenByParentId[keyOfTexts([parentId])] ~= makeAnyRef(childType, childId);
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
        if (auto parents = storedParents(fk, parentType, childRefs))
            return resolve(parents);

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
                    result ~= makeAnyRef(parentType, keyOfTexts([*fkPtr]));
                } else {
                    result ~= AnyRef.init;
                }
            } else {
                result ~= AnyRef.init;
            }
        }
        return resolve(result);
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
        auto insertSql = generateInsertSQL(table, input).render(sqliteDialect());
        _cachedSQL = insertSql;

        // Execute INSERT
        _db.exec(insertSql);

        // Fetch the inserted row — use last_insert_rowid() for auto-increment,
        // otherwise use PK values from input
        auto selectSql = (isAutoIncrement ? generateSelectLastInsertSQL(table)
            : generateSelectByPkSQL(table, pkColumns, input)).render(sqliteDialect());
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
        auto updateSql = generateUpdateSQL(table, input, pkColumns).render(sqliteDialect());
        _cachedSQL = updateSql;

        // Execute UPDATE
        _db.exec(updateSql);

        // Fetch the updated rows
        auto selectSql = generateSelectUpdatedSQL(table, input.ids, pkColumns).render(sqliteDialect());
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
        auto deleteSql = generateDeleteSQL(table, ids, pkColumns).render(sqliteDialect());
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
class SQLiteDB(DBConfig config = defaultDBConfig) : DataSource, SqlDataSource {
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
    /// The dialect of the database's queries
    @property SqlDialect sqlDialect() {
        return sqliteDialect();
    }

    override ExprOptimizer[] requestedOptimizers() {
        return [_sqlOptimizer];
    }

    /// Create a fresh per-request session.
    override DataSession createSession() {
        return new SQLiteSession(_db);
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
