/// Unit-test fixture for ComputedFieldsPlugin: computed fields of the root
/// types (Query and Mutation) declared as free functions, over the schema of
/// computed_fixture.d (see computed_root_tests.d).
module dunamis.schema.computed_root_fixture;

version (unittest):

import std.array : join;
import std.typecons : Nullable;

import dunamis.core.expr : Expr, constant, effect, fieldAccess, map, use;
import dunamis.graphql.schema : GqlDescription;
import dunamis.schema.computed_fixture : Query, User;

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
