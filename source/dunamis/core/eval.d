module dunamis.core.eval;

import dunamis.core.types;

// ============================================================================
// Type-Safe Storage for Heterogeneous Values
// ============================================================================

/// Type-safe wrapper for storing arrays of any type with runtime type checking.
/// Avoids serialization overhead of JSONValue while providing safety.
struct SealedArray {
    private void[] _data;
    private TypeInfo _type;

    /// Construct from a typed array.
    this(T)(T[] arr) {
        _data = cast(void[]) arr;
        _type = typeid(T);
    }

    /// Check if the stored type matches T.
    bool hasType(T)() const {
        return _type == typeid(T);
    }

    /// Retrieve as typed array. Asserts if type doesn't match.
    T[] get(T)() {
        assert(_type == typeid(T), "SealedArray type mismatch: expected " ~ _type.toString() ~ ", got " ~ typeid(T).toString());
        return cast(T[]) _data;
    }

    /// Check if empty (uninitialized).
    bool empty() const {
        return _data.length == 0;
    }
}

// ============================================================================
// Eval Context - Abstract Key-Value Storage
// ============================================================================

/// Evaluation context providing abstract key-value storage for expressions.
/// Each data source (relational, REST, etc.) registers its own context type.
///
/// The context provides:
/// - Generic value storage (setValues/getValues) for expressions to communicate
/// - Expression result caching for memoization
/// - Source-specific context registration
///
/// Usage:
///   auto relCtx = evalCtx.getSourceContext!RelationalEvalContext();
///   auto values = relCtx.getColumnValues!string("name", refs);
class EvalContext {
    mixin SourceContextRegistry;

    /// Generic value storage keyed by expression identity.
    /// Expressions use this to pass values to their children.
    /// Examples:
    /// - MapExpr stores N items for EveryItemOfExpr to retrieve
    /// - SortByExpr stores 2 items (left, right) for SortItemExpr
    /// - FilterByExpr stores 1 item for FilterItemExpr
    /// - Optimized paths store AnyRef[] for column access
    private SealedArray[void*] _valueMap;

    /// Expression evaluation cache, keyed by expression object identity.
    /// Used by evalAs() to automatically memoize expression evaluation.
    /// When the same expression is evaluated multiple times (e.g., via
    /// parallel dependencies), the same Promise is returned.
    /// Uses SealedArray for runtime type checking (stores promise as 1-element array).
    private SealedArray[void*] _exprCache;

    /// Set values for an expression (generic storage for any T[]).
    void setValues(T)(Object key, T[] vals) {
        _valueMap[cast(void*) key] = SealedArray(vals);
    }

    /// Get values for an expression.
    /// Returns empty array if not set or if type doesn't match.
    T[] getValues(T)(Object key) {
        if (auto p = cast(void*) key in _valueMap) {
            if (!p.empty && p.hasType!T) {
                return p.get!T();
            }
        }
        return [];
    }

    /// Get cached Promise for an expression, or null if types don't match.
    /// Uses runtime type checking via SealedArray — asserts on type mismatch
    /// rather than silently returning null.
    import ae.utils.promise : Promise;
    Promise!(T[]) getCachedEval(T)(Object expr) {
        if (auto p = cast(void*) expr in _exprCache) {
            if (p.hasType!(Promise!(T[])))
                return p.get!(Promise!(T[]))()[0];
        }
        return null;
    }

    /// Cache a Promise for an expression.
    /// Only caches if no entry exists yet — avoids overwriting a differently-typed
    /// cached promise (the same expression may be evaluated as different types).
    void setCachedEval(T)(Object expr, Promise!(T[]) promise) {
        auto key = cast(void*) expr;
        if (key !in _exprCache)
            _exprCache[key] = SealedArray([promise]);
    }

    /// Clear the cached eval for a specific expression.
    /// Used by filtering/sorting to invalidate cache between iterations.
    void clearCachedEval(Object expr) {
        _exprCache.remove(cast(void*) expr);
    }

    /// Clear all cached evaluations.
    /// Used when context state changes in ways that invalidate all cached results.
    void clearAllCachedEvals() {
        _exprCache.clear();
    }

    // ========================================================================
    // Request Context Storage
    // ========================================================================

    /// Type-keyed storage for request-scoped context values.
    /// Users can store multiple context types (e.g., AuthCtx, TenantCtx)
    /// and retrieve them from computed fields via context!T(expr).
    private void*[TypeInfo] _requestContexts;

    /// Store a request context value. Call once per type before executing a query.
    /// Only struct types are supported (value semantics, no aliasing issues).
    void setRequestContext(T)(T value) if (is(T == struct)) {
        auto p = new T;
        *p = value;
        _requestContexts[typeid(T)] = cast(void*) p;
    }

    /// Retrieve a previously stored request context value.
    /// Asserts if the context type was not set — this is a programming error.
    T getRequestContext(T)() if (is(T == struct)) {
        auto p = typeid(T) in _requestContexts;
        assert(p !is null,
            "Request context " ~ T.stringof ~ " not set. " ~
            "Call evalCtx.setRequestContext(" ~ T.stringof ~ "(...)) before executing the query.");
        return *(cast(T*) *p);
    }

    /// Check if a request context type has been set.
    bool hasRequestContext(T)() if (is(T == struct)) {
        return (typeid(T) in _requestContexts) !is null;
    }
}

// ============================================================================
// Tests
// ============================================================================

/// Test source context class (must be at module level for `new T()` to work)
private class TestEvalSourceContext {
    int value = 99;
}

unittest {
    // Test source context creation
    auto ctx = new EvalContext();

    auto src1 = ctx.getSourceContext!TestEvalSourceContext("db1");
    auto src2 = ctx.getSourceContext!TestEvalSourceContext("db2");
    auto src1again = ctx.getSourceContext!TestEvalSourceContext("db1");

    assert(src1 !is src2);  // Different source IDs
    assert(src1 is src1again);  // Same source ID returns same context
    assert(src1.value == 99);
}

unittest {
    // Test generic value storage
    auto ctx = new EvalContext();

    static struct TestEntity { int id; }

    auto key1 = new Object();
    auto key2 = new Object();

    ctx.setValues!TestEntity(key1, [TestEntity(1), TestEntity(2)]);
    ctx.setValues!int(key2, [10, 20, 30]);

    auto vals1 = ctx.getValues!TestEntity(key1);
    assert(vals1.length == 2);
    assert(vals1[0].id == 1);
    assert(vals1[1].id == 2);

    auto vals2 = ctx.getValues!int(key2);
    assert(vals2 == [10, 20, 30]);

    // Non-existent key returns empty
    auto vals3 = ctx.getValues!int(new Object());
    assert(vals3.length == 0);
}

unittest {
    // Test request context storage with multiple types
    static struct AuthCtx { string userId; bool isAdmin; }
    static struct TenantCtx { string tenantId; string locale; }

    auto ctx = new EvalContext();

    // Initially not set
    assert(!ctx.hasRequestContext!AuthCtx);
    assert(!ctx.hasRequestContext!TenantCtx);

    // Set and retrieve AuthCtx
    ctx.setRequestContext(AuthCtx("user-1", true));
    assert(ctx.hasRequestContext!AuthCtx);
    auto auth = ctx.getRequestContext!AuthCtx;
    assert(auth.userId == "user-1");
    assert(auth.isAdmin == true);

    // Set and retrieve TenantCtx (independent of AuthCtx)
    ctx.setRequestContext(TenantCtx("tenant-abc", "fr"));
    assert(ctx.hasRequestContext!TenantCtx);
    auto tenant = ctx.getRequestContext!TenantCtx;
    assert(tenant.tenantId == "tenant-abc");
    assert(tenant.locale == "fr");

    // AuthCtx still available
    auto authAgain = ctx.getRequestContext!AuthCtx;
    assert(authAgain.userId == "user-1");

    // Overwrite with new value
    ctx.setRequestContext(AuthCtx("user-2", false));
    auto authNew = ctx.getRequestContext!AuthCtx;
    assert(authNew.userId == "user-2");
    assert(authNew.isAdmin == false);
}
