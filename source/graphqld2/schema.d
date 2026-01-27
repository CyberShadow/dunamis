module graphqld2.schema;

import std.algorithm;
import std.array;
import std.meta;
import std.traits;
import std.conv;

import graphqld2.plan;
import graphqld2.eval;

// ============================================================================
// Core Expression Types
// ============================================================================

/// Base class for all expressions in the two-phase model
abstract class Expr(T) {
    alias ResultType = T;

    /// Phase 1: Declare what data this expression needs
    abstract void plan(PlanContext ctx);

    /// Phase 2: Evaluate with pre-fetched data
    /// Returns one T per entity in ctx.currentIds
    abstract T[] eval(EvalContext ctx);
}

// ============================================================================
// Column Expression
// ============================================================================

/// Expression that reads a column from the current layer
class ColumnExpr(T) : Expr!T {
    private string _column;
    private int _layerId;  // Set during planning

    this(string column) {
        _column = column;
    }

    override void plan(PlanContext ctx) {
        _layerId = ctx.currentLayerId;
        ctx.requireColumn(_column);
    }

    override T[] eval(EvalContext ctx) {
        // Must evaluate in the layer we planned for
        assert(ctx.currentLayerId == _layerId,
            "Layer mismatch: planned for " ~ _layerId.to!string ~
            " but evaluating in " ~ ctx.currentLayerId.to!string);
        return ctx.getColumn!T(_column);
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
    private int _childLayerId;  // Set during planning

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
    private int _childLayerId;
    private Expr!T _childExpr;

    override void plan(PlanContext ctx) {
        _childLayerId = ctx.enterHasMany(
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
        // Get child IDs grouped by parent
        auto childIdGroups = ctx.getHasManyIds(_childLayerId, foreignKey);

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

    override T[][] eval(EvalContext ctx) {
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
    private int _parentLayerId;
    private Expr!T _parentExpr;

    override void plan(PlanContext ctx) {
        _parentLayerId = ctx.enterBelongsTo(
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
        // Get parent IDs for current entities
        auto parentIds = ctx.getBelongsToIds(_parentLayerId, foreignKey);

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
// Use Combinator (computed fields)
// ============================================================================

/// Extract result type from an Expr
template ExprResultType(E) {
    static if (is(E : Expr!T, T))
        alias ExprResultType = T;
    else
        static assert(false, "Not an Expr type: " ~ E.stringof);
}

/// Check if something is an Expr
template isExpr(T) {
    enum isExpr = is(T : Expr!U, U);
}

private template toArray(T) {
    alias toArray = T[];
}

/// Computed field expression using the `use` combinator
class UseExpr(Fn, Exprs...) : Expr!(ReturnType!Fn)
    if (Exprs.length >= 1 && allSatisfy!(isExpr, Exprs))
{
    import std.typecons : Tuple;

    alias R = ReturnType!Fn;
    alias InputTypes = staticMap!(ExprResultType, Exprs);
    alias EvaluatedArrays = Tuple!(staticMap!(toArray, InputTypes));

    private Tuple!Exprs _inputs;
    private Fn _fn;

    this(Exprs inputs, Fn fn) {
        static foreach (i; 0 .. Exprs.length) {
            _inputs[i] = inputs[i];
        }
        _fn = fn;
    }

    override void plan(PlanContext ctx) {
        // Plan all input expressions
        static foreach (i; 0 .. Exprs.length) {
            _inputs[i].plan(ctx);
        }
    }

    override R[] eval(EvalContext ctx) {
        // Evaluate all inputs into arrays
        EvaluatedArrays evaluated;
        static foreach (i; 0 .. Exprs.length) {
            evaluated[i] = _inputs[i].eval(ctx);
        }

        // Apply function per-element
        auto count = ctx.currentIds.length;
        R[] result = new R[count];
        foreach (idx; 0 .. count) {
            // Build args tuple for this index
            Tuple!InputTypes args;
            static foreach (i; 0 .. Exprs.length) {
                args[i] = evaluated[i][idx];
            }
            result[idx] = _fn(args.expand);
        }
        return result;
    }
}

/// Create a use expression from a callable and expressions
auto use(Fn, Exprs...)(Fn fn, Exprs exprs)
    if (Exprs.length >= 1 && allSatisfy!(isExpr, Exprs))
{
    return new UseExpr!(Fn, Exprs)(exprs, fn);
}

// ============================================================================
// Entity Mixin
// ============================================================================

/// Mixin to define an entity (table mapping)
mixin template Entity(string tableName) {
    static immutable string _table = tableName;
}

// ============================================================================
// Tests
// ============================================================================

// Test planning a simple field and computed fields
unittest {
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

    // Test planning a simple field
    {
        auto ctx = new PlanContext();
        ctx.setRoot("User", "users");

        auto expr = User.firstName();
        expr.plan(ctx);

        assert(ctx.layers.length == 1);
        assert(ctx.layers[0].columns.canFind("first_name"));
    }

    // Test planning a computed field
    {
        auto ctx = new PlanContext();
        ctx.setRoot("User", "users");

        auto expr = User.fullName();
        expr.plan(ctx);

        assert(ctx.layers.length == 1);
        assert(ctx.layers[0].columns.canFind("first_name"));
        assert(ctx.layers[0].columns.canFind("last_name"));
    }
}

// Test belongsTo relationship
unittest {
    // Define Post first since User doesn't reference Post in this test
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
    ctx.setRoot("Post", "posts");

    auto expr = Post.titleWithAuthor();
    expr.plan(ctx);

    // Should have two layers: Post and User
    assert(ctx.layers.length == 2);
    assert(ctx.layers[0].table == "posts");
    assert(ctx.layers[0].columns.canFind("title"));
    assert(ctx.layers[0].columns.canFind("author_id"));  // FK needed
    assert(ctx.layers[1].table == "users");
    assert(ctx.layers[1].columns.canFind("first_name"));
    assert(ctx.layers[1].columns.canFind("last_name"));
}

// Test hasMany relationship
unittest {
    // Define Post first since User references Post
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
    ctx.setRoot("User", "users");

    auto expr = User.posts().title();
    expr.plan(ctx);

    assert(ctx.layers.length == 2);
    assert(ctx.layers[0].table == "users");
    assert(ctx.layers[1].table == "posts");
    assert(ctx.layers[1].columns.canFind("title"));
    assert(ctx.layers[1].columns.canFind("author_id"));  // FK for grouping
}
