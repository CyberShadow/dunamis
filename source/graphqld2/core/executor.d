module graphqld2.core.executor;

import graphqld2.core.eval;
import graphqld2.core.expr;
import graphqld2.core.optimize;
import graphqld2.core.types;

/// Executes expressions.
///
/// The executor:
/// 1. Optimizes the expression tree (unless disabled)
/// 2. Walks tree to collect data source-specific optimizers
/// 3. Runs collected optimizers
/// 4. Evaluates the expression
class Executor {
    /// Execute an expression, optionally with optimization.
    T execute(E, T = E.ResultType)(E expr, bool optimize = true) {
        E toEval = expr;

        if (optimize) {
            auto optCtx = new OptimizeContext();
            toEval = cast(E) expr.optimize(optCtx);

            // Walk tree to collect and run optimizers
            foreach (optimizer; collectOptimizers(toEval)) {
                optimizer.optimize(toEval, optCtx);
            }
        }

        auto ctx = new EvalContext();
        ctx.currentRefs = [queryRoot];
        return toEval.eval(ctx)[0];
    }

    /// Walk expression tree and collect optimizers, deduplicated by instance.
    private ExprOptimizer[] collectOptimizers(ExprBase root) {
        ExprOptimizer[] result;
        bool[ExprOptimizer] seen;

        void walk(ExprBase expr) {
            if (expr is null) return;

            // Collect optimizers from this expression
            foreach (opt; expr.requestedOptimizers()) {
                if (opt !in seen) {
                    seen[opt] = true;
                    result ~= opt;
                }
            }

            // Recurse into dependencies
            foreach (dep; expr.dependencies()) {
                walk(dep);
            }
        }

        walk(root);
        return result;
    }
}

// ============================================================================
// Tests
// ============================================================================

unittest {
    // Test basic execution with constant expressions
    auto executor = new Executor();

    auto expr = constant(42);
    // Note: constant expressions need a length source or will use ctx.currentRefs
    // For this test, queryRoot provides 1 ref, so we get 1 result
    auto result = executor.execute(expr);
    assert(result == 42);
}

unittest {
    // Test execution with map expression
    class ConstRefArrayExpr : Expr!(Ref[]) {
        Ref[] _refs;
        this(Ref[] refs) { _refs = refs; }

        override ExprBase[] dependencies() { return []; }
        override void replaceDependency(size_t index, ExprBase newDep) {}

        override Ref[][] eval(EvalContext ctx) {
            return [_refs];
        }
    }

    auto executor = new Executor();

    auto collection = new ConstRefArrayExpr([Ref("Test:1"), Ref("Test:2")]);
    auto mapExpr = map!(
        (Expr!Ref item) => use(
            (Ref r) => r.nodeId,
            item
        )
    )(collection);

    auto result = executor.execute(mapExpr);
    assert(result == ["Test:1", "Test:2"]);
}
