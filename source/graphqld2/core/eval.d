module graphqld2.core.eval;

import graphqld2.core.types;

// ============================================================================
// Eval Context - Data Source Agnostic
// ============================================================================

/// Key for looking up source-specific contexts
private struct SourceKey {
    TypeInfo type;
    string sourceId;
}

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
    private {
        Object[SourceKey] _sourceContexts;
    }

    /// The refs currently being iterated over within a MapExpr.
    ///
    /// This is the communication channel between MapExpr and EveryItemOfExpr:
    /// - MapExpr sets this to the flattened collection items before evaluating its body
    /// - EveryItemOfExpr returns this value (representing "the current items")
    /// - MapExpr restores the previous value after body evaluation
    ///
    /// Other expressions should NOT use this for batch size - they should derive
    /// length from their inputs instead.
    Ref[] currentRefs;

    /// Get or create a source-specific evaluation context.
    /// Each data source type has its own context for storing fetched data.
    T getSourceContext(T)(string sourceId = "default") {
        auto key = SourceKey(typeid(T), sourceId);
        if (auto ctx = key in _sourceContexts) {
            return cast(T) *ctx;
        }
        auto ctx = new T();
        _sourceContexts[key] = ctx;
        return ctx;
    }

    /// Get all source contexts (for iteration)
    Object[SourceKey] allSourceContexts() {
        return _sourceContexts;
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
