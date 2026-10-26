module dunamis.relational.optimize_context;

import dunamis.core.types : AnyRef;
import dunamis.core.expr;
import dunamis.relational.project;
import dunamis.relational.query_node;

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
        PrefetchExpr[QueryNodeId] _prefetchExprs;

        /// Next query node ID
        int _nextNodeId = 0;

        /// Next computed column alias number
        int _nextComputedAlias = 0;
    }

    /// Allocate a computed column alias, unique within this optimization.
    string newComputedColumnAlias() {
        import std.conv : to;
        return "computed_" ~ (_nextComputedAlias++).to!string;
    }

    /// Get or create a QueryNode for a MapExpr.
    /// Called by access expressions during optimization.
    /// pkColumns: SQL column names for the entity's primary key.
    QueryNode getOrCreateNode(Object mapExpr, string typeName, string table, string[] pkColumns) {
        assert(mapExpr !is null, "mapExpr must not be null for QueryNode lookup");
        auto key = cast(void*) mapExpr;
        if (key in _queryNodes) {
            return _queryNodes[key];
        }

        auto node = new QueryNode(QueryNodeId(_nextNodeId++), typeName, table, pkColumns);
        node.mapExpr = mapExpr;  // Store for looking up currentRefs at eval time
        _queryNodes[key] = node;
        return node;
    }

    /// Get existing node for a MapExpr (returns null if not found)
    QueryNode getNode(Object mapExpr) {
        auto key = cast(void*) mapExpr;
        return _queryNodes.get(key, null);
    }

    /// Find a root node by typeName and table (for GetAllExpr to find its QueryNode)
    /// Returns the first matching root node, or null if not found.
    /// Nodes never configured as roots (e.g. of a hasMany whose parent could
    /// not be resolved, which falls back to the naive path) are not roots.
    QueryNode findRootNode(string typeName, string table) {
        foreach (node; _queryNodes.values) {
            if (node.isRoot && node.rootFilter != FilterType.none &&
                    node.typeName == typeName && node.table == table) {
                return node;
            }
        }
        return null;
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
        bool[QueryNodeId] added;

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

        // Assert parent-before-child ordering
        foreach (i, node; result) {
            if (node.parent !is null) {
                bool parentFound = false;
                foreach (j; 0 .. i) {
                    if (result[j] is node.parent) {
                        parentFound = true;
                        break;
                    }
                }
                assert(parentFound, "Parent node must appear before child in nodesInOrder");
            }
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
Object findMapExpr(ExprBase expr) {
    while (expr !is null) {
        // Found the placeholder? Return its parent map.
        // Use EveryItemOfExprInfo interface to detect any EveryItemOfExpr!Entity
        if (auto every = cast(EveryItemOfExprInfo) expr) {
            return every.parentMap;
        }

        // Try to continue through access expressions
        expr = getInputExpr(expr);
    }
    return null;
}

/// Get the _input field from an access expression using runtime reflection.
/// Returns null if the expression doesn't have an _input field.
private ExprBase getInputExpr(ExprBase expr) {
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

    auto node1 = ctx.getOrCreateNode(map1, "User", "users", ["id"]);
    auto node2 = ctx.getOrCreateNode(map2, "Post", "posts", ["id"]);
    auto node1again = ctx.getOrCreateNode(map1, "User", "users", ["id"]);

    assert(node1.id == QueryNodeId(0));
    assert(node2.id == QueryNodeId(1));
    assert(node1again is node1);  // Same node returned

    assert(ctx.allNodes().length == 2);
}

unittest {
    // Test nodesInOrder with parent-child
    auto ctx = new RelationalOptimizeContext();

    auto map1 = new Object();
    auto map2 = new Object();

    auto parent = ctx.getOrCreateNode(map1, "User", "users", ["id"]);
    auto child = ctx.getOrCreateNode(map2, "Post", "posts", ["id"]);
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
    import dunamis.core;
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import dunamis.relational.eval_context;

    static MockDB!() db;

    // Test: Optimized execution produces same results as naive
    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("firstName", string);
        mixin Col!("lastName", string);
    }

    db = new MockDB!();
    db.setTableData("users", `[
        {"id": 1, "first_name": "Alice", "last_name": "Smith"},
        {"id": 2, "first_name": "Bob", "last_name": "Jones"},
        {"id": 3, "first_name": "Carol", "last_name": "White"}
    ]`);

    auto executor = new Executor();

    auto makeQuery() {
        return map!(
            (Expr!User user) => jsonObject(
                "first", user.firstName,
                "last", user.lastName
            )
        )(getByIds!User([1, 2, 3]));
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
    import dunamis.core;
    import dunamis.relational.schema;
    import dunamis.relational.demo;

    static MockDB!() db;

    // Test: QueryNode inspection - verify optimization creates correct nodes
    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("firstName", string);
        mixin Col!("age", long);
    }

    db = new MockDB!();

    auto query = map!(
        (Expr!User user) => jsonObject(
            "name", user.firstName,
            "age", user.age
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
    import dunamis.core;
    import dunamis.relational.schema;
    import dunamis.relational.demo;

    static MockDB!() db;

    // Test: Nested hasMany creates linked QueryNodes
    @DemoEntity!(db, "posts")
    static struct Post {
        mixin DemoId;
        mixin Col!("title", string);
    }

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("firstName", string);
        mixin HasMany!("posts", Post, "author_id");
    }

    auto query = map!(
        (Expr!User user) => jsonObject(
            "name", user.firstName,
            "posts", map!(
                (Expr!Post post) => jsonObject(
                    "title", post.title
                )
            )(user.posts)
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
    import dunamis.core;
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import dunamis.relational.eval_context;

    static MockDB!() db;

    // Test: BelongsTo creates JOINs (not separate QueryNodes)
    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("firstName", string);
    }

    @DemoEntity!(db, "posts")
    static struct Post {
        mixin DemoId;
        mixin Col!("title", string);
        mixin Col!("authorId", ForeignKey!User);
        mixin BelongsTo!("author", "authorId");

        static auto authorName(Expr!Post p) {
            return User.firstName(author(p));
        }
    }

    db = new MockDB!();
    db.setTableData("users", `[
        {"id": 1, "first_name": "Alice"},
        {"id": 2, "first_name": "Bob"}
    ]`);
    db.setTableData("posts", `[
        {"id": 1, "author_id": 1, "title": "Hello"},
        {"id": 2, "author_id": 2, "title": "World"},
        {"id": 3, "author_id": 1, "title": "Again"}
    ]`);

    auto executor = new Executor();

    auto makeQuery() {
        return map!(
            (Expr!Post post) => jsonObject(
                "title", post.title,
                "authorName", post.authorName
            )
        )(getByIds!Post([1, 2, 3]));
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

// ============================================================================
// Pagination Push-Down Tests
// ============================================================================

unittest {
    import std.algorithm : canFind;
    import dunamis.core;
    import dunamis.core.pagination : limit, offset;
    import dunamis.relational.schema;
    import dunamis.relational.demo;

    static MockDB!() db;

    // Test: Pagination expressions push values to QueryNode
    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("firstName", string);
    }

    db = new MockDB!();

    // Create query with limit and offset
    auto query = map!(
        (Expr!User user) => jsonObject(
            "name", user.firstName
        )
    )(limit(offset(getAll!User(), 10), 5));  // Skip 10, take 5

    auto optCtx = new OptimizeContext();
    query.optimize(optCtx);

    auto relCtx = optCtx.getSourceContext!RelationalOptimizeContext();
    auto nodes = relCtx.allNodes();
    assert(nodes.length == 1, "Should have exactly 1 QueryNode");

    auto node = nodes[0];
    assert(node.typeName == "User");
    assert(node.rootFilter == FilterType.all);

    // Verify pagination was pushed to QueryNode
    assert(!node.limit_.isNull, "Limit should be set");
    assert(node.limit_.get == 5, "Limit should be 5");
    assert(!node.offset_.isNull, "Offset should be set");
    assert(node.offset_.get == 10, "Offset should be 10");
}

unittest {
    import std.algorithm : canFind;
    import dunamis.core;
    import dunamis.core.pagination : limit;
    import dunamis.relational.schema;
    import dunamis.relational.demo;

    static MockDB!() db;

    // Test: Limit only (no offset)
    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("firstName", string);
    }

    db = new MockDB!();

    auto query = map!(
        (Expr!User user) => jsonObject("name", user.firstName)
    )(limit(getAll!User(), 20));

    auto optCtx = new OptimizeContext();
    query.optimize(optCtx);

    auto relCtx = optCtx.getSourceContext!RelationalOptimizeContext();
    auto node = relCtx.allNodes()[0];

    assert(!node.limit_.isNull, "Limit should be set");
    assert(node.limit_.get == 20);
    assert(node.offset_.isNull, "Offset should not be set");
}
