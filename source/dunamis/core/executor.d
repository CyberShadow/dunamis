module dunamis.core.executor;

import ae.utils.promise;
import ae.utils.promise.await : awaitSync;

import dunamis.core.datasource : ChangeEvent, DataSource, DataSession, SetupMode;
import dunamis.core.elements : analyzeBinders, subexpressions;
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
        E toEval = optimize ? this.optimize(expr) : expr;

        // Collect data sources for lifecycle management
        auto sources = collectDataSources(toEval);

        if (sources.length == 0) {
            // No data sources — evaluate directly (no setup/teardown needed)
            return toEval.eval(evalCtx.createScope(rootBinding)).then((T[] results) => results[0]);
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
            return toEval.eval(evalCtx.createScope(rootBinding));
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

    /// Optimize an expression tree (standard optimization, then the
    /// optimizers its data sources request, then the analysis of its binders,
    /// see `analyzeBinders`), without evaluating it.
    ///
    /// The optimized tree is not modified by evaluation, so it may be
    /// evaluated any number of times, also concurrently, with
    /// `execute(optimized, evalCtx, false)`.
    E optimize(E)(E expr) {
        auto optCtx = new OptimizeContext();
        E optimized = cast(E) expr.optimize(optCtx);

        // Walk tree to collect and run optimizers
        foreach (optimizer; collectOptimizers(optimized)) {
            optimizer.optimize(optimized, optCtx);
        }
        analyzeBinders(optimized);
        return optimized;
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

            // Recurse into subexpressions (also the predicates of filters
            // and sorts, which are not their dependencies)
            foreach (part; subexpressions(expr)) {
                walk(part);
            }
        }

        walk(root);
        return result;
    }

    /// The data sources of the expressions of a tree, deduplicated by instance.
    static DataSource[] dataSourcesOf(ExprBase root) {
        return collectDataSources(root);
    }

    /// Walk expression tree and collect data sources, deduplicated by instance.
    private static DataSource[] collectDataSources(ExprBase root) {
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

            foreach (part; subexpressions(expr)) {
                walk(part);
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
        _optimized = executor.optimize(expr);

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
        return execute(value, new EvalContext());
    }

    /// Deliver an event and evaluate the subscription query in `evalCtx`,
    /// a fresh context for this delivery (e.g. with request contexts set).
    Promise!JSONValue execute(T value, EvalContext evalCtx) {
        import std.json : JSONValue;

        _eventSource.deliver(evalCtx, value);

        if (_sources.length == 0) {
            return _optimized.eval(evalCtx.createScope(rootBinding))
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
            return _optimized.eval(evalCtx.createScope(rootBinding));
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
// Subscription Manager
// ============================================================================

/// Holds a table name and a type-erased handler for subscription events.
/// Created by relational helpers (e.g., `createSubscriptionHandler`) and
/// passed to `SubscriptionManager.subscribe()`.
struct SubscriptionRegistration {
    string tableName;
    SubscriptionManager.Handler handler;
}

/// Manages persistent subscriptions with dispatch by table name.
///
/// Supports multiple concurrent subscriptions per table. Each subscription
/// gets a unique ID for later removal via `unsubscribe()`.
///
/// Usage:
/// ---
/// auto mgr = new SubscriptionManager();
///
/// // Register a subscription (persistent — stays until unsubscribed)
/// auto id = mgr.subscribe("users", handler, onResult, onError);
///
/// // Wire event dispatch
/// session.setEventListener(mgr.eventListener());
///
/// // Later: remove the subscription
/// mgr.unsubscribe(id);
/// ---
class SubscriptionManager {
    import std.json : JSONValue;

    alias Handler = Promise!JSONValue delegate(ChangeEvent);
    alias ResultCallback = void delegate(JSONValue);
    alias ErrorCallback = void delegate(Exception);

    private struct Entry {
        size_t id;
        Handler handler;
        ResultCallback onResult;
        ErrorCallback onError;
    }

    private Entry[][string] _byTable;
    private size_t _nextId;

    /// Register a persistent subscription. Returns an ID for unsubscribe().
    size_t subscribe(string tableName, Handler handler,
                     ResultCallback onResult, ErrorCallback onError = null) {
        auto id = _nextId++;
        _byTable[tableName] ~= Entry(id, handler, onResult, onError);
        return id;
    }

    /// ditto
    size_t subscribe(SubscriptionRegistration reg,
                     ResultCallback onResult, ErrorCallback onError = null) {
        return subscribe(reg.tableName, reg.handler, onResult, onError);
    }

    /// Subscribe once, then auto-unsubscribe after first event delivery.
    /// Useful for HTTP long-poll testing; real transports use persistent subscribe().
    size_t subscribeOnce(string tableName, Handler handler,
                         ResultCallback onResult, ErrorCallback onError = null) {
        size_t id;
        id = subscribe(tableName, handler, (JSONValue result) {
            unsubscribe(id);
            onResult(result);
        }, onError is null ? null : (Exception e) {
            unsubscribe(id);
            onError(e);
        });
        return id;
    }

    /// ditto
    size_t subscribeOnce(SubscriptionRegistration reg,
                         ResultCallback onResult, ErrorCallback onError = null) {
        return subscribeOnce(reg.tableName, reg.handler, onResult, onError);
    }

    /// Remove a subscription by ID.
    void unsubscribe(size_t id) {
        foreach (table, ref entries; _byTable) {
            for (size_t i = 0; i < entries.length; i++) {
                if (entries[i].id == id) {
                    entries = entries[0 .. i] ~ entries[i + 1 .. $];
                    if (entries.length == 0)
                        _byTable.remove(table);
                    return;
                }
            }
        }
    }

    /// Dispatch an event to all matching subscriptions.
    void dispatch(ChangeEvent event) {
        if (auto entries = event.table in _byTable) {
            foreach (ref entry; *entries) {
                entry.handler(event).then((JSONValue result) {
                    entry.onResult(result);
                }).except((Exception e) {
                    if (entry.onError !is null)
                        entry.onError(e);
                });
            }
        }
    }

    /// Returns a delegate suitable for setEventListener().
    void delegate(ChangeEvent) eventListener() {
        return &dispatch;
    }

    @property bool hasSubscriptions() const {
        return _byTable.length > 0;
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

// Test: SubscriptionManager dispatch and unsubscribe
unittest {
    import std.json;

    auto mgr = new SubscriptionManager();

    JSONValue[] received;
    size_t id = mgr.subscribe("users",
        (ChangeEvent event) {
            return resolve(JSONValue(["table": JSONValue(event.table)]));
        },
        (JSONValue result) { received ~= result; }
    );

    assert(mgr.hasSubscriptions);

    // Dispatch an event
    auto event = new ChangeEvent();
    event.table = "users";
    event.kind = ChangeEvent.Kind.created;
    event.ids = ["1"];
    mgr.dispatch(event);

    // Resolve promises
    import ae.net.asockets : socketManager;
    socketManager.loop();

    assert(received.length == 1);
    assert(received[0]["table"].str == "users");

    // Unsubscribe
    mgr.unsubscribe(id);
    assert(!mgr.hasSubscriptions);

    // Dispatch again — no callback
    mgr.dispatch(event);
    socketManager.loop();
    assert(received.length == 1);
}

// Test: SubscriptionManager subscribeOnce auto-removes
unittest {
    import std.json;

    auto mgr = new SubscriptionManager();

    JSONValue[] received;
    mgr.subscribeOnce("posts",
        (ChangeEvent event) {
            return resolve(JSONValue(["id": JSONValue(event.ids[0])]));
        },
        (JSONValue result) { received ~= result; }
    );

    assert(mgr.hasSubscriptions);

    auto event = new ChangeEvent();
    event.table = "posts";
    event.kind = ChangeEvent.Kind.created;
    event.ids = ["42"];

    // First dispatch — delivers and auto-unsubscribes
    mgr.dispatch(event);
    import ae.net.asockets : socketManager;
    socketManager.loop();

    assert(received.length == 1);
    assert(received[0]["id"].str == "42");
    assert(!mgr.hasSubscriptions);

    // Second dispatch — no effect
    mgr.dispatch(event);
    socketManager.loop();
    assert(received.length == 1);
}

// Test: SubscriptionManager with SubscriptionRegistration
unittest {
    import std.json;

    auto mgr = new SubscriptionManager();

    JSONValue[] received;
    auto reg = SubscriptionRegistration("items",
        (ChangeEvent event) {
            return resolve(JSONValue("handled"));
        }
    );

    mgr.subscribe(reg, (JSONValue result) { received ~= result; });
    assert(mgr.hasSubscriptions);

    auto event = new ChangeEvent();
    event.table = "items";
    event.kind = ChangeEvent.Kind.created;
    event.ids = ["1"];
    mgr.dispatch(event);

    import ae.net.asockets : socketManager;
    socketManager.loop();

    assert(received.length == 1);
    assert(received[0].str == "handled");
}

unittest {
    // The data sources and optimizers of expressions within the predicates
    // of filters and sorts (which are not their dependencies) are the
    // tree's too: their sessions are set up for the request
    import dunamis.core.datasource : DataSource, DataSession, SetupMode;
    import dunamis.core.filtering : filterBy;
    import dunamis.core.sorting : sortBy;

    static class CountingSession : DataSession {
        bool setUp;
        override Promise!void setup(SetupMode mode = SetupMode.query) {
            setUp = true;
            return resolve();
        }
    }
    static class CountingSource : DataSource {
        override DataSession createSession() { return new CountingSession(); }
    }
    // An expression reading a data source (whose session must be set up)
    static class ReadsSource : Expr!bool {
        ExprBase _input;
        DataSource _source;
        this(ExprBase input, DataSource source) { _input = input; _source = source; }
        override ExprBase[] dependencies() { return [_input]; }
        override void replaceDependency(size_t index, ExprBase newDep) { _input = newDep; }
        override DataSource[] dataSources() { return [_source]; }
        override Promise!(bool[]) eval(EvalContext ctx) {
            auto session = cast(CountingSession) ctx.getSession(_source);
            assert(session.setUp, "The session of a data source read in a predicate was not set up");
            return _input.evalResultLength(ctx).then((size_t n) => new bool[n]);
        }
    }

    auto collection = new MockCollectionExpr!TestEntity([TestEntity("1"), TestEntity("2")]);
    auto source = new CountingSource();
    auto filtered = filterBy!((Expr!TestEntity e) => cast(Expr!bool) new ReadsSource(e, source))(collection);
    assert(Executor.dataSourcesOf(filtered) == [source]);
    assert(awaitSync(new Executor().execute(filtered)) == []);

    auto source2 = new CountingSource();
    auto sorted = sortBy!((Expr!TestEntity a, Expr!TestEntity b) => cast(Expr!bool) new ReadsSource(a, source2))(
        collection);
    assert(Executor.dataSourcesOf(sorted) == [source2]);
}
