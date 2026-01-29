module graphqld2.executor;

import std.algorithm;
import std.array;
import std.conv;
import std.json;

import graphqld2.core;
import graphqld2.relational;

/// Executes expressions against a data source.
///
/// The new architecture uses a simple Ref-based system:
/// - Expressions take Ref[] and return T[]
/// - Access expressions fetch data directly (naive path)
/// - Optimization replaces access expressions with projections
///   that read from pre-fetched data (optimized path)
class Executor {
    private {
        DataFetcher _fetcher;
    }

    this(DataFetcher fetcher) {
        _fetcher = fetcher;
    }

    /// Execute an expression starting from the query root (naive path).
    /// Access expressions fetch data directly, potentially causing N+1 queries.
    T execute(E, T = E.ResultType)(E expr) {
        // Create evaluation context
        auto ctx = new EvalContext();
        ctx.fetcher = _fetcher;

        // Execute with query root as the single input
        auto results = expr.eval(ctx, [queryRoot]);

        // Return the single result
        return results[0];
    }

    /// Execute with optimization (optimized path).
    /// 1. Optimize: Transform access expressions into projections
    /// 2. Fetch: Execute all QueryNodes and store results in EvalContext
    /// 3. Evaluate: Run the optimized expression (reads from pre-fetched data)
    T executeOptimized(E, T = E.ResultType)(E expr) {
        // Phase 1: Optimize
        auto optCtx = new OptimizeContext(_fetcher);
        auto optimized = cast(E) expr.optimize(optCtx);

        // Phase 2: Fetch all data
        auto evalCtx = new EvalContext();
        evalCtx.fetcher = _fetcher;

        // Execute QueryNodes in topological order (parents before children)
        auto nodes = optCtx.nodesInOrder();

        debug(sql) {
            import std.stdio : writeln, writefln;
            writefln("=== Executing %d QueryNode(s) ===\n", nodes.length);
            writeln(toSQL(nodes));
            writeln();
        }

        foreach (node; nodes) {
            auto result = executeQueryNode(node, evalCtx);
            evalCtx.storeQueryResult(node.id, result);
        }

        debug(sql) {
            import std.stdio : writeln;
            writeln("=== Query execution complete ===\n");
        }

        // Phase 3: Evaluate the optimized expression
        auto results = optimized.eval(evalCtx, [queryRoot]);

        return results[0];
    }

    /// Execute a QueryNode and return its QueryResult.
    private QueryResult executeQueryNode(QueryNode node, EvalContext evalCtx) {
        import std.conv : to;
        import std.json : JSONValue;

        auto result = new QueryResult();
        Ref[] refs;

        // Step 1: Determine the refs for this node
        if (node.isRoot) {
            final switch (node.rootFilter) {
                case FilterType.none:
                    // Not configured as root - shouldn't happen
                    break;

                case FilterType.all:
                    // Fetch all IDs from table
                    auto ids = _fetcher.fetchAllIds(node.table);
                    refs = ids.map!(id => makeRef(node.typeName, id)).array;
                    result.initialize(node.typeName, refs);
                    break;

                case FilterType.byId:
                case FilterType.byIds:
                    refs = node.rootFilterRefs.dup;
                    result.initialize(node.typeName, refs);
                    break;
            }
        } else {
            // Child node: get children via fetchChildren
            auto parentResult = evalCtx.getQueryResult(node.parent.id);
            if (parentResult !is null) {
                auto parentRefs = parentResult.allRefs();

                // fetchChildren returns Ref[][] grouped by parent
                auto childGroups = _fetcher.fetchChildren(
                    node.table, node.typeName, node.parentFk, parentRefs);

                // Flatten to get all child refs
                foreach (group; childGroups) {
                    refs ~= group;
                }

                // Initialize with parent grouping info
                // We need to fetch the FK column to build the grouping
                auto fkValues = _fetcher.fetchColumnJson(node.table, node.parentFk, refs);
                result.initializeAsChild(node.typeName, refs, parentRefs, node.parentFk, fkValues);
            }
        }

        // Step 2: Fetch each column from base table
        foreach (column; node.columns) {
            auto values = _fetcher.fetchColumnJson(node.table, column, refs);
            result.loadColumn(column, refs, values);
        }

        // Step 3: Fetch columns from JOINed tables
        foreach (joinInfo; node.joins) {
            auto joinAlias = joinInfo.alias_;
            auto joinedCols = node.joinedColumns.get(joinAlias, null);
            if (joinedCols is null) continue;

            // Get FK values to determine which joined rows we need
            auto fkValues = _fetcher.fetchColumnJson(node.table, joinInfo.fk, refs);

            // Convert FK values to refs for the joined table
            Ref[] joinedRefs;
            foreach (fkVal; fkValues) {
                if (fkVal.type == JSONType.null_) {
                    joinedRefs ~= Ref.init;
                } else {
                    long fkId = fkVal.type == JSONType.integer ? fkVal.integer : fkVal.str.to!long;
                    joinedRefs ~= makeRef(joinInfo.targetType, fkId);
                }
            }

            // Fetch each column from the joined table
            foreach (column; joinedCols) {
                auto values = _fetcher.fetchColumnJson(joinInfo.targetTable, column, joinedRefs);
                // Store with alias prefix
                result.loadColumn(joinAlias ~ "." ~ column, refs, values);
            }
        }

        return result;
    }
}

// ============================================================================
// Tests
// ============================================================================

unittest {
    // Define test entities
    struct User {
        mixin Entity!"users";
        mixin Col!("firstName", string);
        mixin Col!("lastName", string);

        static auto fullName(Expr!Ref u) {
            return use(
                (string first, string last) => first ~ " " ~ last,
                firstName(u),
                lastName(u)
            );
        }
    }

    // Create mock fetcher with test data
    auto fetcher = new MockDataFetcher();
    fetcher.setTableData("users", `[
        {"id": 1, "first_name": "Alice", "last_name": "Smith"},
        {"id": 2, "first_name": "Bob", "last_name": "Jones"}
    ]`);

    auto executor = new Executor(fetcher);

    // Test: map over users and get full names
    auto query = map!(
        (Expr!Ref user) => User.fullName(user)
    )(getByIds!User([1, 2]));

    auto result = executor.execute(query);
    assert(result == ["Alice Smith", "Bob Jones"]);
}

unittest {
    // Test with relationships
    struct Post {
        mixin Entity!"posts";
        mixin Col!("title", string);
    }

    struct User {
        mixin Entity!"users";
        mixin Col!("firstName", string);
        mixin HasMany!("posts", Post, "author_id");
    }

    auto fetcher = new MockDataFetcher();
    fetcher.setTableData("users", `[
        {"id": 1, "first_name": "Alice"},
        {"id": 2, "first_name": "Bob"}
    ]`);
    fetcher.setTableData("posts", `[
        {"id": 1, "author_id": 1, "title": "Hello"},
        {"id": 2, "author_id": 1, "title": "World"},
        {"id": 3, "author_id": 2, "title": "D Lang"}
    ]`);

    auto executor = new Executor(fetcher);

    // Query: { users { firstName, posts { title } } }
    auto query = map!(
        (Expr!Ref user) => jsonObject(
            "firstName", User.firstName(user),
            "posts", map!(
                (Expr!Ref post) => jsonObject(
                    "title", Post.title(post)
                )
            )(User.posts(user))
        )
    )(getByIds!User([1, 2]));

    auto result = executor.execute(query);
    assert(result.length == 2);

    // User 1: Alice with 2 posts
    assert(result[0]["firstName"].str == "Alice");
    assert(result[0]["posts"].array.length == 2);
    assert(result[0]["posts"][0]["title"].str == "Hello");
    assert(result[0]["posts"][1]["title"].str == "World");

    // User 2: Bob with 1 post
    assert(result[1]["firstName"].str == "Bob");
    assert(result[1]["posts"].array.length == 1);
    assert(result[1]["posts"][0]["title"].str == "D Lang");
}

unittest {
    // Test belongsTo chaining
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
        {"id": 2, "author_id": 2, "title": "World"}
    ]`);

    auto executor = new Executor(fetcher);

    // Query: { posts { title, authorName } }
    auto query = map!(
        (Expr!Ref post) => jsonObject(
            "title", Post.title(post),
            "authorName", Post.authorName(post)
        )
    )(getByIds!Post([1, 2]));

    auto result = executor.execute(query);
    assert(result.length == 2);
    assert(result[0]["title"].str == "Hello");
    assert(result[0]["authorName"].str == "Alice");
    assert(result[1]["title"].str == "World");
    assert(result[1]["authorName"].str == "Bob");
}

// ============================================================================
// Optimized Execution Tests
// ============================================================================

unittest {
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

    auto executor = new Executor(fetcher);

    // Simple query: get first and last names
    auto query = map!(
        (Expr!Ref user) => jsonObject(
            "first", User.firstName(user),
            "last", User.lastName(user)
        )
    )(getByIds!User([1, 2, 3]));

    // Execute both ways
    auto naiveResult = executor.execute(query);
    auto optimizedResult = executor.executeOptimized(query);

    // Both should produce the same output
    assert(naiveResult.length == optimizedResult.length);
    assert(naiveResult.length == 3);

    foreach (i; 0 .. 3) {
        assert(naiveResult[i]["first"].str == optimizedResult[i]["first"].str);
        assert(naiveResult[i]["last"].str == optimizedResult[i]["last"].str);
    }

    // Verify actual values
    assert(optimizedResult[0]["first"].str == "Alice");
    assert(optimizedResult[0]["last"].str == "Smith");
    assert(optimizedResult[1]["first"].str == "Bob");
    assert(optimizedResult[1]["last"].str == "Jones");
    assert(optimizedResult[2]["first"].str == "Carol");
    assert(optimizedResult[2]["last"].str == "White");
}

unittest {
    // Test: Optimized execution with QueryNode inspection
    import std.json : parseJSON;

    struct User {
        mixin Entity!"users";
        mixin Col!("firstName", string);
        mixin Col!("age", long);
    }

    auto fetcher = new MockDataFetcher();
    fetcher.setTableData("users", `[
        {"id": 1, "first_name": "Alice", "age": 30},
        {"id": 2, "first_name": "Bob", "age": 25}
    ]`);

    // Build a query
    auto query = map!(
        (Expr!Ref user) => jsonObject(
            "name", User.firstName(user),
            "age", User.age(user)
        )
    )(getByIds!User([1, 2]));

    // Manually optimize to inspect the QueryNodes
    auto optCtx = new OptimizeContext(fetcher);
    query.optimize(optCtx);

    auto nodes = optCtx.allNodes();
    assert(nodes.length == 1, "Should have exactly 1 QueryNode");

    auto node = nodes[0];
    assert(node.typeName == "User");
    assert(node.table == "users");
    assert(node.rootFilter == FilterType.byIds);
    assert(node.rootFilterRefs.length == 2);

    // Columns should include id, first_name, and age
    import std.algorithm : canFind;
    assert(node.columns.canFind("id"));
    assert(node.columns.canFind("first_name"));
    assert(node.columns.canFind("age"));
}

unittest {
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

    auto fetcher = new MockDataFetcher();

    // Build a nested query: users { firstName, posts { title } }
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

    // Optimize and inspect QueryNodes
    auto optCtx = new OptimizeContext(fetcher);
    query.optimize(optCtx);

    auto nodes = optCtx.nodesInOrder();
    assert(nodes.length == 2, "Should have 2 QueryNodes (User and Post)");

    // First node should be User (parent)
    auto userNode = nodes[0];
    assert(userNode.typeName == "User");
    assert(userNode.isRoot);
    assert(userNode.rootFilter == FilterType.byIds);

    // Second node should be Post (child)
    auto postNode = nodes[1];
    assert(postNode.typeName == "Post");
    assert(!postNode.isRoot);
    assert(postNode.parent is userNode);
    assert(postNode.parentFk == "author_id");
    assert(postNode.parentTypeName == "User");

    import std.algorithm : canFind;
    assert(postNode.columns.canFind("title"));
    assert(postNode.columns.canFind("author_id"));  // FK should be auto-added
}

unittest {
    // Test: End-to-end optimized execution with nested hasMany
    struct Post {
        mixin Entity!"posts";
        mixin Col!("title", string);
    }

    struct User {
        mixin Entity!"users";
        mixin Col!("firstName", string);
        mixin HasMany!("posts", Post, "author_id");
    }

    auto fetcher = new MockDataFetcher();
    fetcher.setTableData("users", `[
        {"id": 1, "first_name": "Alice"},
        {"id": 2, "first_name": "Bob"}
    ]`);
    fetcher.setTableData("posts", `[
        {"id": 1, "author_id": 1, "title": "Hello"},
        {"id": 2, "author_id": 1, "title": "World"},
        {"id": 3, "author_id": 2, "title": "D Lang"}
    ]`);

    auto executor = new Executor(fetcher);

    // Build nested query
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

    // Execute both ways and compare
    auto naiveResult = executor.execute(query);
    auto optimizedResult = executor.executeOptimized(query);

    // Should produce identical results
    assert(naiveResult.length == optimizedResult.length);
    assert(optimizedResult.length == 2);

    // User 1: Alice with 2 posts
    assert(optimizedResult[0]["name"].str == "Alice");
    assert(optimizedResult[0]["posts"].array.length == 2);
    assert(optimizedResult[0]["posts"][0]["title"].str == "Hello");
    assert(optimizedResult[0]["posts"][1]["title"].str == "World");

    // User 2: Bob with 1 post
    assert(optimizedResult[1]["name"].str == "Bob");
    assert(optimizedResult[1]["posts"].array.length == 1);
    assert(optimizedResult[1]["posts"][0]["title"].str == "D Lang");

    // Verify naive and optimized match
    assert(naiveResult[0]["name"].str == optimizedResult[0]["name"].str);
    assert(naiveResult[1]["posts"].array.length == optimizedResult[1]["posts"].array.length);
}

unittest {
    // Test: BelongsTo JOIN optimization
    struct User {
        mixin Entity!"users";
        mixin Col!("firstName", string);
    }

    struct Post {
        mixin Entity!"posts";
        mixin Col!("title", string);
        mixin BelongsTo!("author", User, "author_id");

        // Access column through belongsTo chain
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

    auto executor = new Executor(fetcher);

    // Helper to create the query (since optimize mutates the expression)
    auto makeQuery() {
        return map!(
            (Expr!Ref post) => jsonObject(
                "title", Post.title(post),
                "authorName", Post.authorName(post)
            )
        )(getByIds!Post([1, 2, 3]));
    }

    // First: execute both ways BEFORE manual inspection
    // (since optimize mutates the expression)
    auto queryForNaive = makeQuery();
    auto naiveResult = executor.execute(queryForNaive);

    auto queryForOptimized = makeQuery();
    auto optimizedResult = executor.executeOptimized(queryForOptimized);

    // Verify optimization creates JOINs (use a fresh query for inspection)
    auto queryForInspection = makeQuery();
    auto optCtx = new OptimizeContext(fetcher);
    queryForInspection.optimize(optCtx);

    auto nodes = optCtx.allNodes();
    assert(nodes.length == 1, "Should have 1 QueryNode (with JOINs, not separate nodes)");

    auto node = nodes[0];
    assert(node.typeName == "Post");
    assert(node.rootFilter == FilterType.byIds, "Should have byIds filter");
    assert(node.rootFilterRefs.length == 3, "Should have 3 root refs");
    assert(node.joins.length == 1, "Should have 1 JOIN");
    assert(node.joins[0].targetTable == "users");
    assert(node.joins[0].fk == "author_id");

    import std.algorithm : canFind;
    assert(node.columns.canFind("title"), "Should have title column");
    assert(node.columns.canFind("author_id"), "Should have author_id column for JOIN");

    assert(optimizedResult.length == 3, "Expected 3 results, got " ~ optimizedResult.length.to!string);
    assert(optimizedResult[0]["title"].str == "Hello",
        "Expected 'Hello', got: " ~ optimizedResult[0].toString);
    assert(optimizedResult[0]["authorName"].str == "Alice");
    assert(optimizedResult[1]["title"].str == "World");
    assert(optimizedResult[1]["authorName"].str == "Bob");
    assert(optimizedResult[2]["title"].str == "Again");
    assert(optimizedResult[2]["authorName"].str == "Alice");

    // Verify naive and optimized produce same results
    foreach (i; 0 .. 3) {
        assert(naiveResult[i]["title"].str == optimizedResult[i]["title"].str);
        assert(naiveResult[i]["authorName"].str == optimizedResult[i]["authorName"].str);
    }
}
