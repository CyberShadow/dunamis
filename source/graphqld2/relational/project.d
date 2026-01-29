module graphqld2.relational.project;

import std.algorithm;
import std.array;
import std.range : iota;

import graphqld2.core.types;
import graphqld2.core.eval;
import graphqld2.core.expr;
import graphqld2.core.optimize;
import graphqld2.relational.eval_context;

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
        ExprBase _input;  // The input chain (for deriving refs)
    }

    this(int queryNodeId, string column, Expr!Ref input) {
        _queryNodeId = queryNodeId;
        _column = column;
        _input = input;
    }

    override ExprBase[] dependencies() {
        return [_input];
    }

    override void replaceDependency(size_t index, ExprBase newDep) {
        if (index == 0)
            _input = newDep;
    }

    override T[] eval(EvalContext ctx) {
        // Derive refs from input chain
        Ref[] refs = evalAs!Ref(_input, ctx);
        // Read from pre-fetched data via relational context
        auto relCtx = ctx.getSourceContext!RelationalEvalContext();
        return relCtx.getColumnValues!T(_queryNodeId, _column, refs);
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
        ExprBase _input;  // The input chain (for deriving refs)
    }

    this(int queryNodeId, string joinAlias, string column, Expr!Ref input) {
        _queryNodeId = queryNodeId;
        _joinAlias = joinAlias;
        _column = column;
        _input = input;
    }

    override ExprBase[] dependencies() {
        return [_input];
    }

    override void replaceDependency(size_t index, ExprBase newDep) {
        if (index == 0)
            _input = newDep;
    }

    override T[] eval(EvalContext ctx) {
        // Derive refs from input chain
        Ref[] refs = evalAs!Ref(_input, ctx);
        // Read from JOINed data via relational context
        auto relCtx = ctx.getSourceContext!RelationalEvalContext();
        return relCtx.getJoinedColumnValues!T(_queryNodeId, _joinAlias, _column, refs);
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
    }

    this(int queryNodeId) {
        _queryNodeId = queryNodeId;
    }

    override ExprBase[] dependencies() {
        return [];  // Reads from QueryResult
    }

    override void replaceDependency(size_t index, ExprBase newDep) {
        // No dependencies
    }

    override Ref[][] eval(EvalContext ctx) {
        // Get all refs from the pre-fetched QueryResult via relational context
        auto relCtx = ctx.getSourceContext!RelationalEvalContext();
        auto result = relCtx.getQueryResult(_queryNodeId);
        if (result is null) {
            return [[]];  // Single empty result for the single root parent
        }
        auto refs = result.allRefs();
        // Return single result for the single root parent
        return [refs];
    }

    @property int queryNodeId() { return _queryNodeId; }
}

/// Projects child refs grouped by parent from a QueryResult.
/// Used for hasMany relationships in optimized path.
class ProjectChildRefsExpr : Expr!(Ref[]) {
    private {
        int _queryNodeId;
        ExprBase _parentInput;  // Expression that yields parent refs
    }

    this(int queryNodeId, Expr!Ref parentInput) {
        _queryNodeId = queryNodeId;
        _parentInput = parentInput;
    }

    override ExprBase[] dependencies() {
        return [_parentInput];
    }

    override void replaceDependency(size_t index, ExprBase newDep) {
        if (index == 0)
            _parentInput = newDep;
    }

    override Ref[][] eval(EvalContext ctx) {
        // Get parent refs from the input chain
        Ref[] parentRefs = evalAs!Ref(_parentInput, ctx);

        // Get children grouped by parent from QueryResult via relational context
        auto relCtx = ctx.getSourceContext!RelationalEvalContext();
        auto result = relCtx.getQueryResult(_queryNodeId);
        if (result is null) {
            return parentRefs.map!(_ => cast(Ref[])[]).array;
        }
        return result.getChildRefs(parentRefs);
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
        ExprBase _input;  // The input chain (for deriving refs)
    }

    this(int queryNodeId, string fkColumn, string parentTypeName, Expr!Ref input) {
        _queryNodeId = queryNodeId;
        _fkColumn = fkColumn;
        _parentTypeName = parentTypeName;
        _input = input;
    }

    override ExprBase[] dependencies() {
        return [_input];
    }

    override void replaceDependency(size_t index, ExprBase newDep) {
        if (index == 0)
            _input = newDep;
    }

    override Ref[] eval(EvalContext ctx) {
        // Derive refs from input chain
        Ref[] refs = evalAs!Ref(_input, ctx);
        // Read FK values and encode as parent refs via relational context
        auto relCtx = ctx.getSourceContext!RelationalEvalContext();
        auto fkValues = relCtx.getColumnValues!long(_queryNodeId, _fkColumn, refs);
        return fkValues.map!(fk => fk == 0 ? Ref.init : makeRef(_parentTypeName, fk)).array;
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

    // Set up mock QueryResult
    auto result = new QueryResult();
    auto rows = [
        parseJSON(`{"id": 1, "first_name": "Alice"}`),
        parseJSON(`{"id": 2, "first_name": "Bob"}`)
    ];
    result.loadFromRows(rows, "User");
    relCtx.storeQueryResult(0, result);

    // Create a mock input that returns the refs
    auto item = new EveryItemOfExpr();
    ctx.currentRefs = [Ref("User:1"), Ref("User:2")];

    // Create projection with input
    auto proj = new ProjectColumnExpr!string(0, "first_name", item);

    // Evaluate
    auto names = proj.eval(ctx);
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

    auto proj = new ProjectRefsExpr(0);
    ctx.currentRefs = [queryRoot];
    auto refArrays = proj.eval(ctx);

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

    // Create a mock input that returns the refs
    auto item = new EveryItemOfExpr();
    ctx.currentRefs = [Ref("Post:1"), Ref("Post:2")];

    auto proj = new ProjectBelongsToExpr(0, "author_id", "User", item);
    auto parentRefs = proj.eval(ctx);

    assert(parentRefs == [Ref("User:10"), Ref("User:20")]);
}
