module dunamis.core.optimize;

import dunamis.core.expr : ExprBase;
import dunamis.core.types : SourceContextRegistry;

// ============================================================================
// Optimize Context - Data Source Agnostic
// ============================================================================

/// Interface for optimizers that run after standard optimization.
/// Implementations transform the expression tree for their specific data source.
/// Data fetchers declare which optimizers they need via requestedOptimizers().
interface ExprOptimizer {
    /// Run this optimizer on the expression tree.
    void optimize(ExprBase expr, OptimizeContext ctx);
}

/// Top-level optimization context that holds per-source contexts.
/// Each data source (relational, REST, etc.) registers its own context type.
///
/// Usage:
///   auto relCtx = optCtx.getSourceContext!RelationalOptimizeContext();
///   auto node = relCtx.getOrCreateNode(mapExpr, typeName, table);
class OptimizeContext {
    mixin SourceContextRegistry;

    /// Maps whose elements placeholders range over (see elementOwner).
    private Object[void*] _elementOwners;

    /// Record that the placeholder `placeholder` (e.g. a filter predicate's
    /// item) ranges over rows of the collection of the map `owner` (see
    /// `dunamis.core.elements.registerElementOwner`). The first
    /// registration of a placeholder wins.
    void setElementOwner(Object placeholder, Object owner) {
        auto key = cast(void*) placeholder;
        if (key !in _elementOwners)
            _elementOwners[key] = owner;
    }

    /// The map over whose collection's rows `placeholder` ranges, if
    /// recorded (else null): what an optimizer fetches for that map's
    /// elements also serves the placeholder's.
    Object elementOwner(Object placeholder) {
        return _elementOwners.get(cast(void*) placeholder, null);
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
