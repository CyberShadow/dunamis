/// Procedures: side-effecting code (such as the implementation of a
/// mutation field) run as part of an expression's evaluation.
///
/// `perform` runs a procedure once per request, in a fiber of its own, so
/// that it can be written in direct style: it awaits the promises of the data
/// sessions (`ae.utils.promise.await.await`), and evaluates typed expressions
/// on the request's sessions with `evaluateNested`, which see its writes.
module dunamis.core.expr.effects;

import ae.utils.promise;

import dunamis.core.datasource : DataSource;
import dunamis.core.eval;
import dunamis.core.expr.base;
import dunamis.core.optimize : OptimizeContext;

/// The default size of the fiber stack of a procedure.
enum size_t defaultProcedureStackSize = 1024 * 1024;

/// Expression which runs a procedure (see `perform`).
///
/// Not templated on the procedure, so that procedures with the same result
/// type share one class. The expression itself is not modified by
/// evaluation: the procedure's result is memoized in the request's context.
final class PerformExpr(R) : Expr!R {
    private R delegate(EvalContext) _procedure;
    private ExprBase _lengthSource;
    private DataSource[] _sources;
    private size_t _stackSize;

    this(R delegate(EvalContext) procedure, ExprBase lengthSource, DataSource[] sources, size_t stackSize) {
        assert(procedure !is null, "perform: null procedure");
        _procedure = procedure;
        _lengthSource = lengthSource;
        _sources = sources;
        _stackSize = stackSize;
    }

    override ExprBase[] dependencies() {
        return _lengthSource !is null ? [_lengthSource] : [];
    }

    override void replaceDependency(size_t index, ExprBase newDep) {
        if (index == 0 && _lengthSource !is null)
            _lengthSource = newDep;
    }

    override DataSource[] dataSources() {
        return _sources;
    }

    override Expr!R optimize(OptimizeContext ctx) {
        if (_lengthSource !is null)
            _lengthSource = optimizeExpr(_lengthSource, ctx);
        return this;  // The procedure itself is opaque
    }

    override Promise!(R[]) eval(EvalContext ctx) {
        import ae.utils.promise.await : async;

        // Once per request: whichever scope evaluates it first, every
        // evaluation of this expression in the request gets the same result.
        auto request = ctx.request;
        auto result = request.getCachedEval!R(this);
        if (result is null) {
            auto procedure = _procedure;
            // (The fiber starts on the next turn of the event loop, so the
            // promise is cached before the procedure can evaluate anything.)
            auto value = async(() => procedure(request), _stackSize);
            result = value.then((R v) => [v]);
            request.setCachedEval!R(this, result);
        }
        if (_lengthSource is null)
            return result;
        auto lengthSource = _lengthSource;
        return result.then((R[] values) => lengthSource.evalResultLength(ctx).then((size_t count) {
            auto results = new R[count];
            results[] = values[0];
            return results;
        }));
    }
}

/// An expression which runs the procedure `fn(EvalContext ctx, args)`, and
/// evaluates to its result, for every item of `lengthSource`'s batch (for a
/// mutation field, its `Expr!Mutation`).
///
/// The procedure runs once per request, however many fields evaluate the
/// expression, when it is first evaluated (so, in a mutation, in the order of
/// the mutation's fields). It runs in a fiber of its own (with a stack of
/// `stackSize` bytes), so that it may `await` promises, and is passed the
/// context of the request. If it throws, the evaluation fails (for a field,
/// with a field error). `sources` are the data sources it uses: the executor
/// sets up their sessions for the request, which the procedure gets with
/// `ctx.getSession`, and on which `evaluateNested` evaluates expressions.
///
/// The arguments are captured when the expression is built; the expression
/// holds no other state.
///
/// Example:
/// ---
/// Expr!CreatePayload create(Expr!Mutation m, CreateInput input) {
///     return perform!createUser(m, [db], input);
/// }
/// CreatePayload createUser(EvalContext ctx, CreateInput input) @async {
///     auto session = cast(PostgresSession) ctx.getSession(db);
///     auto id = session.queryLongs("INSERT ... RETURNING id").await[0];
///     return CreatePayload(User(cast(int) id));
/// }
/// ---
auto perform(alias fn, Args...)(ExprBase lengthSource, DataSource[] sources, Args args) {
    return performSized!(fn, Args)(defaultProcedureStackSize, lengthSource, sources, args);
}

/// ditto
auto performSized(alias fn, Args...)(size_t stackSize, ExprBase lengthSource, DataSource[] sources, Args args) {
    alias R = typeof(fn(EvalContext.init, args));
    return cast(Expr!R) new PerformExpr!R((EvalContext ctx) => fn(ctx, args), lengthSource, sources, stackSize);
}

/// Evaluate the expression `expr` within the evaluation in `ctx` (for
/// example from a procedure, see `perform`): optimized as its own tree, and
/// evaluated once, as a root expression, in a scope of `ctx`, on the sessions
/// of the request, so that it sees the request's writes so far.
///
/// The sessions of its data sources must have been set up for the request
/// (for a procedure, by naming them in perform's `sources`). In a scope with
/// sessions of its own (see `EvalContext.createScope`), it is evaluated on
/// these: e.g. as of other database settings.
Promise!T evaluateNested(T)(Expr!T expr, EvalContext ctx) {
    import dunamis.core.executor : Executor;
    import dunamis.core.types : AnyRef, queryRoot;

    auto optimized = new Executor().optimize(expr);
    foreach (ds; Executor.dataSourcesOf(optimized))
        if (!ctx.hasSession(ds))
            throw new Exception("evaluateNested: an expression's data source has no session in the request " ~
                "(name it in the sources of the procedure)");
    auto scope_ = ctx.createScope();
    scope_.setValues!AnyRef(null, [queryRoot]);
    return optimized.eval(scope_).then((T[] values) {
        if (values.length != 1)
            throw new Exception("evaluateNested: a root expression evaluated to a batch");
        return values[0];
    });
}
