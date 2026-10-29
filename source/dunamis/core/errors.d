/// `Error`s thrown during evaluation.
///
/// An `Error` (a failed assertion, a range violation, ...: a bug) thrown
/// by the code of an expression is not an `Exception`, which the promises
/// of evaluation pass on: by itself, it would leave the evaluation pending
/// forever, and stop the event loop of its thread. Instead, it is logged,
/// and fails the evaluation, as an `EvaluationError` (see
/// `ae.utils.promise.errorRejection`, which this module sets for the
/// process).
module dunamis.core.errors;

/// The failure of an evaluation by an `Error` (a bug) thrown during it.
class EvaluationError : Exception {
    /// The `Error`.
    Error error;

    this(Error error) nothrow {
        this.error = error;
        super("Internal error: " ~ typeid(error).name ~ ": " ~ error.msg, error.file, error.line);
    }
}

/// Log the `Error` `error`, thrown during an evaluation, and return the
/// failure of the evaluation by it.
EvaluationError evaluationFailure(Error error) nothrow {
    import std.stdio : stderr;
    try
        stderr.writefln("Error during evaluation (failing it): %s", error);
    catch (Exception) {}
    return new EvaluationError(error);
}

shared static this() {
    import ae.utils.promise : errorRejection;
    if (errorRejection is null)
        errorRejection = function Exception(Error error) nothrow => evaluationFailure(error);
}

// An Error thrown by an expression's evaluation fails the execution
// (rather than leaving it pending, and escaping the event loop)
unittest {
    import core.exception : RangeError;
    import std.algorithm.searching : canFind;
    import std.exception : collectException;
    import ae.utils.promise : Promise, resolve;
    import ae.utils.promise.await : awaitSync;
    import dunamis.core.eval : EvalContext;
    import dunamis.core.executor : Executor;
    import dunamis.core.expr : Expr, ExprBase;

    static class Buggy : Expr!int {
        override ExprBase[] dependencies() { return []; }
        override void replaceDependency(size_t, ExprBase) {}
        override Promise!(int[]) eval(EvalContext) {
            return resolve(cast(int[]) []).then((int[] none) {
                return [none[0]];  // (out of bounds)
            });
        }
    }

    auto failure = collectException(awaitSync(new Executor().execute(new Buggy())));
    assert(failure !is null, "the execution succeeded");
    auto error = cast(EvaluationError) failure;
    assert(error !is null, failure.toString());
    assert(cast(RangeError) error.error !is null, error.error.toString());
    assert(error.msg.canFind("Internal error") && error.msg.canFind("out of bounds"), error.msg);
}
