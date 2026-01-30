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
    private Ref[][void*] _refsMap;

    /// Set refs for a specific MapExpr (or null for root).
    void setCurrentRefs(Object mapExpr, Ref[] refs) {
        _refsMap[cast(void*) mapExpr] = refs;
    }

    /// Get refs for a specific MapExpr (or null for root).
    Ref[] getCurrentRefs(Object mapExpr) {
        if (auto p = cast(void*) mapExpr in _refsMap) {
            return *p;
        }
        return [];
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
