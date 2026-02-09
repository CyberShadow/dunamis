module dunamis.relational.eval_context;

import std.algorithm;
import std.array;
import std.conv;
import std.json;
import std.typecons : Nullable;

import ae.utils.promise;

import dunamis.core.types;
import dunamis.core.sorting : OrderBySpec, SortDirection;
import dunamis.relational.query_node;

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

    if (s.length == 0) return T.init;

    static foreach (member; EnumMembers!T) {
        if (__traits(identifier, member) == s) {
            return member;
        }
    }

    return T.init;  // Default for unknown values
}

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
    import dunamis.core.optimize : ExprOptimizer;
    import dunamis.core.expr : ExprBase;

    /// Cache of PK column names per table, populated by fetchAllIdsString calls.
    /// Used by naive-path fetchColumn* methods to generate correct WHERE clauses.
    protected string[][string] _pkColumnsByTable;

    /// Get the PK columns for a table (defaults to ["id"] if not cached)
    protected string[] getPkColumnsForTable(string table) {
        return _pkColumnsByTable.get(table, ["id"]);
    }

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

    /// Returns true if this fetcher supports the naive (unoptimized) evaluation path.
    /// Some async databases (PostgreSQL, MySQL) only support the optimized path.
    /// Default: true (assumes naive path is supported).
    bool supportsNaivePath() {
        return true;
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
                        // Extract inner value and wrap in Nullable
                        static if (isCustomScalar!U) {
                            // Custom scalar - extract underlying value and wrap
                            alias DType = U.DType;
                            static if (is(DType == int) || is(DType == long)) {
                                if (val.type == JSONType.integer) {
                                    result ~= T(U(cast(DType) val.integer));
                                } else if (val.type == JSONType.string) {
                                    import std.conv : to;
                                    result ~= T(U(val.str.to!DType));
                                } else {
                                    result ~= T.init;
                                }
                            } else static if (is(DType == string)) {
                                if (val.type == JSONType.string) {
                                    result ~= T(U(val.str));
                                } else if (val.type == JSONType.integer) {
                                    import std.conv : to;
                                    result ~= T(U(val.integer.to!string));
                                } else {
                                    result ~= T.init;
                                }
                            } else {
                                result ~= T.init;
                            }
                        } else static if (is(U == int) || is(U == long)) {
                            if (val.type == JSONType.integer) {
                                result ~= T(cast(U) val.integer);
                            } else if (val.type == JSONType.string) {
                                import std.conv : to;
                                result ~= T(val.str.to!U);
                            } else {
                                result ~= T.init;
                            }
                        } else static if (is(U == string)) {
                            if (val.type == JSONType.string) {
                                result ~= T(val.str);
                            } else if (val.type == JSONType.integer) {
                                import std.conv : to;
                                result ~= T(val.integer.to!string);
                            } else {
                                result ~= T.init;
                            }
                        } else {
                            // Fallback for other types
                            result ~= T.init;
                        }
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
        import std.typecons : Nullable;
        import dunamis.core.types : isCustomScalar;

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
        } else static if (is(T == enum)) {
            // D enum - extract as string and convert
            if (val.type == JSONType.string) {
                return enumFromDbString!T(val.str);
            }
            return T.init;
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
    private QueryResult[QueryNodeId] _queryResults;

    /// Mutation results, keyed by entity type name.
    /// Stored by InsertExpr/UpdateExpr, read by ColumnAccessExpr.
    private QueryResult[string] _mutationResults;

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

    /// Fetch all IDs for a table as strings, wrapped in AnyRef (delegates to fetcher)
    Promise!(AnyRef[]) fetchAllIdsString(string table, string typeName, string[] pkColumns) {
        if (fetcher !is null) {
            // Cache PK columns for later use by fetchColumn* methods
            fetcher._pkColumnsByTable[table] = pkColumns;
            return fetcher.fetchAllIdsString(table, pkColumns).then((string[] ids) {
                return ids.map!(id => makeAnyRef(typeName, id)).array;
            });
        }
        return resolve(cast(AnyRef[])[]);
    }

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
    // Test RelationalEvalContext
    auto ctx = new RelationalEvalContext();

    auto result = new QueryResult();
    result.initialize("User", [AnyRef("User:1"), AnyRef("User:2")]);
    ctx.storeQueryResult(QueryNodeId(0), result);

    assert(ctx.hasQueryResult(QueryNodeId(0)));
    assert(!ctx.hasQueryResult(QueryNodeId(1)));
    assert(ctx.getQueryResult(QueryNodeId(0)) is result);
}
