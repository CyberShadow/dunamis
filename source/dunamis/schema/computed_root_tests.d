/// Unit tests for computed fields of the root types (Query and Mutation)
/// declared as free functions, over the fields in computed_root_fixture.d:
/// the root types are object types like any other, so ComputedFieldsPlugin
/// attaches functions written against them as it does for entities.
module dunamis.schema.computed_root_tests;

version (unittest):

import std.algorithm : canFind;
import std.conv : to;
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
import dunamis.schema.computed_root_fixture : Mutation, mutationLog, procedureRuns, atomicLog, AtomicLogDB;
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
    procedureRuns = 0;
    atomicLog = new AtomicLogDB;
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

// Procedures (perform): run once, in order with the other mutation fields;
// a nested evaluation sees the procedure's writes
unittest {
    seed();
    auto ctx = new EvalContext();
    auto result = run(`mutation {
        added: addUser(id: 4, name: "Dave")
        twice: addUserReadTwice(id: 5, name: "Eve")
    }`, ctx);
    assert(ctx.errors.length == 0, ctx.errors[0].message);
    assert(result == parseJSON(`{"added": 4, "twice": 10}`), result.toString());
    assert(procedureRuns == 2);
    auto users = run(`{ userCount }`);
    assert(users == parseJSON(`{"userCount": 5}`), users.toString());
}

// A procedure which throws makes its field fail, with the error at its path
unittest {
    seed();
    auto ctx = new EvalContext();
    auto result = run(`mutation { a: record(entry: "a") failed: failingProcedure b: record(entry: "b") }`, ctx);
    assert(result == parseJSON(`{"a": "a", "failed": null, "b": "b"}`), result.toString());
    assert(ctx.errors.length == 1 && ctx.errors[0].message == "procedure failed");
    assert(ctx.errors[0].path == [JSONValue("failed")]);
}

// Nested evaluations of different trees in one request
unittest {
    seed();
    auto ctx = new EvalContext();
    auto result = run(`{ users { name } namesAndTitles }`, ctx);
    assert(ctx.errors.length == 0, ctx.errors[0].message);
    assert(result["namesAndTitles"] == JSONValue("Alice,Bob,Carol|Hello,hidden,Other"), result.toString());
}

// Each mutation field is an atomic section of the request's sessions, undone
// if the field fails (also if a non-null field of its value does)
unittest {
    seed();
    auto ctx = new EvalContext();
    auto result = run(`mutation {
        a: atomicStep(entry: "a")
        b: atomicStep(entry: "")
        c: atomicStepPayload(entry: "") { checked }
        d: atomicStepPayload(entry: "d") { checked }
    }`, ctx);
    assert(result == parseJSON(`{"a": "a", "b": null, "c": null, "d": {"checked": "d"}}`), result.toString());
    assert(ctx.errors.length == 2, result.toString());
    assert(atomicLog.log == ["begin 1", "keep 1", "begin 2", "undo 2", "begin 3", "undo 3", "begin 4", "keep 4"],
        atomicLog.log.to!string);
}

// Input objects: three-state fields (absent, null, value), lists of nullable
// items, a non-list value given for a list, field defaults
unittest {
    enum sdl = generateSchemaSDL!RootSchema;
    static assert(sdl.canFind("input Options {\n  note: String\n  numbers: [Int]!\n  tags: [String!]! = []\n}"), sdl);

    seed();
    auto result = run(`mutation {
        absent: describeOptions(options: {numbers: [1, null]})
        nul: describeOptions(options: {note: null, numbers: 2, tags: ["x"]})
        value: describeOptions(options: {note: "n", numbers: []})
    }`);
    assert(result == parseJSON(`{"absent": "absent [1,null] []", "nul": "null [2] [x]", "value": "n [] []"}`),
        result.toString());

    // The same through variables
    auto ctx = new EvalContext();
    ctx.setRequestContext(Greeting("Hi"));
    auto query = compileQuery!RootSchema(`mutation($a: Options!, $b: Options!) {
        a: describeOptions(options: $a) b: describeOptions(options: $b) }`,
        parseJSON(`{"a": {"numbers": [null]}, "b": {"note": null, "numbers": 3}}`));
    auto viaVariables = awaitSync(new Executor().execute(query, ctx));
    assert(viaVariables == parseJSON(`{"a": "absent [null] []", "b": "null [3] []"}`), viaVariables.toString());

    // Introspection gives the default
    auto type = run(`{ __type(name: "Options") { inputFields { name defaultValue } } }`);
    assert(type["__type"]["inputFields"] == parseJSON(`[
        {"name": "note", "defaultValue": null},
        {"name": "numbers", "defaultValue": null},
        {"name": "tags", "defaultValue": "[]"}
    ]`), type.toString());
}

// Unknown fields, of the root types and of the objects of their fields,
// are validation errors (on the field's line), and nothing is executed
unittest {
    import dunamis.graphql.compiler.validation : ValidationException;

    void expectUnknown(string query, string field, string type, size_t line) {
        try {
            compileQuery!RootSchema(query);
            assert(false, "No validation error for " ~ query);
        } catch (ValidationException e) {
            assert(e.errors.length == 1, e.msg);
            assert(e.errors[0].message == "Unknown field '" ~ field ~ "' on type " ~ type, e.errors[0].message);
            assert(e.errors[0].line == line, e.errors[0].line.to!string);
        }
    }
    seed();
    expectUnknown("{\n  userCount\n  noSuchField\n}", "noSuchField", "Query", 3);
    expectUnknown("{\n  firstUser {\n    name\n    noSuchField\n  }\n}", "noSuchField", "User", 4);
    expectUnknown("mutation {\n  record(entry: \"a\")\n  noSuchMutation(entry: \"b\")\n}",
        "noSuchMutation", "Mutation", 3);
    expectUnknown("mutation {\n  recordFor(userId: 1) {\n    user { noSuchField }\n  }\n}",
        "noSuchField", "User", 3);
    assert(mutationLog == []);
}

// Nested input objects with three-state fields, literal and in variables
unittest {
    seed();
    auto result = run(`mutation {
        literal: describeChanges(input: {changes: [{id: 1, patch: {name: "a", count: null}}, {patch: null}, {id: 2}]})
    }`);
    assert(result == parseJSON(`{"literal": "1:a/null;new:null;2:absent;"}`), result.toString());
    auto ctx = new EvalContext();
    ctx.setRequestContext(Greeting("Hi"));
    auto query = compileQuery!RootSchema(`mutation($input: Changes!) { v: describeChanges(input: $input) w: describeChangesLater(input: $input) }`,
        parseJSON(`{"input": {"changes": [{"id": -1, "patch": {"count": 3}}, {"patch": {}}]}}`));
    auto viaVariables = awaitSync(new Executor().execute(query, ctx));
    assert(viaVariables == parseJSON(`{"v": "-1:-/3;new:-/-;", "w": "-1:-/3;new:-/-;"}`), viaVariables.toString());
}

// Nested evaluations in a scope with a session of its own (EvalContext.
// createScope(overrides)) read through it; sibling evaluations in the
// request read through the request's session
unittest {
    import dunamis.core.datasource : DataSource;
    import dunamis.core.expr : evaluateNested, singleton;
    import dunamis.relational.demo : MockDB;

    seed();
    auto other = new MockDB!();
    other.setTableData("users", `[{"id": 7, "name": "Zed"}]`);
    auto ctx = new EvalContext();
    auto session = ctx.getSession(fixtureDb);
    auto scope_ = ctx.createScope([cast(DataSource) fixtureDb: other.createSession()]);

    auto inScope = evaluateNested(rootFixture.userCount(Query().singleton()), scope_);
    auto inRequest = evaluateNested(rootFixture.userCount(Query().singleton()), ctx);
    auto inScopeAgain = evaluateNested(rootFixture.census(Query().singleton()), scope_.createScope());
    assert(awaitSync(inScope) == 1);
    assert(awaitSync(inRequest) == 3);
    assert(awaitSync(inScopeAgain) == "1 users from #7", awaitSync(inScopeAgain));
    assert(ctx.getSession(fixtureDb) is session && ctx.allSessions == [session]);
}

// An expression evaluated in a request, then in a scope of it with a session
// of its own, is evaluated again there, on the scope's session (the
// request's memoized evaluation read the request's)
unittest {
    import dunamis.core.datasource : DataSource;
    import dunamis.core.expr : evalAs, singleton;
    import dunamis.core.types : AnyRef, queryRoot;
    import dunamis.relational.demo : MockDB;

    seed();
    auto other = new MockDB!();
    other.setTableData("users", `[{"id": 7, "name": "Zed"}]`);
    auto count = new Executor().optimize(rootFixture.userCount(Query().singleton()));
    auto ctx = new EvalContext();
    ctx.setValues!AnyRef(null, [queryRoot]);
    assert(awaitSync(evalAs!int(count, ctx)) == [3]);
    auto scope_ = ctx.createScope([cast(DataSource) fixtureDb: other.createSession()]);
    assert(awaitSync(evalAs!int(count, scope_)) == [1]);
    assert(awaitSync(evalAs!int(count, scope_.createScope())) == [1]);
    assert(awaitSync(evalAs!int(count, ctx.createScope())) == [3]);
}

// Asynchronous batch functions (useAsync): run once per batch, with nested
// evaluations; a failing function fails the field; per-item errors
// (GqlResult) at the items' paths
unittest {
    seed();
    rootFixture.badgeBatches = null;
    auto ctx = new EvalContext();
    auto result = run(`{ users { id badge failingBadge } }`, ctx);
    assert(result == parseJSON(`{"users": [
        {"id": 1, "badge": "#1/3", "failingBadge": null},
        {"id": 2, "badge": "#2/3", "failingBadge": null},
        {"id": 3, "badge": "#3/3", "failingBadge": null}
    ]}`), result.toString());
    assert(rootFixture.badgeBatches == [[1, 2, 3]], rootFixture.badgeBatches.stringof);
    assert(ctx.errors.length == 1 && ctx.errors[0].message == "badges failed", ctx.errors.stringof);
    assert(ctx.errors[0].path == [JSONValue("users"), JSONValue("failingBadge")], ctx.errors.stringof);

    // A per-item error, at the item's path (check is non-null: it nulls the data)
    auto checkCtx = new EvalContext();
    auto checked = run(`{ users { id check } }`, checkCtx);
    assert(checked.isNull, checked.toString());
    assert(checkCtx.errors.length == 1 && checkCtx.errors[0].message == "user 2 failed the check",
        checkCtx.errors.stringof);
    assert(checkCtx.errors[0].path == [JSONValue("users"), JSONValue(1), JSONValue("check")], checkCtx.errors.stringof);

    // Other batches; an empty batch does not run the function
    rootFixture.badgeBatches = null;
    auto others = run(`{ usersExcept(name: "Alice") { badge } }`);
    assert(others == parseJSON(`{"usersExcept": [{"badge": "#2/3"}, {"badge": "#3/3"}]}`), others.toString());
    auto none = run(`{ users(filter: {id: {equalTo: 99}}) { badge } }`);
    assert(none == parseJSON(`{"users": []}`), none.toString());
    assert(rootFixture.badgeBatches == [[2, 3]], rootFixture.badgeBatches.stringof);
}
