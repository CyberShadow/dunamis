module graphqld2.core.executor;

import ae.utils.promise;
import ae.utils.promise.await : awaitSync;

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
    /// Returns a Promise that resolves to the result.
    Promise!T execute(E, T = E.ResultType)(E expr, bool optimize = true) {
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
        ctx.setCurrentRefs(null, [queryRoot]);  // null key for root level
        return toEval.eval(ctx).then((results) => results[0]);
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

/// Helper: expression that returns a fixed array of refs.
private class MockCollectionExpr : Expr!(Ref[]) {
    Ref[] _refs;
    this(Ref[] refs) { _refs = refs; }

    override ExprBase[] dependencies() { return []; }
    override void replaceDependency(size_t index, ExprBase newDep) {}

    override Promise!(Ref[][]) eval(EvalContext ctx) {
        return resolve([_refs]);
    }
}

unittest {
    // Test executor with map expression
    auto executor = new Executor();

    auto collection = new MockCollectionExpr([Ref("Test:1"), Ref("Test:2")]);
    auto query = map!(
        (Expr!Ref item) => use((Ref r) => r.nodeId, item)
    )(collection);

    auto result = awaitSync(executor.execute(query));
    assert(result == ["Test:1", "Test:2"]);
}

unittest {
    // Test executor with operators and literals
    import std.conv : to;

    auto executor = new Executor();

    auto collection = new MockCollectionExpr([Ref("Test:1"), Ref("Test:2")]);
    auto query = map!(
        (Expr!Ref item) => use((Ref r) => r.localId.to!long, item) * 10 + 1
    )(collection);

    auto result = awaitSync(executor.execute(query));
    assert(result == [11, 21]);
}
