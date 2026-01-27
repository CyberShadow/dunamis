module graphqld2.relational.schema;

import std.algorithm;
import std.array;
import std.meta;
import std.traits;

import graphqld2.core;
import graphqld2.relational.types;
import graphqld2.relational.context;

// ============================================================================
// Entity Mixin
// ============================================================================

/// Mixin to define an entity (table mapping)
mixin template Entity(string tableName, string sourceId = "default") {
    static immutable string _table = tableName;
    static immutable string _sourceId = sourceId;
}

// ============================================================================
// Column Expression
// ============================================================================

/// Expression that reads a column from the current layer
class ColumnExpr(T) : Expr!T {
    private string _column;
    private int _layerId;
    private string _sourceId;

    this(string column) {
        _column = column;
    }

    override void plan(PlanContext ctx) {
        _layerId = ctx.currentLayerId;
        _sourceId = ctx.currentSourceId;
        ctx.source!RelationalPlanContext().requireColumn(_layerId, _column);
    }

    override T[] eval(EvalContext ctx) {
        auto relCtx = ctx.source!RelationalEvalContext(_sourceId);
        return relCtx.getColumn!T(_layerId, _column, ctx.currentIds);
    }
}

/// Helper to create a column expression
Expr!T column(T)(string columnName) {
    return new ColumnExpr!T(columnName);
}

// ============================================================================
// HasMany Relationship Expression
// ============================================================================

/// Expression representing a one-to-many relationship
/// Provides field access to child entity fields via opDispatch
class HasManyExpr(ChildEntity, string foreignKey) {
    private int _childLayerId;
    private string _sourceId;

    /// Forward field access to child entity's fields
    /// Returns an expression that evaluates to T[] per parent
    auto opDispatch(string field)() {
        alias FieldType = typeof(__traits(getMember, ChildEntity, field)());
        static if (is(FieldType : Expr!U, U)) {
            return new HasManyFieldExpr!(ChildEntity, foreignKey, field, U)();
        } else {
            // It's another relationship expression, wrap it
            return new HasManyRelExpr!(ChildEntity, foreignKey, field, FieldType)();
        }
    }
}

/// Expression for accessing a scalar field through a hasMany relationship
class HasManyFieldExpr(ChildEntity, string foreignKey, string field, T) : Expr!(T[]) {
    private int _parentLayerId;
    private int _childLayerId;
    private string _sourceId;
    private Expr!T _childExpr;

    override void plan(PlanContext ctx) {
        _parentLayerId = ctx.currentLayerId;
        _sourceId = ctx.currentSourceId;

        auto relCtx = ctx.source!RelationalPlanContext();
        _childLayerId = relCtx.enterHasMany(
            _parentLayerId,
            ChildEntity.stringof,
            ChildEntity._table,
            foreignKey
        );

        ctx.withLayer(_childLayerId, {
            _childExpr = __traits(getMember, ChildEntity, field)();
            _childExpr.plan(ctx);
        });
    }

    override T[][] eval(EvalContext ctx) {
        auto relCtx = ctx.source!RelationalEvalContext(_sourceId);

        // Get child IDs grouped by parent
        auto childIdGroups = relCtx.getHasManyIds(_childLayerId, foreignKey, ctx.currentIds);

        // Evaluate child expression for all children at once
        long[] allChildIds = childIdGroups.joiner.array;

        T[] allChildValues;
        if (allChildIds.length > 0) {
            ctx.withState(_childLayerId, allChildIds, {
                allChildValues = _childExpr.eval(ctx);
            });
        }

        // Re-group results by parent
        T[][] result;
        size_t offset = 0;
        foreach (group; childIdGroups) {
            result ~= allChildValues[offset .. offset + group.length];
            offset += group.length;
        }
        return result;
    }
}

/// Expression for accessing a relationship through a hasMany relationship
/// e.g., posts().comments() where posts is hasMany and comments is also hasMany
class HasManyRelExpr(ChildEntity, string foreignKey, string field, RelType) : Expr!(RelType[]) {
    // TODO: Implement nested relationship traversal
    override void plan(PlanContext ctx) {
        assert(false, "Nested relationship traversal not yet implemented");
    }

    override RelType[][] eval(EvalContext ctx) {
        assert(false, "Nested relationship traversal not yet implemented");
    }
}

/// Helper to create a hasMany expression
HasManyExpr!(ChildEntity, foreignKey) hasMany(ChildEntity, string foreignKey)() {
    return new HasManyExpr!(ChildEntity, foreignKey)();
}

// ============================================================================
// BelongsTo Relationship Expression
// ============================================================================

/// Expression representing a many-to-one relationship
class BelongsToExpr(ParentEntity, string foreignKey) {
    private int _parentLayerId;
    private string _sourceId;

    /// Forward field access to parent entity's fields
    auto opDispatch(string field)() {
        alias FieldType = typeof(__traits(getMember, ParentEntity, field)());
        static if (is(FieldType : Expr!U, U)) {
            return new BelongsToFieldExpr!(ParentEntity, foreignKey, field, U)();
        } else {
            static assert(false, "Nested relationships through belongsTo not yet supported");
        }
    }
}

/// Expression for accessing a scalar field through a belongsTo relationship
class BelongsToFieldExpr(ParentEntity, string foreignKey, string field, T) : Expr!T {
    private int _childLayerId;
    private int _parentLayerId;
    private string _sourceId;
    private Expr!T _parentExpr;

    override void plan(PlanContext ctx) {
        _childLayerId = ctx.currentLayerId;
        _sourceId = ctx.currentSourceId;

        auto relCtx = ctx.source!RelationalPlanContext();
        _parentLayerId = relCtx.enterBelongsTo(
            _childLayerId,
            ParentEntity.stringof,
            ParentEntity._table,
            foreignKey
        );

        ctx.withLayer(_parentLayerId, {
            _parentExpr = __traits(getMember, ParentEntity, field)();
            _parentExpr.plan(ctx);
        });
    }

    override T[] eval(EvalContext ctx) {
        auto relCtx = ctx.source!RelationalEvalContext(_sourceId);

        // Get FK values from current layer's rows
        auto parentIds = relCtx.getBelongsToIds(_childLayerId, foreignKey, ctx.currentIds);

        // Get unique parent IDs (preserve order for result mapping)
        long[] uniqueParentIds;
        size_t[long] parentIdIndex;
        foreach (pid; parentIds) {
            if (pid != 0 && pid !in parentIdIndex) {
                parentIdIndex[pid] = uniqueParentIds.length;
                uniqueParentIds ~= pid;
            }
        }

        // Evaluate parent expression for all unique parents
        T[] parentValues;
        if (uniqueParentIds.length > 0) {
            ctx.withState(_parentLayerId, uniqueParentIds, {
                parentValues = _parentExpr.eval(ctx);
            });
        }

        // Map back to original order
        T[] result;
        foreach (pid; parentIds) {
            if (pid == 0) {
                result ~= T.init;  // Null FK
            } else {
                result ~= parentValues[parentIdIndex[pid]];
            }
        }
        return result;
    }
}

/// Helper to create a belongsTo expression
BelongsToExpr!(ParentEntity, foreignKey) belongsTo(ParentEntity, string foreignKey)() {
    return new BelongsToExpr!(ParentEntity, foreignKey)();
}

// ============================================================================
// Root Expressions
// ============================================================================

/// Root expression that fetches all entities of a type
class RootAllExpr(Entity) {
    private int _layerId = -1;
    private string _sourceId;

    void plan(PlanContext ctx) {
        _sourceId = ctx.currentSourceId;
        auto relCtx = ctx.source!RelationalPlanContext();
        _layerId = relCtx.setRoot(Entity.stringof, Entity._table, FilterType.all);
        ctx.currentLayerId = _layerId;
    }

    /// Wrap an expression with this root
    auto select(E)(E expr) {
        return new RootSelectExpr!(typeof(this), E)(this, expr);
    }

    /// Convenience: access a field directly via opDispatch
    auto opDispatch(string fieldName)() {
        return select(__traits(getMember, Entity, fieldName)());
    }

    @property int layerId() { return _layerId; }
    @property string sourceId() { return _sourceId; }
}

/// Root expression that fetches a single entity by ID
class RootByIdExpr(Entity) {
    private long _id;
    private int _layerId = -1;
    private string _sourceId;

    this(long id) {
        _id = id;
    }

    void plan(PlanContext ctx) {
        _sourceId = ctx.currentSourceId;
        auto relCtx = ctx.source!RelationalPlanContext();
        _layerId = relCtx.setRoot(Entity.stringof, Entity._table, FilterType.byId, [_id]);
        ctx.currentLayerId = _layerId;
    }

    /// Wrap an expression with this root
    auto select(E)(E expr) {
        return new RootSelectExpr!(typeof(this), E)(this, expr);
    }

    /// Convenience: access a field directly via opDispatch
    auto opDispatch(string fieldName)() {
        return select(__traits(getMember, Entity, fieldName)());
    }

    @property int layerId() { return _layerId; }
    @property string sourceId() { return _sourceId; }
}

/// Combines a root expression with a field expression into a single evaluable expression
class RootSelectExpr(Root, E) : Expr!(E.ResultType) {
    private Root _root;
    private E _expr;

    this(Root root, E expr) {
        _root = root;
        _expr = expr;
    }

    override void plan(PlanContext ctx) {
        _root.plan(ctx);   // Sets up root layer
        _expr.plan(ctx);   // Plans expression in that context
    }

    override E.ResultType[] eval(EvalContext ctx) {
        return _expr.eval(ctx);
    }
}

/// Helper to create a root expression for all entities
RootAllExpr!Entity rootAll(Entity)() {
    return new RootAllExpr!Entity();
}

/// Helper to create a root expression for a single entity by ID
RootByIdExpr!Entity rootById(Entity)(long id) {
    return new RootByIdExpr!Entity(id);
}

// ============================================================================
// Tests
// ============================================================================

unittest {
    // Test planning with RelationalPlanContext
    auto ctx = new PlanContext();

    struct User {
        mixin Entity!"users";
        static Expr!string firstName() => column!string("first_name");
    }

    // Set up root
    ctx.currentSourceId = "default";
    auto relCtx = ctx.source!RelationalPlanContext();
    auto rootId = relCtx.setRoot("User", "users");
    ctx.currentLayerId = rootId;

    // Plan a column expression
    auto expr = User.firstName();
    expr.plan(ctx);

    assert(relCtx.layers.length >= 1);
    assert(relCtx.layers[0].columns.canFind("first_name"));
}

unittest {
    // Test hasMany relationship
    struct Post {
        mixin Entity!"posts";
        static Expr!string title() => column!string("title");
    }

    struct User {
        mixin Entity!"users";
        static Expr!string firstName() => column!string("first_name");
        static auto posts() => hasMany!(Post, "author_id");
    }

    auto ctx = new PlanContext();
    ctx.currentSourceId = "default";

    auto relCtx = ctx.source!RelationalPlanContext();
    auto rootId = relCtx.setRoot("User", "users");
    ctx.currentLayerId = rootId;

    auto expr = User.posts().title();
    expr.plan(ctx);

    assert(relCtx.layers.length >= 2);
    assert(relCtx.layers[0].table == "users");
    assert(relCtx.layers[1].table == "posts");
    assert(relCtx.layers[1].columns.canFind("title"));
    assert(relCtx.layers[1].columns.canFind("author_id"));
}

unittest {
    // Test belongsTo relationship
    struct User {
        mixin Entity!"users";
        static Expr!string firstName() => column!string("first_name");
        static Expr!string lastName() => column!string("last_name");
        static auto fullName() => use(
            (string first, string last) => first ~ " " ~ last,
            firstName(),
            lastName()
        );
    }

    struct Post {
        mixin Entity!"posts";
        static Expr!string title() => column!string("title");
        static auto author() => belongsTo!(User, "author_id");
        static auto titleWithAuthor() => use(
            (string title, string authorName) => title ~ " by " ~ authorName,
            title(),
            author().fullName()
        );
    }

    auto ctx = new PlanContext();
    ctx.currentSourceId = "default";

    auto relCtx = ctx.source!RelationalPlanContext();
    auto rootId = relCtx.setRoot("Post", "posts");
    ctx.currentLayerId = rootId;

    auto expr = Post.titleWithAuthor();
    expr.plan(ctx);

    assert(relCtx.layers.length >= 2);
    assert(relCtx.layers[0].table == "posts");
    assert(relCtx.layers[0].columns.canFind("title"));
    assert(relCtx.layers[0].columns.canFind("author_id"));
    assert(relCtx.layers[1].table == "users");
    assert(relCtx.layers[1].columns.canFind("first_name"));
    assert(relCtx.layers[1].columns.canFind("last_name"));
}
