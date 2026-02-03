module graphqld2.core.eval;

import graphqld2.core.types;

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
