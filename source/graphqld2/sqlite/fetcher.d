module graphqld2.sqlite.fetcher;

import std.algorithm;
import std.array;
import std.conv;
import std.json;
import std.string;

import ae.sys.sqlite3 : SQLite;
import ae.utils.promise : Promise, resolve;

import graphqld2.core.types : AnyRef, makeAnyRef;
import graphqld2.core.optimize : ExprOptimizer;
import graphqld2.core.expr : ExprBase;
import graphqld2.relational.eval_context;
import std.format : format;
import graphqld2.relational.query_node;
import graphqld2.relational.sql_optimizer;
import graphqld2.sqlite.dialect : sqliteDialect;
import graphqld2.sqlite.sql;

/// SQLite data fetcher using ae.sys.sqlite3.
/// Executes SQL generated from QueryNodes against a SQLite database.
///
/// Note: SQLite operations are synchronous, so promises are resolved immediately.
///
/// Parameterized by DBConfig for compile-time feature configuration.
class SQLiteDB(DBConfig config = defaultDBConfig) : DataFetcher {
    /// Configuration accessible at compile time
    enum configuration = config;

    private SQLite _db;
    private SqlOptimizer _sqlOptimizer;
    private QueryNode[] _executedNodes;
    private string _cachedSQL;
    private QueryResult[int] _cachedResults;
    private QueryResult[string] _cachedResultsByType;

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

    /// Get original expression for fallback evaluation (not used - real DB evaluates SQL)
    override ExprBase getOriginalExpr(string alias_) {
        return null;
    }

    /// Reset for next query
    void reset() {
        _executedNodes = [];
        _cachedSQL = "";
        _sqlOptimizer = new SqlOptimizer(sqliteDialect());
        _cachedResults.clear();
        _cachedResultsByType.clear();
    }

    /// Get the generated SQL (for debugging)
    @property string sql() { return _cachedSQL; }

    /// Execute a QueryNode by running SQL against SQLite.
    /// Returns an immediately resolved promise since SQLite is synchronous.
    override Promise!QueryResult executeQueryNode(QueryNode node, QueryResult parentResult) {
        // For child nodes, check if we already have cached results from root CTE execution
        if (!node.isRoot) {
            if (node.id in _cachedResults) {
                return resolve(_cachedResults[node.id]);
            }
            return resolve(new QueryResult());
        }

        // Root node: generate CTE for entire tree
        auto allNodes = node.allNodesInTree();
        _executedNodes = allNodes;

        // Generate the full CTE query
        auto sql = graphqld2.sqlite.sql.toSQL(allNodes, _sqlOptimizer);

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

        auto result = parseQueryResult(jsonResult, _executedNodes);
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
                    _cachedResults[node.id] = result;
                    _cachedResultsByType[node.typeName] = result;
                }
            }
        }

        return rootResult !is null ? rootResult : new QueryResult();
    }

    // =========================================================================
    // Individual fetch methods (for naive/fallback path)
    // =========================================================================

    override string[] fetchColumnString(string table, string column, AnyRef[] refs) {
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
        return [];
    }

    override AnyRef[][] fetchChildren(string childTable, string childType, string fk, AnyRef[] parentRefs) {
        if (auto result = childType in _cachedResultsByType) {
            return (*result).getChildRefs(parentRefs);
        }
        return parentRefs.map!(_ => cast(AnyRef[])[]).array;
    }

    override AnyRef[] fetchBelongsTo(string childTable, string fk, string parentType, AnyRef[] childRefs) {
        if (childRefs.length == 0) {
            return [];
        }

        // fk is already the SQL column name (from @SqlColumn UDA via getSqlColumn)
        // Try to get FK values from cached query results first
        // The FK column is included in the main query, so we can avoid an extra query
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
                return refs;
            }
        }

        // Naive path fallback: query the database directly
        auto idList = childRefs.map!(r => r.localId).join(",");
        if (idList.length == 0) {
            return childRefs.map!(_ => AnyRef.init).array;
        }

        auto sql = format("SELECT id, %s FROM %s WHERE id IN (%s)", fk, childTable, idList);

        // Build id -> fk value map from query results
        string[string] fkByChildId;
        foreach (cells, columns; _db.query(sql)) {
            if (cells.length >= 2) {
                auto childId = cells[0] !is null ? cells[0].idup : "";
                auto fkValue = cells[1] !is null ? cells[1].idup : "";
                fkByChildId[childId] = fkValue;
            }
        }

        // Map child refs to parent refs
        AnyRef[] result;
        result.reserve(childRefs.length);
        foreach (childRef; childRefs) {
            if (auto fkPtr = childRef.localId in fkByChildId) {
                if ((*fkPtr).length > 0) {
                    result ~= makeAnyRef(parentType, *fkPtr);
                } else {
                    result ~= AnyRef.init;
                }
            } else {
                result ~= AnyRef.init;
            }
        }
        return result;
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

    /// Execute INSERT and return the new row.
    /// SQLite is synchronous, so we return an immediately resolved promise.
    override Promise!QueryResult executeInsert(string table, string typeName, InsertInput input) {
        auto insertSql = generateInsertSQL(table, input);
        _cachedSQL = insertSql;

        // Execute INSERT
        _db.exec(insertSql);

        // Fetch the inserted row
        auto selectSql = generateSelectLastInsertSQL(table);
        auto result = new QueryResult();

        foreach (cells, columns; _db.query(selectSql)) {
            auto jsonRow = rowToJson(cells, columns);
            result.loadFromRows([jsonRow], typeName);
            break;
        }

        return resolve(result);
    }

    /// Execute UPDATE and return updated rows.
    override Promise!QueryResult executeUpdate(string table, string typeName, UpdateInput input) {
        auto updateSql = generateUpdateSQL(table, input);
        _cachedSQL = updateSql;

        // Execute UPDATE
        _db.exec(updateSql);

        // Fetch the updated rows
        auto selectSql = generateSelectUpdatedSQL(table, input.ids);
        auto result = new QueryResult();

        JSONValue[] rows;
        foreach (cells, columns; _db.query(selectSql)) {
            rows ~= rowToJson(cells, columns);
        }

        if (rows.length > 0) {
            result.loadFromRows(rows, typeName);
        }

        return resolve(result);
    }

    /// Execute DELETE and return count of deleted rows.
    override Promise!int executeDelete(string table, long[] ids) {
        auto deleteSql = generateDeleteSQL(table, ids);
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

/// Create a SQLiteDB instance from a filename.
SQLiteDB!config createSQLiteDB(DBConfig config = defaultDBConfig)(string filename) {
    return new SQLiteDB!config(filename);
}

/// Create an in-memory SQLiteDB instance.
SQLiteDB!config createInMemorySQLiteDB(DBConfig config = defaultDBConfig)() {
    return new SQLiteDB!config(":memory:");
}
