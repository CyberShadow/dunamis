module graphqld2.relational.optimize_context;

import graphqld2.core.types;
import graphqld2.core.expr;
import graphqld2.relational.project;
import graphqld2.relational.query_node;

// ============================================================================
// Relational Optimize Context
// ============================================================================

/// Relational-specific optimization context.
/// Holds QueryNodes and their PrefetchExprs keyed by MapExpr identity.
/// Retrieved via OptimizeContext.getSourceContext!RelationalOptimizeContext()
class RelationalOptimizeContext {
    private {
        /// Query nodes keyed by MapExpr identity (using Object pointer)
        QueryNode[void*] _queryNodes;

        /// PrefetchExpr for each QueryNode (keyed by node ID)
        PrefetchExpr[int] _prefetchExprs;

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

    /// Get or create a PrefetchExpr for a QueryNode.
    /// Called by access expressions to get the prefetch dependency.
    PrefetchExpr getPrefetchExpr(QueryNode node) {
        if (node.id in _prefetchExprs) {
            return _prefetchExprs[node.id];
        }

        // Get parent's PrefetchExpr if this is a child node
        PrefetchExpr parentPrefetch = null;
        if (node.parent !is null) {
            parentPrefetch = getPrefetchExpr(node.parent);
        }

        auto prefetch = new PrefetchExpr(node, parentPrefetch);
        _prefetchExprs[node.id] = prefetch;
        return prefetch;
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

// ============================================================================
// Integration Tests: Optimization produces correct QueryNodes
// ============================================================================

import ae.utils.promise.await : awaitSync;

unittest {
    import std.algorithm : canFind;
    import std.conv : to;
    import std.json;
    import graphqld2.core;
    import graphqld2.relational.schema;
    import graphqld2.relational.eval_context;

    // Test: Optimized execution produces same results as naive
    struct User {
        mixin Entity!"users";
        mixin Col!("firstName", string);
        mixin Col!("lastName", string);
    }

    auto fetcher = new MockDataFetcher();
    fetcher.setTableData("users", `[
        {"id": 1, "first_name": "Alice", "last_name": "Smith"},
        {"id": 2, "first_name": "Bob", "last_name": "Jones"},
        {"id": 3, "first_name": "Carol", "last_name": "White"}
    ]`);

    auto executor = new Executor();

    auto makeQuery() {
        return map!(
            (Expr!Ref user) => jsonObject(
                "first", User.firstName(user),
                "last", User.lastName(user)
            )
        )(getByIds!User([1, 2, 3], fetcher));
    }

    auto naiveResult = awaitSync(executor.execute(makeQuery(), false));
    auto optimizedResult = awaitSync(executor.execute(makeQuery(), true));

    assert(naiveResult.length == optimizedResult.length);
    assert(naiveResult.length == 3);

    foreach (i; 0 .. 3) {
        assert(naiveResult[i]["first"].str == optimizedResult[i]["first"].str);
        assert(naiveResult[i]["last"].str == optimizedResult[i]["last"].str);
    }
}

unittest {
    import std.algorithm : canFind;
    import graphqld2.core;
    import graphqld2.relational.schema;

    // Test: QueryNode inspection - verify optimization creates correct nodes
    struct User {
        mixin Entity!"users";
        mixin Col!("firstName", string);
        mixin Col!("age", long);
    }

    auto query = map!(
        (Expr!Ref user) => jsonObject(
            "name", User.firstName(user),
            "age", User.age(user)
        )
    )(getByIds!User([1, 2]));

    auto optCtx = new OptimizeContext();
    query.optimize(optCtx);

    auto relCtx = optCtx.getSourceContext!RelationalOptimizeContext();
    auto nodes = relCtx.allNodes();
    assert(nodes.length == 1, "Should have exactly 1 QueryNode");

    auto node = nodes[0];
    assert(node.typeName == "User");
    assert(node.table == "users");
    assert(node.rootFilter == FilterType.byIds);
    assert(node.rootFilterRefs.length == 2);
    assert(node.columns.canFind("id"));
    assert(node.columns.canFind("first_name"));
    assert(node.columns.canFind("age"));
}

unittest {
    import std.algorithm : canFind;
    import graphqld2.core;
    import graphqld2.relational.schema;

    // Test: Nested hasMany creates linked QueryNodes
    struct Post {
        mixin Entity!"posts";
        mixin Col!("title", string);
    }

    struct User {
        mixin Entity!"users";
        mixin Col!("firstName", string);
        mixin HasMany!("posts", Post, "author_id");
    }

    auto query = map!(
        (Expr!Ref user) => jsonObject(
            "name", User.firstName(user),
            "posts", map!(
                (Expr!Ref post) => jsonObject(
                    "title", Post.title(post)
                )
            )(User.posts(user))
        )
    )(getByIds!User([1, 2]));

    auto optCtx = new OptimizeContext();
    query.optimize(optCtx);

    auto relCtx = optCtx.getSourceContext!RelationalOptimizeContext();
    auto nodes = relCtx.nodesInOrder();
    assert(nodes.length == 2, "Should have 2 QueryNodes (User and Post)");

    auto userNode = nodes[0];
    assert(userNode.typeName == "User");
    assert(userNode.isRoot);
    assert(userNode.rootFilter == FilterType.byIds);

    auto postNode = nodes[1];
    assert(postNode.typeName == "Post");
    assert(!postNode.isRoot);
    assert(postNode.parent is userNode);
    assert(postNode.parentFk == "author_id");
    assert(postNode.parentTypeName == "User");
    assert(postNode.columns.canFind("title"));
    assert(postNode.columns.canFind("author_id"));
}

unittest {
    import std.algorithm : canFind;
    import std.conv : to;
    import std.json;
    import graphqld2.core;
    import graphqld2.relational.schema;
    import graphqld2.relational.eval_context;

    // Test: BelongsTo creates JOINs (not separate QueryNodes)
    struct User {
        mixin Entity!"users";
        mixin Col!("firstName", string);
    }

    struct Post {
        mixin Entity!"posts";
        mixin Col!("title", string);
        mixin BelongsTo!("author", User, "author_id");

        static auto authorName(Expr!Ref p) {
            return User.firstName(author(p));
        }
    }

    auto fetcher = new MockDataFetcher();
    fetcher.setTableData("users", `[
        {"id": 1, "first_name": "Alice"},
        {"id": 2, "first_name": "Bob"}
    ]`);
    fetcher.setTableData("posts", `[
        {"id": 1, "author_id": 1, "title": "Hello"},
        {"id": 2, "author_id": 2, "title": "World"},
        {"id": 3, "author_id": 1, "title": "Again"}
    ]`);

    auto executor = new Executor();

    auto makeQuery() {
        return map!(
            (Expr!Ref post) => jsonObject(
                "title", Post.title(post),
                "authorName", Post.authorName(post)
            )
        )(getByIds!Post([1, 2, 3], fetcher));
    }

    // Execute both ways
    auto naiveResult = awaitSync(executor.execute(makeQuery(), false));
    auto optimizedResult = awaitSync(executor.execute(makeQuery(), true));

    // Verify optimization creates JOINs
    auto queryForInspection = makeQuery();
    auto optCtx = new OptimizeContext();
    queryForInspection.optimize(optCtx);

    auto relCtx = optCtx.getSourceContext!RelationalOptimizeContext();
    auto nodes = relCtx.allNodes();
    assert(nodes.length == 1, "Should have 1 QueryNode (with JOINs, not separate nodes)");

    auto node = nodes[0];
    assert(node.typeName == "Post");
    assert(node.joins.length == 1, "Should have 1 JOIN");
    assert(node.joins[0].targetTable == "users");
    assert(node.joins[0].fk == "author_id");
    assert(node.columns.canFind("title"));
    assert(node.columns.canFind("author_id"));

    // Verify results match
    assert(optimizedResult.length == 3);
    assert(optimizedResult[0]["authorName"].str == "Alice");
    assert(optimizedResult[1]["authorName"].str == "Bob");
    assert(optimizedResult[2]["authorName"].str == "Alice");

    foreach (i; 0 .. 3) {
        assert(naiveResult[i]["title"].str == optimizedResult[i]["title"].str);
        assert(naiveResult[i]["authorName"].str == optimizedResult[i]["authorName"].str);
    }
}
