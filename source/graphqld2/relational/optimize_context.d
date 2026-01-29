module graphqld2.relational.optimize_context;

import graphqld2.core.types;
import graphqld2.core.expr;
import graphqld2.relational.query_node;

// ============================================================================
// Relational Optimize Context
// ============================================================================

/// Relational-specific optimization context.
/// Holds QueryNodes keyed by MapExpr identity.
/// Retrieved via OptimizeContext.getSourceContext!RelationalOptimizeContext()
class RelationalOptimizeContext {
    private {
        /// Query nodes keyed by MapExpr identity (using Object pointer)
        QueryNode[void*] _queryNodes;

        /// Next query node ID
        int _nextNodeId = 0;
    }

    /// Get or create a QueryNode for a MapExpr.
    /// Called by access expressions during optimization.
    QueryNode getOrCreateNode(Object mapExpr, string typeName, string table) {
        auto key = cast(void*) mapExpr;
        if (key in _queryNodes) {
            return _queryNodes[key];
        }

        auto node = new QueryNode(_nextNodeId++, typeName, table);
        _queryNodes[key] = node;
        return node;
    }

    /// Get existing node for a MapExpr (returns null if not found)
    QueryNode getNode(Object mapExpr) {
        auto key = cast(void*) mapExpr;
        return _queryNodes.get(key, null);
    }

    /// Get all query nodes (for executor to fetch data)
    QueryNode[] allNodes() {
        return _queryNodes.values;
    }

    /// Get nodes in execution order (parents before children)
    QueryNode[] nodesInOrder() {
        auto nodes = allNodes();

        // Topological sort: roots first, then children
        QueryNode[] result;
        bool[int] added;

        void addWithDeps(QueryNode node) {
            if (node.id in added) return;
            if (node.parent !is null) {
                addWithDeps(node.parent);
            }
            result ~= node;
            added[node.id] = true;
        }

        foreach (node; nodes) {
            addWithDeps(node);
        }

        return result;
    }
}

// ============================================================================
// Helper: Find MapExpr from _input chain
// ============================================================================

/// Walk _input chain to find the owning MapExpr.
/// Access expressions call this during optimization to find their query scope.
///
/// Returns: the MapExpr as Object, or null if not found.
Object findMapExpr(Expr!Ref expr) {
    while (expr !is null) {
        // Found the placeholder? Return its parent map.
        if (auto every = cast(EveryItemOfExpr) expr) {
            return every._parentMap;
        }

        // Try to continue through access expressions
        expr = getInputExpr(expr);
    }
    return null;
}

/// Get the _input field from an access expression using runtime reflection.
/// Returns null if the expression doesn't have an _input field.
private Expr!Ref getInputExpr(Expr!Ref expr) {
    // This uses runtime type checking since we can't easily get _input
    // from arbitrary expression types. The access expressions in schema.d
    // handle this through their own interfaces.
    return null;
}

// ============================================================================
// Tests
// ============================================================================

unittest {
    // Test RelationalOptimizeContext
    auto ctx = new RelationalOptimizeContext();

    // Create mock "MapExpr" objects
    auto map1 = new Object();
    auto map2 = new Object();

    auto node1 = ctx.getOrCreateNode(map1, "User", "users");
    auto node2 = ctx.getOrCreateNode(map2, "Post", "posts");
    auto node1again = ctx.getOrCreateNode(map1, "User", "users");

    assert(node1.id == 0);
    assert(node2.id == 1);
    assert(node1again is node1);  // Same node returned

    assert(ctx.allNodes().length == 2);
}

unittest {
    // Test nodesInOrder with parent-child
    auto ctx = new RelationalOptimizeContext();

    auto map1 = new Object();
    auto map2 = new Object();

    auto parent = ctx.getOrCreateNode(map1, "User", "users");
    auto child = ctx.getOrCreateNode(map2, "Post", "posts");
    child.setParent(parent, "author_id", "User");

    auto ordered = ctx.nodesInOrder();
    assert(ordered.length == 2);
    assert(ordered[0] is parent);  // Parent comes first
    assert(ordered[1] is child);
}
