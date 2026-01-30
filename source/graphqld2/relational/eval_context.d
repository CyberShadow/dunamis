module graphqld2.relational.eval_context;

import std.algorithm;
import std.array;
import std.conv;
import std.json;

import ae.utils.promise;

import graphqld2.core.types;
import graphqld2.relational.query_node;

// ============================================================================
// Data Fetcher Base Class
// ============================================================================

/// Base class for fetching data from a relational data source.
///
/// The main method is executeQueryNode(), which executes a QueryNode as a
/// single query and returns all results. SqlDataFetcher generates and executes
/// SQL; MockDataFetcher filters in-memory data.
///
/// The individual fetch methods (fetchColumn, fetchChildren, etc.) are used
/// by the naive (unoptimized) evaluation path and internally by MockDataFetcher.
abstract class DataFetcher {
    import graphqld2.core.optimize : ExprOptimizer;

    /// Get the optimizers this data source needs.
    /// Default: no additional optimizers.
    /// SQL-backed fetchers would override to return [new SqlOptimizer()].
    ExprOptimizer[] requestedOptimizers() {
        return [];
    }

    /// Execute a QueryNode as a single query and return all results.
    /// This is the main entry point for the optimized path.
    ///
    /// For root nodes, parentResult is null.
    /// For child nodes, parentResult contains the parent's data (for FK lookups).
    ///
    /// SqlDataFetcher: generates SQL from QueryNode, executes, parses results.
    /// MockDataFetcher: filters in-memory data based on QueryNode criteria.
    abstract Promise!QueryResult executeQueryNode(QueryNode node, QueryResult parentResult);

    // =========================================================================
    // Individual fetch methods (for naive path and MockDataFetcher internals)
    // =========================================================================

    /// Fetch column values for refs (template dispatcher)
    final T[] fetchColumn(T)(string table, string column, Ref[] refs) {
        static if (is(T == string)) {
            return fetchColumnString(table, column, refs);
        } else static if (is(T == long)) {
            return fetchColumnLong(table, column, refs);
        } else static if (is(T == int)) {
            return cast(int[]) fetchColumnLong(table, column, refs);
        } else {
            static assert(false, "Unsupported column type: " ~ T.stringof);
        }
    }

    /// Fetch string column values - override in subclass
    string[] fetchColumnString(string table, string column, Ref[] refs) {
        string[] result;
        result.length = refs.length;
        return result;
    }

    /// Fetch long column values - override in subclass
    long[] fetchColumnLong(string table, string column, Ref[] refs) {
        long[] result;
        result.length = refs.length;
        return result;
    }

    /// Fetch all IDs from a table (returns native long IDs)
    abstract long[] fetchAllIds(string table);

    /// Fetch children for parent refs (hasMany)
    /// Returns Ref[][] - one Ref[] per parent
    abstract Ref[][] fetchChildren(string childTable, string childType, string fk, Ref[] parentRefs);

    /// Fetch parent refs for child refs (belongsTo)
    /// Returns one Ref per child (or Ref.init for NULL FKs)
    abstract Ref[] fetchBelongsTo(string childTable, string fk, string parentType, Ref[] childRefs);

    /// Fetch a column as JSONValue array (type-erased).
    abstract JSONValue[] fetchColumnJson(string table, string column, Ref[] refs);
}

// ============================================================================
// Query Result (for optimized path)
// ============================================================================

// TODO: Rename to better indicate this holds aggregated query results
// (e.g., BatchResult, AggregatedResult)

/// Results from executing a QueryNode.
/// Column-oriented storage for efficient per-column access.
class QueryResult {
    private {
        string _typeName;

        /// Column data: column name → (nodeId → value)
        JSONValue[string][string] _columns;

        /// All refs in result order
        Ref[] _allRefs;

        /// For child layers: groups of child refs by parent nodeId
        Ref[][string] _childRefsByParent;
    }

    /// Initialize with refs (call before loadColumn)
    void initialize(string typeName, Ref[] refs) {
        _typeName = typeName;
        _allRefs = refs;
    }

    /// Load from row-oriented data (for tests and backwards compatibility)
    void loadFromRows(JSONValue[] rows, string typeName, string idColumn = "id",
                      string parentFk = null, string parentType = null) {
        _typeName = typeName;
        _allRefs = [];

        // First pass: collect all refs and build parent grouping
        foreach (row; rows) {
            auto id = row[idColumn];
            string idStr;
            if (id.type == JSONType.integer) {
                idStr = id.integer.to!string;
            } else {
                idStr = id.str;
            }
            auto nodeId = typeName ~ ":" ~ idStr;
            _allRefs ~= Ref(nodeId);

            // If this is a child layer, also index by parent
            if (parentFk !is null && parentType !is null && parentFk in row) {
                auto parentIdVal = row[parentFk];
                if (parentIdVal.type != JSONType.null_) {
                    string parentIdStr;
                    if (parentIdVal.type == JSONType.integer) {
                        parentIdStr = parentIdVal.integer.to!string;
                    } else {
                        parentIdStr = parentIdVal.str;
                    }
                    auto parentNodeId = parentType ~ ":" ~ parentIdStr;
                    _childRefsByParent[parentNodeId] ~= Ref(nodeId);
                }
            }
        }

        // Second pass: extract columns
        // Get all column names from first row
        if (rows.length > 0) {
            foreach (colName; rows[0].object.keys) {
                JSONValue[string] colData;
                foreach (i, row; rows) {
                    colData[_allRefs[i].nodeId] = row[colName];
                }
                _columns[colName] = colData;
            }
        }
    }

    /// Initialize as child result with parent grouping
    void initializeAsChild(string typeName, Ref[] refs, Ref[] parentRefs,
                           string fkColumn, JSONValue[] fkValues) {
        _typeName = typeName;
        _allRefs = refs;

        // Build parent grouping from FK values
        foreach (i, r; refs) {
            auto fkVal = fkValues[i];
            if (fkVal.type != JSONType.null_) {
                string parentIdStr;
                if (fkVal.type == JSONType.integer) {
                    parentIdStr = fkVal.integer.to!string;
                } else {
                    parentIdStr = fkVal.str;
                }
                // Find parent type from first parent ref
                string parentType = parentRefs.length > 0 ? parentRefs[0].typeName : "";
                auto parentNodeId = parentType ~ ":" ~ parentIdStr;
                _childRefsByParent[parentNodeId] ~= r;
            }
        }
    }

    /// Load a column's data
    void loadColumn(string column, Ref[] refs, JSONValue[] values) {
        JSONValue[string] colData;
        foreach (i, r; refs) {
            colData[r.nodeId] = values[i];
        }
        _columns[column] = colData;
    }

    /// Get all refs in this result
    Ref[] allRefs() {
        return _allRefs;
    }

    /// Get column values for given refs
    T[] getColumn(T)(string column, Ref[] refs) {
        auto colData = _columns.get(column, null);
        if (colData is null) {
            T[] result;
            result.length = refs.length;
            return result;
        }

        T[] result;
        result.reserve(refs.length);
        foreach (r; refs) {
            if (auto valPtr = r.nodeId in colData) {
                result ~= extractValue!T(*valPtr);
            } else {
                result ~= T.init;
            }
        }
        return result;
    }

    /// Get column from JOINed data (aliased columns like "j0.first_name")
    T[] getJoinedColumn(T)(string joinAlias, string column, Ref[] refs) {
        auto fullColumn = joinAlias ~ "." ~ column;
        return getColumn!T(fullColumn, refs);
    }

    /// Get child refs for parent refs (used by HasMany projection)
    Ref[][] getChildRefs(Ref[] parentRefs) {
        Ref[][] result;
        result.length = parentRefs.length;
        foreach (i, p; parentRefs) {
            if (auto children = p.nodeId in _childRefsByParent) {
                result[i] = *children;
            } else {
                result[i] = [];
            }
        }
        return result;
    }

    /// Check if a ref exists in this result
    bool hasRef(Ref r) {
        // Check if ref is in _allRefs
        foreach (ref_; _allRefs) {
            if (ref_.nodeId == r.nodeId) return true;
        }
        return false;
    }

    private T extractValue(T)(JSONValue val) {
        if (val.type == JSONType.null_) {
            return T.init;
        }
        static if (is(T == string)) {
            return val.str;
        } else static if (is(T == long)) {
            return val.integer;
        } else static if (is(T == int)) {
            return cast(int)val.integer;
        } else static if (is(T == bool)) {
            return val.boolean;
        } else static if (is(T == double)) {
            if (val.type == JSONType.integer) return cast(double)val.integer;
            return val.floating;
        } else static if (is(T == float)) {
            if (val.type == JSONType.integer) return cast(float)val.integer;
            return cast(float)val.floating;
        } else static if (is(T == Ref)) {
            return Ref(val.str);
        } else {
            static assert(false, "Unsupported type: " ~ T.stringof);
        }
    }
}

// ============================================================================
// Relational Eval Context
// ============================================================================

/// Relational-specific evaluation context.
/// Holds DataFetcher and QueryResults for relational data access.
/// Retrieved via EvalContext.getSourceContext!RelationalEvalContext()
class RelationalEvalContext {
    /// Data fetcher for naive evaluation (when not optimized)
    DataFetcher fetcher;

    /// Pre-fetched query results, keyed by QueryNode ID.
    /// Stored by PrefetchExpr after query execution, read by ProjectColumnExpr.
    private QueryResult[int] _queryResults;

    /// Store results from a QueryNode execution
    void storeQueryResult(int queryNodeId, QueryResult result) {
        _queryResults[queryNodeId] = result;
    }

    /// Check if we have results for a query node
    bool hasQueryResult(int queryNodeId) {
        return (queryNodeId in _queryResults) !is null;
    }

    /// Get query result by node ID
    QueryResult getQueryResult(int queryNodeId) {
        return _queryResults.get(queryNodeId, null);
    }

    /// Get column values from pre-fetched results
    T[] getColumnValues(T)(int queryNodeId, string column, Ref[] refs) {
        auto result = _queryResults.get(queryNodeId, null);
        if (result is null) return refs.map!(_ => T.init).array;
        return result.getColumn!T(column, refs);
    }

    /// Get column values from a JOINed table
    T[] getJoinedColumnValues(T)(int queryNodeId, string joinAlias, string column, Ref[] refs) {
        auto result = _queryResults.get(queryNodeId, null);
        if (result is null) return refs.map!(_ => T.init).array;
        return result.getJoinedColumn!T(joinAlias, column, refs);
    }

    /// Fetch all IDs for a table (delegates to fetcher)
    long[] fetchAllIds(string table) {
        if (fetcher !is null) {
            return fetcher.fetchAllIds(table);
        }
        return [];
    }
}

// ============================================================================
// Mock Data Fetcher for Testing
// ============================================================================

/// Simple mock data fetcher for unit tests
class MockDataFetcher : DataFetcher {
    private {
        JSONValue[string] _tableData;  // table -> array of rows
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
        // MockDataFetcher resolves immediately (sync execution wrapped in promise)
        return resolve(executeQueryNodeSync(node, parentResult));
    }

    /// Synchronous implementation of executeQueryNode
    private QueryResult executeQueryNodeSync(QueryNode node, QueryResult parentResult) {
        auto result = new QueryResult();
        Ref[] refs;

        // Step 1: Determine refs based on root filter or parent relationship
        if (node.isRoot) {
            final switch (node.rootFilter) {
                case FilterType.none:
                    break;
                case FilterType.all:
                    auto ids = fetchAllIds(node.table);
                    refs = ids.map!(id => makeRef(node.typeName, id)).array;
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
                auto childGroups = fetchChildren(
                    node.table, node.typeName, node.parentFk, parentRefs);

                foreach (group; childGroups) {
                    refs ~= group;
                }

                auto fkValues = fetchColumnJson(node.table, node.parentFk, refs);
                result.initializeAsChild(node.typeName, refs, parentRefs, node.parentFk, fkValues);
            }
        }

        // Step 2: Load all columns from base table
        foreach (column; node.columns) {
            auto values = fetchColumnJson(node.table, column, refs);
            result.loadColumn(column, refs, values);
        }

        // Step 3: Load columns from JOINed tables
        foreach (joinInfo; node.joins) {
            auto joinAlias = joinInfo.alias_;
            auto joinedCols = node.joinedColumns.get(joinAlias, null);
            if (joinedCols is null) continue;

            // Get FK values to determine joined refs
            auto fkValues = fetchColumnJson(node.table, joinInfo.fk, refs);

            Ref[] joinedRefs;
            foreach (fkVal; fkValues) {
                if (fkVal.type == JSONType.null_) {
                    joinedRefs ~= Ref.init;
                } else {
                    long fkId = fkVal.type == JSONType.integer ? fkVal.integer : fkVal.str.to!long;
                    joinedRefs ~= makeRef(joinInfo.targetType, fkId);
                }
            }

            // Load each joined column
            foreach (column; joinedCols) {
                auto values = fetchColumnJson(joinInfo.targetTable, column, joinedRefs);
                result.loadColumn(joinAlias ~ "." ~ column, refs, values);
            }
        }

        return result;
    }

    override string[] fetchColumnString(string table, string column, Ref[] refs) {
        return fetchColumnGeneric!string(table, column, refs);
    }

    override long[] fetchColumnLong(string table, string column, Ref[] refs) {
        return fetchColumnGeneric!long(table, column, refs);
    }

    private T[] fetchColumnGeneric(T)(string table, string column, Ref[] refs) {
        T[] result;
        if (table !in _tableData) {
            result.length = refs.length;
            return result;
        }

        // Build id -> row index
        JSONValue[long] rowById;
        foreach (row; _tableData[table].array) {
            rowById[row["id"].integer] = row;
        }

        foreach (r; refs) {
            auto id = decodeAsLong(r);
            if (auto rowPtr = id in rowById) {
                result ~= extractValue!T((*rowPtr)[column]);
            } else {
                result ~= T.init;
            }
        }
        return result;
    }

    override long[] fetchAllIds(string table) {
        if (table !in _tableData) return [];
        return _tableData[table].array.map!(row => row["id"].integer).array;
    }

    override Ref[][] fetchChildren(string childTable, string childType, string fk, Ref[] parentRefs) {
        if (childTable !in _tableData) {
            return parentRefs.map!(_ => cast(Ref[])[]).array;
        }

        // Group children by FK value
        Ref[][long] childrenByParentId;
        foreach (row; _tableData[childTable].array) {
            auto fkVal = row[fk];
            if (fkVal.type != JSONType.null_) {
                auto parentId = fkVal.integer;
                childrenByParentId[parentId] ~= makeRef(childType, row["id"].integer);
            }
        }

        // Return children for each parent ref
        Ref[][] result;
        foreach (parentRef; parentRefs) {
            auto parentId = decodeAsLong(parentRef);
            if (auto children = parentId in childrenByParentId) {
                result ~= *children;
            } else {
                result ~= cast(Ref[])[];  // Explicit cast to avoid ambiguity
            }
        }
        return result;
    }

    override Ref[] fetchBelongsTo(string childTable, string fk, string parentType, Ref[] childRefs) {
        if (childTable !in _tableData) {
            return childRefs.map!(_ => Ref.init).array;
        }

        // Build id -> row index
        JSONValue[long] rowById;
        foreach (row; _tableData[childTable].array) {
            rowById[row["id"].integer] = row;
        }

        Ref[] result;
        foreach (childRef; childRefs) {
            auto childId = decodeAsLong(childRef);
            if (auto rowPtr = childId in rowById) {
                auto fkVal = (*rowPtr)[fk];
                if (fkVal.type != JSONType.null_) {
                    result ~= makeRef(parentType, fkVal.integer);
                } else {
                    result ~= Ref.init;
                }
            } else {
                result ~= Ref.init;
            }
        }
        return result;
    }

    override JSONValue[] fetchColumnJson(string table, string column, Ref[] refs) {
        if (table !in _tableData) {
            JSONValue[] result;
            result.length = refs.length;
            foreach (ref r; result) r = JSONValue(null);
            return result;
        }

        // Build id -> row index
        JSONValue[long] rowById;
        foreach (row; _tableData[table].array) {
            rowById[row["id"].integer] = row;
        }

        JSONValue[] result;
        result.reserve(refs.length);
        foreach (r; refs) {
            auto id = decodeAsLong(r);
            if (auto rowPtr = id in rowById) {
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
            return val.str;
        } else static if (is(T == long)) {
            return val.integer;
        } else static if (is(T == int)) {
            return cast(int)val.integer;
        } else static if (is(T == bool)) {
            return val.boolean;
        } else static if (is(T == double)) {
            if (val.type == JSONType.integer) return cast(double)val.integer;
            return val.floating;
        } else {
            static assert(false, "Unsupported type: " ~ T.stringof);
        }
    }
}

// ============================================================================
// Debug SQL Fetcher - Prints SQL, Delegates to Mock
// ============================================================================

/// A DataFetcher wrapper that prints the SQL it would execute.
/// Useful for debugging and understanding what queries are generated.
/// Wraps another fetcher (typically MockDataFetcher) for actual data.
///
/// Call printSQL() after query execution to see the combined CTE query.
class DebugSqlFetcher : DataFetcher {
    import std.stdio : writeln;
    import graphqld2.relational.sql_optimizer : toSQL;

    private DataFetcher _delegate;
    private QueryNode[] _executedNodes;

    this(DataFetcher delegate_) {
        _delegate = delegate_;
    }

    /// Get all executed nodes (for generating combined SQL)
    @property QueryNode[] executedNodes() {
        return _executedNodes;
    }

    /// Print the combined SQL for all executed nodes.
    /// This shows what a real SQL executor would run as a single query.
    void printSQL() {
        if (_executedNodes.length > 0) {
            writeln(toSQL(_executedNodes));
        }
    }

    /// Reset collected nodes (call between queries)
    void reset() {
        _executedNodes = [];
    }

    override Promise!QueryResult executeQueryNode(QueryNode node, QueryResult parentResult) {
        _executedNodes ~= node;
        return _delegate.executeQueryNode(node, parentResult);
    }

    // Delegate all other methods to wrapped fetcher
    override string[] fetchColumnString(string table, string column, Ref[] refs) {
        return _delegate.fetchColumnString(table, column, refs);
    }

    override long[] fetchColumnLong(string table, string column, Ref[] refs) {
        return _delegate.fetchColumnLong(table, column, refs);
    }

    override long[] fetchAllIds(string table) {
        return _delegate.fetchAllIds(table);
    }

    override Ref[][] fetchChildren(string childTable, string childType, string fk, Ref[] parentRefs) {
        return _delegate.fetchChildren(childTable, childType, fk, parentRefs);
    }

    override Ref[] fetchBelongsTo(string childTable, string fk, string parentType, Ref[] childRefs) {
        return _delegate.fetchBelongsTo(childTable, fk, parentType, childRefs);
    }

    override JSONValue[] fetchColumnJson(string table, string column, Ref[] refs) {
        return _delegate.fetchColumnJson(table, column, refs);
    }
}

// ============================================================================
// Tests
// ============================================================================

unittest {
    // Test QueryResult
    auto result = new QueryResult();
    auto rows = [
        parseJSON(`{"id": 1, "first_name": "Alice"}`),
        parseJSON(`{"id": 2, "first_name": "Bob"}`)
    ];
    result.loadFromRows(rows, "User");

    auto refs = [Ref("User:1"), Ref("User:2")];
    auto names = result.getColumn!string("first_name", refs);
    assert(names == ["Alice", "Bob"]);

    assert(result.allRefs == refs);
    assert(result.hasRef(Ref("User:1")));
    assert(!result.hasRef(Ref("User:99")));
}

unittest {
    // Test QueryResult with parent-child relationship
    auto result = new QueryResult();
    auto rows = [
        parseJSON(`{"id": 101, "post_id": 1, "body": "Great!"}`),
        parseJSON(`{"id": 102, "post_id": 1, "body": "Thanks!"}`),
        parseJSON(`{"id": 103, "post_id": 2, "body": "Nice!"}`)
    ];
    result.loadFromRows(rows, "Comment", "id", "post_id", "Post");

    auto childRefs = result.getChildRefs([Ref("Post:1"), Ref("Post:2"), Ref("Post:3")]);
    assert(childRefs.length == 3);
    assert(childRefs[0].length == 2);  // Post:1 has 2 comments
    assert(childRefs[1].length == 1);  // Post:2 has 1 comment
    assert(childRefs[2].length == 0);  // Post:3 has no comments
}

unittest {
    // Test MockDataFetcher
    auto fetcher = new MockDataFetcher();
    fetcher.setTableData("users", `[
        {"id": 1, "first_name": "Alice"},
        {"id": 2, "first_name": "Bob"}
    ]`);

    auto refs = [Ref("User:1"), Ref("User:2")];
    auto names = fetcher.fetchColumn!string("users", "first_name", refs);
    assert(names == ["Alice", "Bob"]);

    auto allIds = fetcher.fetchAllIds("users");
    assert(allIds == [1, 2]);
}

unittest {
    // Test MockDataFetcher hasMany
    auto fetcher = new MockDataFetcher();
    fetcher.setTableData("posts", `[
        {"id": 1, "author_id": 1, "title": "Hello"},
        {"id": 2, "author_id": 1, "title": "World"},
        {"id": 3, "author_id": 2, "title": "D Lang"}
    ]`);

    auto parentRefs = [Ref("User:1"), Ref("User:2")];
    auto children = fetcher.fetchChildren("posts", "Post", "author_id", parentRefs);
    assert(children.length == 2);
    assert(children[0].length == 2);  // User:1 has 2 posts
    assert(children[1].length == 1);  // User:2 has 1 post
}

unittest {
    // Test MockDataFetcher belongsTo
    auto fetcher = new MockDataFetcher();
    fetcher.setTableData("posts", `[
        {"id": 1, "author_id": 10, "title": "Hello"},
        {"id": 2, "author_id": 20, "title": "World"}
    ]`);

    auto childRefs = [Ref("Post:1"), Ref("Post:2")];
    auto parents = fetcher.fetchBelongsTo("posts", "author_id", "User", childRefs);
    assert(parents == [Ref("User:10"), Ref("User:20")]);
}

unittest {
    // Test RelationalEvalContext
    auto ctx = new RelationalEvalContext();

    auto result = new QueryResult();
    result.initialize("User", [Ref("User:1"), Ref("User:2")]);
    ctx.storeQueryResult(0, result);

    assert(ctx.hasQueryResult(0));
    assert(!ctx.hasQueryResult(1));
    assert(ctx.getQueryResult(0) is result);
}
