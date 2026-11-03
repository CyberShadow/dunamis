module dunamis.sqlite.fetcher;

import dunamis.relational.native : SqlDataSource;
import dunamis.relational.sql_dialect : SqlDialect;
import dunamis.relational.sql_fragment : Sql, SqlName, SqlValue, sql;
import std.algorithm;
import std.array;
import std.conv;
import std.json;
import std.string;

import ae.net.db.sqlite : Param, SqliteConnection, SqliteRow = Row;
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
    private Promise!SqliteConnection _connection;
    private SqliteConnection _conn;
    private SessionTurns _turns;
    private Promise!void _turn;
    private string _cachedSQL;

    this(Promise!SqliteConnection connection, SessionTurns turns) {
        _connection = connection;
        _turns = turns;
    }

    /// Begin a transaction (once the sessions before it ended theirs).
    override Promise!void setup(SetupMode mode = SetupMode.query) {
        super.setup(mode);
        auto previous = _turns.last;
        _turn = _turns.last = new Promise!void;
        return previous.then(() => _connection).then((SqliteConnection conn) {
            _conn = conn;
            return _conn.query("BEGIN").array();
        }).then((SqliteRow[] _) { });
    }

    /// Commit or rollback the transaction (letting the next session begin
    /// its own), then fire pending events.
    override Promise!void teardown(SetupMode mode = SetupMode.query, bool success = true) {
        auto turn = _turn;
        _turn = null;
        void endTurn() {
            if (turn !is null)
                turn.fulfill();
        }
        if (_conn is null) {  // setup failed
            endTurn();
            return resolve();
        }
        return _conn.query(success ? "COMMIT" : "ROLLBACK").array().then((SqliteRow[] _) {
            endTurn();
            return super.teardown(mode, success);
        }, (Exception e) {
            endTurn();
            throw e;
            return resolve();
        });
    }

    /// Execute the statement `statement`.
    override Promise!void execute(Sql statement) {
        return run(statement).then((SqliteRow[] _) { });
    }

    /// Run the statement `statement`, whose values are its parameters (see
    /// `Sql.render`, and `sqliteParam`). Returns its rows (and tells
    /// `affected`, if not null, the number of rows it affected).
    private Promise!(SqliteRow[]) run(Sql statement, void delegate(ulong) affected = null) {
        auto bound = statement.render(sqliteDialect());
        auto result = bound.params.length
            ? _conn.query(bound.text, bound.params.map!(v => sqliteParam(v)).array)
            : _conn.query(bound.text);
        return result.array().then((SqliteRow[] rows) {
            if (affected !is null)
                affected(result.affectedRows);
            return rows;
        });
    }

    /// The values of the cells of the row `row`, as text (null: NULL).
    private static string[] cellsOf(SqliteRow row) {
        auto cells = new string[row.length];
        foreach (i, ref cell; cells)
            if (!row.isNull(i)) {
                cell = row.column!string(i);
                if (cell is null)
                    cell = "";
            }
        return cells;
    }

    /// The value `value` as a parameter: as its literal would be (SQLite's
    /// booleans are integers, JSON arrays and objects their JSON text).
    private static Param sqliteParam(const SqlValue value) {
        import std.json : JSONType;
        final switch (value.kind) {
            case SqlValue.Kind.null_: return Param.init;
            case SqlValue.Kind.boolean: return Param.of(value.text == "true" ? 1 : 0);
            case SqlValue.Kind.number:
                return value.isInteger ? Param.of(value.text.to!long) : Param.of(value.text.to!double);
            case SqlValue.Kind.text: return Param.of(value.text);
            case SqlValue.Kind.array: assert(false, "SQLite has no arrays");
            case SqlValue.Kind.json:
                auto json = value.json;
                final switch (json.type) {
                    case JSONType.null_: return Param.init;
                    case JSONType.string: return Param.of(json.str);
                    case JSONType.integer: return Param.of(json.integer);
                    case JSONType.uinteger: return Param.of(cast(long) json.uinteger);
                    case JSONType.float_: return Param.of(json.floating);
                    case JSONType.true_: return Param.of(1);
                    case JSONType.false_: return Param.of(0);
                    case JSONType.array:
                    case JSONType.object: return Param.of(json.toString());
                }
        }
    }

    /// Get the generated SQL (for debugging)
    @property string lastSql() { return _cachedSQL; }

    /// Execute a QueryNode by running SQL against SQLite.
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
        SqlValue[] ids;
        if (root.filter == FilterType.byId || root.filter == FilterType.byIds)
            ids = root.refs.map!(r => SqlValue.of(singleKeyValue(r.localId))).array;
        auto statement = toSQL(allNodes, sqliteDialect(), root.filter, ids);
        auto sql = statement.renderInline(sqliteDialect());

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

        return run(statement).then((SqliteRow[] rows) {
            string jsonResult;
            if (rows.length && rows[0].length && !rows[0].isNull(0))
                jsonResult = rows[0].column!string(0);  // (Only one row expected)
            return parseQueryResult(jsonResult, allNodes);
        });
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
    // =========================================================================

    /// Generate SQL to fetch a column value, keyed by PK columns.
    /// For single PK: SELECT pk, column FROM table WHERE pk IN (...)
    /// For composite PK: SELECT pk1, pk2, ..., column FROM table WHERE (pk1=v1 AND pk2=v2) OR ...
    private Sql buildFetchColumnSQL(string table, string column, string[] validIds) {
        auto pkColumns = getPkColumnsForTable(table);
        auto from = SqlName(table), value = SqlName(column);

        if (pkColumns.length == 1) {
            auto pk = SqlName(pkColumns[0]);
            return sql(i"SELECT $(pk), $(value) FROM $(from) WHERE $(pk) IN ($(idList(validIds)))");
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
            return sql(i"SELECT $(columnList(pkColumns)), $(value) FROM $(from) WHERE $(where)");
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

        return run(sql).then((SqliteRow[] rows) {
            // Build value lookup map
            string[string] values;
            foreach (row; rows) {
                auto cells = cellsOf(row);
                auto pkCount = pkColumns.length;
                if (cells.length > pkCount) {
                    auto key = buildKeyFromCells(cells, pkCount);
                    auto value = cells[pkCount] !is null ? cells[pkCount] : "";
                    values[key] = value;
                }
            }

            // Return in ref order (handles duplicate refs correctly)
            return refs.map!(r => r.isValid ? values.get(r.localId, "") : "").array;
        });
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

        return run(sql).then((SqliteRow[] rows) {
            // Build value lookup map
            long[string] values;
            foreach (row; rows) {
                auto cells = cellsOf(row);
                auto pkCount = pkColumns.length;
                if (cells.length > pkCount) {
                    auto key = buildKeyFromCells(cells, pkCount);
                    auto valueStr = cells[pkCount] !is null ? cells[pkCount] : "0";
                    values[key] = valueStr.to!long;
                }
            }

            // Return in ref order (handles duplicate refs correctly)
            return refs.map!(r => r.isValid ? values.get(r.localId, 0L) : 0L).array;
        });
    }

    override Promise!(string[]) fetchAllIdsString(string table, string[] pkColumns, string[] orderBy = null) {
        auto query = sql(i"SELECT $(columnList(pkColumns)) FROM $(SqlName(table))");
        if (orderBy.length)
            query = sql(i"$(query) ORDER BY $(columnList(orderBy))");
        return run(query).then((SqliteRow[] rows) {
            string[] result;
            foreach (row; rows) {
                auto cells = cellsOf(row);
                if (cells.length >= 1 && cells[0] !is null)
                    result ~= buildKeyFromCells(cells, pkColumns.length);
            }
            return result;
        });
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

        /// Map to result array (including empty arrays for invalid refs)
        AnyRef[][] mapToParents() {
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
            return result;
        }

        if (validIds.length == 0)
            return resolve(mapToParents());

        auto childPkColumns = getPkColumnsForTable(childTable);
        auto fkColumn = SqlName(fk);
        auto children = sql(i"SELECT $(columnList(childPkColumns)), $(fkColumn) FROM $(SqlName(childTable))");
        auto query = sql(i"$(children) WHERE $(fkColumn) IN ($(idList(validIds)))");
        if (orderBy.length)
            query = sql(i"$(query) ORDER BY $(columnList(orderBy))");

        return run(query).then((SqliteRow[] rows) {
            // Group children by parent FK
            foreach (row; rows) {
                auto cells = cellsOf(row);
                auto pkCount = childPkColumns.length;
                if (cells.length > pkCount) {
                    auto childId = buildKeyFromCells(cells, pkCount);
                    auto parentId = cells[pkCount] !is null ? cells[pkCount] : "";
                    if (parentId.length > 0) {
                        childrenByParentId[keyOfTexts([parentId])] ~= makeAnyRef(childType, childId);
                    }
                }
            }
            return mapToParents();
        });
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

        return run(sql).then((SqliteRow[] rows) {
            // Build id -> fk value map from query results
            string[string] fkByChildId;
            foreach (row; rows) {
                auto cells = cellsOf(row);
                auto pkCount = pkColumns.length;
                if (cells.length > pkCount) {
                    auto key = buildKeyFromCells(cells, pkCount);
                    auto fkValue = cells[pkCount] !is null ? cells[pkCount] : "";
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
            return result;
        });
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

        return run(sql).then((SqliteRow[] rows) {
            // Build value lookup map
            JSONValue[string] values;
            foreach (row; rows) {
                auto cells = cellsOf(row);
                auto pkCount = pkColumns.length;
                if (cells.length > pkCount) {
                    auto key = buildKeyFromCells(cells, pkCount);
                    if (cells[pkCount] is null) {
                        values[key] = JSONValue(null);
                    } else {
                        auto val = cells[pkCount];
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
            return refs.map!(r => r.isValid ? values.get(r.localId, JSONValue(null)) : JSONValue(null)).array;
        });
    }

    // =========================================================================
    // Mutation methods (INSERT/UPDATE/DELETE)
    // =========================================================================

    import dunamis.relational.mutation : InsertInput, UpdateInput;

    /// Execute INSERT and return the new row.
    override Promise!QueryResult executeInsert(string table, string typeName, InsertInput input, string[] pkColumns, bool isAutoIncrement) {
        auto insertSql = generateInsertSQL(table, input);
        _cachedSQL = insertSql.renderInline(sqliteDialect());

        // Execute INSERT, then fetch the inserted row — use
        // last_insert_rowid() for auto-increment, otherwise use PK values
        // from input (the session's transaction is the connection's only
        // one, see `SessionTurns`)
        return run(insertSql).then((SqliteRow[] _) {
            auto selectSql = (isAutoIncrement ? generateSelectLastInsertSQL(table)
                : generateSelectByPkSQL(table, pkColumns, input));
            return run(selectSql);
        }).then((SqliteRow[] rows) {
            auto result = new QueryResult();
            if (rows.length)
                result.loadFromRows([rowToJson(rows[0])], typeName, pkColumns);
            return result;
        });
    }

    /// Execute UPDATE and return updated rows.
    override Promise!QueryResult executeUpdate(string table, string typeName, UpdateInput input, string[] pkColumns) {
        auto updateSql = generateUpdateSQL(table, input, pkColumns);
        _cachedSQL = updateSql.renderInline(sqliteDialect());

        // Execute UPDATE, then fetch the updated rows
        return run(updateSql).then((SqliteRow[] _) {
            return run(generateSelectUpdatedSQL(table, input.ids, pkColumns));
        }).then((SqliteRow[] rows) {
            auto result = new QueryResult();
            if (rows.length > 0)
                result.loadFromRows(rows.map!(row => rowToJson(row)).array, typeName, pkColumns);
            return result;
        });
    }

    /// Execute DELETE and return count of deleted rows.
    override Promise!int executeDelete(string table, string[] ids, string[] pkColumns) {
        auto deleteSql = generateDeleteSQL(table, ids, pkColumns);
        _cachedSQL = deleteSql.renderInline(sqliteDialect());

        // Execute DELETE, returning the number of deleted rows
        ulong deleted;
        return run(deleteSql, (ulong affected) { deleted = affected; })
            .then((SqliteRow[] _) => cast(int) deleted);
    }

    /// Convert a SQLite row to JSONValue
    private JSONValue rowToJson(SqliteRow row) {
        import std.exception : collectException;

        auto cells = cellsOf(row), columns = row.columnNames;
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

/// The order of the sessions of a connection: their transactions, the
/// connection's, follow each other (each session begins its own once the
/// session before it ended its own).
final class SessionTurns {
    /// Fulfilled when the last session to begin ends its transaction.
    Promise!void last;

    this() {
        last = resolve();
    }
}

/// SQLite data source using ae.net.db.sqlite.
/// Holds the database connection and creates per-request sessions, whose
/// transactions (on the connection) follow each other.
///
/// Parameterized by DBConfig for compile-time feature configuration.
class SQLiteDB(DBConfig config = defaultDBConfig) : DataSource, SqlDataSource {
    /// Configuration accessible at compile time
    enum configuration = config;

    private Promise!SqliteConnection _connection;
    private SessionTurns _turns;
    private SqlOptimizer _sqlOptimizer;

    /// A data source of the connection `connection`.
    this(SqliteConnection connection) {
        this(resolve(connection));
    }

    /// ditto, once it is open
    this(Promise!SqliteConnection connection) {
        _connection = connection;
        _turns = new SessionTurns();
        _sqlOptimizer = new SqlOptimizer(sqliteDialect());
    }

    /// A data source of the database file `filename` (see
    /// `ae.net.db.sqlite.connect`).
    this(string filename) {
        import ae.net.db.sqlite : connect;
        this(connect(filename));
    }

    /// Close the connection (once the sessions ended their transactions).
    Promise!void close() {
        return _turns.last.then(() => _connection).then((SqliteConnection conn) => conn.close());
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
        return new SQLiteSession(_connection, _turns);
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
