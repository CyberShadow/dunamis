module graphqld2.core.expr;

import std.meta;
import std.traits;
import std.typecons : Tuple;

import graphqld2.core.plan;
import graphqld2.core.eval;

// ============================================================================
// Core Expression Type
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
// Tests
// ============================================================================

unittest {
    // Test that UseExpr compiles and works with mock expressions
    static class MockExpr(T) : Expr!T {
        T _value;
        this(T v) { _value = v; }

        override void plan(PlanContext ctx) {}
        override T[] eval(EvalContext ctx) {
            T[] result;
            foreach (_; ctx.currentIds) {
                result ~= _value;
            }
            return result;
        }
    }

    auto expr1 = new MockExpr!string("Hello");
    auto expr2 = new MockExpr!string("World");

    auto combined = use(
        (string a, string b) => a ~ " " ~ b,
        expr1,
        expr2
    );

    auto ctx = new PlanContext();
    combined.plan(ctx);

    auto evalCtx = new EvalContext();
    evalCtx.currentIds = [1, 2, 3];

    auto result = combined.eval(evalCtx);
    assert(result == ["Hello World", "Hello World", "Hello World"]);
}
