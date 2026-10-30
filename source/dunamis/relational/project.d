module dunamis.relational.project;

import std.algorithm;
import std.array;
import std.conv;
import std.json;
import std.range : iota;

import ae.utils.promise;
import ae.utils.promise.await : awaitSync;

import dunamis.core.types;
import dunamis.core.eval;
import dunamis.core.expr;
import dunamis.core.optimize;
import dunamis.relational.eval_context;
import dunamis.relational.query_node;
import dunamis.relational.schema : BelongsToInfo, PrimaryKey;

// ============================================================================
// Prefetch Expression
// ============================================================================

/// Expression that prefetches data for a QueryNode.
/// When evaluated, executes the query and stores results in the RelationalSession.
///
/// Projection expressions depend on this to ensure data is loaded before reading.
/// Uses EvalContext's expression memoization to prevent duplicate fetches when
/// multiple projections depend on the same prefetch.
class PrefetchExpr : Expr!(AnyRef[]) {
    private {
        QueryNode _node;
        PrefetchExpr _parentPrefetch;  // For child nodes, ensures parent is fetched first
    }

    this(QueryNode node, PrefetchExpr parentPrefetch = null) {
        assert(node !is null, "PrefetchExpr requires a non-null QueryNode");
        assert((parentPrefetch !is null) == (node.parent !is null),
            "parentPrefetch must be provided iff node has a parent");
        _node = node;
        _parentPrefetch = parentPrefetch;
    }

    override ExprBase[] dependencies() {
        return _parentPrefetch !is null ? [_parentPrefetch] : [];
    }

    override void replaceDependency(size_t index, ExprBase newDep) {
        if (index == 0 && _parentPrefetch !is null)
            _parentPrefetch = cast(PrefetchExpr) newDep;
    }

    override Promise!(AnyRef[][]) eval(EvalContext ctx) {
        import dunamis.relational.query_node : FilterType;

        // Get session from QueryNode's data source
        auto ds = _node.dataSource;
        if (ds is null) return resolve([cast(AnyRef[])[]]);
        auto session = cast(RelationalSession) ctx.getSession(ds);

        // For mutation-returned entities: if this is a root node with no filter,
        // select the refs the MapExpr is iterating over in this evaluation.
        // They are passed along with the (read-only) node, not stored in it.
        auto root = _node.rootSelection;
        if (_node.isRoot && root.filter == FilterType.none && _node.mapExpr !is null) {
            auto currentRefs = ctx.getValues!AnyRef(_node.mapExpr);
            if (currentRefs.length > 0) {
                root = RootSelection(FilterType.byIds, currentRefs);
            }
        }

        // A query of the node's own rows already sent in this session (e.g.
        // from a scope of the evaluation, such as a filter predicate's,
        // whose memo the other scopes do not see) is not sent again.
        bool ownRows = root.filter == _node.rootFilter && root.refs is _node.rootFilterRefs;
        auto requested = root.refs;
        auto stored = session.getQueryResult(_node.id);
        if (ownRows) {
            if (stored !is null)
                return resolve([stored.allRefs()]);
            if (auto pending = session.pendingQueryResult(_node.id))
                return pending.then((QueryResult result) => [result.allRefs()]);
        } else if (stored !is null) {
            // Rows selected by the refs bound in this evaluation (of a
            // mutation's objects): those of an earlier evaluation, e.g. in
            // another scope with other refs, only if they hold these refs.
            // Otherwise the query selects both (the projections of the
            // earlier evaluation read the result stored, which replaces it).
            assert(root.filter == FilterType.byIds, "A node's stored result of other rows");
            if (stored.containsAllRefs(requested))
                return resolve([requested.dup]);
            auto all = stored.allRefs();
            foreach (r; requested)
                if (!stored.hasRef(r))
                    all ~= r;
            root = RootSelection(FilterType.byIds, all);
        }

        // Ensure parent is fetched first
        Promise!void parentReady;
        if (_parentPrefetch !is null) {
            parentReady = evalAs!(AnyRef[])(_parentPrefetch, ctx).then((_) {});
        } else {
            parentReady = resolve();
        }

        // Capture node for use in closure
        auto node = _node;

        auto query = parentReady.then(() {
            // Get parent result for child nodes
            QueryResult parentResult = null;
            if (node.parent !is null) {
                parentResult = session.getQueryResult(node.parent.id);
            }

            // Execute the query via session (async)
            return session.executeQueryNode(node, parentResult, root);
        }).then((QueryResult result) {
            session.storeQueryResult(node.id, result);
            return result;
        });
        if (ownRows) {
            session.setPendingQueryResult(node.id, query);
            return query.then((QueryResult result) => [result.allRefs()]);
        }
        return query.then((QueryResult _) => [requested]);
    }

    @property QueryNode node() { return _node; }
}

// ============================================================================
// Interfaces for Optimizer Pattern Matching
// ============================================================================

/// Interface for ProjectColumnExpr pattern matching by external optimizers
interface ProjectColumnInfo {
    @property QueryNodeId queryNodeId();
    @property string column();
}

/// Interface for ProjectJoinedColumnExpr pattern matching by external optimizers
interface ProjectJoinedColumnInfo {
    @property QueryNodeId queryNodeId();
    @property JoinAlias joinAlias();
    @property string column();
}

// ============================================================================
// Entity-to-AnyRef Adapter
// ============================================================================

/// Wraps an Expr!Entity and produces AnyRef[] by extracting the primary key.
/// Created by the relational optimizer at the point where the entity type is known,
/// so that downstream projection expressions can work with AnyRef[] without
/// needing entity-type awareness.
class EntityToAnyRefExpr(Entity) : Expr!AnyRef {
    private ExprBase _inner;

    this(ExprBase inner) {
        _inner = inner;
    }

    override ExprBase[] dependencies() {
        return [_inner];
    }

    override void replaceDependency(size_t index, ExprBase newDep) {
        if (index == 0)
            _inner = newDep;
    }

    override Promise!(AnyRef[]) eval(EvalContext ctx) {
        import dunamis.relational.schema.types : entityToRef;
        return evalAs!Entity(_inner, ctx).then((Entity[] entities) {
            return entities.map!(e => entityToRef(e)).array;
        });
    }
}

// ============================================================================
// Projection Expressions
// ============================================================================

/// Reads a column from pre-fetched QueryResults.
/// Created by optimizer when transforming ColumnAccessExpr.
class ProjectColumnExpr(T) : Expr!T, ProjectColumnInfo {
    private {
        QueryNodeId _queryNodeId;
        string _column;
        ExprBase _input;     // The input chain (for deriving refs) - Expr!AnyRef via EntityToAnyRefExpr
        ExprBase _prefetch;  // PrefetchExpr - ensures data is loaded
    }

    /// Accepts ExprBase to work with both typed Expr!Entity and untyped Expr!AnyRef
    this(QueryNodeId queryNodeId, string column, ExprBase input, PrefetchExpr prefetch) {
        assert(column.length > 0, "ProjectColumnExpr column must not be empty");
        assert(input !is null, "ProjectColumnExpr input must not be null");
        assert(prefetch !is null, "ProjectColumnExpr prefetch must not be null");
        _queryNodeId = queryNodeId;
        _column = column;
        _input = input;
        _prefetch = prefetch;
    }

    override ExprBase[] dependencies() {
        return [_input, _prefetch];
    }

    override void replaceDependency(size_t index, ExprBase newDep) {
        if (index == 0)
            _input = newDep;
        else if (index == 1)
            _prefetch = newDep;
    }

    override Promise!(T[]) eval(EvalContext ctx) {
        auto queryNodeId = _queryNodeId;
        auto column = _column;
        auto input = _input;
        auto prefetch = cast(PrefetchExpr) _prefetch;

        // Ensure data is prefetched, then evaluate input refs, then read
        return evalAs!(AnyRef[])(_prefetch, ctx).then((_) {
            return evalAs!AnyRef(input, ctx);
        }).then((AnyRef[] refs) {
            auto session = cast(RelationalSession) ctx.getSession(prefetch.node.dataSource);
            return session.getColumnValues!T(queryNodeId, column, refs);
        });
    }

    @property QueryNodeId queryNodeId() { return _queryNodeId; }
    @property string column() { return _column; }
}

/// Reads a column from a JOINed table in pre-fetched QueryResults.
/// Created by optimizer for belongsTo chain access.
class ProjectJoinedColumnExpr(T) : Expr!T, ProjectJoinedColumnInfo {
    private {
        QueryNodeId _queryNodeId;
        JoinAlias _joinAlias;
        string _column;
        ExprBase _input;     // The input chain (for deriving refs)
        ExprBase _prefetch;  // PrefetchExpr - ensures data is loaded
    }

    /// Accepts ExprBase to work with both typed Expr!Entity and untyped Expr!AnyRef
    this(QueryNodeId queryNodeId, JoinAlias joinAlias, string column, ExprBase input, PrefetchExpr prefetch) {
        assert(joinAlias.value.length > 0, "ProjectJoinedColumnExpr joinAlias must not be empty");
        assert(column.length > 0, "ProjectJoinedColumnExpr column must not be empty");
        assert(input !is null, "ProjectJoinedColumnExpr input must not be null");
        assert(prefetch !is null, "ProjectJoinedColumnExpr prefetch must not be null");
        _queryNodeId = queryNodeId;
        _joinAlias = joinAlias;
        _column = column;
        _input = input;
        _prefetch = prefetch;
    }

    override ExprBase[] dependencies() {
        return [_input, _prefetch];
    }

    override void replaceDependency(size_t index, ExprBase newDep) {
        if (index == 0)
            _input = newDep;
        else if (index == 1)
            _prefetch = newDep;
    }

    override Promise!(T[]) eval(EvalContext ctx) {
        auto queryNodeId = _queryNodeId;
        auto joinAlias = _joinAlias;
        auto column = _column;
        auto input = _input;
        auto prefetch = cast(PrefetchExpr) _prefetch;

        // Ensure data is prefetched, then evaluate input refs, then read
        return evalAs!(AnyRef[])(_prefetch, ctx).then((_) {
            return evalAs!AnyRef(input, ctx);
        }).then((AnyRef[] refs) {
            auto session = cast(RelationalSession) ctx.getSession(prefetch.node.dataSource);
            return session.getJoinedColumnValues!T(queryNodeId, joinAlias, column, refs);
        });
    }

    @property QueryNodeId queryNodeId() { return _queryNodeId; }
    @property JoinAlias joinAlias() { return _joinAlias; }
    @property string column() { return _column; }
}

/// Projects parent ref for each child (belongsTo).
/// Reads FK from the child's query result and encodes as parent ref.
class ProjectBelongsToExpr : Expr!AnyRef {
    private {
        QueryNodeId _queryNodeId;
        string _fkColumn;
        string _parentTypeName;
        ExprBase _input;     // The input chain (for deriving refs)
        ExprBase _prefetch;  // PrefetchExpr - ensures data is loaded
    }

    /// Accepts ExprBase to work with both typed Expr!Entity and untyped Expr!AnyRef
    this(QueryNodeId queryNodeId, string fkColumn, string parentTypeName, ExprBase input, PrefetchExpr prefetch) {
        assert(fkColumn.length > 0, "ProjectBelongsToExpr fkColumn must not be empty");
        assert(parentTypeName.length > 0, "ProjectBelongsToExpr parentTypeName must not be empty");
        assert(input !is null, "ProjectBelongsToExpr input must not be null");
        assert(prefetch !is null, "ProjectBelongsToExpr prefetch must not be null");
        _queryNodeId = queryNodeId;
        _fkColumn = fkColumn;
        _parentTypeName = parentTypeName;
        _input = input;
        _prefetch = prefetch;
    }

    override ExprBase[] dependencies() {
        return [_input, _prefetch];
    }

    override void replaceDependency(size_t index, ExprBase newDep) {
        if (index == 0)
            _input = newDep;
        else if (index == 1)
            _prefetch = newDep;
    }

    override Promise!(AnyRef[]) eval(EvalContext ctx) {
        auto queryNodeId = _queryNodeId;
        auto fkColumn = _fkColumn;
        auto parentTypeName = _parentTypeName;
        auto input = _input;
        auto prefetch = cast(PrefetchExpr) _prefetch;

        // Ensure data is prefetched, then evaluate input refs, then read FK values
        return evalAs!(AnyRef[])(_prefetch, ctx).then((_) {
            return evalAs!AnyRef(input, ctx);
        }).then((AnyRef[] refs) {
            auto session = cast(RelationalSession) ctx.getSession(prefetch.node.dataSource);
            // Read FK as string to support non-numeric IDs
            auto fkValues = session.getColumnValues!string(queryNodeId, fkColumn, refs);
            return fkValues.map!(fk => fk.length == 0 ? AnyRef.init : makeAnyRef(parentTypeName, fk)).array;
        });
    }

    @property QueryNodeId queryNodeId() { return _queryNodeId; }
    @property string fkColumn() { return _fkColumn; }
    @property string parentTypeName() { return _parentTypeName; }
}

/// Typed wrapper for ProjectBelongsToExpr that converts AnyRef to entity type.
/// Returns Parent[] for required FK, Nullable!Parent[] for optional FK.
/// Used by BelongsToAccessExpr.optimize() to replace naive fetchBelongsTo path.
///
/// Implements BelongsToInfo to allow chain traversal for nested BelongsTo
/// relationships (e.g., task.assignee.department).
class ProjectTypedBelongsToExpr(Child, Parent, ResultType, string fk) : Expr!ResultType, BelongsToInfo {
    import std.typecons : Nullable;
    import dunamis.relational.schema : EntityID;

    private ProjectBelongsToExpr _inner;
    private ExprBase _baseInput;  // Original input for chain continuation

    this(ProjectBelongsToExpr inner, ExprBase baseInput) {
        _inner = inner;
        _baseInput = baseInput;
    }

    override ExprBase[] dependencies() {
        return [_inner];
    }

    override void replaceDependency(size_t index, ExprBase newDep) {
        if (index == 0)
            _inner = cast(ProjectBelongsToExpr) newDep;
    }

    override Promise!(ResultType[]) eval(EvalContext ctx) {
        import dunamis.relational.schema.types : makeEntityFromRef, requiredParents;
        static if (is(ResultType == Parent)) {
            // Required FK - convert AnyRef to Parent; a missing one is of a
            // placeholder child, or an error (see requiredParents)
            auto baseInput = _baseInput;
            return _inner.eval(ctx).then((AnyRef[] refs) {
                if (refs.all!(r => r.isValid && r.localId.length))
                    return resolve(refs.map!(r => makeEntityFromRef!Parent(r)).array);
                return evalAs!AnyRef(baseInput, ctx).then((AnyRef[] childRefs) =>
                    requiredParents!(Child, Parent)(refs, childRefs, EntityID!Child.typeName ~ "." ~ fk));
            });
        } else static if (is(ResultType == Nullable!Parent)) {
            // Optional FK - wrap valid refs in Nullable, invalid as null
            return _inner.eval(ctx).then((AnyRef[] refs) =>
                refs.map!(r => r.isValid ? Nullable!Parent(makeEntityFromRef!Parent(r)) : Nullable!Parent.init).array);
        } else {
            static assert(false, "ResultType must be Parent or Nullable!Parent");
        }
    }

    // BelongsToInfo implementation for nested BelongsTo chain traversal
    @property ExprBase inputExpr() { return _baseInput; }
    @property ExprBase inputAsAnyRefExpr() { return _baseInput; }  // Already Expr!AnyRef (EntityToAnyRefExpr)
    @property string childTable() { return EntityID!Child.table; }
    @property string childTypeName() { return EntityID!Child.typeName; }
    @property string[] childPkColumns() {
        import dunamis.relational.schema.attrs : getPkColumns;
        return getPkColumns!Child;
    }
    @property string parentTable() { return EntityID!Parent.table; }
    @property string parentTypeName() { return EntityID!Parent.typeName; }
    @property string fkColumn() { return fk; }
    @property string[] parentPkColumns() {
        import dunamis.relational.schema.attrs : getPkColumns;
        return getPkColumns!Parent;
    }

    @property QueryNodeId queryNodeId() { return _inner.queryNodeId; }
}

// ============================================================================
// Tests
// ============================================================================


unittest {
    import std.json : parseJSON;

    import dunamis.relational.schema.attrs : Entity;
    import dunamis.relational.mock : MockDB;
    static MockDB!() _testDb;

    // Minimal entity for testing
    @Entity!(_testDb, "users", "User")
    static struct TestUser {
        @PrimaryKey long id;
    }

    _testDb = new MockDB!();

    // Test ProjectColumnExpr
    auto ctx = new EvalContext();
    auto session = cast(RelationalSession) ctx.getSession(_testDb);

    // Set up mock QueryResult (pre-stored, so PrefetchExpr will just return)
    auto result = new QueryResult();
    auto rows = [
        parseJSON(`{"id": 1, "first_name": "Alice"}`),
        parseJSON(`{"id": 2, "first_name": "Bob"}`)
    ];
    result.loadFromRows(rows, "User", ["id"]);
    session.storeQueryResult(QueryNodeId(0), result);

    // Create mock QueryNode and PrefetchExpr
    auto node = new QueryNode(QueryNodeId(0), "User", "users", ["id"]);
    node.dataSource = _testDb;
    auto prefetch = new PrefetchExpr(node);

    // Create a mock input that returns the refs via EntityToAnyRefExpr
    auto item = new EveryItemOfExpr!TestUser();
    ctx.setValues!TestUser(null, [TestUser(1), TestUser(2)]);
    auto refInput = new EntityToAnyRefExpr!TestUser(item);

    // Create projection with input and prefetch
    auto proj = new ProjectColumnExpr!string(QueryNodeId(0), "first_name", refInput, prefetch);

    // Evaluate
    auto names = awaitSync(proj.eval(ctx));
    assert(names == ["Alice", "Bob"]);
}

unittest {
    import std.json : parseJSON;

    import dunamis.relational.schema.attrs : Entity;
    import dunamis.relational.mock : MockDB;
    static MockDB!() _testDb2;

    // Minimal entity for testing
    @Entity!(_testDb2, "posts", "Post")
    static struct TestPost {
        @PrimaryKey long id;
    }

    _testDb2 = new MockDB!();

    // Test ProjectBelongsToExpr
    auto ctx = new EvalContext();
    auto session = cast(RelationalSession) ctx.getSession(_testDb2);

    auto result = new QueryResult();
    auto rows = [
        parseJSON(`{"id": 1, "author_id": 10}`),
        parseJSON(`{"id": 2, "author_id": 20}`)
    ];
    result.loadFromRows(rows, "Post", ["id"]);
    session.storeQueryResult(QueryNodeId(0), result);

    // Create mock QueryNode and PrefetchExpr
    auto node = new QueryNode(QueryNodeId(0), "Post", "posts", ["id"]);
    node.dataSource = _testDb2;
    auto prefetch = new PrefetchExpr(node);

    // Create a mock input that returns the refs via EntityToAnyRefExpr
    auto item = new EveryItemOfExpr!TestPost();
    ctx.setValues!TestPost(null, [TestPost(1), TestPost(2)]);
    auto refInput = new EntityToAnyRefExpr!TestPost(item);

    auto proj = new ProjectBelongsToExpr(QueryNodeId(0), "author_id", "User", refInput, prefetch);
    auto parentRefs = awaitSync(proj.eval(ctx));

    assert(parentRefs == [AnyRef("User:10"), AnyRef("User:20")]);
}

// A root node without a filter of its own (mutation-returned entities)
// selects the refs bound by each evaluation; evaluating the PrefetchExpr
// must not fix one evaluation's refs into the shared QueryNode.
unittest {
    import dunamis.relational.mock : MockDB;
    static MockDB!() _testDb3;
    _testDb3 = new MockDB!();
    _testDb3.setTableData("users", `[{"id": 1}, {"id": 2}]`);

    auto node = new QueryNode(QueryNodeId(0), "User", "users", ["id"]);
    node.dataSource = _testDb3;
    auto mapKey = new Object();
    node.mapExpr = mapKey;
    auto prefetch = new PrefetchExpr(node);

    AnyRef[] fetch(AnyRef[] bound) {
        auto ctx = new EvalContext();
        awaitSync(ctx.getSession(_testDb3).setup());
        ctx.setValues!AnyRef(mapKey, bound);
        return awaitSync(prefetch.eval(ctx))[0];
    }

    assert(fetch([AnyRef("User:1")]) == [AnyRef("User:1")]);
    assert(fetch([AnyRef("User:2")]) == [AnyRef("User:2")]);
    assert(node.rootFilter == FilterType.none);

    // Also in scopes of one request (one session), which bind other refs:
    // each gets the rows of its refs, not those of the first evaluation
    auto ctx = new EvalContext();
    awaitSync(ctx.getSession(_testDb3).setup());
    AnyRef[] fetchIn(AnyRef[] bound) {
        auto scope_ = ctx.createScope();
        scope_.setValues!AnyRef(mapKey, bound);
        return awaitSync(prefetch.eval(scope_))[0];
    }
    assert(fetchIn([AnyRef("User:1")]) == [AnyRef("User:1")]);
    assert(fetchIn([AnyRef("User:2")]) == [AnyRef("User:2")]);
    // (The session's result holds the rows of both)
    auto session = cast(RelationalSession) ctx.getSession(_testDb3);
    assert(session.getQueryResult(node.id).containsAllRefs([AnyRef("User:1"), AnyRef("User:2")]));
}
