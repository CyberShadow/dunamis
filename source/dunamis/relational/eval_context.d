module dunamis.relational.eval_context;

import std.algorithm;
import std.array;
import std.conv;
import std.json;
import std.typecons : Nullable;

import ae.utils.promise;

import dunamis.core.datasource : DataSource, DataSession, SetupMode, ChangeEvent;
import dunamis.core.types;
import dunamis.core.sorting : OrderBySpec, SortDirection;
import dunamis.relational.query_node;

/// Convert the JSON representation returned by SQL aggregation into a typed
/// column value. Kept at module scope so both optimized QueryResult decoding
/// and the generic/naive column dispatcher support the same type set.
private T extractJsonValue(T)(JSONValue val) {
    import std.conv : to;
    import std.json : JSONType;
    import std.typecons : Nullable;
    import dunamis.core.types : AnyRef, isCustomScalar;

    static if (is(T == Nullable!U, U)) {
        return val.type == JSONType.null_ ? T.init : T(extractJsonValue!U(val));
    } else if (val.type == JSONType.null_) {
        return T.init;
    } else static if (isCustomScalar!T) {
        return T(extractJsonValue!(T.DType)(val));
    } else static if (is(T == enum)) {
        return val.type == JSONType.string ? enumFromDbString!T(val.str) : T.init;
    } else static if (is(T == string)) {
        if (val.type == JSONType.integer) return val.integer.to!string;
        if (val.type == JSONType.float_) return val.floating.to!string;
        return val.str;
    } else static if (is(T == long)) {
        return val.type == JSONType.string ? val.str.to!long : val.integer;
    } else static if (is(T == int)) {
        return val.type == JSONType.string ? val.str.to!int : cast(int) val.integer;
    } else static if (is(T == bool)) {
        if (val.type == JSONType.true_ || val.type == JSONType.false_)
            return val.boolean;
        if (val.type == JSONType.integer)
            return val.integer != 0;
        if (val.type == JSONType.string)
            return val.str == "true" || val.str == "t" || val.str == "1" || val.str == "TRUE" || val.str == "T";
        return false;
    } else static if (is(T == double)) {
        return val.type == JSONType.integer ? cast(double) val.integer : val.floating;
    } else static if (is(T == float)) {
        return val.type == JSONType.integer ? cast(float) val.integer : cast(float) val.floating;
    } else static if (is(T == E[], E)) {
        if (val.type == JSONType.null_)
            return [];
        T result;
        if (val.type == JSONType.array) {
            foreach (element; val.array)
                result ~= extractJsonValue!E(element);
        } else if (val.type == JSONType.string && val.str.length >= 2 &&
                   val.str[0] == '{' && val.str[$ - 1] == '}') {
            // PostgreSQL arrays may remain text literals when selected through
            // compatibility views. Decode the one-dimensional wire syntax,
            // preserving quoted commas/backslashes and unquoted NULL values.
            auto body = val.str[1 .. $ - 1];
            string token;
            bool quoted, escaped, tokenWasQuoted;
            void appendToken() {
                if (!tokenWasQuoted && token == "NULL")
                    result ~= extractJsonValue!E(JSONValue(null));
                else
                    result ~= extractJsonValue!E(JSONValue(token));
                token = null;
                tokenWasQuoted = false;
            }
            foreach (c; body) {
                if (escaped) {
                    token ~= c;
                    escaped = false;
                } else if (quoted && c == '\\') {
                    escaped = true;
                } else if (c == '"') {
                    quoted = !quoted;
                    tokenWasQuoted = true;
                } else if (!quoted && c == ',') {
                    appendToken();
                } else {
                    token ~= c;
                }
            }
            if (body.length) appendToken();
        } else {
            throw new Exception("Expected JSON or PostgreSQL array while decoding " ~
                T.stringof ~ ", got " ~ val.type.to!string ~ ": " ~ val.toString());
        }
        return result;
    } else static if (is(T == struct)) {
        import std.traits : FieldNameTuple;
        T result;
        // PostgreSQL range values are emitted by row_to_json as their textual
        // representation. Decode range-shaped structs (e.g. a DateRange)
        // into their start/end members.
        static if (__traits(hasMember, T, "start") && __traits(hasMember, T, "end")) {
            if (val.type == JSONType.string) {
                auto text = val.str;
                auto comma = text.countUntil(',');
                if (comma >= 0 && text.length >= 2) {
                    auto start = text[1 .. cast(size_t) comma];
                    auto end = text[cast(size_t) comma + 1 .. $ - 1];
                    if (start.length)
                        result.start = extractJsonValue!(typeof(result.start))(JSONValue(start));
                    if (end.length)
                        result.end = extractJsonValue!(typeof(result.end))(JSONValue(end));
                }
                return result;
            }
        }
        static foreach (fieldName; FieldNameTuple!T) {{
            enum sqlName = (() {
                string name;
                foreach (i, c; fieldName) {
                    if (c >= 'A' && c <= 'Z') {
                        if (i > 0) name ~= '_';
                        name ~= cast(char)(c + ('a' - 'A'));
                    } else name ~= c;
                }
                return name;
            })();
            if (auto field = sqlName in val)
                __traits(getMember, result, fieldName) =
                    extractJsonValue!(typeof(__traits(getMember, result, fieldName)))(*field);
        }}
        return result;
    } else static if (is(T == AnyRef)) {
        return AnyRef(val.str);
    } else {
        static assert(false, "Unsupported JSON column type: " ~ T.stringof);
    }
}

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
// Enum Helpers
// ============================================================================

/// Convert a database string to a D enum value.
/// Matches the string against enum member names.
/// Returns T.init for empty strings or unknown values (graceful degradation).
T enumFromDbString(T)(string s) if (is(T == enum)) {
    import std.traits : EnumMembers;
    import std.string : toLower;

    if (s.length == 0) return T.init;

    static foreach (member; EnumMembers!T) {
        if (__traits(identifier, member).toLower == s.toLower) {
            return member;
        }
    }

    return T.init;  // Default for unknown values
}

// ============================================================================
// Relational Session (Per-Request)
// ============================================================================

/// Per-request session for relational data sources.
///
/// Holds the connection and transaction state for a single query/mutation
/// execution. Created by DataSource.createSession().
///
/// The main method is executeQueryNode(), which executes a QueryNode as a
/// single query and returns all results.
///
/// Individual fetch methods (fetchColumn, fetchChildren, etc.) are used
/// by the naive (unoptimized) evaluation path.
abstract class RelationalSession : DataSession {
    import dunamis.core.optimize : ExprOptimizer;
    import dunamis.core.expr : ExprBase;

    /// Cache of PK column names per table, populated by fetchAllIdsString calls.
    /// Used by naive-path fetchColumn* methods to generate correct WHERE clauses.
    protected string[][string] _pkColumnsByTable;

    /// Pre-fetched query results, keyed by QueryNode ID.
    /// Stored by PrefetchExpr after query execution, read by ProjectColumnExpr.
    private QueryResult[QueryNodeId] _queryResults;

    /// Mutation results, keyed by entity type name.
    /// Stored by InsertExpr/UpdateExpr, read by ColumnAccessExpr.
    private QueryResult[string] _mutationResults;

    /// Pending change events queued during mutations, fired post-commit.
    private ChangeEvent[] _pendingEvents;

    /// Listener for change events. When null (default), recordChange() is a
    /// no-op — zero overhead without subscriptions.
    private void delegate(ChangeEvent) _eventListener;

    /// Register a listener for change events (set by subscription infrastructure).
    void setEventListener(void delegate(ChangeEvent) listener) {
        _eventListener = listener;
    }

    /// Record a change event (called by mutation expressions after DB operation).
    /// No-op when no event listener is registered.
    void recordChange(string table, ChangeEvent.Kind kind, string[] ids) {
        if (_eventListener is null) return;
        auto event = new ChangeEvent();
        event.table = table;
        event.kind = kind;
        event.ids = ids;
        _pendingEvents ~= event;
    }

    /// Clear per-request state at the start of each request.
    /// Subclasses that override setup() should call super.setup().
    override Promise!void setup(SetupMode mode = SetupMode.query) {
        _pendingEvents = [];
        _queryResults.clear();
        _mutationResults.clear();
        return resolve();
    }

    /// Fire pending events post-commit and clear queue.
    /// Subclasses that override teardown() should call super.teardown() to
    /// ensure events fire after the transaction commits.
    override Promise!void teardown(SetupMode mode = SetupMode.query, bool success = true) {
        if (success && _pendingEvents.length > 0 && _eventListener !is null) {
            foreach (event; _pendingEvents) {
                _eventListener(event);
            }
        }
        _pendingEvents = [];
        return resolve();
    }

    /// Get the PK columns for a table (defaults to ["id"] if not cached)
    protected string[] getPkColumnsForTable(string table) {
        return _pkColumnsByTable.get(table, ["id"]);
    }

    // =========================================================================
    // Query Result Storage (for optimized path)
    // =========================================================================

    /// Store results from a QueryNode execution
    void storeQueryResult(QueryNodeId queryNodeId, QueryResult result) {
        assert(result !is null, "Cannot store null QueryResult");
        _queryResults[queryNodeId] = result;
    }

    /// Check if we have results for a query node
    bool hasQueryResult(QueryNodeId queryNodeId) {
        return (queryNodeId in _queryResults) !is null;
    }

    /// Get query result by node ID
    QueryResult getQueryResult(QueryNodeId queryNodeId) {
        return _queryResults.get(queryNodeId, null);
    }

    /// Get column values from pre-fetched results
    T[] getColumnValues(T)(QueryNodeId queryNodeId, string column, AnyRef[] refs) {
        auto result = _queryResults.get(queryNodeId, null);
        if (result is null) return refs.map!(_ => T.init).array;
        return result.getColumn!T(column, refs);
    }

    /// Get column values from a JOINed table
    T[] getJoinedColumnValues(T)(QueryNodeId queryNodeId, JoinAlias joinAlias, string column, AnyRef[] refs) {
        auto result = _queryResults.get(queryNodeId, null);
        if (result is null) return refs.map!(_ => T.init).array;
        return result.getJoinedColumn!T(joinAlias, column, refs);
    }

    /// Fetch all IDs for a table as strings, wrapped in AnyRef
    Promise!(AnyRef[]) fetchAllIdsAsRefs(string table, string typeName, string[] pkColumns) {
        // Cache PK columns for later use by fetchColumn* methods
        _pkColumnsByTable[table] = pkColumns;
        return fetchAllIdsString(table, pkColumns).then((string[] ids) {
            return ids.map!(id => makeAnyRef(typeName, id)).array;
        });
    }

    // =========================================================================
    // Mutation Result Storage
    // =========================================================================

    /// Store mutation result for later field access.
    /// Called by InsertExpr/UpdateExpr after executing the mutation.
    void storeMutationResult(string typeName, QueryResult result) {
        assert(typeName.length > 0, "Mutation typeName must not be empty");
        assert(result !is null, "Cannot store null mutation QueryResult");
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

    /// Get the original expression for a computed column alias (for fallback evaluation).
    /// Used when SQL push-down creates ProjectComputedExpr but the data source
    /// (like MockDB!()) can't actually evaluate the SQL expression.
    /// Returns null by default (no fallback available).
    ExprBase getOriginalExpr(string alias_) {
        return null;
    }

    /// Returns true if this session supports the naive (unoptimized) evaluation path.
    /// Some async databases (PostgreSQL, MySQL) only support the optimized path.
    /// Default: true (assumes naive path is supported).
    bool supportsNaivePath() {
        return true;
    }

    /// Execute raw SQL for session setup (SET LOCAL, SET TRANSACTION, etc.).
    /// Override in subclasses to execute against the actual database connection.
    /// Default: no-op.
    Promise!void execute(string sql) {
        return resolve();
    }

    /// Execute a QueryNode as a single query and return all results.
    /// This is the main entry point for the optimized path.
    ///
    /// For root nodes, parentResult is null.
    /// For child nodes, parentResult contains the parent's data (for FK lookups).
    abstract Promise!QueryResult executeQueryNode(QueryNode node, QueryResult parentResult);

    // =========================================================================
    // Individual fetch methods (for naive path and MockDB!() internals)
    // These return Promises to support async databases (PostgreSQL, MySQL).
    // Sync databases (SQLite, MockDB) wrap results with resolve().
    // =========================================================================

    /// Fetch column values for refs (template dispatcher)
    final Promise!(T[]) fetchColumn(T)(string table, string column, AnyRef[] refs) {
        import std.typecons : Nullable;
        import dunamis.core.types : isCustomScalar;
        import std.algorithm : map;
        import std.array : array;
        import std.json : JSONType;

        static if (is(T == Nullable!U, U)) {
            // Nullable type - use JSON fetch to preserve null information
            return fetchColumnJson(table, column, refs).then((JSONValue[] jsonValues) {
                T[] result;
                result.reserve(jsonValues.length);
                foreach (val; jsonValues) {
                    if (val.type == JSONType.null_) {
                        result ~= T.init;  // Null Nullable
                    } else {
                        result ~= T(extractJsonValue!U(val));
                    }
                }
                return result;
            });
        } else static if (isCustomScalar!T) {
            // Custom scalar - fetch underlying type and wrap
            return fetchColumn!(T.DType)(table, column, refs).then((T.DType[] rawValues) {
                return rawValues.map!(v => T(v)).array;
            });
        } else static if (is(T == enum)) {
            // D enum - fetch as string and convert
            return fetchColumnString(table, column, refs).then((string[] rawValues) {
                return rawValues.map!(v => enumFromDbString!T(v)).array;
            });
        } else static if (is(T == string)) {
            return fetchColumnString(table, column, refs);
        } else static if (is(T == long)) {
            return fetchColumnLong(table, column, refs);
        } else static if (is(T == int)) {
            return fetchColumnLong(table, column, refs).then((long[] longs) {
                // Element-wise conversion, not binary cast
                int[] result;
                result.reserve(longs.length);
                foreach (l; longs) {
                    result ~= cast(int) l;
                }
                return result;
            });
        } else static if (is(T == bool)) {
            return fetchColumnJson(table, column, refs).then((JSONValue[] values) {
                return values.map!(value => extractJsonValue!bool(value)).array;
            });
        } else static if (is(T == E[], E)) {
            return fetchColumnJson(table, column, refs).then((JSONValue[] values) {
                return values.map!(value => extractJsonValue!T(value)).array;
            });
        } else static if (is(T == struct)) {
            return fetchColumnJson(table, column, refs).then((JSONValue[] values) {
                return values.map!(value => extractJsonValue!T(value)).array;
            });
        } else {
            static assert(false, "Unsupported column type: " ~ T.stringof);
        }
    }

    /// Fetch string column values - override in subclass
    Promise!(string[]) fetchColumnString(string table, string column, AnyRef[] refs) {
        string[] result;
        result.length = refs.length;
        return resolve(result);
    }

    /// Fetch long column values - override in subclass
    Promise!(long[]) fetchColumnLong(string table, string column, AnyRef[] refs) {
        long[] result;
        result.length = refs.length;
        return resolve(result);
    }

    /// Fetch all IDs from a table as strings (supports any ID type including composite keys)
    abstract Promise!(string[]) fetchAllIdsString(string table, string[] pkColumns);

    /// Fetch children for parent refs (hasMany)
    /// Returns AnyRef[][] - one AnyRef[] per parent
    abstract Promise!(AnyRef[][]) fetchChildren(string childTable, string childType, string fk, AnyRef[] parentRefs);

    /// Fetch parent refs for child refs (belongsTo)
    /// Returns one AnyRef per child (or AnyRef.init for NULL FKs)
    abstract Promise!(AnyRef[]) fetchBelongsTo(string childTable, string fk, string parentType, AnyRef[] childRefs);

    /// Fetch a column as JSONValue array (type-erased).
    abstract Promise!(JSONValue[]) fetchColumnJson(string table, string column, AnyRef[] refs);

    // =========================================================================
    // Mutation methods (for INSERT/UPDATE/DELETE)
    // =========================================================================

    import dunamis.relational.mutation : InsertInput, UpdateInput;

    /// Execute INSERT and return the new row as QueryResult.
    /// Default implementation returns empty result (no-op).
    Promise!QueryResult executeInsert(string table, string typeName, InsertInput input, string[] pkColumns, bool isAutoIncrement) {
        return resolve(new QueryResult());
    }

    /// Execute UPDATE and return updated rows as QueryResult.
    /// Default implementation returns empty result (no-op).
    Promise!QueryResult executeUpdate(string table, string typeName, UpdateInput input, string[] pkColumns) {
        return resolve(new QueryResult());
    }

    /// Execute DELETE and return count of deleted rows.
    /// Default implementation returns 0 (no-op).
    Promise!int executeDelete(string table, string[] ids, string[] pkColumns) {
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

        /// Column data: column name → (ref id → value)
        JSONValue[string][string] _columns;

        /// All refs in result order
        AnyRef[] _allRefs;

        /// For child layers: groups of child refs by parent ref id
        AnyRef[][string] _childRefsByParent;
    }

    /// Initialize with refs (call before loadColumn)
    void initialize(string typeName, AnyRef[] refs) {
        _typeName = typeName;
        _allRefs = refs;
    }

    /// Load from row-oriented data (column-oriented storage built from rows)
    void loadFromRows(JSONValue[] rows, string typeName, string[] idColumns,
                               string parentFk = null, string parentType = null) {
        import dunamis.core.types : encodeCompositeKey;

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
            string idStr = encodeCompositeKey(keyParts);
            auto refId = typeName ~ ":" ~ idStr;
            _allRefs ~= AnyRef(refId);

            // If this is a child layer, also index by parent
            if (parentFk !is null && parentType !is null && parentFk in row) {
                auto parentIdVal = row[parentFk];
                if (parentIdVal.type != JSONType.null_) {
                    auto parentIdStr = jsonValToString(parentIdVal);
                    auto parentRefId = parentType ~ ":" ~ parentIdStr;
                    _childRefsByParent[parentRefId] ~= AnyRef(refId);
                }
            }
        }

        // Second pass: extract columns
        // Get all column names from first row
        if (rows.length > 0) {
            foreach (colName; rows[0].object.keys) {
                JSONValue[string] colData;
                foreach (i, row; rows) {
                    colData[_allRefs[i].id] = row[colName];
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
                auto parentRefId = parentType ~ ":" ~ parentIdStr;
                _childRefsByParent[parentRefId] ~= r;
            }
        }
    }

    /// Load a column's data
    void loadColumn(string column, AnyRef[] refs, JSONValue[] values) {
        assert(refs.length == values.length,
            "loadColumn: refs and values length mismatch");
        JSONValue[string] colData;
        foreach (i, r; refs) {
            colData[r.id] = values[i];
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
            if (auto valPtr = r.id in colData) {
                result ~= extractValue!T(*valPtr);
            } else {
                result ~= T.init;
            }
        }
        return result;
    }

    /// Get column from JOINed data (aliased columns like "j0__first_name")
    T[] getJoinedColumn(T)(JoinAlias joinAlias, string column, AnyRef[] refs) {
        auto fullColumn = joinAlias.value ~ "__" ~ column;
        return getColumn!T(fullColumn, refs);
    }

    /// Get child refs for parent refs (used by HasMany projection)
    AnyRef[][] getChildRefs(AnyRef[] parentRefs) {
        AnyRef[][] result;
        result.length = parentRefs.length;
        foreach (i, p; parentRefs) {
            if (auto children = p.id in _childRefsByParent) {
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

    /// Get raw JSONValue for a column (for FK lookups)
    JSONValue[] getColumnRaw(string column, AnyRef[] refs) {
        auto colData = _columns.get(column, null);
        if (colData is null) {
            JSONValue[] result;
            result.length = refs.length;
            foreach (ref r; result) r = JSONValue(null);
            return result;
        }

        JSONValue[] result;
        result.reserve(refs.length);
        foreach (r; refs) {
            if (auto valPtr = r.id in colData) {
                result ~= *valPtr;
            } else {
                result ~= JSONValue(null);
            }
        }
        return result;
    }

    /// Check if a ref exists in this result
    bool hasRef(AnyRef r) {
        // Check if ref is in _allRefs
        foreach (ref_; _allRefs) {
            if (ref_.id == r.id) return true;
        }
        return false;
    }

    /// Check if any of the given refs exist in this result.
    /// Used by fetchBelongsTo to disambiguate cached results that share
    /// the same FK column name (e.g., author_id on both Comment and Post).
    bool containsAnyRef(AnyRef[] refs) {
        if (_allRefs.length == 0 || refs.length == 0) return false;

        // Build a set for O(1) lookup
        bool[string] refSet;
        foreach (r; _allRefs) {
            refSet[r.id] = true;
        }
        foreach (r; refs) {
            if (r.id in refSet) return true;
        }
        return false;
    }

    private T extractValue(T)(JSONValue val) {
        return extractJsonValue!T(val);
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
    result.loadFromRows(rows, "User", ["id"]);

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
    result.loadFromRows(rows, "Comment", ["id"], "post_id", "Post");

    auto childRefs = result.getChildRefs([AnyRef("Post:1"), AnyRef("Post:2"), AnyRef("Post:3")]);
    assert(childRefs.length == 3);
    assert(childRefs[0].length == 2);  // Post:1 has 2 comments
    assert(childRefs[1].length == 1);  // Post:2 has 1 comment
    assert(childRefs[2].length == 0);  // Post:3 has no comments
}

unittest {
    // Test RelationalSession query result storage
    import dunamis.relational.mock : MockDB;
    static MockDB!() _testDb;
    _testDb = new MockDB!();

    auto session = cast(RelationalSession) _testDb.createSession();

    auto result = new QueryResult();
    result.initialize("User", [AnyRef("User:1"), AnyRef("User:2")]);
    session.storeQueryResult(QueryNodeId(0), result);

    assert(session.hasQueryResult(QueryNodeId(0)));
    assert(!session.hasQueryResult(QueryNodeId(1)));
    assert(session.getQueryResult(QueryNodeId(0)) is result);
}
