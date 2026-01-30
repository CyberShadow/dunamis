module graphqld2.relational.project;

import std.algorithm;
import std.array;
import std.conv;
import std.json;
import std.range : iota;

import ae.utils.promise;
import ae.utils.promise.await : awaitSync;

import graphqld2.core.types;
import graphqld2.core.eval;
import graphqld2.core.expr;
import graphqld2.core.optimize;
import graphqld2.relational.eval_context;
import graphqld2.relational.query_node;

// ============================================================================
// Prefetch Expression
// ============================================================================

/// Expression that prefetches data for a QueryNode.
/// When evaluated, executes the query and stores results in RelationalEvalContext.
///
/// Projection expressions depend on this to ensure data is loaded before reading.
/// Uses EvalContext's expression memoization to prevent duplicate fetches when
/// multiple projections depend on the same prefetch.
class PrefetchExpr : Expr!(Ref[]) {
    private {
        QueryNode _node;
        PrefetchExpr _parentPrefetch;  // For child nodes, ensures parent is fetched first
    }

    this(QueryNode node, PrefetchExpr parentPrefetch = null) {
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

    override Promise!(Ref[][]) eval(EvalContext ctx) {
        auto relCtx = ctx.getSourceContext!RelationalEvalContext();

        // Fast-path: data already stored from a previous evaluation
        if (relCtx.getQueryResult(_node.id) !is null) {
            return resolve([relCtx.getQueryResult(_node.id).allRefs()]);
        }

        // Note: Expression memoization is handled by evalAs(), so we don't need
        // to cache the Promise here. Multiple callers will get the same Promise.

        // Ensure parent is fetched first
        Promise!void parentReady;
        if (_parentPrefetch !is null) {
            parentReady = evalAs!(Ref[])(_parentPrefetch, ctx).then((_) {});
        } else {
            parentReady = resolve();
        }

        // Capture node for use in closure
        auto node = _node;

        return parentReady.then(() {
            // Get parent result for child nodes
            QueryResult parentResult = null;
            if (node.parent !is null) {
                parentResult = relCtx.getQueryResult(node.parent.id);
            }

            // Execute the query via DataFetcher (async)
            return relCtx.fetcher.executeQueryNode(node, parentResult);
        }).then((QueryResult result) {
            relCtx.storeQueryResult(node.id, result);
            return [result.allRefs()];
        });
    }

    @property QueryNode node() { return _node; }
}

// ============================================================================
// Interfaces for Optimizer Pattern Matching
// ============================================================================

/// Interface for ProjectColumnExpr pattern matching by external optimizers
interface ProjectColumnInfo {
    @property int queryNodeId();
    @property string column();
}

/// Interface for ProjectJoinedColumnExpr pattern matching by external optimizers
interface ProjectJoinedColumnInfo {
    @property int queryNodeId();
    @property string joinAlias();
    @property string column();
}

// ============================================================================
// Projection Expressions
// ============================================================================

/// Reads a column from pre-fetched QueryResults.
/// Created by optimizer when transforming ColumnAccessExpr.
class ProjectColumnExpr(T) : Expr!T, ProjectColumnInfo {
    private {
        int _queryNodeId;
        string _column;
        ExprBase _input;     // The input chain (for deriving refs)
        ExprBase _prefetch;  // PrefetchExpr - ensures data is loaded
    }

    this(int queryNodeId, string column, Expr!Ref input, PrefetchExpr prefetch) {
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

        // Ensure data is prefetched, then evaluate input, then read
        return evalAs!(Ref[])(_prefetch, ctx).then((_) {
            return evalAs!Ref(input, ctx);
        }).then((Ref[] refs) {
            auto relCtx = ctx.getSourceContext!RelationalEvalContext();
            return relCtx.getColumnValues!T(queryNodeId, column, refs);
        });
    }

    @property int queryNodeId() { return _queryNodeId; }
    @property string column() { return _column; }
}

/// Reads a column from a JOINed table in pre-fetched QueryResults.
/// Created by optimizer for belongsTo chain access.
class ProjectJoinedColumnExpr(T) : Expr!T, ProjectJoinedColumnInfo {
    private {
        int _queryNodeId;
        string _joinAlias;
        string _column;
        ExprBase _input;     // The input chain (for deriving refs)
        ExprBase _prefetch;  // PrefetchExpr - ensures data is loaded
    }

    this(int queryNodeId, string joinAlias, string column, Expr!Ref input, PrefetchExpr prefetch) {
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

        // Ensure data is prefetched, then evaluate input, then read
        return evalAs!(Ref[])(_prefetch, ctx).then((_) {
            return evalAs!Ref(input, ctx);
        }).then((Ref[] refs) {
            auto relCtx = ctx.getSourceContext!RelationalEvalContext();
            return relCtx.getJoinedColumnValues!T(queryNodeId, joinAlias, column, refs);
        });
    }

    @property int queryNodeId() { return _queryNodeId; }
    @property string joinAlias() { return _joinAlias; }
    @property string column() { return _column; }
}

/// Projects refs from a QueryResult (for root expressions).
/// Replaces GetByIdsExpr/GetAllExpr in optimized path.
/// At the root level, there's always exactly 1 parent (queryRoot).
class ProjectRefsExpr : Expr!(Ref[]) {
    private {
        int _queryNodeId;
        ExprBase _prefetch;  // PrefetchExpr - ensures data is loaded
    }

    this(int queryNodeId, PrefetchExpr prefetch) {
        _queryNodeId = queryNodeId;
        _prefetch = prefetch;
    }

    override ExprBase[] dependencies() {
        return [_prefetch];
    }

    override void replaceDependency(size_t index, ExprBase newDep) {
        if (index == 0)
            _prefetch = newDep;
    }

    override Promise!(Ref[][]) eval(EvalContext ctx) {
        auto queryNodeId = _queryNodeId;

        // Ensure data is prefetched, then read refs
        return evalAs!(Ref[])(_prefetch, ctx).then((_) {
            auto relCtx = ctx.getSourceContext!RelationalEvalContext();
            auto result = relCtx.getQueryResult(queryNodeId);
            if (result is null) {
                return [cast(Ref[])[]];  // Single empty result for the single root parent
            }
            auto refs = result.allRefs();
            // Return single result for the single root parent
            return [refs];
        });
    }

    @property int queryNodeId() { return _queryNodeId; }
}

/// Projects child refs grouped by parent from a QueryResult.
/// Used for hasMany relationships in optimized path.
class ProjectChildRefsExpr : Expr!(Ref[]) {
    private {
        int _queryNodeId;
        ExprBase _parentInput;  // Expression that yields parent refs
        ExprBase _prefetch;     // PrefetchExpr - ensures data is loaded
    }

    this(int queryNodeId, Expr!Ref parentInput, PrefetchExpr prefetch) {
        _queryNodeId = queryNodeId;
        _parentInput = parentInput;
        _prefetch = prefetch;
    }

    override ExprBase[] dependencies() {
        return [_parentInput, _prefetch];
    }

    override void replaceDependency(size_t index, ExprBase newDep) {
        if (index == 0)
            _parentInput = newDep;
        else if (index == 1)
            _prefetch = newDep;
    }

    override Promise!(Ref[][]) eval(EvalContext ctx) {
        auto queryNodeId = _queryNodeId;
        auto parentInput = _parentInput;

        // Ensure data is prefetched, then get parent refs, then lookup children
        return evalAs!(Ref[])(_prefetch, ctx).then((_) {
            return evalAs!Ref(parentInput, ctx);
        }).then((Ref[] parentRefs) {
            auto relCtx = ctx.getSourceContext!RelationalEvalContext();
            auto result = relCtx.getQueryResult(queryNodeId);
            if (result is null) {
                return parentRefs.map!(_ => cast(Ref[])[]).array;
            }
            return result.getChildRefs(parentRefs);
        });
    }

    @property int queryNodeId() { return _queryNodeId; }
}

/// Projects parent ref for each child (belongsTo).
/// Reads FK from the child's query result and encodes as parent ref.
class ProjectBelongsToExpr : Expr!Ref {
    private {
        int _queryNodeId;
        string _fkColumn;
        string _parentTypeName;
        ExprBase _input;     // The input chain (for deriving refs)
        ExprBase _prefetch;  // PrefetchExpr - ensures data is loaded
    }

    this(int queryNodeId, string fkColumn, string parentTypeName, Expr!Ref input, PrefetchExpr prefetch) {
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

    override Promise!(Ref[]) eval(EvalContext ctx) {
        auto queryNodeId = _queryNodeId;
        auto fkColumn = _fkColumn;
        auto parentTypeName = _parentTypeName;
        auto input = _input;

        // Ensure data is prefetched, then derive refs, then read FK values
        return evalAs!(Ref[])(_prefetch, ctx).then((_) {
            return evalAs!Ref(input, ctx);
        }).then((Ref[] refs) {
            auto relCtx = ctx.getSourceContext!RelationalEvalContext();
            // Read FK as string to support non-numeric IDs
            auto fkValues = relCtx.getColumnValues!string(queryNodeId, fkColumn, refs);
            return fkValues.map!(fk => fk.length == 0 ? Ref.init : makeRef(parentTypeName, fk)).array;
        });
    }

    @property int queryNodeId() { return _queryNodeId; }
    @property string fkColumn() { return _fkColumn; }
    @property string parentTypeName() { return _parentTypeName; }
}

// ============================================================================
// Tests
// ============================================================================


unittest {
    import std.json : parseJSON;

    // Test ProjectColumnExpr
    auto ctx = new EvalContext();
    auto relCtx = ctx.getSourceContext!RelationalEvalContext();

    // Set up mock QueryResult (pre-stored, so PrefetchExpr will just return)
    auto result = new QueryResult();
    auto rows = [
        parseJSON(`{"id": 1, "first_name": "Alice"}`),
        parseJSON(`{"id": 2, "first_name": "Bob"}`)
    ];
    result.loadFromRows(rows, "User");
    relCtx.storeQueryResult(0, result);

    // Create mock QueryNode and PrefetchExpr
    auto node = new QueryNode(0, "User", "users");
    auto prefetch = new PrefetchExpr(node);

    // Create a mock input that returns the refs
    auto item = new EveryItemOfExpr();
    ctx.setCurrentRefs(null, [Ref("User:1"), Ref("User:2")]);

    // Create projection with input and prefetch
    auto proj = new ProjectColumnExpr!string(0, "first_name", item, prefetch);

    // Evaluate
    auto names = awaitSync(proj.eval(ctx));
    assert(names == ["Alice", "Bob"]);
}

unittest {
    import std.json : parseJSON;

    // Test ProjectRefsExpr
    auto ctx = new EvalContext();
    auto relCtx = ctx.getSourceContext!RelationalEvalContext();

    auto result = new QueryResult();
    auto rows = [
        parseJSON(`{"id": 1}`),
        parseJSON(`{"id": 2}`),
        parseJSON(`{"id": 3}`)
    ];
    result.loadFromRows(rows, "User");
    relCtx.storeQueryResult(0, result);

    // Create mock QueryNode and PrefetchExpr
    auto node = new QueryNode(0, "User", "users");
    auto prefetch = new PrefetchExpr(node);

    auto proj = new ProjectRefsExpr(0, prefetch);
    ctx.setCurrentRefs(null, [queryRoot]);
    auto refArrays = awaitSync(proj.eval(ctx));

    assert(refArrays.length == 1);
    assert(refArrays[0] == [Ref("User:1"), Ref("User:2"), Ref("User:3")]);
}

// ProjectChildRefsExpr is tested via executor.d hasMany tests

unittest {
    import std.json : parseJSON;

    // Test ProjectBelongsToExpr
    auto ctx = new EvalContext();
    auto relCtx = ctx.getSourceContext!RelationalEvalContext();

    auto result = new QueryResult();
    auto rows = [
        parseJSON(`{"id": 1, "author_id": 10}`),
        parseJSON(`{"id": 2, "author_id": 20}`)
    ];
    result.loadFromRows(rows, "Post");
    relCtx.storeQueryResult(0, result);

    // Create mock QueryNode and PrefetchExpr
    auto node = new QueryNode(0, "Post", "posts");
    auto prefetch = new PrefetchExpr(node);

    // Create a mock input that returns the refs
    auto item = new EveryItemOfExpr();
    ctx.setCurrentRefs(null, [Ref("Post:1"), Ref("Post:2")]);

    auto proj = new ProjectBelongsToExpr(0, "author_id", "User", item, prefetch);
    auto parentRefs = awaitSync(proj.eval(ctx));

    assert(parentRefs == [Ref("User:10"), Ref("User:20")]);
}
