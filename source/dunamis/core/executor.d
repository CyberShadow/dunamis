module dunamis.core.executor;

import ae.utils.promise;
import ae.utils.promise.await : awaitSync;

import dunamis.core.datasource : DataSource, DataSession, SetupMode;
import dunamis.core.eval;
import dunamis.core.expr;
import dunamis.core.optimize;
import dunamis.core.types;

/// Executes expressions.
///
/// The executor:
/// 1. Optimizes the expression tree (unless disabled)
/// 2. Walks tree to collect data source-specific optimizers
/// 3. Runs collected optimizers
/// 4. Creates per-request sessions for all data sources
/// 5. Calls setup() on all sessions
/// 6. Evaluates the expression
/// 7. Calls teardown() on all sessions (success=true on success, false on error)
class Executor {
    /// Execute an expression, optionally with optimization.
    /// Returns a Promise that resolves to the result.
    ///
    /// Data source lifecycle:
    ///   A per-request session is created for each data source.
    ///   setup() is called on all sessions before evaluation.
    ///   teardown(true) is called after successful evaluation.
    ///   teardown(false) is called if evaluation fails.
    Promise!T execute(E, T = E.ResultType)(E expr, bool optimize = true) {
        return execute!(E, T)(expr, new EvalContext(), optimize);
    }

    /// Execute an expression with a pre-configured EvalContext.
    /// Use this overload to pass request-scoped context values:
    ///
    /// ---
    /// auto ctx = new EvalContext();
    /// ctx.setRequestContext(AuthCtx("user-1", false));
    /// auto result = executor.execute(query, ctx);
    /// ---
    Promise!T execute(E, T = E.ResultType)(E expr, EvalContext evalCtx, bool optimize = true) {
        E toEval = expr;

        if (optimize) {
            auto optCtx = new OptimizeContext();
            toEval = cast(E) expr.optimize(optCtx);

            // Walk tree to collect and run optimizers
            foreach (optimizer; collectOptimizers(toEval)) {
                optimizer.optimize(toEval, optCtx);
            }
        }

        // Collect data sources for lifecycle management
        auto sources = collectDataSources(toEval);

        if (sources.length == 0) {
            // No data sources — evaluate directly (no setup/teardown needed)
            evalCtx.setValues!AnyRef(null, [queryRoot]);
            return toEval.eval(evalCtx).then((results) => results[0]);
        }

        // Create per-request sessions for each data source
        DataSession[] sessions;
        foreach (ds; sources)
            sessions ~= evalCtx.getSession(ds);

        // Setup all sessions, then evaluate, then teardown
        auto setupChain = resolve();
        foreach (s; sessions)
            setupChain = setupChain.then(() => s.setup());

        return setupChain.then(() {
            evalCtx.setValues!AnyRef(null, [queryRoot]);
            return toEval.eval(evalCtx);
        }).then((T[] results) {
            // Teardown with success
            auto p = resolve();
            foreach (s; sessions)
                p = p.then(() => s.teardown(SetupMode.query, true));
            return p.then(() => results[0]);
        }).except((Exception e) {
            // Teardown with failure
            auto p = resolve();
            foreach (s; sessions)
                p = p.then(() => s.teardown(SetupMode.query, false));
            return p.then(() { throw e; return T.init; });
        });
    }

    /// Walk expression tree and collect optimizers, deduplicated by instance.
    private ExprOptimizer[] collectOptimizers(ExprBase root) {
        ExprOptimizer[] result;
        bool[ExprOptimizer] seen;

        void walk(ExprBase expr) {
            if (expr is null) return;

            // Collect optimizers from this expression
            foreach (opt; expr.requestedOptimizers()) {
                if (opt !in seen) {
                    seen[opt] = true;
                    result ~= opt;
                }
            }

            // Recurse into dependencies
            foreach (dep; expr.dependencies()) {
                walk(dep);
            }
        }

        walk(root);
        return result;
    }

    /// Walk expression tree and collect data sources, deduplicated by instance.
    private DataSource[] collectDataSources(ExprBase root) {
        DataSource[] result;
        bool[DataSource] seen;

        void walk(ExprBase expr) {
            if (expr is null) return;

            foreach (ds; expr.dataSources()) {
                if (ds !is null && ds !in seen) {
                    seen[ds] = true;
                    result ~= ds;
                }
            }

            foreach (dep; expr.dependencies()) {
                walk(dep);
            }
        }

        walk(root);
        return result;
    }
}

// ============================================================================
// Subscription Executor
// ============================================================================

/// Manages a subscription's lifecycle: optimizes the expression tree once,
/// then re-evaluates it for each event delivery.
///
/// Usage:
/// ---
/// auto query = compileQuery!MySchema(`subscription { userCreated { firstName } }`);
/// auto sub = SubscriptionExecutor!User(executor, query);
///
/// // For each event:
/// auto result = sub.execute(someUser);  // Returns JSONValue
/// ---
class SubscriptionExecutor(T) {
    import dunamis.core.expr.combinators : EventSourceExpr;
    import std.json : JSONValue;

    private Expr!JSONValue _optimized;
    private EventSourceExpr!T _eventSource;
    private DataSource[] _sources;

    this(Executor executor, Expr!JSONValue expr) {
        // Optimize once
        auto optCtx = new OptimizeContext();
        _optimized = cast(Expr!JSONValue) expr.optimize(optCtx);

        foreach (optimizer; executor.collectOptimizers(_optimized)) {
            optimizer.optimize(_optimized, optCtx);
        }

        // Find the EventSourceExpr in the tree
        _eventSource = findEventSource(_optimized);
        if (_eventSource is null) {
            throw new Exception("SubscriptionExecutor: no EventSourceExpr!" ~
                T.stringof ~ " found in expression tree");
        }

        // Collect data sources
        _sources = executor.collectDataSources(_optimized);
    }

    /// Deliver an event and evaluate the subscription query.
    /// Creates a fresh EvalContext for each event.
    Promise!JSONValue execute(T value) {
        import std.json : JSONValue;

        auto evalCtx = new EvalContext();
        _eventSource.deliver(evalCtx, value);
        evalCtx.setValues!AnyRef(null, [queryRoot]);

        if (_sources.length == 0) {
            return _optimized.eval(evalCtx)
                .then((JSONValue[] results) => results[0]);
        }

        // Create sessions and manage lifecycle
        DataSession[] sessions;
        foreach (ds; _sources)
            sessions ~= evalCtx.getSession(ds);

        auto setupChain = resolve();
        foreach (s; sessions)
            setupChain = setupChain.then(() => s.setup(SetupMode.respond));

        return setupChain.then(() {
            return _optimized.eval(evalCtx);
        }).then((JSONValue[] results) {
            auto p = resolve();
            foreach (s; sessions)
                p = p.then(() => s.teardown(SetupMode.respond, true));
            return p.then(() => results[0]);
        }).except((Exception e) {
            auto p = resolve();
            foreach (s; sessions)
                p = p.then(() => s.teardown(SetupMode.respond, false));
            return p.then(() { throw e; return JSONValue.init; });
        });
    }

    /// Walk the expression tree to find the EventSourceExpr!T.
    private static EventSourceExpr!T findEventSource(ExprBase root) {
        if (root is null) return null;

        if (auto es = cast(EventSourceExpr!T) root) return es;

        foreach (dep; root.dependencies()) {
            if (auto found = findEventSource(dep))
                return found;
        }
        return null;
    }
}

// ============================================================================
// Tests
// ============================================================================

/// Dummy entity type for tests
private struct TestEntity {
    string id;
}

/// Helper: expression that returns a fixed array of entities.
private class MockCollectionExpr(Entity) : Expr!(Entity[]) {
    Entity[] _entities;
    this(Entity[] entities) { _entities = entities; }

    override ExprBase[] dependencies() { return []; }
    override void replaceDependency(size_t index, ExprBase newDep) {}

    override Promise!(Entity[][]) eval(EvalContext ctx) {
        return resolve([_entities]);
    }
}

unittest {
    // Test executor with map expression
    auto executor = new Executor();

    auto collection = new MockCollectionExpr!TestEntity([TestEntity("1"), TestEntity("2")]);
    auto query = map!(
        (Expr!TestEntity item) => use((TestEntity e) => e.id, item)
    )(collection);

    auto result = awaitSync(executor.execute(query));
    assert(result == ["1", "2"]);
}

unittest {
    // Test executor with operators and literals
    import std.conv : to;

    auto executor = new Executor();

    auto collection = new MockCollectionExpr!TestEntity([TestEntity("1"), TestEntity("2")]);
    auto query = map!(
        (Expr!TestEntity item) => use((TestEntity e) => e.id.to!long, item) * 10 + 1
    )(collection);

    auto result = awaitSync(executor.execute(query));
    assert(result == [11, 21]);
}

unittest {
    // Test executor with request context
    import dunamis.core.expr.combinators : context;

    static struct RequestCtx {
        string locale;
    }

    auto executor = new Executor();

    auto collection = new MockCollectionExpr!TestEntity([TestEntity("1"), TestEntity("2")]);
    auto query = map!(
        (Expr!TestEntity item) => use(
            (string id, RequestCtx ctx) => ctx.locale ~ ":" ~ id,
            use((TestEntity e) => e.id, item),
            context!RequestCtx(item)
        )
    )(collection);

    auto evalCtx = new EvalContext();
    evalCtx.setRequestContext(RequestCtx("fr"));

    auto result = awaitSync(executor.execute(query, evalCtx));
    assert(result == ["fr:1", "fr:2"]);
}

unittest {
    // Test executor with multiple context types
    import dunamis.core.expr.combinators : context;

    static struct AuthCtx { string userId; }
    static struct TenantCtx { string tenantId; }

    auto executor = new Executor();

    auto collection = new MockCollectionExpr!TestEntity([TestEntity("a")]);
    auto query = map!(
        (Expr!TestEntity item) => use(
            (string id, AuthCtx auth, TenantCtx tenant) =>
                auth.userId ~ "/" ~ tenant.tenantId ~ "/" ~ id,
            use((TestEntity e) => e.id, item),
            context!AuthCtx(item),
            context!TenantCtx(item)
        )
    )(collection);

    auto evalCtx = new EvalContext();
    evalCtx.setRequestContext(AuthCtx("user-1"));
    evalCtx.setRequestContext(TenantCtx("tenant-abc"));

    auto result = awaitSync(executor.execute(query, evalCtx));
    assert(result == ["user-1/tenant-abc/a"]);
}

// Test: SubscriptionExecutor basic event delivery
unittest {
    import std.json;
    import dunamis.core.expr.combinators : EventSourceExpr;

    static struct User {
        string name;
    }

    // Build a simple subscription expression tree:
    // eventSource!User → use to transform single entity to JSON
    auto es = new EventSourceExpr!User();
    auto query = use((User user) => JSONValue(["name": JSONValue(user.name)]), es);

    auto executor = new Executor();
    auto sub = new SubscriptionExecutor!User(executor, query);

    // Deliver an event
    auto result = awaitSync(sub.execute(User("Alice")));
    assert(result["name"].str == "Alice");

    // Deliver another event — fresh context
    auto result2 = awaitSync(sub.execute(User("Bob")));
    assert(result2["name"].str == "Bob");
}

// Test: SubscriptionExecutor with no EventSourceExpr throws
unittest {
    import std.json;

    static struct Dummy { string x; }

    auto expr = singleton(JSONValue("hello"));
    auto executor = new Executor();

    try {
        auto sub = new SubscriptionExecutor!Dummy(executor, expr);
        assert(false, "Should have thrown");
    } catch (Exception e) {
        // Expected: no EventSourceExpr found
    }
}
