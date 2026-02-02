module graphqld2.relational.eval_context;

import std.algorithm;
import std.array;
import std.conv;
import std.json;
import std.typecons : Nullable;

import ae.utils.promise;

import graphqld2.core.types;
import graphqld2.relational.query_node;

// ============================================================================
// Data Source Configuration
// ============================================================================

/// Configuration for a data source.
/// Controls feature generation (pagination, filtering) and naming conventions.
/// Used at compile-time by Table mixin to determine what to generate.
struct DBConfig {
    /// Enable pagination parameters (limit, offset)
    bool pagination = false;

    /// Enable filtering parameter (where)
    bool filtering = false;

    /// Enable ordering parameter (orderBy)
    bool ordering = false;

    /// Parameter name customization
    string limitName = "limit";
    string offsetName = "offset";
    string whereName = "where";
    string orderByName = "orderBy";

    /// Pagination limits
    Nullable!int defaultLimit;
    Nullable!int maxLimit;
}

/// Default configuration with all features disabled
enum defaultDBConfig = DBConfig();

// ============================================================================
// Data Fetcher Base Class
// ============================================================================

/// Base class for fetching data from a relational data source.
///
/// The main method is executeQueryNode(), which executes a QueryNode as a
/// single query and returns all results. SqlDataFetcher generates and executes
/// SQL; MockDB!() filters in-memory data.
///
/// The individual fetch methods (fetchColumn, fetchChildren, etc.) are used
/// by the naive (unoptimized) evaluation path and internally by MockDB!().
abstract class DataFetcher {
    import graphqld2.core.optimize : ExprOptimizer;
    import graphqld2.core.expr : ExprBase;

    /// Get the optimizers this data source needs.
    /// Default: no additional optimizers.
    /// SQL-backed fetchers would override to return [new SqlOptimizer()].
    ExprOptimizer[] requestedOptimizers() {
        return [];
    }

    /// Get the original expression for a computed column alias (for fallback evaluation).
    /// Used when SQL push-down creates ProjectComputedExpr but the data source
    /// (like MockDB!()) can't actually evaluate the SQL expression.
    /// Returns null by default (no fallback available).
    ExprBase getOriginalExpr(string alias_) {
        return null;
    }

    /// Execute a QueryNode as a single query and return all results.
    /// This is the main entry point for the optimized path.
    ///
    /// For root nodes, parentResult is null.
    /// For child nodes, parentResult contains the parent's data (for FK lookups).
    ///
    /// SqlDataFetcher: generates SQL from QueryNode, executes, parses results.
    /// MockDB!(): filters in-memory data based on QueryNode criteria.
    abstract Promise!QueryResult executeQueryNode(QueryNode node, QueryResult parentResult);

    // =========================================================================
    // Individual fetch methods (for naive path and MockDB!() internals)
    // =========================================================================

    /// Fetch column values for refs (template dispatcher)
    final T[] fetchColumn(T)(string table, string column, AnyRef[] refs) {
        import std.typecons : Nullable;
        import graphqld2.core.types : isCustomScalar;
        import std.algorithm : map;
        import std.array : array;

        static if (is(T == Nullable!U, U)) {
            // Nullable type - fetch inner type and wrap (nulls preserved via Nullable)
            auto rawValues = fetchColumn!U(table, column, refs);
            return rawValues.map!(v => T(v)).array;
        } else static if (isCustomScalar!T) {
            // Custom scalar - fetch underlying type and wrap
            auto rawValues = fetchColumn!(T.DType)(table, column, refs);
            return rawValues.map!(v => T(v)).array;
        } else static if (is(T == string)) {
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
    string[] fetchColumnString(string table, string column, AnyRef[] refs) {
        string[] result;
        result.length = refs.length;
        return result;
    }

    /// Fetch long column values - override in subclass
    long[] fetchColumnLong(string table, string column, AnyRef[] refs) {
        long[] result;
        result.length = refs.length;
        return result;
    }

    /// Fetch all IDs from a table (returns native long IDs)
    abstract long[] fetchAllIds(string table);

    /// Fetch children for parent refs (hasMany)
    /// Returns AnyRef[][] - one AnyRef[] per parent
    abstract AnyRef[][] fetchChildren(string childTable, string childType, string fk, AnyRef[] parentRefs);

    /// Fetch parent refs for child refs (belongsTo)
    /// Returns one AnyRef per child (or AnyRef.init for NULL FKs)
    abstract AnyRef[] fetchBelongsTo(string childTable, string fk, string parentType, AnyRef[] childRefs);

    /// Fetch a column as JSONValue array (type-erased).
    abstract JSONValue[] fetchColumnJson(string table, string column, AnyRef[] refs);

    // =========================================================================
    // Mutation methods (for INSERT/UPDATE/DELETE)
    // =========================================================================

    import graphqld2.relational.mutation : InsertInput, UpdateInput;

    /// Execute INSERT and return the new row as QueryResult.
    /// Default implementation returns empty result (no-op).
    Promise!QueryResult executeInsert(string table, string typeName, InsertInput input) {
        return resolve(new QueryResult());
    }

    /// Execute UPDATE and return updated rows as QueryResult.
    /// Default implementation returns empty result (no-op).
    Promise!QueryResult executeUpdate(string table, string typeName, UpdateInput input) {
        return resolve(new QueryResult());
    }

    /// Execute DELETE and return count of deleted rows.
    /// Default implementation returns 0 (no-op).
    Promise!int executeDelete(string table, long[] ids) {
        return resolve(0);
    }
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
        AnyRef[] _allRefs;

        /// For child layers: groups of child refs by parent nodeId
        AnyRef[][string] _childRefsByParent;
    }

    /// Initialize with refs (call before loadColumn)
    void initialize(string typeName, AnyRef[] refs) {
        _typeName = typeName;
        _allRefs = refs;
    }

    /// Load from row-oriented data (for tests)
    void loadFromRows(JSONValue[] rows, string typeName, string idColumn = "id",
                      string parentFk = null, string parentType = null) {
        // Single-column ID - delegate to composite version
        loadFromRowsComposite(rows, typeName, [idColumn], parentFk, parentType);
    }

    /// Load from row-oriented data with composite primary key
    void loadFromRowsComposite(JSONValue[] rows, string typeName, string[] idColumns,
                               string parentFk = null, string parentType = null) {
        import graphqld2.core.types : encodeCompositeKey;

        _typeName = typeName;
        _allRefs = [];

        // Helper to extract ID value as string from JSON
        static string jsonValToString(JSONValue val) {
            if (val.type == JSONType.integer) {
                return val.integer.to!string;
            } else if (val.type == JSONType.string) {
                return val.str;
            } else {
                return "";
            }
        }

        // First pass: collect all refs and build parent grouping
        foreach (row; rows) {
            // Build composite key from all ID columns
            string[] keyParts;
            foreach (col; idColumns) {
                keyParts ~= jsonValToString(row[col]);
            }
            string idStr = idColumns.length == 1 ? keyParts[0] : encodeCompositeKey(keyParts);
            auto nodeId = typeName ~ ":" ~ idStr;
            _allRefs ~= AnyRef(nodeId);

            // If this is a child layer, also index by parent
            if (parentFk !is null && parentType !is null && parentFk in row) {
                auto parentIdVal = row[parentFk];
                if (parentIdVal.type != JSONType.null_) {
                    auto parentIdStr = jsonValToString(parentIdVal);
                    auto parentNodeId = parentType ~ ":" ~ parentIdStr;
                    _childRefsByParent[parentNodeId] ~= AnyRef(nodeId);
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
    void initializeAsChild(string typeName, AnyRef[] refs, AnyRef[] parentRefs,
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
    void loadColumn(string column, AnyRef[] refs, JSONValue[] values) {
        JSONValue[string] colData;
        foreach (i, r; refs) {
            colData[r.nodeId] = values[i];
        }
        _columns[column] = colData;
    }

    /// Get all refs in this result
    AnyRef[] allRefs() {
        return _allRefs;
    }

    /// Get column values for given refs
    T[] getColumn(T)(string column, AnyRef[] refs) {
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
    T[] getJoinedColumn(T)(string joinAlias, string column, AnyRef[] refs) {
        auto fullColumn = joinAlias ~ "." ~ column;
        return getColumn!T(fullColumn, refs);
    }

    /// Get child refs for parent refs (used by HasMany projection)
    AnyRef[][] getChildRefs(AnyRef[] parentRefs) {
        AnyRef[][] result;
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

    /// Check if a column exists in this result
    bool hasColumn(string column) {
        return (column in _columns) !is null;
    }

    /// Check if a ref exists in this result
    bool hasRef(AnyRef r) {
        // Check if ref is in _allRefs
        foreach (ref_; _allRefs) {
            if (ref_.nodeId == r.nodeId) return true;
        }
        return false;
    }

    private T extractValue(T)(JSONValue val) {
        import std.typecons : Nullable;
        import graphqld2.core.types : isCustomScalar;

        static if (is(T == Nullable!U, U)) {
            // Nullable type - return null or extract inner value
            if (val.type == JSONType.null_) {
                return T.init;
            }
            return T(extractValue!U(val));
        } else if (val.type == JSONType.null_) {
            return T.init;
        } else static if (isCustomScalar!T) {
            // Custom scalar - extract underlying type and wrap
            return T(extractValue!(T.DType)(val));
        } else static if (is(T == string)) {
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
            return val.boolean;
        } else static if (is(T == double)) {
            if (val.type == JSONType.integer) return cast(double)val.integer;
            return val.floating;
        } else static if (is(T == float)) {
            if (val.type == JSONType.integer) return cast(float)val.integer;
            return cast(float)val.floating;
        } else static if (is(T == AnyRef)) {
            return AnyRef(val.str);
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

    /// Mutation results, keyed by entity type name.
    /// Stored by InsertExpr/UpdateExpr, read by ColumnAccessExpr.
    private QueryResult[string] _mutationResults;

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
    T[] getColumnValues(T)(int queryNodeId, string column, AnyRef[] refs) {
        auto result = _queryResults.get(queryNodeId, null);
        if (result is null) return refs.map!(_ => T.init).array;
        return result.getColumn!T(column, refs);
    }

    /// Get column values from a JOINed table
    T[] getJoinedColumnValues(T)(int queryNodeId, string joinAlias, string column, AnyRef[] refs) {
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

    /// Store mutation result for later field access.
    /// Called by InsertExpr/UpdateExpr after executing the mutation.
    void storeMutationResult(string typeName, QueryResult result) {
        _mutationResults[typeName] = result;
    }

    /// Get column values from mutation results.
    /// Used by ColumnAccessExpr when evaluating fields on mutation results.
    T[] getMutationColumnValues(T)(string typeName, string column, AnyRef[] refs) {
        auto result = _mutationResults.get(typeName, null);
        if (result is null) return refs.map!(_ => T.init).array;
        return result.getColumn!T(column, refs);
    }

    /// Check if we have mutation results for a type
    bool hasMutationResult(string typeName) {
        return (typeName in _mutationResults) !is null;
    }
}

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
                    auto ids = fetchAllIdsString(node.table);
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
                auto childGroups = fetchChildren(
                    node.table, node.typeName, node.parentFk, parentRefs);

                foreach (group; childGroups) {
                    refs ~= group;
                }

                auto fkValues = fetchColumnJson(node.table, node.parentFk, refs);
                result.initializeAsChild(node.typeName, refs, parentRefs, node.parentFk, fkValues);
            }
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
                auto values = fetchColumnJson(joinInfo.targetTable, column, joinedRefs);
                result.loadColumn(joinAlias ~ "." ~ column, refs, values);
            }
        }

        return result;
    }

    override string[] fetchColumnString(string table, string column, AnyRef[] refs) {
        return fetchColumnGeneric!string(table, column, refs);
    }

    override long[] fetchColumnLong(string table, string column, AnyRef[] refs) {
        return fetchColumnGeneric!long(table, column, refs);
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

    /// Build composite key string from a row using the table's PK columns
    private string buildKeyFromRow(string table, JSONValue row) {
        import graphqld2.core.types : encodeCompositeKey;
        auto pkCols = getPrimaryKey(table);
        if (pkCols.length == 1) {
            return jsonIdToString(row[pkCols[0]]);
        }
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

    private T[] fetchColumnGeneric(T)(string table, string column, AnyRef[] refs) {
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

    override long[] fetchAllIds(string table) {
        if (table !in _tableData) return [];
        return _tableData[table].array
            .filter!(row => row["id"].type == JSONType.integer)
            .map!(row => row["id"].integer)
            .array;
    }

    /// Fetch all IDs as strings (supports any ID type including composite keys)
    string[] fetchAllIdsString(string table) {
        if (table !in _tableData) return [];
        return _tableData[table].array.map!(row => buildKeyFromRow(table, row)).array;
    }

    override AnyRef[][] fetchChildren(string childTable, string childType, string fk, AnyRef[] parentRefs) {
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

    override AnyRef[] fetchBelongsTo(string childTable, string fk, string parentType, AnyRef[] childRefs) {
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

    override JSONValue[] fetchColumnJson(string table, string column, AnyRef[] refs) {
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
            return val.boolean;
        } else static if (is(T == double)) {
            if (val.type == JSONType.integer) return cast(double)val.integer;
            return val.floating;
        } else {
            static assert(false, "Unsupported type: " ~ T.stringof);
        }
    }

    // =========================================================================
    // Mutation methods (INSERT/UPDATE/DELETE)
    // =========================================================================

    private long[string] _nextId;  // Auto-increment ID per table

    /// Execute INSERT into in-memory data.
    override Promise!QueryResult executeInsert(string table, string typeName, InsertInput input) {
        // Get next ID
        auto nextId = _nextId.get(table, 1);
        _nextId[table] = nextId + 1;

        // Build new row
        auto newRow = JSONValue.emptyObject;
        newRow["id"] = JSONValue(nextId);
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
        result.loadFromRows([newRow], typeName);
        return resolve(result);
    }

    /// Execute UPDATE on in-memory data.
    override Promise!QueryResult executeUpdate(string table, string typeName, UpdateInput input) {
        JSONValue[] updatedRows;

        if (table in _tableData) {
            auto rows = _tableData[table].array;

            // Find and update matching rows
            foreach (ref row; rows) {
                auto rowId = row["id"].integer;
                if (input.ids.canFind(rowId)) {
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
        result.loadFromRows(updatedRows, typeName);
        return resolve(result);
    }

    /// Execute DELETE on in-memory data.
    override Promise!int executeDelete(string table, long[] ids) {
        int deleteCount = 0;

        if (table in _tableData) {
            auto rows = _tableData[table].array;

            // Filter out deleted rows
            JSONValue[] remaining;
            foreach (row; rows) {
                auto rowId = row["id"].integer;
                if (ids.canFind(rowId)) {
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
    import graphqld2.relational.sql_optimizer : toSQL, CapturingSqlOptimizer;
    import graphqld2.relational.sql_dialect : SqlDialect;
    import graphqld2.core.optimize : ExprOptimizer;

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
    string getSQL() {
        if (_cachedSQL.length == 0 && _executedNodes.length > 0) {
            _cachedSQL = toSQL(_executedNodes, _sqlOptimizer);
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
    override string[] fetchColumnString(string table, string column, AnyRef[] refs) {
        return _delegate.fetchColumnString(table, column, refs);
    }

    override long[] fetchColumnLong(string table, string column, AnyRef[] refs) {
        return _delegate.fetchColumnLong(table, column, refs);
    }

    override long[] fetchAllIds(string table) {
        return _delegate.fetchAllIds(table);
    }

    override AnyRef[][] fetchChildren(string childTable, string childType, string fk, AnyRef[] parentRefs) {
        return _delegate.fetchChildren(childTable, childType, fk, parentRefs);
    }

    override AnyRef[] fetchBelongsTo(string childTable, string fk, string parentType, AnyRef[] childRefs) {
        return _delegate.fetchBelongsTo(childTable, fk, parentType, childRefs);
    }

    override JSONValue[] fetchColumnJson(string table, string column, AnyRef[] refs) {
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

    auto refs = [AnyRef("User:1"), AnyRef("User:2")];
    auto names = result.getColumn!string("first_name", refs);
    assert(names == ["Alice", "Bob"]);

    assert(result.allRefs == refs);
    assert(result.hasRef(AnyRef("User:1")));
    assert(!result.hasRef(AnyRef("User:99")));
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

    auto childRefs = result.getChildRefs([AnyRef("Post:1"), AnyRef("Post:2"), AnyRef("Post:3")]);
    assert(childRefs.length == 3);
    assert(childRefs[0].length == 2);  // Post:1 has 2 comments
    assert(childRefs[1].length == 1);  // Post:2 has 1 comment
    assert(childRefs[2].length == 0);  // Post:3 has no comments
}

unittest {
    // Test MockDB!()
    auto fetcher = new MockDB!()();
    fetcher.setTableData("users", `[
        {"id": 1, "first_name": "Alice"},
        {"id": 2, "first_name": "Bob"}
    ]`);

    auto refs = [AnyRef("User:1"), AnyRef("User:2")];
    auto names = fetcher.fetchColumn!string("users", "first_name", refs);
    assert(names == ["Alice", "Bob"]);

    auto allIds = fetcher.fetchAllIds("users");
    assert(allIds == [1, 2]);
}

unittest {
    // Test MockDB!() hasMany
    auto fetcher = new MockDB!()();
    fetcher.setTableData("posts", `[
        {"id": 1, "author_id": 1, "title": "Hello"},
        {"id": 2, "author_id": 1, "title": "World"},
        {"id": 3, "author_id": 2, "title": "D Lang"}
    ]`);

    auto parentRefs = [AnyRef("User:1"), AnyRef("User:2")];
    auto children = fetcher.fetchChildren("posts", "Post", "author_id", parentRefs);
    assert(children.length == 2);
    assert(children[0].length == 2);  // User:1 has 2 posts
    assert(children[1].length == 1);  // User:2 has 1 post
}

unittest {
    // Test MockDB!() belongsTo
    auto fetcher = new MockDB!()();
    fetcher.setTableData("posts", `[
        {"id": 1, "author_id": 10, "title": "Hello"},
        {"id": 2, "author_id": 20, "title": "World"}
    ]`);

    auto childRefs = [AnyRef("Post:1"), AnyRef("Post:2")];
    auto parents = fetcher.fetchBelongsTo("posts", "author_id", "User", childRefs);
    assert(parents == [AnyRef("User:10"), AnyRef("User:20")]);
}

unittest {
    // Test RelationalEvalContext
    auto ctx = new RelationalEvalContext();

    auto result = new QueryResult();
    result.initialize("User", [AnyRef("User:1"), AnyRef("User:2")]);
    ctx.storeQueryResult(0, result);

    assert(ctx.hasQueryResult(0));
    assert(!ctx.hasQueryResult(1));
    assert(ctx.getQueryResult(0) is result);
}

unittest {
    // Test string (UUID-style) primary keys
    auto fetcher = new MockDB!()();
    fetcher.setTableData("items", `[
        {"id": "abc-123", "name": "First"},
        {"id": "def-456", "name": "Second"},
        {"id": "ghi-789", "name": "Third"}
    ]`);

    // Fetch by string IDs
    auto refs = [AnyRef("Item:abc-123"), AnyRef("Item:def-456")];
    auto names = fetcher.fetchColumn!string("items", "name", refs);
    assert(names == ["First", "Second"]);

    // Fetch all IDs as strings
    auto allIds = fetcher.fetchAllIdsString("items");
    assert(allIds == ["abc-123", "def-456", "ghi-789"]);
}

unittest {
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
    auto parents = fetcher.fetchBelongsTo("products", "category_id", "Category", childRefs);
    assert(parents == [AnyRef("Category:cat-a"), AnyRef("Category:cat-b")]);

    // Fetch hasMany with string FKs
    auto parentRefs = [AnyRef("Category:cat-a"), AnyRef("Category:cat-b")];
    auto children = fetcher.fetchChildren("products", "Product", "category_id", parentRefs);
    assert(children.length == 2);
    assert(children[0].length == 2);  // cat-a has 2 products
    assert(children[1].length == 1);  // cat-b has 1 product
}

unittest {
    import graphqld2.core.types : encodeCompositeKey, decodeCompositeKey;

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
    assert(fetcher.fetchAllIdsString("order_items") == ["1,100", "1,101", "2,100", "2,102"]);

    // Fetch column values by composite key
    auto quantities = fetcher.fetchColumn!long("order_items", "quantity", [ref1, ref2, ref3]);
    assert(quantities == [2, 1, 3]);
}

unittest {
    import graphqld2.core.types : encodeCompositeKey;

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

    auto values = fetcher.fetchColumn!string("translations", "value", [ref1, ref2]);
    assert(values == ["Hello", "Hello, World"]);
}
