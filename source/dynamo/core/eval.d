module dynamo.core.eval;

import dynamo.core.types;

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

/// Type-safe wrapper for storing a single value of any type.
struct SealedValue {
    private void* _data;  // Heap-allocated value
    private TypeInfo _type;

    /// Construct from a typed value.
    this(T)(T val) {
        _data = [val].ptr;  // Allocate on heap via GC
        _type = typeid(T);
    }

    /// Retrieve as typed value. Asserts if type doesn't match.
    T get(T)() {
        assert(_type == typeid(T), "SealedValue type mismatch: expected " ~ _type.toString() ~ ", got " ~ typeid(T).toString());
        return *cast(T*) _data;
    }

    /// Check if empty (uninitialized).
    bool empty() const {
        return _data is null;
    }
}

// ============================================================================
// Eval Context - Data Source Agnostic
// ============================================================================

/// Top-level evaluation context that holds per-source contexts.
/// Each data source (relational, REST, etc.) registers its own context type.
///
/// The context also carries the current batch refs being evaluated.
/// This is set by MapExpr before evaluating its body, allowing expressions
/// to access the refs without explicit parameter passing.
///
/// Usage:
///   auto relCtx = evalCtx.getSourceContext!RelationalEvalContext();
///   auto values = relCtx.getColumnValues!string(nodeId, "name", refs);
class EvalContext {
    mixin SourceContextRegistry;

    /// Refs keyed by MapExpr identity.
    /// This allows parallel evaluation of expressions without interference.
    ///
    /// Communication between MapExpr and EveryItemOfExpr:
    /// - MapExpr calls setCurrentRefs(this, flatRefs) before evaluating its body
    /// - EveryItemOfExpr calls getCurrentRefs(_parentMap) to get its refs
    ///
    /// The null key is used for the root level (queryRoot).
    /// Uses AnyRef for storage since different MapExpr scopes may have different entity types.
    private AnyRef[][void*] _refsMap;

    /// Sort comparison items keyed by SortByExpr identity.
    /// Communication between SortByExpr and SortItemExpr:
    /// - SortByExpr calls setSortItems(this, left, right) before evaluating predicate
    /// - SortItemExpr calls getSortItem(_parentSort, _isLeftItem) to get its ref
    private AnyRef[2][void*] _sortItemsMap;

    /// Predicate evaluation items keyed by SomeExpr/EveryExpr identity.
    /// Communication between SomeExpr/EveryExpr and EveryItemOfExpr:
    /// - SomeExpr/EveryExpr calls setPredicateItem(this, ref) before evaluating predicate
    /// - EveryItemOfExpr calls getPredicateItem(_parentMap) if getCurrentRefs is empty
    /// Unlike map which evaluates all items at once, some/every evaluates one at a time.
    private AnyRef[void*] _predicateItemMap;

    /// Filter evaluation items keyed by FilterByExpr identity.
    /// Communication between FilterByExpr and FilterItemExpr:
    /// - FilterByExpr calls setFilterItem(this, ref) before evaluating predicate
    /// - FilterItemExpr calls getFilterItem(_parentFilter) to get its ref
    /// Similar to some/every, filter evaluates one item at a time.
    private AnyRef[void*] _filterItemMap;

    /// Scalar array batch refs keyed by SomeExpr/EveryExpr identity.
    /// Used for scalar collections (string[], int[], etc.) similar to _refsMap for entities.
    /// Uses SealedArray for type-safe storage without serialization overhead.
    private SealedArray[void*] _scalarRefsMap;

    /// Scalar array single item keyed by SomeExpr/EveryExpr identity.
    /// Fallback when batch refs aren't set (single-item predicate evaluation).
    private SealedValue[void*] _scalarItemMap;

    /// Expression evaluation cache, keyed by expression object identity.
    /// Used by evalAs() to automatically memoize expression evaluation.
    /// When the same expression is evaluated multiple times (e.g., via
    /// parallel dependencies), the same Promise is returned.
    ///
    /// This is type-erased (Object) since different expressions return
    /// different Promise types. evalAs() casts back to the expected type.
    private Object[void*] _exprCache;

    /// Set refs for a specific MapExpr (or null for root).
    void setCurrentRefs(Object mapExpr, AnyRef[] refs) {
        _refsMap[cast(void*) mapExpr] = refs;
    }

    /// Get refs for a specific MapExpr (or null for root).
    AnyRef[] getCurrentRefs(Object mapExpr) {
        if (auto p = cast(void*) mapExpr in _refsMap) {
            return *p;
        }
        return [];
    }

    /// Set scalar refs for batch evaluation of scalar arrays.
    void setScalarRefs(T)(Object expr, T[] vals) {
        _scalarRefsMap[cast(void*) expr] = SealedArray(vals);
    }

    /// Get scalar refs for batch evaluation.
    T[] getScalarRefs(T)(Object expr) {
        if (auto p = cast(void*) expr in _scalarRefsMap) {
            if (!p.empty) {
                return p.get!T();
            }
        }
        return [];
    }

    /// Set comparison items for a SortByExpr.
    /// Used during sort predicate evaluation.
    void setSortItems(Object sortExpr, AnyRef left, AnyRef right) {
        _sortItemsMap[cast(void*) sortExpr] = [left, right];
    }

    /// Get a comparison item for a SortItemExpr.
    /// isLeft: true for left item (a), false for right item (b)
    AnyRef getSortItem(Object sortExpr, bool isLeft) {
        if (auto p = cast(void*) sortExpr in _sortItemsMap) {
            return (*p)[isLeft ? 0 : 1];
        }
        return AnyRef.init;
    }

    /// Set single predicate item for SomeExpr/EveryExpr.
    /// Used during some/every predicate evaluation (one item at a time).
    void setPredicateItem(Object predicateExpr, AnyRef item) {
        _predicateItemMap[cast(void*) predicateExpr] = item;
    }

    /// Get single predicate item for EveryItemOfExpr in some/every context.
    /// Returns AnyRef.init if not set.
    AnyRef getPredicateItem(Object predicateExpr) {
        if (auto p = cast(void*) predicateExpr in _predicateItemMap) {
            return *p;
        }
        return AnyRef.init;
    }

    /// Set filter item for FilterByExpr.
    /// Used during filter predicate evaluation (one item at a time).
    void setFilterItem(Object filterExpr, AnyRef item) {
        _filterItemMap[cast(void*) filterExpr] = item;
    }

    /// Get filter item for FilterItemExpr.
    /// Returns AnyRef.init if not set.
    AnyRef getFilterItem(Object filterExpr) {
        if (auto p = cast(void*) filterExpr in _filterItemMap) {
            return *p;
        }
        return AnyRef.init;
    }

    /// Set scalar item for SomeExpr/EveryExpr with scalar element types.
    /// Used during scalar array predicate evaluation (one item at a time).
    void setScalarItem(T)(Object scalarExpr, T item) {
        _scalarItemMap[cast(void*) scalarExpr] = SealedValue(item);
    }

    /// Get scalar item for EveryItemOfExpr with scalar element types.
    /// Returns T.init if not set.
    T getScalarItem(T)(Object scalarExpr) {
        if (auto p = cast(void*) scalarExpr in _scalarItemMap) {
            if (!p.empty) {
                return p.get!T();
            }
        }
        return T.init;
    }

    /// Check if a scalar item is set for the given expression.
    bool hasScalarItem(Object scalarExpr) {
        if (auto p = cast(void*) scalarExpr in _scalarItemMap) {
            return !p.empty;
        }
        return false;
    }

    /// Get cached Promise for an expression, or null if not cached.
    /// Used internally by evalAs() for automatic memoization.
    Object getCachedEval(Object expr) {
        if (auto p = cast(void*) expr in _exprCache) {
            return *p;
        }
        return null;
    }

    /// Cache a Promise for an expression.
    /// Used internally by evalAs() for automatic memoization.
    void setCachedEval(Object expr, Object promise) {
        _exprCache[cast(void*) expr] = promise;
    }

    /// Clear the cached eval for a specific expression.
    /// Used by some/every to invalidate placeholder cache between iterations.
    void clearCachedEval(Object expr) {
        _exprCache.remove(cast(void*) expr);
    }

    /// Clear all cached evaluations.
    /// Used when context state changes in ways that invalidate all cached results.
    void clearAllCachedEvals() {
        _exprCache.clear();
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
