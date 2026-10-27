/// Waiting for promises within fibers.
module dunamis.core.awaiting;

import ae.utils.promise : Promise, Result, toResult;

/// Synchronously waits until the promise `p` is settled, then returns its
/// value or throws its error. Can only be called in a fiber.
///
/// Behaves as ae's `await`, but keeps the result in a plain variable rather
/// than in a `Nullable`: Phobos compiles the (non-template) `toString` of
/// every `Nullable!T`, which formats every field of `T`, so that awaiting the
/// values of each schema type would compile the formatting of each.
T await(T, E)(Promise!(T, E) p) {
    import core.thread : Fiber;

    Result!(T, E) result;
    bool settled;

    auto f = Fiber.getThis();
    assert(f, "await called while not in a fiber");
    p.toResult.dmd21804workaround.then((r) { result = r; settled = true; f.call(); });
    Fiber.yield();
    assert(settled, "await resumed before its promise settled");
    return result.unwrap();
}

unittest {
    import ae.net.asockets : socketManager;
    import ae.utils.promise : resolve, reject;
    import ae.utils.promise.await : async;
    import std.exception : collectExceptionMsg;

    auto one = resolve(1);
    auto two = resolve(2);

    int sum;
    async(one.await + two.await).then((int value) { sum = value; });
    socketManager.loop();
    assert(sum == 3);

    string msg;
    async({
        msg = collectExceptionMsg(reject!int(new Exception("boom")).await);
    }).then({});
    socketManager.loop();
    assert(msg == "boom");
}
