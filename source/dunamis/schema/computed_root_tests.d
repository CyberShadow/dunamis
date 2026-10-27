/// Unit tests for computed fields of the root types (Query and Mutation)
/// declared as free functions, over the fields in computed_root_fixture.d:
/// the root types are object types like any other, so ComputedFieldsPlugin
/// attaches functions written against them as it does for entities.
module dunamis.schema.computed_root_tests;

version (unittest):

import std.algorithm : canFind;
import std.json : JSONValue, parseJSON;

import ae.utils.promise.await : awaitSync;

import dunamis.core : EvalContext, Executor;
import dunamis.graphql.compiler : compileQuery;
import dunamis.graphql.schema : Schema, generateSchemaSDL;
import dunamis.relational.demo : MockDB;
import dunamis.schema.computed : ComputedFieldsPlugin;
import dunamis.schema.filtering : FilterPlugin;
import dunamis.schema.pagination : PaginationPlugin;
import dunamis.schema.plugin : ApplyPlugins;
import dunamis.schema.sorting : SortingPlugin;
static import dunamis.schema.computed_fixture;
static import dunamis.schema.computed_root_fixture;
import dunamis.schema.computed_fixture : fixtureDb, Greeting, Query;
import dunamis.schema.computed_root_fixture : Mutation, mutationLog;
alias fixture = dunamis.schema.computed_fixture;
alias rootFixture = dunamis.schema.computed_root_fixture;

/// The documented placement, with the root fields' module as a source too.
alias RootSchema = ApplyPlugins!(Schema!(Query, Mutation),
    ComputedFieldsPlugin!(fixture, rootFixture), FilterPlugin, SortingPlugin, PaginationPlugin);

private void seed() {
    fixtureDb = new MockDB!();
    fixtureDb.setTableData("users", `[
        {"id": 1, "name": "Alice"},
        {"id": 2, "name": "Bob"},
        {"id": 3, "name": "Carol"}
    ]`);
    fixtureDb.setTableData("posts", `[
        {"id": 10, "title": "Hello", "author_id": 1},
        {"id": 11, "title": "hidden", "author_id": 1},
        {"id": 12, "title": "Other", "author_id": 2}
    ]`);
    fixtureDb.setTableData("comments", `[]`);
    fixtureDb.setTableData("likes", `[]`);
    mutationLog = null;
}

private JSONValue run(string query, EvalContext ctx = null) {
    if (ctx is null)
        ctx = new EvalContext();
    ctx.setRequestContext(Greeting("Hi"));
    auto result = awaitSync(new Executor().execute(compileQuery!RootSchema(query), ctx));
    return result;
}

// SDL: root fields appear on Query and Mutation, with their arguments and
// descriptions; the types only mutation fields return are discovered
unittest {
    enum sdl = generateSchemaSDL!RootSchema;
    static assert(sdl.canFind(`"""Number of users"""` ~ "\n  userCount: Int!"), sdl);
    static assert(sdl.canFind("userNamed(name: String!): User\n"), sdl);
    static assert(sdl.canFind("firstUser: User!"), sdl);
    // A list root field gets the query plugins' arguments like any other
    static assert(sdl.canFind("usersExcept(name: String!, filter: UserFilter, " ~
        "orderBy: [_OrderByStruct_Query_usersExcept!] = [], first: Int = null, offset: Int = null): [User!]!"), sdl);
    static assert(sdl.canFind("census: String!"), sdl);
    static assert(sdl.canFind("type Mutation {"), sdl);
    static assert(sdl.canFind("record(entry: String!): String!"), sdl);
    static assert(sdl.canFind("tryRecord(entry: String!): String\n"), sdl);
    static assert(sdl.canFind("recordFor(userId: Int!): RecordPayload!"), sdl);
    static assert(sdl.canFind("maybeUser(userId: Int!): User\n"), sdl);
    static assert(sdl.canFind("query: Query!"), sdl);
    static assert(sdl.canFind("type RecordPayload {\n  entry: String!\n  user: User!\n  logLength: Int!\n}"), sdl);
    // Root types are named after their role, whatever plugins wrapped them
    static assert(!sdl.canFind("type Filtered") && !sdl.canFind("type Paginated") &&
        !sdl.canFind("type WithComputed"), sdl);
}

// Query: scalar, nullable entity, entity and list root fields, with nested
// selections; a root field over other root fields; plugin arguments
unittest {
    seed();
    auto ctx = new EvalContext();
    auto result = run(`{
        userCount
        bob: userNamed(name: "Bob") { name posts { title } }
        nobody: userNamed(name: "Nobody") { name }
        firstUser { name postCount }
        usersExcept(name: "Alice", orderBy: [{field: id, direction: DESC}]) { name }
        census
        __typename
    }`, ctx);
    assert(ctx.errors.length == 0, ctx.errors[0].message);
    assert(result == parseJSON(`{
        "userCount": 3,
        "bob": {"name": "Bob", "posts": [{"title": "Other"}]},
        "nobody": null,
        "firstUser": {"name": "Alice", "postCount": 2},
        "usersExcept": [{"name": "Carol"}, {"name": "Bob"}],
        "census": "3 users from #1",
        "__typename": "Query"
    }`), result.toString());
}

// Mutation: fields evaluate in order; root mutation fields return entities,
// nullable entities, payloads with entities and the query root, with nested
// selections
unittest {
    seed();
    auto ctx = new EvalContext();
    auto result = run(`mutation {
        a: record(entry: "a")
        before: recorded
        b: record(entry: "b")
        payload: recordFor(userId: 2) { entry logLength user { name posts { title } } }
        after: recorded
        someone: maybeUser(userId: 3) { name }
        nobody: maybeUser(userId: 0) { name }
        query { userCount firstUser { name } }
        __typename
    }`, ctx);
    assert(ctx.errors.length == 0, ctx.errors[0].message);
    assert(result == parseJSON(`{
        "a": "a",
        "before": "a",
        "b": "b",
        "payload": {"entry": "user2", "logLength": 3, "user": {"name": "Bob", "posts": [{"title": "Other"}]}},
        "after": "a,b,user2",
        "someone": {"name": "Carol"},
        "nobody": null,
        "query": {"userCount": 3, "firstUser": {"name": "Alice"}},
        "__typename": "Mutation"
    }`), result.toString());
    assert(mutationLog == ["a", "b", "user2"]);
}

// Mutation: a failing nullable field is null, with the error at its path
// (its alias); the fields after it still run
unittest {
    seed();
    auto ctx = new EvalContext();
    auto result = run(`mutation {
        a: tryRecord(entry: "a")
        failed: tryRecord(entry: "")
        c: tryRecord(entry: "c")
    }`, ctx);
    assert(result == parseJSON(`{"a": "a", "failed": null, "c": "c"}`), result.toString());
    assert(ctx.errors.length == 1, result.toString());
    assert(ctx.errors[0].message == "empty entry");
    assert(ctx.errors[0].path == [JSONValue("failed")]);
    assert(mutationLog == ["a", "c"]);
}

// Mutation: a failing non-null field makes the whole result null (null
// bubbling, as for queries), and the fields after it do not run
unittest {
    seed();
    auto ctx = new EvalContext();
    auto result = run(`mutation {
        a: mustRecord(entry: "a")
        failed: mustRecord(entry: "")
        c: mustRecord(entry: "c")
    }`, ctx);
    assert(result.isNull, result.toString());
    assert(ctx.errors.length == 1);
    assert(ctx.errors[0].message == "empty entry");
    assert(ctx.errors[0].path == [JSONValue("failed")]);
    assert(mutationLog == ["a"]);
}

// Introspection describes the root fields like those of any other type
unittest {
    seed();
    auto result = run(`{
        __schema { mutationType { name } }
        mutation: __type(name: "Mutation") { fields { name } }
        payload: __type(name: "RecordPayload") { fields { name } }
        query: __type(name: "Query") { fields { name } }
    }`);
    assert(result["__schema"]["mutationType"]["name"].str == "Mutation", result.toString());
    bool hasField(JSONValue type, string name) {
        foreach (f; type["fields"].array)
            if (f["name"].str == name)
                return true;
        return false;
    }
    assert(hasField(result["mutation"], "recordFor") && hasField(result["mutation"], "query"), result.toString());
    assert(hasField(result["payload"], "user"), result.toString());
    assert(hasField(result["query"], "census") && hasField(result["query"], "users"), result.toString());
}
