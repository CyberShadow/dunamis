module dunamis.relational.mock;

import std.algorithm;
import std.array;
import std.conv;
import std.json;
import std.typecons : Nullable;

import ae.utils.promise;

import dunamis.core.types;
import dunamis.core.sorting : OrderBySpec, SortDirection;
import dunamis.relational.eval_context;
import dunamis.relational.mutation : InsertInput, UpdateInput;
import dunamis.relational.query_node;

// ============================================================================
// Mock Data Fetcher for Testing
// ============================================================================

/// Mock data fetcher for unit tests.
/// Parameterized by DBConfig for compile-time feature configuration.
class MockDB(DBConfig config = defaultDBConfig) : DataFetcher {
    /// Configuration accessible at compile time
    enum configuration = config;

    private {
        JSONValue[string] _tableData;  // table -> array of rows
        string[][string] _primaryKeys;  // table -> list of PK column names (default: ["id"])
    }

    /// Set the primary key columns for a table (for composite keys)
    void setPrimaryKey(string table, string[] columns...) {
        _primaryKeys[table] = columns.dup;
    }

    /// Get the primary key columns for a table (defaults to ["id"])
    string[] getPrimaryKey(string table) {
        return _primaryKeys.get(table, ["id"]);
    }

    /// Set data for a table
    void setTableData(string table, JSONValue[] rows) {
        _tableData[table] = JSONValue(rows);
    }

    /// Set data from JSON string
    void setTableData(string table, string jsonStr) {
        _tableData[table] = parseJSON(jsonStr);
    }

    /// Execute a QueryNode by filtering in-memory data
    override Promise!QueryResult executeQueryNode(QueryNode node, QueryResult parentResult) {
        // MockDB!() resolves immediately (sync execution wrapped in promise)
        return resolve(executeQueryNodeSync(node, parentResult));
    }

    /// Synchronous implementation of executeQueryNode
    private QueryResult executeQueryNodeSync(QueryNode node, QueryResult parentResult) {
        auto result = new QueryResult();
        AnyRef[] refs;

        // Step 1: Determine refs based on root filter or parent relationship
        if (node.isRoot) {
            final switch (node.rootFilter) {
                case FilterType.none:
                    break;
                case FilterType.all:
                    // Use string IDs to support any key type including composite keys
                    auto ids = fetchAllIdsStringSync(node.table);
                    refs = ids.map!(id => makeAnyRef(node.typeName, id)).array;
                    result.initialize(node.typeName, refs);
                    break;
                case FilterType.byId:
                case FilterType.byIds:
                    refs = node.rootFilterRefs.dup;
                    result.initialize(node.typeName, refs);
                    break;
            }
        } else {
            // Child node: get children via parent
            if (parentResult !is null) {
                auto parentRefs = parentResult.allRefs();
                auto childGroups = fetchChildrenSync(
                    node.table, node.typeName, node.parentFk, parentRefs);

                foreach (group; childGroups) {
                    refs ~= group;
                }

                auto fkValues = fetchColumnJsonSync(node.table, node.parentFk, refs);
                result.initializeAsChild(node.typeName, refs, parentRefs, node.parentFk, fkValues);
            }
        }

        // Apply sorting for root nodes (before pagination)
        if (node.isRoot && node.orderBy_.length > 0 && refs.length > 1) {
            refs = sortRefs(node.table, refs, node.orderBy_);
            // Re-initialize result with sorted refs
            result.initialize(node.typeName, refs);
        }

        // Apply pagination for root nodes (OFFSET first, then LIMIT)
        if (node.isRoot && (!node.offset_.isNull || !node.limit_.isNull)) {
            // Apply offset first
            if (!node.offset_.isNull && refs.length > 0) {
                size_t off = node.offset_.get;
                refs = refs.length > off ? refs[off .. $] : [];
            }
            // Apply limit
            if (!node.limit_.isNull && refs.length > 0) {
                size_t lim = node.limit_.get;
                refs = refs.length > lim ? refs[0 .. lim] : refs;
            }
            // Re-initialize result with paginated refs
            result.initialize(node.typeName, refs);
        }

        // Step 2: Load all columns from base table
        foreach (column; node.columns) {
            auto values = fetchColumnJsonSync(node.table, column, refs);
            result.loadColumn(column, refs, values);
        }

        // Step 3: Load columns from JOINed tables
        foreach (joinInfo; node.joins) {
            auto joinAlias = joinInfo.alias_;
            auto joinedCols = node.joinedColumns.get(joinAlias, null);
            if (joinedCols is null) continue;

            // Get FK values to determine joined refs
            JSONValue[] fkValues;
            if (!joinInfo.sourceAlias.isNull) {
                // Multi-hop: FK is on a previously joined table, read from result
                auto fkKey = joinInfo.sourceAlias.get.value ~ "__" ~ joinInfo.fk;
                fkValues = result.getColumnRaw(fkKey, refs);
            } else {
                // Single hop: FK is on the root table
                fkValues = fetchColumnJsonSync(node.table, joinInfo.fk, refs);
            }

            AnyRef[] joinedRefs;
            foreach (fkVal; fkValues) {
                if (fkVal.type == JSONType.null_) {
                    joinedRefs ~= AnyRef.init;
                } else {
                    auto fkId = jsonIdToString(fkVal);
                    joinedRefs ~= makeAnyRef(joinInfo.targetType, fkId);
                }
            }

            // Load each joined column
            foreach (column; joinedCols) {
                auto values = fetchColumnJsonSync(joinInfo.targetTable, column, joinedRefs);
                result.loadColumn(joinAlias.value ~ "__" ~ column, refs, values);
            }
        }

        return result;
    }

    override Promise!(string[]) fetchColumnString(string table, string column, AnyRef[] refs) {
        return resolve(fetchColumnGenericSync!string(table, column, refs));
    }

    override Promise!(long[]) fetchColumnLong(string table, string column, AnyRef[] refs) {
        return resolve(fetchColumnGenericSync!long(table, column, refs));
    }

    /// Extract ID from JSON value as string (handles both integer and string IDs)
    private static string jsonIdToString(JSONValue val) {
        if (val.type == JSONType.integer) {
            return val.integer.to!string;
        } else if (val.type == JSONType.string) {
            return val.str;
        } else {
            return "";
        }
    }

    /// Build key string from a row using the table's PK columns.
    /// For single-column PKs, produces the same result as direct ID extraction
    /// since encodeCompositeKey(["123"]) == "123".
    private string buildKeyFromRow(string table, JSONValue row) {
        import dunamis.core.types : encodeCompositeKey;
        auto pkCols = getPrimaryKey(table);
        string[] keyParts;
        foreach (col; pkCols) {
            keyParts ~= jsonIdToString(row[col]);
        }
        return encodeCompositeKey(keyParts);
    }

    /// Build an AnyRef from a row using the table's PK columns
    private AnyRef buildRefFromRow(string table, string typeName, JSONValue row) {
        auto keyStr = buildKeyFromRow(table, row);
        return AnyRef(typeName ~ ":" ~ keyStr);
    }

    private T[] fetchColumnGenericSync(T)(string table, string column, AnyRef[] refs) {
        T[] result;
        if (table !in _tableData) {
            result.length = refs.length;
            return result;
        }

        // Build key -> row (using composite key string)
        JSONValue[string] rowByKey;
        foreach (row; _tableData[table].array) {
            rowByKey[buildKeyFromRow(table, row)] = row;
        }

        foreach (r; refs) {
            if (auto rowPtr = r.localId in rowByKey) {
                result ~= extractValue!T((*rowPtr)[column]);
            } else {
                result ~= T.init;
            }
        }
        return result;
    }

    override Promise!(string[]) fetchAllIdsString(string table, string[] pkColumns) {
        return resolve(fetchAllIdsStringSync(table));
    }

    /// Synchronous implementation of fetchAllIdsString (used internally)
    string[] fetchAllIdsStringSync(string table) {
        if (table !in _tableData) return [];
        return _tableData[table].array.map!(row => buildKeyFromRow(table, row)).array;
    }

    override Promise!(AnyRef[][]) fetchChildren(string childTable, string childType, string fk, AnyRef[] parentRefs) {
        return resolve(fetchChildrenSync(childTable, childType, fk, parentRefs));
    }

    /// Synchronous implementation of fetchChildren (used internally by executeQueryNodeSync)
    private AnyRef[][] fetchChildrenSync(string childTable, string childType, string fk, AnyRef[] parentRefs) {
        if (childTable !in _tableData) {
            return parentRefs.map!(_ => cast(AnyRef[])[]).array;
        }

        // Group children by FK value (using string keys)
        AnyRef[][string] childrenByParentId;
        foreach (row; _tableData[childTable].array) {
            auto fkVal = row[fk];
            if (fkVal.type != JSONType.null_) {
                auto parentId = jsonIdToString(fkVal);
                auto childRef = buildRefFromRow(childTable, childType, row);
                childrenByParentId[parentId] ~= childRef;
            }
        }

        // Return children for each parent ref
        AnyRef[][] result;
        foreach (parentRef; parentRefs) {
            if (auto children = parentRef.localId in childrenByParentId) {
                result ~= *children;
            } else {
                result ~= cast(AnyRef[])[];  // Explicit cast to avoid ambiguity
            }
        }
        return result;
    }

    override Promise!(AnyRef[]) fetchBelongsTo(string childTable, string fk, string parentType, AnyRef[] childRefs) {
        return resolve(fetchBelongsToSync(childTable, fk, parentType, childRefs));
    }

    /// Synchronous implementation of fetchBelongsTo (used internally)
    private AnyRef[] fetchBelongsToSync(string childTable, string fk, string parentType, AnyRef[] childRefs) {
        if (childTable !in _tableData) {
            return childRefs.map!(_ => AnyRef.init).array;
        }

        // Build key -> row (using composite key string)
        JSONValue[string] rowByKey;
        foreach (row; _tableData[childTable].array) {
            rowByKey[buildKeyFromRow(childTable, row)] = row;
        }

        AnyRef[] result;
        foreach (childRef; childRefs) {
            if (auto rowPtr = childRef.localId in rowByKey) {
                auto fkVal = (*rowPtr)[fk];
                if (fkVal.type != JSONType.null_) {
                    result ~= makeAnyRef(parentType, jsonIdToString(fkVal));
                } else {
                    result ~= AnyRef.init;
                }
            } else {
                result ~= AnyRef.init;
            }
        }
        return result;
    }

    override Promise!(JSONValue[]) fetchColumnJson(string table, string column, AnyRef[] refs) {
        return resolve(fetchColumnJsonSync(table, column, refs));
    }

    /// Synchronous implementation of fetchColumnJson (used internally by executeQueryNodeSync)
    private JSONValue[] fetchColumnJsonSync(string table, string column, AnyRef[] refs) {
        if (table !in _tableData) {
            JSONValue[] result;
            result.length = refs.length;
            foreach (ref r; result) r = JSONValue(null);
            return result;
        }

        // Build key -> row (using composite key string)
        JSONValue[string] rowByKey;
        foreach (row; _tableData[table].array) {
            rowByKey[buildKeyFromRow(table, row)] = row;
        }

        JSONValue[] result;
        result.reserve(refs.length);
        foreach (r; refs) {
            if (auto rowPtr = r.localId in rowByKey) {
                if (column in *rowPtr) {
                    result ~= (*rowPtr)[column];
                } else {
                    result ~= JSONValue(null);
                }
            } else {
                result ~= JSONValue(null);
            }
        }
        return result;
    }

    private T extractValue(T)(JSONValue val) {
        if (val.type == JSONType.null_) return T.init;
        static if (is(T == string)) {
            // Handle both string and integer values (for FK columns)
            if (val.type == JSONType.integer) {
                return val.integer.to!string;
            }
            return val.str;
        } else static if (is(T == long)) {
            // Handle both integer and string values
            if (val.type == JSONType.string) {
                return val.str.to!long;
            }
            return val.integer;
        } else static if (is(T == int)) {
            if (val.type == JSONType.string) {
                return val.str.to!int;
            }
            return cast(int)val.integer;
        } else static if (is(T == bool)) {
            // Handle different representations of boolean in SQL results:
            // - JSON boolean (true/false)
            // - Integer (0/1) - common in SQLite
            // - String ("true"/"false", "t"/"f", "1"/"0") - common in PostgreSQL
            if (val.type == JSONType.true_ || val.type == JSONType.false_) {
                return val.boolean;
            } else if (val.type == JSONType.integer) {
                return val.integer != 0;
            } else if (val.type == JSONType.string) {
                auto s = val.str;
                return s == "true" || s == "t" || s == "1" || s == "TRUE" || s == "T";
            }
            return false;
        } else static if (is(T == double)) {
            if (val.type == JSONType.integer) return cast(double)val.integer;
            return val.floating;
        } else static if (is(T == enum)) {
            // D enum - extract as string and convert
            if (val.type == JSONType.string) {
                return enumFromDbString!T(val.str);
            }
            return T.init;
        } else {
            static assert(false, "Unsupported type: " ~ T.stringof);
        }
    }

    // =========================================================================
    // Sorting methods
    // =========================================================================

    /// Sort refs by column values according to ORDER BY specs
    private AnyRef[] sortRefs(string table, AnyRef[] refs, OrderBySpec[] orderBySpecs) {
        import std.range : iota;
        import std.typecons : tuple;

        if (table !in _tableData) return refs;

        // Build key -> row lookup
        JSONValue[string] rowByKey;
        foreach (row; _tableData[table].array) {
            rowByKey[buildKeyFromRow(table, row)] = row;
        }

        // Create array of (index, ref) pairs to sort
        auto indexed = refs.length.iota.map!(i => tuple(i, refs[i])).array;

        // Sort using multi-key comparison
        indexed.sort!((a, b) {
            auto refA = a[1];
            auto refB = b[1];

            auto rowPtrA = refA.localId in rowByKey;
            auto rowPtrB = refB.localId in rowByKey;

            // Handle missing rows
            if (rowPtrA is null && rowPtrB is null) return false;
            if (rowPtrA is null) return true;  // Nulls last
            if (rowPtrB is null) return false;

            auto rowA = *rowPtrA;
            auto rowB = *rowPtrB;

            // Compare by each ORDER BY column
            foreach (spec; orderBySpecs) {
                auto colName = spec.column;

                // Get column values (handle missing columns)
                auto valA = (colName in rowA) ? rowA[colName] : JSONValue(null);
                auto valB = (colName in rowB) ? rowB[colName] : JSONValue(null);

                auto cmp = jsonCompare(valA, valB);
                if (cmp != 0) {
                    return spec.descending ? (cmp > 0) : (cmp < 0);
                }
            }
            return false;  // Equal
        });

        return indexed.map!(t => t[1]).array;
    }

    /// Compare two JSON values for sorting
    private static int jsonCompare(JSONValue a, JSONValue b) {
        // Handle nulls
        if (a.type == JSONType.null_ && b.type == JSONType.null_) return 0;
        if (a.type == JSONType.null_) return 1;   // null > non-null (nulls last)
        if (b.type == JSONType.null_) return -1;

        // Compare by type
        if (a.type == JSONType.string && b.type == JSONType.string) {
            if (a.str < b.str) return -1;
            if (a.str > b.str) return 1;
            return 0;
        }
        if (a.type == JSONType.integer && b.type == JSONType.integer) {
            if (a.integer < b.integer) return -1;
            if (a.integer > b.integer) return 1;
            return 0;
        }
        if (a.type == JSONType.float_ && b.type == JSONType.float_) {
            if (a.floating < b.floating) return -1;
            if (a.floating > b.floating) return 1;
            return 0;
        }
        if (a.type == JSONType.true_ || a.type == JSONType.false_ ||
            b.type == JSONType.true_ || b.type == JSONType.false_) {
            bool aVal = (a.type == JSONType.true_);
            bool bVal = (b.type == JSONType.true_);
            if (aVal < bVal) return -1;
            if (aVal > bVal) return 1;
            return 0;
        }
        // Incompatible types - compare as strings
        return 0;
    }

    // =========================================================================
    // Mutation methods (INSERT/UPDATE/DELETE)
    // =========================================================================

    private long[string] _nextId;  // Auto-increment ID per table

    /// Execute INSERT into in-memory data.
    override Promise!QueryResult executeInsert(string table, string typeName, InsertInput input, string[] pkColumns) {
        // Build new row
        auto newRow = JSONValue.emptyObject;

        // Only auto-generate ID for single-column "id" PK when not provided in input
        if (pkColumns == ["id"] && "id" !in input.values) {
            auto nextId = _nextId.get(table, 1);
            _nextId[table] = nextId + 1;
            newRow["id"] = JSONValue(nextId);
        }

        foreach (col, val; input.values) {
            newRow[col] = val;
        }

        // Ensure table exists
        if (table !in _tableData) {
            _tableData[table] = JSONValue.emptyArray;
        }

        // Append row
        _tableData[table].array ~= newRow;

        // Return as QueryResult
        auto result = new QueryResult();
        result.loadFromRows([newRow], typeName, pkColumns);
        return resolve(result);
    }

    /// Execute UPDATE on in-memory data.
    override Promise!QueryResult executeUpdate(string table, string typeName, UpdateInput input, string[] pkColumns) {
        JSONValue[] updatedRows;

        if (table in _tableData) {
            auto rows = _tableData[table].array;

            // Find and update matching rows
            foreach (ref row; rows) {
                auto rowKey = buildKeyFromRow(table, row);
                if (input.ids.canFind(rowKey)) {
                    // Update columns
                    foreach (col, val; input.values) {
                        row[col] = val;
                    }
                    updatedRows ~= row;
                }
            }

            // Store back
            _tableData[table] = JSONValue(rows);
        }

        auto result = new QueryResult();
        result.loadFromRows(updatedRows, typeName, pkColumns);
        return resolve(result);
    }

    /// Execute DELETE on in-memory data.
    override Promise!int executeDelete(string table, string[] ids, string[] pkColumns) {
        int deleteCount = 0;

        if (table in _tableData) {
            auto rows = _tableData[table].array;

            // Filter out deleted rows
            JSONValue[] remaining;
            foreach (row; rows) {
                auto rowKey = buildKeyFromRow(table, row);
                if (ids.canFind(rowKey)) {
                    deleteCount++;
                } else {
                    remaining ~= row;
                }
            }

            _tableData[table] = JSONValue(remaining);
        }

        return resolve(deleteCount);
    }
}


// ============================================================================
// Debug SQL Fetcher - Prints SQL, Delegates to Mock
// ============================================================================

/// A DataFetcher wrapper that prints the SQL it would execute.
/// Useful for debugging and understanding what queries are generated.
/// Wraps another fetcher (typically MockDB) for actual data.
///
/// Call printSQL() after query execution to see the combined CTE query.
///
/// This fetcher uses CapturingSqlOptimizer to enable SQL push-down while
/// still being able to evaluate computed columns. The optimizer captures
/// original D expressions before replacing them with ProjectComputedExpr,
/// and this fetcher evaluates those expressions to populate computed columns.
///
/// Parameterized by DBConfig for compile-time feature configuration.
class DebugSqlDB(DBConfig config = defaultDBConfig) : DataFetcher {
    import std.stdio : writeln;
    import dunamis.relational.sql_optimizer : SqlOptimizer, CapturingSqlOptimizer;
    import dunamis.relational.sql_dialect : SqlDialect;
    import dunamis.core.optimize : ExprOptimizer;
    import dunamis.core.expr : ExprBase;

    /// Configuration accessible at compile time
    enum configuration = config;

    private DataFetcher _delegate;
    private QueryNode[] _executedNodes;
    private string _cachedSQL;  // Cached to avoid duplicate debug output
    private CapturingSqlOptimizer _sqlOptimizer;
    private SqlDialect _dialect;

    this(DataFetcher delegate_, SqlDialect dialect) {
        _delegate = delegate_;
        _dialect = dialect;
        _sqlOptimizer = new CapturingSqlOptimizer(dialect);
    }

    /// Return the CapturingSqlOptimizer to enable SQL push-down
    override ExprOptimizer[] requestedOptimizers() {
        return [_sqlOptimizer];
    }

    /// Get the SQL optimizer (for accessing computed columns info)
    @property CapturingSqlOptimizer sqlOptimizer() {
        return _sqlOptimizer;
    }

    /// Get original expression for fallback evaluation
    override ExprBase getOriginalExpr(string alias_) {
        return _sqlOptimizer.getOriginalExpr(alias_);
    }

    /// Get all executed nodes (for generating combined SQL)
    @property QueryNode[] executedNodes() {
        return _executedNodes;
    }

    /// Get the combined SQL for all executed nodes as a string.
    /// Caches the result to avoid regenerating (and re-printing in debug mode).
    /// Includes computed columns from SQL push-down optimization.
    /// Requires a toSQL function to be provided at construction time.
    string getSQL() {
        if (_cachedSQL.length == 0 && _executedNodes.length > 0) {
            import dunamis.relational.sql : toSQL;
            _cachedSQL = toSQL(_executedNodes, _dialect, _sqlOptimizer);
        }
        return _cachedSQL;
    }

    /// Print the combined SQL for all executed nodes.
    /// Note: When running with -debug=sql, toSQL() already prints the SQL,
    /// so this only prints if SQL hasn't been generated yet.
    void printSQL() {
        debug(sql) {
            // In debug mode, toSQL() prints automatically.
            // Just trigger generation if not already done.
            getSQL();
        } else {
            auto sql = getSQL();
            if (sql.length > 0) {
                writeln(sql);
            }
        }
    }

    /// Reset collected nodes (call between queries)
    void reset() {
        _executedNodes = [];
        _cachedSQL = "";
        _sqlOptimizer = new CapturingSqlOptimizer(_dialect);
    }

    override Promise!QueryResult executeQueryNode(QueryNode node, QueryResult parentResult) {
        _executedNodes ~= node;
        return _delegate.executeQueryNode(node, parentResult);
    }

    // Delegate all other methods to wrapped fetcher
    override Promise!(string[]) fetchColumnString(string table, string column, AnyRef[] refs) {
        return _delegate.fetchColumnString(table, column, refs);
    }

    override Promise!(long[]) fetchColumnLong(string table, string column, AnyRef[] refs) {
        return _delegate.fetchColumnLong(table, column, refs);
    }

    override Promise!(string[]) fetchAllIdsString(string table, string[] pkColumns) {
        return _delegate.fetchAllIdsString(table, pkColumns);
    }

    override Promise!(AnyRef[][]) fetchChildren(string childTable, string childType, string fk, AnyRef[] parentRefs) {
        return _delegate.fetchChildren(childTable, childType, fk, parentRefs);
    }

    override Promise!(AnyRef[]) fetchBelongsTo(string childTable, string fk, string parentType, AnyRef[] childRefs) {
        return _delegate.fetchBelongsTo(childTable, fk, parentType, childRefs);
    }

    override Promise!(JSONValue[]) fetchColumnJson(string table, string column, AnyRef[] refs) {
        return _delegate.fetchColumnJson(table, column, refs);
    }
}


// ============================================================================
// Tests
// ============================================================================

unittest {
    import ae.utils.promise.await : awaitSync;

    // Test MockDB!()
    auto fetcher = new MockDB!()();
    fetcher.setTableData("users", `[
        {"id": 1, "first_name": "Alice"},
        {"id": 2, "first_name": "Bob"}
    ]`);

    auto refs = [AnyRef("User:1"), AnyRef("User:2")];
    auto names = awaitSync(fetcher.fetchColumn!string("users", "first_name", refs));
    assert(names == ["Alice", "Bob"]);

    auto allIds = awaitSync(fetcher.fetchAllIdsString("users", ["id"]));
    assert(allIds == ["1", "2"]);
}

unittest {
    import ae.utils.promise.await : awaitSync;

    // Test MockDB!() hasMany
    auto fetcher = new MockDB!()();
    fetcher.setTableData("posts", `[
        {"id": 1, "author_id": 1, "title": "Hello"},
        {"id": 2, "author_id": 1, "title": "World"},
        {"id": 3, "author_id": 2, "title": "D Lang"}
    ]`);

    auto parentRefs = [AnyRef("User:1"), AnyRef("User:2")];
    auto children = awaitSync(fetcher.fetchChildren("posts", "Post", "author_id", parentRefs));
    assert(children.length == 2);
    assert(children[0].length == 2);  // User:1 has 2 posts
    assert(children[1].length == 1);  // User:2 has 1 post
}

unittest {
    import ae.utils.promise.await : awaitSync;

    // Test MockDB!() belongsTo
    auto fetcher = new MockDB!()();
    fetcher.setTableData("posts", `[
        {"id": 1, "author_id": 10, "title": "Hello"},
        {"id": 2, "author_id": 20, "title": "World"}
    ]`);

    auto childRefs = [AnyRef("Post:1"), AnyRef("Post:2")];
    auto parents = awaitSync(fetcher.fetchBelongsTo("posts", "author_id", "User", childRefs));
    assert(parents == [AnyRef("User:10"), AnyRef("User:20")]);
}

unittest {
    import ae.utils.promise.await : awaitSync;

    // Test string (UUID-style) primary keys
    auto fetcher = new MockDB!()();
    fetcher.setTableData("items", `[
        {"id": "abc-123", "name": "First"},
        {"id": "def-456", "name": "Second"},
        {"id": "ghi-789", "name": "Third"}
    ]`);

    // Fetch by string IDs
    auto refs = [AnyRef("Item:abc-123"), AnyRef("Item:def-456")];
    auto names = awaitSync(fetcher.fetchColumn!string("items", "name", refs));
    assert(names == ["First", "Second"]);

    // Fetch all IDs as strings
    auto allIds = fetcher.fetchAllIdsStringSync("items");
    assert(allIds == ["abc-123", "def-456", "ghi-789"]);
}

unittest {
    import ae.utils.promise.await : awaitSync;

    // Test string FK references
    auto fetcher = new MockDB!()();
    fetcher.setTableData("categories", `[
        {"id": "cat-a", "name": "Category A"},
        {"id": "cat-b", "name": "Category B"}
    ]`);
    fetcher.setTableData("products", `[
        {"id": "prod-1", "category_id": "cat-a", "name": "Product 1"},
        {"id": "prod-2", "category_id": "cat-b", "name": "Product 2"},
        {"id": "prod-3", "category_id": "cat-a", "name": "Product 3"}
    ]`);

    // Fetch belongsTo with string FKs
    auto childRefs = [AnyRef("Product:prod-1"), AnyRef("Product:prod-2")];
    auto parents = awaitSync(fetcher.fetchBelongsTo("products", "category_id", "Category", childRefs));
    assert(parents == [AnyRef("Category:cat-a"), AnyRef("Category:cat-b")]);

    // Fetch hasMany with string FKs
    auto parentRefs = [AnyRef("Category:cat-a"), AnyRef("Category:cat-b")];
    auto children = awaitSync(fetcher.fetchChildren("products", "Product", "category_id", parentRefs));
    assert(children.length == 2);
    assert(children[0].length == 2);  // cat-a has 2 products
    assert(children[1].length == 1);  // cat-b has 1 product
}

unittest {
    import ae.utils.promise.await : awaitSync;
    import dunamis.core.types : encodeCompositeKey, decodeCompositeKey;

    // Test composite primary keys (e.g., OrderItem with order_id + product_id)
    auto fetcher = new MockDB!()();
    fetcher.setPrimaryKey("order_items", "order_id", "product_id");
    fetcher.setTableData("order_items", `[
        {"order_id": 1, "product_id": 100, "quantity": 2, "price": 10.00},
        {"order_id": 1, "product_id": 101, "quantity": 1, "price": 25.00},
        {"order_id": 2, "product_id": 100, "quantity": 3, "price": 10.00},
        {"order_id": 2, "product_id": 102, "quantity": 1, "price": 50.00}
    ]`);

    // Build refs with composite keys (comma-separated)
    auto ref1 = AnyRef("OrderItem:1,100");  // order 1, product 100
    auto ref2 = AnyRef("OrderItem:1,101");  // order 1, product 101
    auto ref3 = AnyRef("OrderItem:2,100");  // order 2, product 100

    // Verify key building
    assert(fetcher.fetchAllIdsStringSync("order_items") == ["1,100", "1,101", "2,100", "2,102"]);

    // Fetch column values by composite key
    auto quantities = awaitSync(fetcher.fetchColumn!long("order_items", "quantity", [ref1, ref2, ref3]));
    assert(quantities == [2, 1, 3]);
}

unittest {
    import ae.utils.promise.await : awaitSync;
    import dunamis.core.types : encodeCompositeKey;

    // Test composite keys with special characters (requiring quoting)
    auto fetcher = new MockDB!()();
    fetcher.setPrimaryKey("translations", "locale", "key");
    fetcher.setTableData("translations", `[
        {"locale": "en-US", "key": "hello", "value": "Hello"},
        {"locale": "en-US", "key": "hello,world", "value": "Hello, World"},
        {"locale": "de-DE", "key": "hello", "value": "Hallo"}
    ]`);

    // The key "hello,world" contains a comma, so it needs quoting
    auto encodedKey = encodeCompositeKey(["en-US", "hello,world"]);
    assert(encodedKey == `en-US,"hello,world"`);

    auto ref1 = AnyRef("Translation:en-US,hello");
    auto ref2 = AnyRef("Translation:" ~ encodedKey);  // en-US,"hello,world"

    auto values = awaitSync(fetcher.fetchColumn!string("translations", "value", [ref1, ref2]));
    assert(values == ["Hello", "Hello, World"]);
}
