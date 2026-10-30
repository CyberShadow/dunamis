module dunamis.core.expr.base;

import std.meta;
import std.traits;
import std.typecons : Nullable;

import ae.utils.promise;

import dunamis.core.types;
import dunamis.core.eval;
import dunamis.core.optimize;

// ============================================================================
// Type-Erased Base Class
// ============================================================================

/// Type-erased base class for all expressions.
/// Enables external tree traversal and optimization as a separate step.
abstract class ExprBase {
    import dunamis.core.optimize : ExprOptimizer;

    /// Get all child expressions (for tree traversal).
    /// Returns empty array for leaf expressions.
    abstract ExprBase[] dependencies();

    /// Replace a child expression at the given index.
    /// Used by external optimizers to transform the tree.
    abstract void replaceDependency(size_t index, ExprBase newDep);

    /// Get the result type of this expression.
    abstract TypeInfo resultType();

    /// Evaluate and return result length (type-erased).
    /// Used by ConstExpr to derive batch size from another expression.
    abstract Promise!size_t evalResultLength(EvalContext ctx);

    /// Optimize this expression and its children (type-erased: see
    /// `Expr.optimize`, which typed expressions implement this with).
    /// Returns: the optimized expression (this or a replacement).
    ExprBase optimizeBase(OptimizeContext ctx) {
        return this;
    }

    /// Get optimizers this expression needs.
    /// Override in expressions tied to specific data sources.
    /// Executor walks the tree and collects these.
    ExprOptimizer[] requestedOptimizers() {
        return [];
    }

    /// Get data sources this expression is bound to.
    /// Override in expressions tied to specific data sources.
    /// Executor walks the tree and collects these for lifecycle management.
    import dunamis.core.datasource : DataSource;
    DataSource[] dataSources() {
        return [];
    }
}

/// A nesting level's index keys for error path tracking.
/// Each MapExpr level provides local indices (position within parent's
/// collection) and group indices (which parent group each element belongs to).
struct IndexLevel {
    Object localKey;   /// ctx.getValues!size_t(localKey) → local index within parent
    Object groupKey;   /// ctx.getValues!size_t(groupKey) → which parent group
    /// ctx.getValues!MapDedup(dedupKey) → the deduplication of the level's
    /// batch, if its map evaluated each distinct element once (see MapDedup)
    Object dedupKey;
}

/// How a map (MapExpr) evaluated a batch with repeated elements: its body
/// was evaluated once per distinct element, the batch's elements sharing
/// the results of their distinct element. Bound (as a single value) to the
/// map's dedupKey; the map's local and group indices are then those of the
/// distinct elements' first occurrences.
struct MapDedup {
    /// For each distinct element (in the order of their first occurrence),
    /// the positions in the batch of the elements equal to it.
    size_t[][] occurrences;
    /// The local and group indices of every element of the batch.
    size_t[] localIndices, groupIndices;
}

/// Interface for expressions that track element indices in error paths.
/// Implemented by expressions that record per-element errors (e.g.,
/// MaterializeGqlResultExpr). The `map!` function auto-links any
/// IndexSourceConsumer in its body to the MapExpr's index level.
interface IndexSourceConsumer {
    void addIndexSource(IndexLevel level);
}

/// Helper to evaluate an ExprBase with a known type.
/// Returns a Promise that resolves to T[].
/// Asserts if the runtime type doesn't match.
///
/// Automatically memoizes: if the same expression is evaluated multiple times
/// (e.g., via parallel dependencies), returns the cached Promise instead of
/// re-evaluating. This is safe because expressions are pure/deterministic.
Promise!(T[]) evalAs(T)(ExprBase expr, EvalContext ctx) {
    if (auto cached = ctx.getCachedEval!T(expr))
        return cached;

    auto typed = cast(Expr!T) expr;
    assert(typed !is null, "Type mismatch in evalAs: expected " ~ T.stringof);

    auto promise = typed.eval(ctx);
    ctx.setCachedEval!T(expr, promise);
    return promise;
}

// ============================================================================
// Typed Expression Class
// ============================================================================

/// Typed expression base - adds typed evaluation to ExprBase.
/// User-facing code works with Expr!T for compile-time type safety.
///
/// Expressions are written with per-element semantics — as if operating on
/// a single entity. Batching happens automatically during evaluation.
///
/// Batch semantics: eval() returns Promise!(T[]) — one result per input ref.
abstract class Expr(T) : ExprBase {
    alias ResultType = T;

    override TypeInfo resultType() {
        return typeid(T);
    }

    /// Optimize this expression and its children.
    /// Returns: optimized expression (may be this or a replacement).
    Expr!T optimize(OptimizeContext ctx) {
        return this;  // Default: no optimization
    }

    override final ExprBase optimizeBase(OptimizeContext ctx) {
        return optimize(ctx);
    }

    /// Evaluate for the current batch of entity references.
    /// Returns Promise!(T[]) with one result per ref in ctx.currentRefs.
    /// The batch refs are set by MapExpr before evaluating its body.
    abstract Promise!(T[]) eval(EvalContext ctx);

    /// Evaluate and return result length.
    override Promise!size_t evalResultLength(EvalContext ctx) {
        return eval(ctx).then((T[] results) => results.length);
    }

    // =========================================================================
    // Operator Overloading
    // =========================================================================

    /// Check if binary operator `op` is valid between types L and R
    private template isValidBinaryOp(L, string op, R) {
        enum isValidBinaryOp = is(typeof(mixin("L.init " ~ op ~ " R.init")));
    }

    /// Binary operators: expr op expr (potentially different types)
    auto opBinary(string op, R)(Expr!R rhs) if (isValidBinaryOp!(T, op, R)) {
        import dunamis.core.expr.operators : BinaryOpExpr;
        return new BinaryOpExpr!(T, op, R)(this, rhs);
    }

    /// Binary operators: expr op literal
    /// The literal is wrapped in a ConstExpr that derives its batch size from this expression.
    auto opBinary(string op, R)(R rhs) if (!is(R : Expr!U, U) && isValidBinaryOp!(T, op, R)) {
        import dunamis.core.expr.operators : BinaryOpExpr;
        import dunamis.core.expr.primitives : constant;
        return new BinaryOpExpr!(T, op, R)(this, constant(rhs, this));
    }

    /// Binary operators: literal op expr
    /// The literal is wrapped in a ConstExpr that derives its batch size from this expression.
    auto opBinaryRight(string op, L)(L lhs) if (!is(L : Expr!U, U) && isValidBinaryOp!(L, op, T)) {
        import dunamis.core.expr.operators : BinaryOpExpr;
        import dunamis.core.expr.primitives : constant;
        return new BinaryOpExpr!(L, op, T)(constant(lhs, this), this);
    }

    /// Comparison methods that return Expr!bool
    /// Note: Can't override opEquals/opCmp as they conflict with Object methods
    auto eq(R)(Expr!R rhs) if (isValidBinaryOp!(T, "==", R)) {
        import dunamis.core.expr.operators : BinaryOpExpr;
        return new BinaryOpExpr!(T, "==", R)(this, rhs);
    }
    auto ne(R)(Expr!R rhs) if (isValidBinaryOp!(T, "!=", R)) {
        import dunamis.core.expr.operators : BinaryOpExpr;
        return new BinaryOpExpr!(T, "!=", R)(this, rhs);
    }
    auto eq(R)(R rhs) if (!is(R : Expr!U, U) && isValidBinaryOp!(T, "==", R)) {
        import dunamis.core.expr.operators : BinaryOpExpr;
        import dunamis.core.expr.primitives : constant;
        return new BinaryOpExpr!(T, "==", R)(this, constant(rhs, this));
    }
    auto ne(R)(R rhs) if (!is(R : Expr!U, U) && isValidBinaryOp!(T, "!=", R)) {
        import dunamis.core.expr.operators : BinaryOpExpr;
        import dunamis.core.expr.primitives : constant;
        return new BinaryOpExpr!(T, "!=", R)(this, constant(rhs, this));
    }

    auto lt(R)(Expr!R rhs) if (isValidBinaryOp!(T, "<", R)) {
        import dunamis.core.expr.operators : BinaryOpExpr;
        return new BinaryOpExpr!(T, "<", R)(this, rhs);
    }
    auto gt(R)(Expr!R rhs) if (isValidBinaryOp!(T, ">", R)) {
        import dunamis.core.expr.operators : BinaryOpExpr;
        return new BinaryOpExpr!(T, ">", R)(this, rhs);
    }
    auto le(R)(Expr!R rhs) if (isValidBinaryOp!(T, "<=", R)) {
        import dunamis.core.expr.operators : BinaryOpExpr;
        return new BinaryOpExpr!(T, "<=", R)(this, rhs);
    }
    auto ge(R)(Expr!R rhs) if (isValidBinaryOp!(T, ">=", R)) {
        import dunamis.core.expr.operators : BinaryOpExpr;
        return new BinaryOpExpr!(T, ">=", R)(this, rhs);
    }

    auto lt(R)(R rhs) if (!is(R : Expr!U, U) && isValidBinaryOp!(T, "<", R)) {
        import dunamis.core.expr.operators : BinaryOpExpr;
        import dunamis.core.expr.primitives : constant;
        return new BinaryOpExpr!(T, "<", R)(this, constant(rhs, this));
    }
    auto gt(R)(R rhs) if (!is(R : Expr!U, U) && isValidBinaryOp!(T, ">", R)) {
        import dunamis.core.expr.operators : BinaryOpExpr;
        import dunamis.core.expr.primitives : constant;
        return new BinaryOpExpr!(T, ">", R)(this, constant(rhs, this));
    }
    auto le(R)(R rhs) if (!is(R : Expr!U, U) && isValidBinaryOp!(T, "<=", R)) {
        import dunamis.core.expr.operators : BinaryOpExpr;
        import dunamis.core.expr.primitives : constant;
        return new BinaryOpExpr!(T, "<=", R)(this, constant(rhs, this));
    }
    auto ge(R)(R rhs) if (!is(R : Expr!U, U) && isValidBinaryOp!(T, ">=", R)) {
        import dunamis.core.expr.operators : BinaryOpExpr;
        import dunamis.core.expr.primitives : constant;
        return new BinaryOpExpr!(T, ">=", R)(this, constant(rhs, this));
    }

    // =========================================================================
    // Boolean Logic Operators (only for Expr!bool)
    // =========================================================================

    static if (is(T == bool)) {
        /// Logical AND - combines two boolean expressions
        /// Note: D's && operator cannot be overloaded, so we use a method
        auto and(Expr!bool rhs) {
            import dunamis.core.expr.operators : BinaryOpExpr;
            return new BinaryOpExpr!(bool, "&&", bool)(this, rhs);
        }

        /// Logical AND with literal bool
        auto and(bool rhs) {
            import dunamis.core.expr.operators : BinaryOpExpr;
            import dunamis.core.expr.primitives : constant;
            return new BinaryOpExpr!(bool, "&&", bool)(this, constant(rhs, this));
        }

        /// Logical OR - combines two boolean expressions
        /// Note: D's || operator cannot be overloaded, so we use a method
        auto or(Expr!bool rhs) {
            import dunamis.core.expr.operators : BinaryOpExpr;
            return new BinaryOpExpr!(bool, "||", bool)(this, rhs);
        }

        /// Logical OR with literal bool
        auto or(bool rhs) {
            import dunamis.core.expr.operators : BinaryOpExpr;
            import dunamis.core.expr.primitives : constant;
            return new BinaryOpExpr!(bool, "||", bool)(this, constant(rhs, this));
        }

        /// Logical NOT - negates this boolean expression
        auto not() {
            import dunamis.core.expr.operators : UnaryOpExpr;
            return new UnaryOpExpr!(bool, "!")(this);
        }
    }

    // Null checks - only available on Expr!(Nullable!T). Templates, so that
    // they (and an IsNullExpr class) are only compiled for the nullable
    // types they are used on, not for every Expr!(Nullable!T) (e.g. those of
    // every schema type's to-one fields).
    static if (is(T == Nullable!U, U)) {
        /// Check if this nullable value is null
        auto isNull()() {
            import dunamis.core.expr.operators : IsNullExpr;
            return new IsNullExpr!U(this);
        }

        /// Check if this nullable value is not null (convenience for isNull().not())
        auto isNotNull()() {
            return isNull().not();
        }
    }

    // =========================================================================
    // String-specific Operations (only for Expr!string)
    // =========================================================================

    static if (is(T == string)) {
        /// Check if this string contains the given substring.
        /// Generates SQL LIKE '%pattern%' ESCAPE '\'.
        auto contains(string pattern) {
            import dunamis.core.expr.operators : LikeExpr, escapeLikePattern;
            return new LikeExpr(this, "%" ~ escapeLikePattern(pattern) ~ "%");
        }

        /// Check if this string contains the given substring expression.
        auto contains(Expr!string pattern) {
            import dunamis.core.expr.operators : LikePatternExpr, LikePatternType;
            return new LikePatternExpr(this, pattern, LikePatternType.contains);
        }

        /// Check if this string starts with the given prefix.
        /// Generates SQL LIKE 'pattern%' ESCAPE '\'.
        auto startsWith(string prefix) {
            import dunamis.core.expr.operators : LikeExpr, escapeLikePattern;
            return new LikeExpr(this, escapeLikePattern(prefix) ~ "%");
        }

        /// Check if this string starts with the given prefix expression.
        auto startsWith(Expr!string prefix) {
            import dunamis.core.expr.operators : LikePatternExpr, LikePatternType;
            return new LikePatternExpr(this, prefix, LikePatternType.startsWith);
        }

        /// Check if this string ends with the given suffix.
        /// Generates SQL LIKE '%pattern' ESCAPE '\'.
        auto endsWith(string suffix) {
            import dunamis.core.expr.operators : LikeExpr, escapeLikePattern;
            return new LikeExpr(this, "%" ~ escapeLikePattern(suffix));
        }

        /// Check if this string ends with the given suffix expression.
        auto endsWith(Expr!string suffix) {
            import dunamis.core.expr.operators : LikePatternExpr, LikePatternType;
            return new LikePatternExpr(this, suffix, LikePatternType.endsWith);
        }

        /// Check if this string contains the given substring (case-insensitive).
        /// Generates SQL ILIKE '%pattern%' (PostgreSQL) or LOWER() wrapper (MySQL/SQLite).
        auto containsInsensitive(string pattern) {
            import dunamis.core.expr.operators : LikeExpr, escapeLikePattern;
            return new LikeExpr(this, "%" ~ escapeLikePattern(pattern) ~ "%", true);
        }

        /// Check if this string starts with the given prefix (case-insensitive).
        /// Generates SQL ILIKE 'pattern%' (PostgreSQL) or LOWER() wrapper (MySQL/SQLite).
        auto startsWithInsensitive(string prefix) {
            import dunamis.core.expr.operators : LikeExpr, escapeLikePattern;
            return new LikeExpr(this, escapeLikePattern(prefix) ~ "%", true);
        }

        /// Check if this string ends with the given suffix (case-insensitive).
        /// Generates SQL ILIKE '%pattern' (PostgreSQL) or LOWER() wrapper (MySQL/SQLite).
        auto endsWithInsensitive(string suffix) {
            import dunamis.core.expr.operators : LikeExpr, escapeLikePattern;
            return new LikeExpr(this, "%" ~ escapeLikePattern(suffix), true);
        }

        /// Check if this string matches the SQL LIKE `pattern` (`%` matches
        /// any characters, `_` any one character, `\` escapes the next one).
        auto like(string pattern) {
            import dunamis.core.expr.operators : LikeExpr;
            return new LikeExpr(this, pattern);
        }
    }

    // =========================================================================
    // Field Access via opDispatch
    // =========================================================================

    /// Enable property-like field access when T has a callable member.
    /// Allows: `user.firstName` instead of `User.firstName(user)`
    ///
    /// Uses design-by-introspection: if T has a member `name` that can be
    /// called with `Expr!T`, forward to it. Works for any type, not just entities.
    auto opDispatch(string name)()
        if (__traits(hasMember, T, name) && __traits(compiles, __traits(getMember, T, name)(this)))
    {
        return __traits(getMember, T, name)(this);
    }

    /// Enable property-like field access with arguments.
    /// Allows: `user.greeting("Hello", "!")` instead of `User.greeting(user, "Hello", "!")`
    ///
    /// Arguments are passed as concrete values (available at planning time).
    auto opDispatch(string name, Args...)(Args args)
        if (Args.length > 0 &&
            __traits(hasMember, T, name) &&
            __traits(compiles, __traits(getMember, T, name)(this, args)))
    {
        return __traits(getMember, T, name)(this, args);
    }
}

// ============================================================================
// Forwarding Expression
// ============================================================================

/// Non-final base class for expression wrappers that forward evaluation to an
/// inner expression. Subclass this to tag or wrap expressions without changing
/// their evaluation semantics.
///
/// The wrapper is transparent to the optimizer: `dependencies()` reports the
/// inner expression, so tree-walking (data source collection, optimizer
/// collection) naturally reaches through it. `optimize()` delegates to the
/// inner expression and preserves the wrapper as root.
class ForwardingExpr(T) : Expr!T {
    protected Expr!T _inner;

    this(Expr!T inner) { _inner = inner; }

    override ExprBase[] dependencies() { return [_inner]; }

    override void replaceDependency(size_t index, ExprBase newDep) {
        assert(index == 0);
        _inner = cast(Expr!T) newDep;
    }

    override Expr!T optimize(OptimizeContext ctx) {
        _inner = _inner.optimize(ctx);
        return this;
    }

    override Promise!(T[]) eval(EvalContext ctx) {
        return _inner.eval(ctx);
    }
}

// ============================================================================
// Helper Templates
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

/// Generalize an expression type to its base Expr!T form.
/// Non-expression types are kept as-is.
template GeneralizeExpr(T) {
    static if (is(T : Expr!U, U))
        alias GeneralizeExpr = Expr!U;
    else
        alias GeneralizeExpr = T;
}

/// Generalize all types in a type list.
/// Expression types become Expr!T, others stay unchanged.
template GeneralizeExprs(Args...) {
    import std.meta : staticMap;
    alias GeneralizeExprs = staticMap!(GeneralizeExpr, Args);
}

package(dunamis.core) template toArray(T) {
    alias toArray = T[];
}

/// Optimize an expression of any result type (see `ExprBase.optimizeBase`).
ExprBase optimizeExpr(ExprBase expr, OptimizeContext ctx) {
    return expr is null ? null : expr.optimizeBase(ctx);
}
