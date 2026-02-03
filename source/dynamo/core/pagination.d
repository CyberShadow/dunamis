/// Pagination expression nodes for LIMIT/OFFSET support.
///
/// These wrap list-returning expressions and apply pagination:
/// - LimitExpr: limits results to first N items
/// - OffsetExpr: skips first N items
///
/// During optimization, the relational optimizer can push these down to SQL.
/// If not pushed down, they fall back to in-memory evaluation.
module dynamo.core.pagination;

import std.algorithm : min;
import std.traits : isArray;

import ae.utils.promise;

import dynamo.core.expr;
import dynamo.core.eval;
import dynamo.core.optimize;

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

// ============================================================================
// LimitExpr - Limit results to first N items
// ============================================================================

/// Wraps an expression and limits results to first N items.
///
/// Example:
/// ---
/// auto limited = limit(users(), 10);  // First 10 users
/// ---
class LimitExpr(T) : Expr!(T[]), LimitInfo {
    private ExprBase _source;
    private size_t _limit;

    this(Expr!(T[]) source, size_t lim) {
        _source = source;
        _limit = lim;
    }

    override ExprBase[] dependencies() {
        return [_source];
    }

    override void replaceDependency(size_t index, ExprBase newDep) {
        if (index == 0) _source = newDep;
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
class OffsetExpr(T) : Expr!(T[]), OffsetInfo {
    private ExprBase _source;
    private size_t _offset;

    this(Expr!(T[]) source, size_t off) {
        _source = source;
        _offset = off;
    }

    override ExprBase[] dependencies() {
        return [_source];
    }

    override void replaceDependency(size_t index, ExprBase newDep) {
        if (index == 0) _source = newDep;
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
auto limit(T)(Expr!(T[]) source, size_t n) {
    return new LimitExpr!T(source, n);
}

/// Wrap expression with OFFSET - skips first N items.
///
/// Example:
/// ---
/// auto query = offset(users(), 20);  // Skip first 20 users
/// ---
auto offset(T)(Expr!(T[]) source, size_t n) {
    return new OffsetExpr!T(source, n);
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
