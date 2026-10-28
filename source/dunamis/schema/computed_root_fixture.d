/// Unit-test fixture for ComputedFieldsPlugin: computed fields of the root
/// types (Query and Mutation) declared as free functions, over the schema of
/// computed_fixture.d (see computed_root_tests.d).
module dunamis.schema.computed_root_fixture;

version (unittest):

import std.array : join;
import std.typecons : Nullable;

import dunamis.core.expr : Expr, constant, effect, fieldAccess, map, use;
import dunamis.graphql.schema : GqlDefault, GqlDescription;
import dunamis.schema.computed_fixture : Query, User, fixtureDb;

/// The mutation root type: all its fields are computed fields declared here.
struct Mutation {}

/// The entries recorded by the mutation fields, in order.
__gshared string[] mutationLog;

/// Only returned by a mutation field: refers to an entity.
struct RecordPayload {
    string entry;
    User user;
    int logLength;
}

// ---- Query fields ----

@GqlDescription("Number of users")
Expr!int userCount(Expr!Query q) {
    return use(&countNames, map!userName(Query.users(q)));
}

/// The user with the given name, if any.
Expr!(Nullable!User) userNamed(Expr!Query q, string name) {
    return use(&findUser, map!userId(Query.users(q)), map!userName(Query.users(q)), constant(name, q));
}

/// The first user (by id).
Expr!User firstUser(Expr!Query q) {
    return use(&firstOf, map!userId(Query.users(q)));
}

/// The users whose name is not the given one (built in memory): a list of the schema's entity
/// type, which the plugins after ComputedFieldsPlugin extend like any other.
Expr!(User[]) usersExcept(Expr!Query q, string name) {
    return use(&usersOtherThan, map!userId(Query.users(q)), map!userName(Query.users(q)), constant(name, q));
}

/// A root field over other computed root fields.
Expr!string census(Expr!Query q) {
    return use((int count, User first) => count.stringOf ~ " users from #" ~ first.id.stringOf,
        userCount(q), firstUser(q));
}

private Expr!string userName(Expr!User u) {
    return u.name;
}

private Expr!int userId(Expr!User u) {
    return fieldAccess!"id"(u);
}

private int countNames(string[] names) {
    return cast(int) names.length;
}

private Nullable!User findUser(int[] ids, string[] names, string name) {
    foreach (i, n; names)
        if (n == name)
            return Nullable!User(User(ids[i]));
    return Nullable!User.init;
}

private User[] usersOtherThan(int[] ids, string[] names, string name) {
    User[] result;
    foreach (i, n; names)
        if (n != name)
            result ~= User(ids[i]);
    return result;
}

private User firstOf(int[] ids) {
    int first = ids[0];
    foreach (id; ids)
        if (id < first)
            first = id;
    return User(first);
}

private string stringOf(int n) {
    import std.conv : to;
    return n.to!string;
}

// ---- Mutation fields ----

/// Records an entry.
Expr!string record(Expr!Mutation m, string entry) {
    return effect(() { mutationLog ~= entry; return entry; }, m);
}

/// The entries recorded so far.
Expr!string recorded(Expr!Mutation m) {
    return effect(() => mutationLog.join(","), m);
}

/// Records a non-empty entry; fails for an empty one (a nullable field).
Expr!(Nullable!string) tryRecord(Expr!Mutation m, string entry) {
    return effect(() {
        if (entry.length == 0) throw new Exception("empty entry");
        mutationLog ~= entry;
        return Nullable!string(entry);
    }, m);
}

/// Records a non-empty entry; fails for an empty one (a non-null field).
Expr!string mustRecord(Expr!Mutation m, string entry) {
    return effect(() {
        if (entry.length == 0) throw new Exception("empty entry");
        mutationLog ~= entry;
        return entry;
    }, m);
}

/// Records an entry for a user, returning a payload with the user.
Expr!RecordPayload recordFor(Expr!Mutation m, int userId) {
    return effect(() {
        auto entry = "user" ~ userId.stringOf;
        mutationLog ~= entry;
        return RecordPayload(entry, User(userId), cast(int) mutationLog.length);
    }, m);
}

/// The user with the given id, if positive (a nullable entity).
Expr!(Nullable!User) maybeUser(Expr!Mutation m, int userId) {
    return effect(() => userId > 0 ? Nullable!User(User(userId)) : Nullable!User.init, m);
}

/// The query root, to read the state after the mutation.
Expr!Query query(Expr!Mutation m) {
    return effect(() => Query.init, m);
}

// ---- Procedures (perform) ----

import ae.utils.promise : Promise, resolve;
import ae.utils.promise.await : async, await;
import dunamis.core.datasource : DataSession, DataSource;
import dunamis.core.eval : EvalContext;
import dunamis.core.expr : evaluateNested, perform, singleton;

/// The number of times the procedures below ran.
__gshared int procedureRuns;

/// Adds a user (as a procedure) and returns the number of users then.
Expr!int addUser(Expr!Mutation m, int id, string name) {
    return perform!addUserProcedure(m, [cast(DataSource) fixtureDb], id, name);
}

/// The sum of two reads of one addUser procedure.
Expr!int addUserReadTwice(Expr!Mutation m, int id, string name) {
    auto added = addUser(m, id, name);
    return use((int a, int b) => a + b, added, added);
}

private int addUserProcedure(EvalContext ctx, int id, string name) @async {
    import std.json : JSONValue;
    import dunamis.relational.eval_context : RelationalSession;
    import dunamis.relational.mutation : InsertInput;

    procedureRuns++;
    auto session = cast(RelationalSession) ctx.getSession(fixtureDb);
    session.executeInsert("users", "User", InsertInput(["id": JSONValue(id), "name": JSONValue(name)]),
        ["id"], false).await;
    // A nested evaluation, which sees the new user
    return evaluateNested(userCount(Query().singleton()), ctx).await;
}

/// A procedure which fails (after awaiting).
Expr!(Nullable!int) failingProcedure(Expr!Mutation m) {
    return perform!failAfterAwaiting(m, [cast(DataSource) fixtureDb]);
}

private Nullable!int failAfterAwaiting(EvalContext ctx) @async {
    resolve().await;
    if (ctx !is null)
        throw new Exception("procedure failed");
    return Nullable!int(1);
}

/// The names of the users and the titles of the posts, in two nested
/// evaluations of different trees.
Expr!string namesAndTitles(Expr!Query q) {
    return perform!((EvalContext ctx) {
        import dunamis.schema.computed_fixture : Post;
        auto names = evaluateNested(map!userName(Query.users(Query().singleton())), ctx).await;
        auto titles = evaluateNested(map!((Expr!Post p) => p.title)(Query.posts(Query().singleton())), ctx).await;
        return names.join(",") ~ "|" ~ titles.join(",");
    })(q, [cast(DataSource) fixtureDb]);
}

/// A data source logging the atomic sections of its sessions.
final class AtomicLogDB : DataSource {
    string[] log;
    override DataSession createSession() { return new AtomicLogSession(this); }
}

/// ditto
final class AtomicLogSession : DataSession {
    private AtomicLogDB _db;
    private ulong _next;
    this(AtomicLogDB db) { _db = db; }
    override Promise!ulong beginAtomic() {
        import std.conv : to;
        _db.log ~= "begin " ~ (_next + 1).to!string;
        return resolve(++_next);
    }
    override Promise!void endAtomic(ulong token, bool success) {
        import std.conv : to;
        _db.log ~= (success ? "keep " : "undo ") ~ token.to!string;
        return resolve();
    }
}

/// ditto
__gshared AtomicLogDB atomicLog;

/// Records a non-empty entry on atomicLog's session; fails for an empty one.
Expr!(Nullable!string) atomicStep(Expr!Mutation m, string entry) {
    return perform!((EvalContext ctx, string entry) {
        if (entry.length == 0) throw new Exception("empty step");
        return Nullable!string(entry);
    })(m, [cast(DataSource) atomicLog], entry);
}

/// Like atomicStep, returning an object whose non-null field fails for an
/// empty entry: the step is then null, with an error, too.
Expr!(Nullable!StepPayload) atomicStepPayload(Expr!Mutation m, string entry) {
    return perform!((EvalContext ctx, string entry) => Nullable!StepPayload(StepPayload(entry)))(
        m, [cast(DataSource) atomicLog], entry);
}

/// ditto
struct StepPayload {
    string entry;
    static Expr!string checked(Expr!StepPayload p) {
        return use((StepPayload v) {
            if (v.entry.length == 0) throw new Exception("empty payload");
            return v.entry;
        }, p);
    }
}

// ---- Input objects ----

/// Options of describeOptions.
struct Options {
    /// Three states: absent, null, or a value
    Nullable!(Nullable!string) note;
    /// A list of nullable items
    Nullable!int[] numbers;
    /// Omitted, the empty list
    @GqlDefault("[]") string[] tags;
}

/// Describes its options.
Expr!string describeOptions(Expr!Mutation m, Options options) {
    import std.conv : to;
    auto note = options.note.isNull ? "absent" : options.note.get.isNull ? "null" : options.note.get.get;
    string numbers;
    foreach (n; options.numbers)
        numbers ~= (numbers.length ? "," : "") ~ (n.isNull ? "null" : n.get.to!string);
    return effect(() => note ~ " [" ~ numbers ~ "] [" ~ options.tags.join(",") ~ "]", m);
}

/// A UDA on input fields (not a GraphQL one).
struct Tagged { string tag; }

/// Changes of describeChanges: nested input objects, three-state.
struct ItemPatch {
    @Tagged("n") Nullable!(Nullable!string) name;
    @Tagged("c") Nullable!(Nullable!int) count;
}
/// ditto
struct ItemChange {
    Nullable!int id;
    Nullable!(Nullable!ItemPatch) patch;
}
/// ditto
struct Changes {
    ItemChange[] changes;
    Nullable!string note;
}

/// Describes its changes (as a procedure).
Expr!string describeChangesLater(Expr!Mutation m, Changes input) {
    return perform!((EvalContext ctx, Changes input) => changesText(input))(m, [cast(DataSource) fixtureDb], input);
}

/// Describes its changes.
Expr!string describeChanges(Expr!Mutation m, Changes input) {
    auto result = changesText(input);
    return effect(() => result, m);
}

private string changesText(ref const Changes input) {
    import std.conv : to;
    string result;
    foreach (change; input.changes) {
        result ~= (change.id.isNull ? "new" : change.id.get.to!string) ~ ":";
        if (change.patch.isNull) result ~= "absent";
        else if (change.patch.get.isNull) result ~= "null";
        else {
            auto p = change.patch.get.get;
            result ~= (p.name.isNull ? "-" : p.name.get.isNull ? "null" : p.name.get.get) ~ "/" ~
                (p.count.isNull ? "-" : p.count.get.isNull ? "null" : p.count.get.get.to!string);
        }
        result ~= ";";
    }
    return result;
}

// ---- Asynchronous batch functions (useAsync) ----

import dunamis.core.expr : useAsync;
import dunamis.core.types : GqlResult;

/// The batches of user IDs which badgesOf ran with.
__gshared int[][] badgeBatches;

/// A badge for each user, computed once per batch (see badgesOf).
Expr!string badge(Expr!User u) {
    return useAsync!badgesOf([cast(DataSource) fixtureDb], fieldAccess!"id"(u));
}

private string[] badgesOf(EvalContext ctx, int[] ids) @async {
    badgeBatches ~= ids.dup;
    resolve().await;
    // A nested evaluation, on the request's session
    auto count = evaluateNested(userCount(Query().singleton()), ctx).await;
    string[] badges;
    foreach (id; ids)
        badges ~= "#" ~ id.stringOf ~ "/" ~ count.stringOf;
    return badges;
}

/// A check of each user, which fails for the user 2 only.
Expr!(GqlResult!string) check(Expr!User u) {
    return useAsync!checksOf([cast(DataSource) fixtureDb], fieldAccess!"id"(u));
}

private GqlResult!string[] checksOf(EvalContext ctx, int[] ids) @async {
    resolve().await;
    GqlResult!string[] results;
    foreach (id; ids)
        results ~= id == 2 ? GqlResult!string.err("user 2 failed the check") : GqlResult!string.ok("ok");
    return results;
}

/// A badge whose function fails (for the whole batch).
Expr!(Nullable!string) failingBadge(Expr!User u) {
    return useAsync!failingBadgesOf([cast(DataSource) fixtureDb], fieldAccess!"id"(u));
}

private Nullable!string[] failingBadgesOf(EvalContext ctx, int[] ids) @async {
    resolve().await;
    if (ctx !is null)
        throw new Exception("badges failed");
    return null;
}
