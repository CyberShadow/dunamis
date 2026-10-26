/// Structured joining of concurrently evaluated sub-expressions.
module dunamis.core.join;

import std.meta : allSatisfy, staticMap;
import std.typecons : Tuple;

import ae.utils.promise;

/// Like ae's `all`, but settles only once *every* input has settled.
///
/// `all` rejects as soon as one input rejects, leaving the others running
/// with nobody waiting for them. In expression evaluation that breaks
/// structured concurrency: an `eval` whose promise has settled may still have
/// descendants issuing queries, so the request can finish and tear its
/// `DataSession` down (releasing its connection) under them. Every Dunamis
/// expression that evaluates inputs concurrently must join them with this
/// instead, so that when an `eval` promise settles, all work it started has
/// settled too.
///
/// If several inputs fail, the error of the first one in argument order is
/// propagated (deterministically, regardless of timing).
auto joinAll(Promises...)(Promises promises)
if (Promises.length && allSatisfy!(isPromise, Promises))
{
    alias Settled = staticMap!(SettledOf, Promises);
    Settled settled;
    static foreach (i; 0 .. Promises.length)
        settled[i] = promises[i].toResult();

    return all(settled).then((Tuple!(staticMap!(ResultOf, Promises)) results) {
        static foreach (i; 0 .. Promises.length)
            if (results[i].error !is null)
                throw results[i].error;
        // Everything has fulfilled; this resolves on the next tick.
        return all(promises);
    });
}

/// ditto
auto joinAll(P)(P[] promises)
if (isPromise!P)
{
    return allSettled(promises).then((ResultOf!P[] results) {
        foreach (result; results)
            if (result.error !is null)
                throw result.error;
        return all(promises);
    });
}

private alias ResultOf(P) = Result!(PromiseValue!P, PromiseError!P);
private alias SettledOf(P) = Promise!(ResultOf!P);

version (unittest) {
    import ae.utils.promise.await : awaitSync;
    import std.exception : collectExceptionMsg;
}

// A rejection does not settle the join while a sibling is still pending.
unittest {
    auto failing = new Promise!int;
    auto pending = new Promise!string;
    bool settled;
    auto joined = joinAll(failing, pending);
    joined.then((Tuple!(int, string) _) { settled = true; },
        (Exception e) { settled = true; });

    failing.reject(new Exception("boom"));
    awaitSync(failing.toResult());
    assert(!settled, "join settled while a sibling was still pending");

    pending.fulfill("late");
    assert(collectExceptionMsg(awaitSync(joined)) == "boom");
    assert(settled);
}

// Fulfilled values are passed through, as with `all`.
unittest {
    auto t = awaitSync(joinAll(resolve(1), resolve("a")));
    assert(t[0] == 1 && t[1] == "a");
    assert(awaitSync(joinAll([resolve(1), resolve(2)])) == [1, 2]);
    awaitSync(joinAll([resolve(), resolve()]));
}

// The first failing input in argument order wins, whatever the timing.
unittest {
    auto first = new Promise!int;
    auto second = new Promise!int;
    auto joined = joinAll(first, second);
    second.reject(new Exception("second"));
    first.reject(new Exception("first"));
    assert(collectExceptionMsg(awaitSync(joined)) == "first");

    auto a = new Promise!void, b = new Promise!void;
    auto joinedArray = joinAll([a, b]);
    b.reject(new Exception("b"));
    awaitSync(b.toResult());
    bool settled;
    joinedArray.then(() { settled = true; }, (Exception e) { settled = true; });
    awaitSync(b.toResult());
    assert(!settled);
    a.fulfill();
    assert(collectExceptionMsg(awaitSync(joinedArray)) == "b");
}
