/// Regression tests for the immutability of optimized expression trees.
///
/// A compiled and optimized tree must not be modified by its evaluation: all
/// per-evaluation state lives in the EvalContext and the data sessions. Then
/// one optimized tree can be evaluated for several requests, also
/// concurrently, which these tests do with interleaved evaluations (see
/// `InterleaveBarrier`), also while other queries are being optimized.
module dunamis.reuse_tests;

version (unittest):

import std.conv : to;
import std.json : JSONValue, parseJSON;
import std.typecons : Nullable;

import ae.net.asockets : socketManager;
import ae.utils.promise : Promise;

import dunamis.core : EvalContext, Executor;
import dunamis.core.executor : SubscriptionExecutor;
import dunamis.core.expr : Expr, ExprBase, context, evalAs, map, use;
import dunamis.core.expr.combinators : eventSource;
import dunamis.core.optimize : OptimizeContext;
import dunamis.graphql.compiler : compileQuery;
import dunamis.graphql.schema : Schema;
import dunamis.relational.demo : DemoEntity, DemoId, Int64, MockDB;
import dunamis.relational.mock : DebugSqlDB;
import dunamis.relational.mutation : insert;
import dunamis.relational.schema : BelongsTo, Col, ForeignKey, Table, getAll;
import dunamis.relational.sql_dialect : SqlDialect;

// ============================================================================
// Interleaving
// ============================================================================

/// Lets several evaluations ("participants") of the same tree interleave
/// deterministically: a gated expression of a participant waits until every
/// participant that has not finished is waiting at a gate, and is then
/// released together with all of them. So each participant evaluates past a
/// gate only once all of them have evaluated everything before their gates —
/// e.g. bound the objects whose fields the gates guard.
final class InterleaveBarrier {
    private Promise!void[][] _waiting;
    private bool[] _finished;

    this(size_t participants) {
        _waiting.length = participants;
        _finished.length = participants;
    }

    /// A gate for `participant`.
    Promise!void wait(size_t participant) {
        auto gate = new Promise!void;
        _waiting[participant] ~= gate;
        check();
        return gate;
    }

    /// Record that `participant` finished its evaluation.
    void finish(size_t participant) {
        _finished[participant] = true;
        check();
    }

    private void check() {
        foreach (i, waiting; _waiting)
            if (!_finished[i] && waiting.length == 0)
                return;
        foreach (ref waiting; _waiting) {
            auto gates = waiting;
            waiting = null;
            foreach (gate; gates)
                gate.fulfill();
        }
    }
}

/// Request context identifying a participant of an InterleaveBarrier.
struct InterleaveGate {
    InterleaveBarrier barrier;
    size_t participant;
}

/// Evaluates its input once the participant's gate opens (immediately when
/// not evaluated as a participant).
final class GatedExpr(T) : Expr!T {
    private ExprBase _input;

    this(Expr!T input) { _input = input; }

    override ExprBase[] dependencies() { return [_input]; }
    override void replaceDependency(size_t index, ExprBase dep) { _input = dep; }
    override Expr!T optimize(OptimizeContext ctx) {
        _input = (cast(Expr!T) _input).optimize(ctx);
        return this;
    }

    override Promise!(T[]) eval(EvalContext ctx) {
        auto input = _input;
        if (!ctx.hasRequestContext!InterleaveGate)
            return evalAs!T(input, ctx);
        auto gate = ctx.getRequestContext!InterleaveGate;
        return gate.barrier.wait(gate.participant).then(() => evalAs!T(input, ctx));
    }
}

Expr!T gated(T)(Expr!T input) { return new GatedExpr!T(input); }

/// Evaluate `count` participants interleaved: `start(i, ctx)` starts the
/// evaluation of participant `i` in `ctx`. Returns the results in order.
JSONValue[] interleave(size_t count, Promise!JSONValue delegate(size_t, EvalContext) start) {
    auto barrier = new InterleaveBarrier(count);
    auto results = new JSONValue[count];
    auto contexts = new EvalContext[count];
    auto failures = new string[count];
    void startParticipant(size_t i) {
        auto ctx = contexts[i] = new EvalContext();
        ctx.setRequestContext(InterleaveGate(barrier, i));
        start(i, ctx).then((JSONValue result) {
            results[i] = result;
            barrier.finish(i);
        }).except((Exception e) {
            failures[i] = e.msg;
            barrier.finish(i);
        });
    }
    foreach (i; 0 .. count)
        startParticipant(i);
    socketManager.loop();
    foreach (i; 0 .. count) {
        assert(barrier._finished[i], "Evaluation " ~ i.to!string ~ " did not finish");
        assert(failures[i] is null, "Evaluation " ~ i.to!string ~ " failed: " ~ failures[i]);
        foreach (error; contexts[i].errors)
            assert(false, "Evaluation " ~ i.to!string ~ " reported an error: " ~ error.toJson().toString());
    }
    return results;
}

// ============================================================================
// Schema
// ============================================================================

/// Data of the tests, and their data source: SQL push-down over it, with
/// pushed-down expressions evaluated in memory.
MockDB!() reuseStore;
DebugSqlDB!() reuseDb;

/// Request context: what a request is about.
struct Viewing {
    long ownerId;
    long itemId;
}

struct Label {
    string text;
}

@DemoEntity!(reuseDb, "owners")
struct Owner {
    mixin DemoId;
    mixin Col!("name", string);

    /// Pushed down to SQL (a computed column)
    static auto shout(Expr!Owner o) { return o.name ~ "!"; }
    static auto whisper(Expr!Owner o) { return "(" ~ o.name ~ ")"; }

    static auto gatedId(Expr!Owner o) { return gated(use((Owner x) => x.id.value, o)); }
    static auto gatedName(Expr!Owner o) { return gated(o.name); }

    /// A nullable list of objects: null for owners named "Cid"
    static auto gatedLabels(Expr!Owner o) {
        return gated(use((string name) => name == "Cid" ? Nullable!(Label[]).init :
            Nullable!(Label[])([Label(name ~ "-1"), Label(name ~ "-2")]), o.name));
    }

    /// Everyone's shout (a root collection with a computed column),
    /// for a single owner.
    static auto everyonesShout(Expr!Owner o) {
        return use((string[] shouts, string _) => shouts,
            map!((Expr!Owner x) => x.shout)(getAll!Owner()), o.name);
    }
}

@DemoEntity!(reuseDb, "items")
struct Item {
    mixin DemoId;
    mixin Col!("title", string);
    mixin Col!("ownerId", Nullable!(ForeignKey!Owner));
    mixin BelongsTo!("owner", "ownerId");

    static auto gatedTitle(Expr!Item i) { return gated(i.title); }
    /// A nullable object
    static auto gatedOwner(Expr!Item i) { return gated(i.owner); }
}

struct Query {
    mixin Table!(Owner, "owners");
    mixin Table!(Item, "items");

    /// A non-null object, chosen by the request
    static auto viewer(Expr!Query q) {
        return use((Viewing v) => Owner(Int64(v.ownerId)), context!Viewing(q));
    }

    static auto viewerItem(Expr!Query q) {
        return use((Viewing v) => Item(Int64(v.itemId)), context!Viewing(q));
    }
}

struct Mutation {
    static auto createOwner(Expr!Mutation m, string name) {
        return insert!Owner(["name": JSONValue(name)]);
    }
}

struct Subscription {
    static Expr!Owner ownerEvents(Expr!Subscription s) {
        return eventSource!Owner();
    }
}

alias ReuseSchema = Schema!(Query, Mutation, Subscription);

private SqlDialect reuseDialect() {
    import dunamis.postgres.dialect : postgresDialect;
    return postgresDialect();
}

private void seed() {
    reuseStore = new MockDB!();
    reuseStore.setTableData("owners", `[
        {"id": 1, "name": "Ann"},
        {"id": 2, "name": "Ben"},
        {"id": 3, "name": "Cid"}
    ]`);
    reuseStore.setTableData("items", `[
        {"id": 10, "title": "apple", "owner_id": 1},
        {"id": 11, "title": "bike", "owner_id": 2},
        {"id": 12, "title": "cart", "owner_id": null}
    ]`);
    reuseDb = new DebugSqlDB!()(reuseStore, reuseDialect());
}

private enum everyonesShouts = `["Ann!", "Ben!", "Cid!"]`;

// ============================================================================
// Tests
// ============================================================================

// Queries: non-null and nullable objects, nullable lists, SQL computed
// columns; another query is optimized before the evaluations.
unittest {
    seed();
    auto executor = new Executor();
    auto tree = executor.optimize(compileQuery!ReuseSchema(`{
        viewer { gatedId gatedName gatedLabels { text } }
        viewerItem { gatedTitle gatedOwner { gatedName } }
        owners { shout }
    }`));
    executor.optimize(compileQuery!ReuseSchema(`{ owners { whisper } }`));

    auto viewings = [Viewing(1, 10), Viewing(2, 11), Viewing(3, 12)];
    foreach (round; 0 .. 2) {
        auto results = interleave(viewings.length, (size_t i, EvalContext ctx) {
            ctx.setRequestContext(viewings[i]);
            return executor.execute(tree, ctx, false);
        });
        assert(results[0] == parseJSON(`{
            "viewer": {"gatedId": 1, "gatedName": "Ann",
                "gatedLabels": [{"text": "Ann-1"}, {"text": "Ann-2"}]},
            "viewerItem": {"gatedTitle": "apple", "gatedOwner": {"gatedName": "Ann"}},
            "owners": [{"shout": "Ann!"}, {"shout": "Ben!"}, {"shout": "Cid!"}]
        }`), results[0].toString());
        assert(results[1] == parseJSON(`{
            "viewer": {"gatedId": 2, "gatedName": "Ben",
                "gatedLabels": [{"text": "Ben-1"}, {"text": "Ben-2"}]},
            "viewerItem": {"gatedTitle": "bike", "gatedOwner": {"gatedName": "Ben"}},
            "owners": [{"shout": "Ann!"}, {"shout": "Ben!"}, {"shout": "Cid!"}]
        }`), results[1].toString());
        assert(results[2] == parseJSON(`{
            "viewer": {"gatedId": 3, "gatedName": "Cid", "gatedLabels": null},
            "viewerItem": {"gatedTitle": "cart", "gatedOwner": null},
            "owners": [{"shout": "Ann!"}, {"shout": "Ben!"}, {"shout": "Cid!"}]
        }`), results[2].toString());
    }
}

// Mutations: each evaluation returns the entity it created.
unittest {
    seed();
    auto executor = new Executor();
    auto tree = executor.optimize(compileQuery!ReuseSchema(
        `mutation { createOwner(name: "Dee") { gatedId gatedName } }`));

    auto results = interleave(2, (size_t i, EvalContext ctx) => executor.execute(tree, ctx, false));
    auto first = results[0]["createOwner"], second = results[1]["createOwner"];
    assert(first["gatedName"].str == "Dee" && second["gatedName"].str == "Dee");
    assert(first["gatedId"] != second["gatedId"],
        "Both evaluations returned the same entity: " ~ first.toString());
}

// Subscriptions: one SubscriptionExecutor, redelivering interleaved events,
// including SQL computed columns, after another query has been optimized.
unittest {
    seed();
    auto executor = new Executor();
    auto subscription = new SubscriptionExecutor!Owner(executor, compileQuery!ReuseSchema(
        `subscription { ownerEvents { gatedId gatedName everyonesShout } }`));
    executor.optimize(compileQuery!ReuseSchema(`{ owners { whisper } }`));

    foreach (round; 0 .. 2) {
        auto results = interleave(2, (size_t i, EvalContext ctx) =>
            subscription.execute(Owner(Int64(i + 1)), ctx));
        assert(results[0] == parseJSON(`{"ownerEvents": {"gatedId": 1, "gatedName": "Ann",
            "everyonesShout": ` ~ everyonesShouts ~ `}}`), results[0].toString());
        assert(results[1] == parseJSON(`{"ownerEvents": {"gatedId": 2, "gatedName": "Ben",
            "everyonesShout": ` ~ everyonesShouts ~ `}}`), results[1].toString());
    }
}
