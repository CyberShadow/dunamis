module dunamis.core.eval;

import std.json : JSONValue;

import dunamis.core.types;

// ============================================================================
// Type-Safe Storage for Heterogeneous Values
// ============================================================================

/// Type-safe wrapper for storing arrays of any type with runtime type checking.
/// Avoids serialization overhead of JSONValue while providing safety.
struct SealedArray {
    private void[] _data;
    private TypeInfo _type;

    /// Construct from a typed array.
    this(T)(T[] arr) {
        _data = cast(void[]) arr;
        _type = typeid(T);
    }

    /// Check if the stored type matches T.
    bool hasType(T)() const {
        return _type == typeid(T);
    }

    /// Retrieve as typed array. Asserts if type doesn't match.
    T[] get(T)() {
        assert(_type == typeid(T), "SealedArray type mismatch: expected " ~ _type.toString() ~ ", got " ~ typeid(T).toString());
        return cast(T[]) _data;
    }

    /// Check if empty (uninitialized).
    bool empty() const {
        return _data.length == 0;
    }
}

// ============================================================================
// GraphQL Error Type
// ============================================================================

/// A field-level error with message and path for partial result support.
/// Path elements are field names (strings) and array indices (integers),
/// following the GraphQL spec error format.
struct GraphQLError {
    string message;
    JSONValue[] path;

    /// Convert to the JSON format expected in GraphQL responses.
    JSONValue toJson() const {
        auto result = JSONValue.emptyObject;
        result["message"] = JSONValue(message);
        if (path.length > 0) {
            result["path"] = JSONValue(path.dup);
        }
        return result;
    }
}

// ============================================================================
// Eval Context - Abstract Key-Value Storage
// ============================================================================

/// Evaluation context providing abstract key-value storage for expressions.
/// Each data source (relational, REST, etc.) registers its own context type.
///
/// The context provides:
/// - Generic value storage (setValues/getValues) for expressions to communicate
/// - Expression result caching for memoization
/// - Source-specific context registration
///
/// Usage:
///   auto session = cast(RelationalSession) evalCtx.getSession(db);
///   auto values = session.getColumnValues!string(nodeId, "name", refs);
///
/// A context may be a scope of another (see `createScope`): a scope has its
/// own value bindings and memoized evaluations, and shares everything
/// request-scoped (sessions, request contexts, string maps, errors) with the
/// context it was created from, except for the data sessions it was given
/// to use instead of the request's.
class EvalContext {
    /// The context this one is a scope of (null for a request's context).
    private EvalContext _parent;

    /// The request's context (the outermost one this is a scope of).
    @property EvalContext request() { return root; }

    /// ditto
    private @property EvalContext root() {
        auto ctx = this;
        while (ctx._parent !is null)
            ctx = ctx._parent;
        return ctx;
    }

    /// Create a scope of this context, for evaluating a sub-expression with
    /// bindings of its own (for example a filter predicate for one item).
    /// Values bound and evaluations memoized in the scope stay in the scope;
    /// those of this context are visible from it, unless the scope overrides
    /// them. This context is not modified, so other evaluations in flight in
    /// it are not affected.
    EvalContext createScope() {
        auto scope_ = new EvalContext();
        scope_._parent = this;
        return scope_;
    }

    /// Create a scope of this context in which the data sources of
    /// `overrides` have the sessions given there instead of the request's
    /// (and of this context's): expressions evaluated in the scope (and in
    /// scopes of it), e.g. with `evaluateNested`, use them. For example, a
    /// PostgreSQL session derived from the request's with other settings
    /// (`PostgresSession.withSettings`) evaluates expressions as of these
    /// settings, while sibling evaluations in the request see the request's.
    ///
    /// The overriding sessions belong to the scope: the executor does not
    /// set them up or tear them down (`allSessions` is the request's).
    EvalContext createScope(DataSession[DataSource] overrides) {
        auto scope_ = createScope();
        scope_._overrides = overrides.dup;
        return scope_;
    }

    // ========================================================================
    // Data Session Management
    // ========================================================================

    import dunamis.core.datasource : DataSource, DataSession;

    /// Per-request sessions keyed by their data source singleton.
    /// Created lazily via getSession() and managed by the Executor.
    private DataSession[DataSource] _sessions;

    /// The sessions a scope uses instead of the request's (see createScope).
    private DataSession[DataSource] _overrides;

    /// Get or create a per-request session for a data source.
    /// Sessions are cached: calling getSession(ds) twice returns the same session.
    /// The Executor calls setup()/teardown() on all sessions.
    DataSession getSession(DataSource ds) {
        if (auto s = ds in _overrides)
            return *s;
        if (_parent !is null)
            return _parent.getSession(ds);
        if (auto s = ds in _sessions)
            return *s;
        auto s = ds.createSession();
        _sessions[ds] = s;
        return s;
    }

    /// Whether the request has a session for the data source `ds` (that
    /// is, `getSession(ds)` was called, normally by the executor).
    bool hasSession(DataSource ds) {
        if (ds in _overrides)
            return true;
        if (_parent !is null)
            return _parent.hasSession(ds);
        return (ds in _sessions) !is null;
    }

    /// Get all sessions of the request (for Executor lifecycle management;
    /// without the sessions of scopes, see createScope).
    @property DataSession[] allSessions() {
        if (_parent !is null)
            return root.allSessions;
        return _sessions.values;
    }

    /// Generic value storage keyed by expression identity.
    /// Expressions use this to pass values to their children.
    /// Examples:
    /// - MapExpr stores N items for EveryItemOfExpr to retrieve
    /// - SortByExpr stores 2 items (left, right) for SortItemExpr
    /// - FilterByExpr stores 1 item for FilterItemExpr
    /// - Optimized paths store AnyRef[] for column access
    private SealedArray[void*] _valueMap;

    /// Expression evaluation cache, keyed by expression object identity.
    /// Used by evalAs() to automatically memoize expression evaluation.
    /// When the same expression is evaluated multiple times (e.g., via
    /// parallel dependencies), the same Promise is returned.
    /// Uses SealedArray for runtime type checking (stores promise as 1-element array).
    private SealedArray[void*] _exprCache;

    /// Set values for an expression (generic storage for any T[]).
    void setValues(T)(Object key, T[] vals) {
        _valueMap[cast(void*) key] = SealedArray(vals);
    }

    /// Get values for an expression.
    /// Returns empty array if not set or if type doesn't match.
    T[] getValues(T)(Object key) {
        T[] vals;
        tryGetValues!T(key, vals);
        return vals;
    }

    /// Get the values bound for an expression, distinguishing "bound to an
    /// empty batch" from "not bound". Returns false (leaving `vals` empty) if
    /// no values of type T are bound to `key`.
    bool tryGetValues(T)(Object key, out T[] vals) {
        if (auto p = cast(void*) key in _valueMap) {
            if (p.hasType!T) {
                vals = p.get!T();
                return true;
            }
        }
        if (_parent !is null)
            return _parent.tryGetValues!T(key, vals);
        return false;
    }

    /// Get cached Promise for an expression, or null if types don't match.
    /// Uses runtime type checking via SealedArray — asserts on type mismatch
    /// rather than silently returning null.
    import ae.utils.promise : Promise;
    Promise!(T[]) getCachedEval(T)(Object expr) {
        if (auto p = cast(void*) expr in _exprCache) {
            if (p.hasType!(Promise!(T[])))
                return p.get!(Promise!(T[]))()[0];
        }
        if (_parent !is null)
            return _parent.getCachedEval!T(expr);
        return null;
    }

    /// Cache a Promise for an expression.
    /// Only caches if no entry exists yet — avoids overwriting a differently-typed
    /// cached promise (the same expression may be evaluated as different types).
    void setCachedEval(T)(Object expr, Promise!(T[]) promise) {
        auto key = cast(void*) expr;
        if (key !in _exprCache)
            _exprCache[key] = SealedArray([promise]);
    }

    /// Clear the cached eval for a specific expression (in this context).
    void clearCachedEval(Object expr) {
        _exprCache.remove(cast(void*) expr);
    }

    // ========================================================================
    // Request Context Storage
    // ========================================================================

    /// Type-keyed storage for request-scoped context values.
    /// Users can store multiple context types (e.g., AuthCtx, TenantCtx)
    /// and retrieve them from computed fields via context!T(expr).
    private void*[TypeInfo] _requestContexts;

    /// Store a request context value. Call once per type before executing a query.
    /// Only struct types are supported (value semantics, no aliasing issues).
    void setRequestContext(T)(T value) if (is(T == struct)) {
        if (_parent !is null)
            return root.setRequestContext(value);
        auto p = new T;
        *p = value;
        _requestContexts[typeid(T)] = cast(void*) p;
    }

    /// Retrieve a previously stored request context value.
    /// Asserts if the context type was not set — this is a programming error.
    T getRequestContext(T)() if (is(T == struct)) {
        if (_parent !is null)
            return root.getRequestContext!T();
        auto p = typeid(T) in _requestContexts;
        assert(p !is null,
            "Request context " ~ T.stringof ~ " not set. " ~
            "Call evalCtx.setRequestContext(" ~ T.stringof ~ "(...)) before executing the query.");
        return *(cast(T*) *p);
    }

    /// Check if a request context type has been set.
    bool hasRequestContext(T)() if (is(T == struct)) {
        if (_parent !is null)
            return root.hasRequestContext!T();
        return (typeid(T) in _requestContexts) !is null;
    }

    // ========================================================================
    // Field-Level Error Collection
    // ========================================================================

    private GraphQLError[] _errors;

    /// Record a field-level error with its path.
    void addError(string message, JSONValue[] path) {
        if (_parent !is null)
            return root.addError(message, path);
        _errors ~= GraphQLError(message, path);
    }

    /// Get all collected errors (for response assembly).
    @property const(GraphQLError)[] errors() const {
        return _parent !is null ? _parent.errors : _errors;
    }

    /// Check if any errors were collected.
    @property bool hasErrors() const {
        return errors.length > 0;
    }
}

// ============================================================================
// Tests
// ============================================================================

unittest {
    // Test generic value storage
    auto ctx = new EvalContext();

    static struct TestEntity { int id; }

    auto key1 = new Object();
    auto key2 = new Object();

    ctx.setValues!TestEntity(key1, [TestEntity(1), TestEntity(2)]);
    ctx.setValues!int(key2, [10, 20, 30]);

    auto vals1 = ctx.getValues!TestEntity(key1);
    assert(vals1.length == 2);
    assert(vals1[0].id == 1);
    assert(vals1[1].id == 2);

    auto vals2 = ctx.getValues!int(key2);
    assert(vals2 == [10, 20, 30]);

    // Non-existent key returns empty
    auto vals3 = ctx.getValues!int(new Object());
    assert(vals3.length == 0);
}

unittest {
    // Test request context storage with multiple types
    static struct AuthCtx { string userId; bool isAdmin; }
    static struct TenantCtx { string tenantId; string locale; }

    auto ctx = new EvalContext();

    // Initially not set
    assert(!ctx.hasRequestContext!AuthCtx);
    assert(!ctx.hasRequestContext!TenantCtx);

    // Set and retrieve AuthCtx
    ctx.setRequestContext(AuthCtx("user-1", true));
    assert(ctx.hasRequestContext!AuthCtx);
    auto auth = ctx.getRequestContext!AuthCtx;
    assert(auth.userId == "user-1");
    assert(auth.isAdmin == true);

    // Set and retrieve TenantCtx (independent of AuthCtx)
    ctx.setRequestContext(TenantCtx("tenant-abc", "fr"));
    assert(ctx.hasRequestContext!TenantCtx);
    auto tenant = ctx.getRequestContext!TenantCtx;
    assert(tenant.tenantId == "tenant-abc");
    assert(tenant.locale == "fr");

    // AuthCtx still available
    auto authAgain = ctx.getRequestContext!AuthCtx;
    assert(authAgain.userId == "user-1");

    // Overwrite with new value
    ctx.setRequestContext(AuthCtx("user-2", false));
    auto authNew = ctx.getRequestContext!AuthCtx;
    assert(authNew.userId == "user-2");
    assert(authNew.isAdmin == false);
}

unittest {
    // Test error collection
    auto ctx = new EvalContext();

    assert(!ctx.hasErrors);
    assert(ctx.errors.length == 0);

    // Add errors with paths
    ctx.addError("field failed", [JSONValue("users"), JSONValue("fullName")]);
    assert(ctx.hasErrors);
    assert(ctx.errors.length == 1);
    assert(ctx.errors[0].message == "field failed");
    assert(ctx.errors[0].path == [JSONValue("users"), JSONValue("fullName")]);

    // Add another error
    ctx.addError("another failure", [JSONValue("posts"), JSONValue("title")]);
    assert(ctx.errors.length == 2);

    // Test toJson
    auto json = ctx.errors[0].toJson();
    assert(json["message"].str == "field failed");
    assert(json["path"].array.length == 2);
    assert(json["path"][0].str == "users");
    assert(json["path"][1].str == "fullName");

    // Error with empty path
    ctx.addError("root error", []);
    auto rootJson = ctx.errors[2].toJson();
    assert(rootJson["message"].str == "root error");
    assert("path" !in rootJson);
}

unittest {
    // Scopes: own bindings and memo, request-scoped state shared
    import ae.utils.promise : resolve;
    static struct AuthCtx { string userId; }

    auto ctx = new EvalContext();
    auto key = new Object();
    auto other = new Object();
    ctx.setValues!int(key, [1]);
    ctx.setValues!int(other, [2]);
    ctx.setCachedEval!int(other, resolve([2]));
    ctx.setRequestContext(AuthCtx("user-1"));

    auto scope_ = ctx.createScope();
    scope_.setValues!int(key, [10]);
    assert(scope_.getValues!int(key) == [10]);
    assert(scope_.getValues!int(other) == [2]);
    assert(ctx.getValues!int(key) == [1]);
    assert(scope_.getCachedEval!int(other) is ctx.getCachedEval!int(other));
    scope_.setCachedEval!int(key, resolve([10]));
    assert(ctx.getCachedEval!int(key) is null);
    assert(scope_.getRequestContext!AuthCtx.userId == "user-1");

    scope_.addError("failed", []);
    assert(ctx.hasErrors && ctx.errors.length == 1);
    assert(scope_.errors.length == 1);

    import ae.utils.promise.await : awaitSync;
    assert(awaitSync(ctx.getCachedEval!int(other)) == [2]);
    assert(awaitSync(scope_.getCachedEval!int(key)) == [10]);
}

unittest {
    // Scopes with sessions of their own: used in the scope and its scopes,
    // not in the request's context or its other scopes
    import dunamis.core.datasource : DataSession, DataSource;

    auto ds = new DataSource();
    auto other = new DataSource();
    auto ctx = new EvalContext();
    auto session = ctx.getSession(ds);
    auto override_ = new DataSession();

    auto scope_ = ctx.createScope([ds: override_]);
    assert(scope_.getSession(ds) is override_);
    assert(scope_.hasSession(ds) && !scope_.hasSession(other));
    assert(scope_.createScope().getSession(ds) is override_);
    assert(ctx.getSession(ds) is session);
    assert(ctx.createScope().getSession(ds) is session);
    assert(ctx.allSessions == [session] && scope_.allSessions == [session]);
    // Other data sources: the request's sessions (created in the request)
    auto otherSession = scope_.getSession(other);
    assert(ctx.getSession(other) is otherSession);
}
