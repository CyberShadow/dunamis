/// Pagination expression nodes for LIMIT/OFFSET support.
///
/// These wrap list-returning expressions and apply pagination:
/// - LimitExpr: limits results to first N items
/// - OffsetExpr: skips first N items
///
/// During optimization, the relational optimizer can push these down to SQL.
/// If not pushed down, they fall back to in-memory evaluation.
module dunamis.core.pagination;

import std.algorithm : min;
import std.traits : isArray;

import ae.utils.promise;

import dunamis.core.expr;
import dunamis.core.eval;
import dunamis.core.optimize;

// ============================================================================
// Interfaces for pagination detection
// ============================================================================

/// Interface for expressions that apply a LIMIT.
/// Used by optimizers to detect and push down pagination.
interface LimitInfo {
    /// Get the limit value
    size_t limitValue();

    /// Get the source expression (without the limit wrapper)
    ExprBase limitSource();
}

/// Interface for expressions that apply an OFFSET.
/// Used by optimizers to detect and push down pagination.
interface OffsetInfo {
    /// Get the offset value
    size_t offsetValue();

    /// Get the source expression (without the offset wrapper)
    ExprBase offsetSource();
}

/// Implemented by LimitExpr and OffsetExpr.  A *result window* is the
/// pagination requested for a field (e.g. GraphQL `first`/`offset`
/// arguments), as opposed to a limit that is part of what a field returns
/// (e.g. a computed "five latest posts" field).  A result window is applied
/// to the field's final result: restrictions that other arguments of the same
/// field ask for (filters) belong beneath it, whatever order the plugins
/// providing those arguments were applied in.  See `beneathResultWindows`.
interface ResultWindowInfo {
    /// Whether this LIMIT/OFFSET is a result window.
    bool isResultWindow();

    /// The collection the window is taken from.
    ExprBase windowSource();

    /// A new window of the same kind and size over `source`, which must have
    /// the type of `windowSource`.  This window itself is left unchanged.
    ExprBase withWindowSource(ExprBase source);
}

/// Apply `restrict` to `collection` beneath the result windows (if any) at
/// its top, and return the resulting collection.
///
/// Example: with `collection = limit(offset(users, 2, true), 10, true)` and a
/// filtering `restrict`, the result is `limit(offset(restrict(users), 2), 10)`
/// rather than `restrict(limit(offset(users, 2), 10))`.
///
/// Expression trees are not modified once built (their nodes may be shared),
/// so the result windows are rebuilt over the restricted source; `collection`
/// is left unchanged.
Expr!(E[]) beneathResultWindows(E)(Expr!(E[]) collection,
    scope Expr!(E[]) delegate(Expr!(E[])) restrict)
{
    auto window = cast(ResultWindowInfo) collection;
    if (window is null || !window.isResultWindow)
        return restrict(collection);
    // A LIMIT/OFFSET preserves its source's element type.
    auto source = cast(Expr!(E[])) window.windowSource;
    assert(source !is null, "Result window source has an unexpected type");
    auto rebuilt = cast(Expr!(E[])) window.withWindowSource(
        beneathResultWindows!E(source, restrict));
    assert(rebuilt !is null);
    return rebuilt;
}

// ============================================================================
// LimitExpr - Limit results to first N items
// ============================================================================

/// Wraps an expression and limits results to first N items.
///
/// Example:
/// ---
/// auto limited = limit(users(), 10);  // First 10 users
/// ---
class LimitExpr(T) : Expr!(T[]), LimitInfo, ResultWindowInfo {
    private ExprBase _source;
    private size_t _limit;
    private bool _resultWindow;  // See ResultWindowInfo

    this(Expr!(T[]) source, size_t lim, bool resultWindow = false) {
        _resultWindow = resultWindow;
        _source = source;
        _limit = lim;
    }

    override ExprBase[] dependencies() {
        return [_source];
    }

    override void replaceDependency(size_t index, ExprBase newDep) {
        if (index == 0) _source = newDep;
    }

    bool isResultWindow() { return _resultWindow; }
    ExprBase windowSource() { return _source; }
    ExprBase withWindowSource(ExprBase source) {
        return new LimitExpr!T(cast(Expr!(T[])) source, _limit, _resultWindow);
    }

    /// Get the limit value
    size_t limitValue() {
        return _limit;
    }

    /// Get the source expression (LimitInfo interface)
    ExprBase limitSource() {
        return _source;
    }

    /// Get the source expression (typed)
    @property Expr!(T[]) source() {
        return cast(Expr!(T[])) _source;
    }

    override Expr!(T[]) optimize(OptimizeContext ctx) {
        // Optimize source, keep wrapper (in-memory fallback works)
        // Push-down to SQL happens via the relational optimizer
        _source = source.optimize(ctx);
        return this;
    }

    override Promise!(T[][]) eval(EvalContext ctx) {
        // Fallback: apply in-memory if not pushed down to SQL
        return evalAs!(T[])(source, ctx).then((T[][] results) {
            T[][] limited;
            limited.length = results.length;
            foreach (i, group; results) {
                limited[i] = group.length > _limit ? group[0 .. _limit] : group;
            }
            return limited;
        });
    }
}

// ============================================================================
// OffsetExpr - Skip first N items
// ============================================================================

/// Wraps an expression and skips first N items.
///
/// Example:
/// ---
/// auto skipped = offset(users(), 20);  // Skip first 20 users
/// ---
class OffsetExpr(T) : Expr!(T[]), OffsetInfo, ResultWindowInfo {
    private ExprBase _source;
    private size_t _offset;
    private bool _resultWindow;  // See ResultWindowInfo

    this(Expr!(T[]) source, size_t off, bool resultWindow = false) {
        _resultWindow = resultWindow;
        _source = source;
        _offset = off;
    }

    override ExprBase[] dependencies() {
        return [_source];
    }

    override void replaceDependency(size_t index, ExprBase newDep) {
        if (index == 0) _source = newDep;
    }

    bool isResultWindow() { return _resultWindow; }
    ExprBase windowSource() { return _source; }
    ExprBase withWindowSource(ExprBase source) {
        return new OffsetExpr!T(cast(Expr!(T[])) source, _offset, _resultWindow);
    }

    /// Get the offset value
    size_t offsetValue() {
        return _offset;
    }

    /// Get the source expression (OffsetInfo interface)
    ExprBase offsetSource() {
        return _source;
    }

    /// Get the source expression (typed)
    @property Expr!(T[]) source() {
        return cast(Expr!(T[])) _source;
    }

    override Expr!(T[]) optimize(OptimizeContext ctx) {
        // Optimize source, keep wrapper (in-memory fallback works)
        // Push-down to SQL happens via the relational optimizer
        _source = source.optimize(ctx);
        return this;
    }

    override Promise!(T[][]) eval(EvalContext ctx) {
        // Fallback: apply in-memory if not pushed down to SQL
        return evalAs!(T[])(source, ctx).then((T[][] results) {
            T[][] offsetted;
            offsetted.length = results.length;
            foreach (i, group; results) {
                offsetted[i] = group.length > _offset ? group[_offset .. $] : [];
            }
            return offsetted;
        });
    }
}

// ============================================================================
// Factory Functions
// ============================================================================

/// Wrap expression with LIMIT - limits results to first N items.
///
/// Example:
/// ---
/// auto query = limit(users(), 10);  // First 10 users
/// ---
/// Pass `resultWindow = true` for the pagination requested for a field (see
/// `ResultWindowInfo`).
auto limit(T)(Expr!(T[]) source, size_t n, bool resultWindow = false) {
    return new LimitExpr!T(source, n, resultWindow);
}

/// Wrap expression with OFFSET - skips first N items.
///
/// Example:
/// ---
/// auto query = offset(users(), 20);  // Skip first 20 users
/// ---
/// Pass `resultWindow = true` for the pagination requested for a field (see
/// `ResultWindowInfo`).
auto offset(T)(Expr!(T[]) source, size_t n, bool resultWindow = false) {
    return new OffsetExpr!T(source, n, resultWindow);
}

// ============================================================================
// Unit Tests
// ============================================================================

unittest {
    import ae.utils.promise.await : awaitSync;

    // Test LimitExpr with in-memory data
    static struct Item {
        int value;
    }

    // Create a mock source expression that returns items
    auto source = new class Expr!(Item[]) {
        override ExprBase[] dependencies() { return []; }
        override void replaceDependency(size_t, ExprBase) {}

        override Promise!(Item[][]) eval(EvalContext ctx) {
            // Return two groups: [0,1,2,3,4] and [10,11,12]
            return resolve([
                [Item(0), Item(1), Item(2), Item(3), Item(4)],
                [Item(10), Item(11), Item(12)]
            ]);
        }
    };

    // Test limit
    auto limited = limit(source, 3);
    auto ctx = new EvalContext();
    auto result = awaitSync(limited.eval(ctx));

    assert(result.length == 2);
    assert(result[0].length == 3);  // [0, 1, 2]
    assert(result[0][0].value == 0);
    assert(result[0][2].value == 2);
    assert(result[1].length == 3);  // [10, 11, 12]
    assert(result[1][0].value == 10);
}

unittest {
    import ae.utils.promise.await : awaitSync;

    static struct Item {
        int value;
    }

    auto source = new class Expr!(Item[]) {
        override ExprBase[] dependencies() { return []; }
        override void replaceDependency(size_t, ExprBase) {}

        override Promise!(Item[][]) eval(EvalContext ctx) {
            return resolve([
                [Item(0), Item(1), Item(2), Item(3), Item(4)],
                [Item(10), Item(11), Item(12)]
            ]);
        }
    };

    // Test offset
    auto offsetted = offset(source, 2);
    auto ctx = new EvalContext();
    auto result = awaitSync(offsetted.eval(ctx));

    assert(result.length == 2);
    assert(result[0].length == 3);  // [2, 3, 4]
    assert(result[0][0].value == 2);
    assert(result[1].length == 1);  // [12]
    assert(result[1][0].value == 12);
}

unittest {
    import ae.utils.promise.await : awaitSync;

    static struct Item {
        int value;
    }

    auto source = new class Expr!(Item[]) {
        override ExprBase[] dependencies() { return []; }
        override void replaceDependency(size_t, ExprBase) {}

        override Promise!(Item[][]) eval(EvalContext ctx) {
            return resolve([
                [Item(0), Item(1), Item(2), Item(3), Item(4)]
            ]);
        }
    };

    // Test combined: offset then limit (skip 1, take 2)
    auto combined = limit(offset(source, 1), 2);
    auto ctx = new EvalContext();
    auto result = awaitSync(combined.eval(ctx));

    assert(result.length == 1);
    assert(result[0].length == 2);  // [1, 2]
    assert(result[0][0].value == 1);
    assert(result[0][1].value == 2);
}

unittest {
    import ae.utils.promise.await : awaitSync;

    static struct Item {
        int value;
    }

    auto source = new class Expr!(Item[]) {
        override ExprBase[] dependencies() { return []; }
        override void replaceDependency(size_t, ExprBase) {}

        override Promise!(Item[][]) eval(EvalContext ctx) {
            return resolve([
                [Item(0), Item(1)]
            ]);
        }
    };

    // Test offset larger than array - should return empty
    auto offsetted = offset(source, 10);
    auto ctx = new EvalContext();
    auto result = awaitSync(offsetted.eval(ctx));

    assert(result.length == 1);
    assert(result[0].length == 0);  // Empty
}

unittest {
    import ae.utils.promise.await : awaitSync;

    static struct Item {
        int value;
    }

    auto source = new class Expr!(Item[]) {
        override ExprBase[] dependencies() { return []; }
        override void replaceDependency(size_t, ExprBase) {}

        override Promise!(Item[][]) eval(EvalContext ctx) {
            return resolve([
                [Item(0), Item(1), Item(2)]
            ]);
        }
    };

    // Test limit larger than array - should return full array
    auto limited = limit(source, 100);
    auto ctx = new EvalContext();
    auto result = awaitSync(limited.eval(ctx));

    assert(result.length == 1);
    assert(result[0].length == 3);  // Full array
}

// beneathResultWindows restricts beneath result windows only, and rebuilds
// them rather than modifying the (possibly shared) existing tree.
unittest {
    import std.functional : toDelegate;
    import ae.utils.promise.await : awaitSync;

    static struct Item {
        int value;
    }

    static class Items : Expr!(Item[]) {
        override ExprBase[] dependencies() { return []; }
        override void replaceDependency(size_t, ExprBase) {}
        override Promise!(Item[][]) eval(EvalContext ctx) {
            return resolve([[Item(0), Item(1), Item(2), Item(3), Item(4), Item(5)]]);
        }
    }

    // Keeps the odd items.
    static class Odd : Expr!(Item[]) {
        Expr!(Item[]) source;
        this(Expr!(Item[]) source) { this.source = source; }
        override ExprBase[] dependencies() { return [source]; }
        override void replaceDependency(size_t, ExprBase) { assert(false); }
        override Promise!(Item[][]) eval(EvalContext ctx) {
            return source.eval(ctx).then((Item[][] groups) {
                Item[][] result;
                foreach (group; groups) {
                    Item[] odd;
                    foreach (item; group) if (item.value % 2) odd ~= item;
                    result ~= odd;
                }
                return result;
            });
        }
    }

    static int[] values(Expr!(Item[]) e) {
        int[] result;
        foreach (item; awaitSync(e.eval(new EvalContext()))[0]) result ~= item.value;
        return result;
    }

    static Expr!(Item[]) odd(Expr!(Item[]) s) { return new Odd(s); }

    auto items = new Items();
    auto inner = offset(items, 1, true);
    auto window = limit(inner, 2, true);
    auto restricted = beneathResultWindows!Item(window, toDelegate(&odd));
    assert(values(restricted) == [3, 5]);
    // The original windows are unchanged.
    assert(restricted !is window);
    assert(window.dependencies()[0] is inner && inner.dependencies()[0] is items);
    assert(values(window) == [1, 2]);

    // A limit that is not a result window stays beneath the restriction.
    auto own = limit(items, 2);
    assert(values(beneathResultWindows!Item(own, toDelegate(&odd))) == [1]);
}
