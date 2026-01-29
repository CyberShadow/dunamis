module graphqld2.core.optimize;

// ============================================================================
// Optimize Context - Data Source Agnostic
// ============================================================================

/// Key for looking up source-specific contexts
private struct SourceKey {
    TypeInfo type;
    string sourceId;
}

/// Top-level optimization context that holds per-source contexts.
/// Each data source (relational, REST, etc.) registers its own context type.
///
/// Usage:
///   auto relCtx = optCtx.getSourceContext!RelationalOptimizeContext();
///   auto node = relCtx.getOrCreateNode(mapExpr, typeName, table);
class OptimizeContext {
    private {
        Object[SourceKey] _sourceContexts;
    }

    /// Get or create a source-specific optimization context.
    /// Each data source type has its own context for tracking optimization state.
    T getSourceContext(T)(string sourceId = "default") {
        auto key = SourceKey(typeid(T), sourceId);
        if (auto ctx = key in _sourceContexts) {
            return cast(T) *ctx;
        }
        auto ctx = new T();
        _sourceContexts[key] = ctx;
        return ctx;
    }

    /// Get all source contexts (for iteration after optimization)
    Object[SourceKey] allSourceContexts() {
        return _sourceContexts;
    }
}

// ============================================================================
// Tests
// ============================================================================

/// Test source context class (must be at module level for `new T()` to work)
private class TestSourceContext {
    int value = 42;
}

unittest {
    // Test source context creation
    auto ctx = new OptimizeContext();

    auto src1 = ctx.getSourceContext!TestSourceContext("db1");
    auto src2 = ctx.getSourceContext!TestSourceContext("db2");
    auto src1again = ctx.getSourceContext!TestSourceContext("db1");

    assert(src1 !is src2);  // Different source IDs
    assert(src1 is src1again);  // Same source ID returns same context
    assert(src1.value == 42);
}
