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

/// Whether column values of type `T` are records: structs decoded from a
/// JSON object of their fields (see `extractJsonValue`).
private template isRecordValue(T) {
    import std.traits : FieldNameTuple;
    import dunamis.core.types : AnyRef, isCustomScalar;
    import dunamis.relational.schema.attrs : hasDecodedBy;

    static if (is(T == struct) && !is(T == AnyRef) && !isCustomScalar!T && !hasDecodedBy!T)
        enum isRecordValue = FieldNameTuple!T.length > 0;
    else
        enum isRecordValue = false;
}

/// Convert the JSON representation returned by SQL aggregation into a typed
/// column value. Kept at module scope so both optimized QueryResult decoding
/// and the generic/naive column dispatcher support the same type set.
private T extractJsonValue(T)(JSONValue val) {
    import std.conv : to;
    import std.json : JSONType;
    import std.typecons : Nullable;
    import dunamis.core.types : AnyRef, isCustomScalar;
    import dunamis.relational.schema.attrs : hasDecodedBy, decodeWithDeclaredDecoder;

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
    } else static if (hasDecodedBy!T) {
        // A value type decoded from a representation of its own
        return decodeWithDeclaredDecoder!T(val);
    } else static if (is(T == struct)) {
        import std.traits : FieldNameTuple;
        T result;
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

/// Convert a database string to a D enum value: the member stored under
/// that label (see `dunamis.core.types.StoredAs`).
/// Returns T.init for empty strings or unknown values (graceful degradation).
T enumFromDbString(T)(string s) if (is(T == enum)) {
    import dunamis.core.types : enumFromStoredLabel;
    return enumFromStoredLabel!T(s);
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

    /// The queries of QueryNodes' own rows sent (see pendingQueryResult).
    private Promise!QueryResult[QueryNodeId] _pendingQueryResults;

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
        _pendingQueryResults.clear();
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

    /// The relation the session reads for the table (or logical relation
    /// name) `table` of entities: by default, `table` itself. A session may
    /// resolve names to other relations (e.g. PostgresSession's
    /// setRelationResolver).
    string relationSource(string table) {
        return table;
    }

    /// Record the PK columns of a table, for naive-path fetches of refs that
    /// did not come from a root fetch (e.g. children with a composite key).
    void notePkColumns(string table, string[] pkColumns) {
        _pkColumnsByTable[table] = pkColumns;
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

    /// The result of the query of the rows of the query node `queryNodeId`
    /// selects by itself, if it was sent in this session (it may still be
    /// pending), or null: evaluations of the node's PrefetchExpr in different
    /// scopes of a request share it.
    Promise!QueryResult pendingQueryResult(QueryNodeId queryNodeId) {
        return _pendingQueryResults.get(queryNodeId, null);
    }

    /// Record the query of the rows of a query node (see pendingQueryResult).
    void setPendingQueryResult(QueryNodeId queryNodeId, Promise!QueryResult result) {
        _pendingQueryResults[queryNodeId] = result;
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

    /// Fetch all IDs for a table as strings, wrapped in AnyRef, ordered by
    /// the `orderBy` columns (unordered if empty)
    Promise!(AnyRef[]) fetchAllIdsAsRefs(string table, string typeName, string[] pkColumns,
            string[] orderBy = null) {
        // Cache PK columns for later use by fetchColumn* methods
        _pkColumnsByTable[table] = pkColumns;
        return fetchAllIdsString(table, pkColumns, orderBy).then((string[] ids) {
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

    /// Execute raw SQL for session setup (SET LOCAL, SET TRANSACTION, etc.).
    /// Override in subclasses to execute against the actual database connection.
    /// Default: no-op.
    Promise!void execute(string sql) {
        return resolve();
    }

    /// Execute a QueryNode as a single query and return all results.
    /// This is the main entry point for the optimized path.
    ///
    /// For root nodes, parentResult is null, and `root` selects the root rows
    /// for this evaluation (normally `node.rootSelection`).
    /// For child nodes, parentResult contains the parent's data (for FK lookups).
    abstract Promise!QueryResult executeQueryNode(QueryNode node, QueryResult parentResult,
        RootSelection root);

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
            auto fetched = isRecordValue!U
                ? fetchRecordColumnJson(table, column, refs)
                : fetchColumnJson(table, column, refs);
            return fetched.then((JSONValue[] jsonValues) {
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
            auto fetched = isRecordValue!T
                ? fetchRecordColumnJson(table, column, refs)
                : fetchColumnJson(table, column, refs);
            return fetched.then((JSONValue[] values) {
                return values.map!(value => extractJsonValue!T(value)).array;
            });
        } else {
            static assert(false, "Unsupported column type: " ~ T.stringof);
        }
    }

    /// Fetch a column of a record (composite) type as JSONValue array, as
    /// objects keyed by field name (as the optimized path's JSON rows have
    /// them). By default, as `fetchColumnJson`.
    Promise!(JSONValue[]) fetchRecordColumnJson(string table, string column, AnyRef[] refs) {
        return fetchColumnJson(table, column, refs);
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

    /// Fetch all IDs from a table as strings (supports any ID type including
    /// composite keys), ordered by the `orderBy` columns (unordered if empty)
    abstract Promise!(string[]) fetchAllIdsString(string table, string[] pkColumns, string[] orderBy = null);

    /// Fetch children for parent refs (hasMany), each parent's children
    /// ordered by the `orderBy` child columns (unordered if empty).
    /// Returns AnyRef[][] - one AnyRef[] per parent
    abstract Promise!(AnyRef[][]) fetchChildren(string childTable, string childType, string fk, AnyRef[] parentRefs,
        string[] orderBy = null);

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

/// Keys of the rows of one entity type (or of their parents), as the local
/// ids (the part after "Type:") of their refs: integers (see
/// `isIntegerLocalId`) keyed as such, others (strings, composite keys) by
/// their text. Neither building nor looking up keys allocates strings or
/// hashes refs' full ids.
private struct LocalKeys(V) {
    V[long] byInt;
    V[string] byText;

    /// The value of the local id `text` (null if none).
    V* find(const(char)[] text) {
        long n;
        if (parseIntegerLocalId(text, n))
            return n in byInt;
        return text in byText;
    }

    /// The value of the local id `text`, added (as `V.init`) if need be.
    ref V require(string text) {
        long n;
        if (parseIntegerLocalId(text, n))
            return byInt.require(n);
        return byText.require(text);
    }

    /// ditto, of the local id of the integer `n` (its decimal text)
    ref V require(long n) {
        if (isIntegerLocalId(n))
            return byInt.require(n);
        return byText.require(n.to!string);
    }
}

/// Whether the decimal text of `n` is keyed as an integer (see
/// `parseIntegerLocalId`): if it has at most 18 digits.
private bool isIntegerLocalId(long n) pure nothrow @nogc @safe {
    enum long limit = 1_000_000_000_000_000_000L;
    return n > -limit && n < limit;
}

/// Parse the local id `text` as an integer, if it is the decimal text of one
/// as `to!string` renders it (no plus sign or leading zeros) of at most 18
/// digits; other texts are keyed as text.
private bool parseIntegerLocalId(const(char)[] text, out long n) pure nothrow @nogc @safe {
    size_t i;
    bool negative;
    if (text.length && text[0] == '-') {
        negative = true;
        i = 1;
    }
    auto digits = text.length - i;
    if (digits == 0 || digits > 18 || (text[i] == '0' && (digits > 1 || negative)))
        return false;
    long value;
    foreach (c; text[i .. $]) {
        if (c < '0' || c > '9')
            return false;
        value = value * 10 + (c - '0');
    }
    n = negative ? -value : value;
    return true;
}

/// The local id of the ref `id` (`"Type:local"`) if it is of `typeName`, or
/// null.
private const(char)[] localIdOf(string id, string typeName) pure nothrow @nogc @safe {
    if (id.length > typeName.length && id[typeName.length] == ':' && id[0 .. typeName.length] == typeName)
        return id[typeName.length + 1 .. $];
    return null;
}

/// Results from executing a QueryNode.
/// Column-oriented storage for efficient per-column access.
///
/// The rows are numbered in result order; refs map to their rows by their
/// local ids (see `LocalKeys`), and the values of a column are an array
/// indexed by row, built when the column is first read (from the rows of
/// `loadFromRows`) or loaded (`loadColumn`).
class QueryResult {
    private {
        string _typeName;

        /// All refs in result order (one per row)
        AnyRef[] _allRefs;

        /// The row of each ref (the last, for a ref repeated); refs not of
        /// the result's type (as `initialize` may be given) by their ids.
        LocalKeys!size_t _rowOf;
        size_t[string] _rowOfOtherType;

        /// The rows `loadFromRows` was given (JSON objects), which the
        /// columns read are built from
        JSONValue[] _rows;

        /// Column data: column name → values by row
        JSONValue[][string] _columns;

        /// For child layers: groups of child refs by parent (by the local id
        /// of the FK value)
        LocalKeys!(AnyRef[]) _childRefsByParent;

        /// For child layers: the FK column and parent type the rows are grouped by
        string _parentFk, _parentType;

        /// For child layers: the parents whose children this layer holds
        /// completely (the rows of the parent layer it was selected against).
        /// A parent absent from this set is *unknown* to the layer, not childless.
        LocalKeys!bool _coveredParents;
    }

    /// The rows of the refs last looked up (see rowsOf): a copy of the refs
    /// (whose ids are slices of the same strings), and their rows.
    private AnyRef[] _lookedUp;
    private size_t[] _lookedUpRows;

    /// The rows of `refs` (see rowOf). Reads of several columns for the
    /// same refs (e.g. of several fields of the same rows, which share their
    /// refs) look them up once.
    private const(size_t)[] rowsOf(AnyRef[] refs) {
        if (refs.length == _lookedUp.length && refs.length) {
            bool same = true;
            foreach (i, r; refs)
                if (r.id.ptr !is _lookedUp[i].id.ptr || r.id.length != _lookedUp[i].id.length) {
                    same = false;
                    break;
                }
            if (same)
                return _lookedUpRows;
        }
        auto rows = new size_t[refs.length];
        foreach (i, r; refs)
            rows[i] = rowOf(r);
        _lookedUp = refs.dup;
        _lookedUpRows = rows;
        return rows;
    }

    /// The row of `r`, or size_t.max if it is not one of the result's.
    private size_t rowOf(AnyRef r) {
        if (auto local = localIdOf(r.id, _typeName)) {
            if (auto row = _rowOf.find(local))
                return *row;
            return size_t.max;
        }
        if (_rowOfOtherType.length)
            if (auto row = r.id in _rowOfOtherType)
                return *row;
        return size_t.max;
    }

    /// Initialize with refs (call before loadColumn). Columns already
    /// loaded keep the values of the refs kept.
    void initialize(string typeName, AnyRef[] refs) {
        if (_rows.length)
            foreach (column; _rows[0].object.byKey)
                columnValues(column);
        auto oldColumns = _columns;
        auto oldRows = new size_t[refs.length];
        foreach (i, r; refs)
            oldRows[i] = rowOf(r);

        _typeName = typeName;
        _allRefs = refs;
        _lookedUp = null;
        _rows = null;
        _rowOf = LocalKeys!size_t.init;
        _rowOfOtherType = null;
        foreach (i, r; refs) {
            if (auto local = localIdOf(r.id, typeName))
                _rowOf.require(r.id[$ - local.length .. $]) = i;
            else
                _rowOfOtherType[r.id] = i;
        }
        _columns = null;
        foreach (column, values; oldColumns) {
            auto remapped = new JSONValue[refs.length];
            foreach (i, row; oldRows)
                remapped[i] = row < values.length ? values[row] : JSONValue(null);
            _columns[column] = remapped;
        }
    }

    /// Load from row-oriented data (column-oriented storage built from rows)
    void loadFromRows(JSONValue[] rows, string typeName, string[] idColumns,
                               string parentFk = null, string parentType = null) {
        import dunamis.core.types : encodeCompositeKey, makeAnyRef;

        _typeName = typeName;
        _lookedUp = null;
        _allRefs = new AnyRef[rows.length];
        _rowOf = LocalKeys!size_t.init;
        _rowOfOtherType = null;
        _rows = rows;
        _columns = null;
        _parentFk = parentFk;
        _parentType = parentType;

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

        // Collect all refs and build parent grouping
        bool grouped = parentFk !is null && parentType !is null;
        foreach (i, row; rows) {
            auto fields = row.object;
            // (The key of an integer is its decimal text, which needs no quoting)
            auto single = idColumns.length == 1 ? idColumns[0] in fields : null;
            if (single !is null && single.type == JSONType.integer) {
                auto n = single.integer;
                _allRefs[i] = makeAnyRef(typeName, n);
                _rowOf.require(n) = i;
            } else {
                string[] keyParts;
                foreach (col; idColumns) {
                    keyParts ~= jsonValToString(fields[col]);
                }
                auto key = encodeCompositeKey(keyParts);
                _allRefs[i] = makeAnyRef(typeName, key);
                _rowOf.require(key) = i;
            }

            // If this is a child layer, also index by parent
            if (grouped) {
                if (auto parentIdVal = parentFk in fields) {
                    if (parentIdVal.type == JSONType.integer)
                        _childRefsByParent.require(parentIdVal.integer) ~= _allRefs[i];
                    else if (parentIdVal.type != JSONType.null_)
                        _childRefsByParent.require(jsonValToString(*parentIdVal)) ~= _allRefs[i];
                }
            }
        }
    }

    /// The values of `column` by row (null if the result has no such column).
    private JSONValue[] columnValues(string column) {
        if (auto values = column in _columns)
            return *values;
        if (_rows.length == 0 || (column in _rows[0].object) is null)
            return null;
        auto values = new JSONValue[_rows.length];
        foreach (i, row; _rows) {
            if (auto value = column in row.object)
                values[i] = *value;
            else
                values[i] = JSONValue(null);
        }
        _columns[column] = values;
        return values;
    }

    /// Record which parents this child layer holds the complete children of:
    /// every row of `parentLayer`, identified by its `linkColumns` values
    /// (the values the child layer's FK was matched against).
    void recordCoveredParents(QueryResult parentLayer, string[] linkColumns) {
        import dunamis.core.types : encodeCompositeKey;
        auto links = new JSONValue[][linkColumns.length];
        foreach (i, col; linkColumns)
            links[i] = parentLayer.columnValues(col);
        foreach (row; 0 .. parentLayer._allRefs.length) {
            // (The key of an integer is its decimal text)
            if (links.length == 1 && row < links[0].length && links[0][row].type == JSONType.integer) {
                _coveredParents.require(links[0][row].integer) = true;
                continue;
            }
            string[] parts;
            foreach (values; links) {
                if (row >= values.length || values[row].type == JSONType.null_) {
                    parts = null;
                    break;
                }
                auto value = values[row];
                parts ~= value.type == JSONType.string ? value.str : value.toString();
            }
            if (parts.length)
                _coveredParents.require(encodeCompositeKey(parts)) = true;
        }
    }

    /// Whether this is a child layer of `childType` rows grouped by `fk` that
    /// holds the complete children of every (valid) parent in `parentRefs`,
    /// so that `getChildRefs(parentRefs)` faithfully answers the hasMany
    /// relationship for them.
    bool holdsChildrenOf(string childType, string fk, AnyRef[] parentRefs) {
        if (_parentFk.length == 0 || _typeName != childType || _parentFk != fk)
            return false;
        foreach (p; parentRefs) {
            if (!p.isValid)
                continue;
            auto local = localIdOf(p.id, _parentType);
            if (local is null || _coveredParents.find(local) is null)
                return false;
        }
        return true;
    }

    /// Initialize as child result with parent grouping
    void initializeAsChild(string typeName, AnyRef[] refs, AnyRef[] parentRefs,
                           string fkColumn, JSONValue[] fkValues) {
        initialize(typeName, refs);
        _parentFk = fkColumn;
        _parentType = parentRefs.length > 0 ? parentRefs[0].typeName : "";
        foreach (p; parentRefs)
            if (p.isValid)
                if (auto local = localIdOf(p.id, _parentType))
                    _coveredParents.require(p.id[$ - local.length .. $]) = true;

        // Build parent grouping from FK values
        foreach (i, r; refs) {
            auto fkVal = fkValues[i];
            if (fkVal.type == JSONType.integer)
                _childRefsByParent.require(fkVal.integer) ~= r;
            else if (fkVal.type != JSONType.null_)
                _childRefsByParent.require(fkVal.str) ~= r;
        }
    }

    /// Load a column's data
    void loadColumn(string column, AnyRef[] refs, JSONValue[] values) {
        assert(refs.length == values.length,
            "loadColumn: refs and values length mismatch");
        auto colData = new JSONValue[_allRefs.length];
        colData[] = JSONValue(null);
        foreach (i, r; refs) {
            auto row = rowOf(r);
            if (row < colData.length)
                colData[row] = values[i];
        }
        _columns[column] = colData;
    }

    /// Get all refs in this result
    AnyRef[] allRefs() {
        return _allRefs;
    }

    /// Get column values for given refs
    T[] getColumn(T)(string column, AnyRef[] refs) {
        auto result = new T[refs.length];
        auto colData = columnValues(column);
        if (colData is null)
            return result;
        foreach (i, row; rowsOf(refs))
            if (row < colData.length)
                result[i] = extractValue!T(colData[row]);
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
            auto local = localIdOf(p.id, _parentType);
            if (local is null)
                continue;
            if (auto children = _childRefsByParent.find(local))
                result[i] = *children;
        }
        return result;
    }

    /// Check if a column exists in this result
    bool hasColumn(string column) {
        return (column in _columns) !is null || (_rows.length && (column in _rows[0].object) !is null);
    }

    /// Get raw JSONValue for a column (for FK lookups)
    JSONValue[] getColumnRaw(string column, AnyRef[] refs) {
        auto result = new JSONValue[refs.length];
        result[] = JSONValue(null);
        auto colData = columnValues(column);
        if (colData is null)
            return result;
        foreach (i, row; rowsOf(refs))
            if (row < colData.length)
                result[i] = colData[row];
        return result;
    }

    /// Check if a ref exists in this result
    bool hasRef(AnyRef r) {
        return rowOf(r) != size_t.max;
    }

    /// Check if every valid ref in `refs` exists in this result (and at least
    /// one does). Used by fetchBelongsTo to pick a cached result to read FK
    /// values from: refs carry their type, which disambiguates results that
    /// share an FK column name (e.g., author_id on both Comment and Post), and
    /// a result holding only some of the refs would report the others'
    /// parents as NULL.
    bool containsAllRefs(AnyRef[] refs) {
        if (_allRefs.length == 0) return false;
        bool any;
        foreach (r; refs) {
            if (!r.isValid) continue;
            if (rowOf(r) == size_t.max) return false;
            any = true;
        }
        return any;
    }

    private T extractValue(T)(JSONValue val) {
        return extractJsonValue!T(val);
    }
}

/// Load the layers of one batched CTE execution (`{"layer0": [rows], ...}`)
/// into per-node QueryResults, storing each in `cache`. Child layers record
/// which parents they hold the complete children of, so a later hasMany
/// lookup can tell a childless parent from one the layer never covered.
/// Returns the root node's result (or an empty result if absent).
QueryResult loadLayerResults(JSONValue layers, QueryNode[] nodes,
        ref QueryResult[QueryNode] cache) {
    import dunamis.relational.sql : layerGroupKey;
    import std.algorithm.searching : startsWith;

    // The layers of a query with many are grouped (see layerGroupSize)
    if (layers.type == JSONType.object) {
        JSONValue[string] flat;
        bool grouped;
        foreach (key, value; layers.object) {
            if (key.startsWith(layerGroupKey) && value.type == JSONType.object) {
                grouped = true;
                foreach (k, v; value.object)
                    flat[k] = v;
            } else
                flat[key] = value;
        }
        if (grouped)
            layers = JSONValue(flat);
    }

    QueryResult rootResult;
    QueryResult[QueryNode] loaded;
    foreach (node; nodes) {
        if (node.sameRowsAs !is null)
            continue;
        auto layerKey = "layer" ~ node.id.value.to!string;
        auto layerRows = layerKey in layers;
        if (layerRows is null)
            continue;
        auto result = new QueryResult();
        if (node.isRoot) {
            result.loadFromRows(layerRows.array, node.typeName, node.pkColumns);
            rootResult = result;
        } else {
            result.loadFromRows(layerRows.array, node.typeName, node.pkColumns,
                node.parentFk, node.parentTypeName);
        }
        loaded[node] = result;
        cache[node] = result;
    }
    // Nodes merged into another hold its layer's rows (see QueryNode.mergeFrom)
    foreach (node; nodes)
        if (node.sameRowsAs !is null)
            if (auto layer = node.layerNode in loaded) {
                loaded[node] = *layer;
                cache[node] = *layer;
            }
    foreach (node, result; loaded)
        if (!node.isRoot && node.sameRowsAs is null)
            if (auto parentResult = node.parent in loaded)
                result.recordCoveredParents(*parentResult, node.parentLinkColumns);
    return rootResult !is null ? rootResult : new QueryResult();
}

/// Find a cached child layer that faithfully answers the hasMany relationship
/// `childType`.`fk` for every parent in `parentRefs`, or null if none does
/// (the caller must then fetch the children itself). A layer of the same
/// child type is not enough: it may be grouped by another FK, be a root layer,
/// or have been selected for a different set of parents.
QueryResult findChildLayer(QueryResult[QueryNode] cache, string childType,
        string fk, AnyRef[] parentRefs) {
    foreach (result; cache.byValue)
        if (result.holdsChildrenOf(childType, fk, parentRefs))
            return result;
    return null;
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
    // Rows of composite and of text keys, and of integer keys which are not
    // keyed as integers, are found by their refs; refs of other types and
    // of other rows are not
    auto pairs = new QueryResult();
    pairs.loadFromRows([parseJSON(`{"a": 1, "b": "x,y", "v": 10}`), parseJSON(`{"a": 2, "b": "", "v": 20}`)],
        "Pair", ["a", "b"]);
    assert(pairs.allRefs == [AnyRef(`Pair:1,"x,y"`), AnyRef(`Pair:2,""`)]);
    assert(pairs.getColumn!int("v", [AnyRef(`Pair:2,""`), AnyRef(`Pair:1,"x,y"`), AnyRef("Pair:1")]) == [20, 10, 0]);

    auto codes = new QueryResult();
    codes.loadFromRows([parseJSON(`{"code": "007", "v": 1}`), parseJSON(`{"code": "7", "v": 2}`),
        parseJSON(`{"code": "-0", "v": 3}`)], "Code", ["code"]);
    assert(codes.getColumn!int("v", [AnyRef("Code:7"), AnyRef("Code:007"), AnyRef("Code:-0"), AnyRef("Other:7")]) ==
        [2, 1, 3, 0]);

    auto big = new QueryResult();
    big.loadFromRows([parseJSON(`{"id": 9223372036854775807, "v": 1}`), parseJSON(`{"id": -5, "v": 2}`)],
        "Big", ["id"], "parent_id", "Parent");
    assert(big.allRefs == [AnyRef("Big:9223372036854775807"), AnyRef("Big:-5")]);
    assert(big.getColumn!int("v", [AnyRef("Big:-5"), AnyRef("Big:9223372036854775807")]) == [2, 1]);
    assert(!big.hasRef(AnyRef("Big:5")) && !big.hasColumn("w"));

    // Re-initialized (e.g. reordered) refs keep their loaded values
    auto mock = new QueryResult();
    mock.initialize("User", [AnyRef("User:1"), AnyRef("User:2")]);
    mock.loadColumn("name", [AnyRef("User:2"), AnyRef("User:1")], [JSONValue("b"), JSONValue("a")]);
    mock.initialize("User", [AnyRef("User:2"), AnyRef("User:1")]);
    assert(mock.getColumn!string("name", mock.allRefs) == ["b", "a"]);
    assert(mock.getColumnRaw("name", [AnyRef("User:3")]) == [JSONValue(null)]);
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
    // A hasMany lookup must only be answered by the child layer that was
    // selected for exactly that relationship and those parents. Shape:
    // comments(root) -> post (joined as j0) -> comments(child layer), so the
    // root and child layers share the child type.
    auto rootNode = new QueryNode(QueryNodeId(0), "Comment", "comments", ["id"]);
    auto childNode = new QueryNode(QueryNodeId(1), "Comment", "comments", ["id"]);
    childNode.setParent(rootNode, "post_id", "Post", ["j0__id"]);

    QueryResult[QueryNode] cache;
    auto root = loadLayerResults(parseJSON(`{
        "layer0": [{"id": 1, "post_id": 1, "j0__id": 1}, {"id": 2, "post_id": 2, "j0__id": 2}],
        "layer1": [{"id": 1, "post_id": 1}, {"id": 2, "post_id": 2}, {"id": 3, "post_id": 2}]
    }`), [rootNode, childNode], cache);
    assert(root is cache[rootNode]);

    auto posts = [AnyRef("Post:1"), AnyRef("Post:2")];
    auto layer = findChildLayer(cache, "Comment", "post_id", posts);
    assert(layer is cache[childNode]);
    assert(layer.getChildRefs(posts) ==
        [[AnyRef("Comment:1")], [AnyRef("Comment:2"), AnyRef("Comment:3")]]);

    // A parent the child layer was not selected for is unknown, not childless
    assert(findChildLayer(cache, "Comment", "post_id", [AnyRef("Post:3")]) is null);
    // Same child type, different relationship
    assert(findChildLayer(cache, "Comment", "author_id", posts) is null);
    // Different child type
    assert(findChildLayer(cache, "Post", "post_id", posts) is null);

    // A root layer never answers hasMany lookups, even when its type matches
    QueryResult[QueryNode] rootOnly;
    rootOnly[rootNode] = cache[rootNode];
    assert(findChildLayer(rootOnly, "Comment", "post_id", posts) is null);

    // fetchBelongsTo may only read FKs from a result holding all its refs
    assert(root.containsAllRefs([AnyRef("Comment:1"), AnyRef("Comment:2")]));
    assert(!root.containsAllRefs([AnyRef("Comment:1"), AnyRef("Comment:3")]));
    assert(!root.containsAllRefs([AnyRef("Post:1")]));
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

// A value type declaring its decoder (`@DecodedBy`) is decoded by it; other
// structs from JSON objects with a member per field.
version (unittest) {
    import dunamis.relational.schema.attrs : DecodedBy;

    private Interval decodeInterval(JSONValue v) {
        import std.string : split;
        auto bounds = v.str.split("..");
        return Interval(bounds[0].to!int, bounds[1].to!int);
    }

    @DecodedBy!decodeInterval
    private struct Interval { int from; int to; }

    private struct Pair { int from; int to; }
}

unittest {
    assert(extractJsonValue!Interval(JSONValue("3..5")) == Interval(3, 5));
    assert(extractJsonValue!(Nullable!Interval)(JSONValue(null)).isNull);
    assert(extractJsonValue!Pair(parseJSON(`{"from": 3, "to": 5}`)) == Pair(3, 5));
}
