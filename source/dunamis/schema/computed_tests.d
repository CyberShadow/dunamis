/// Unit tests for ComputedFieldsPlugin, over the fields in computed_fixture.d.
module dunamis.schema.computed_tests;

version (unittest):

import std.json : JSONValue;
import std.typecons : Nullable;

import ae.utils.promise.await : awaitSync;

import dunamis.core : EvalContext, Executor;
import dunamis.core.expr : Expr, use;
import dunamis.graphql.compiler : compileQuery;
import dunamis.graphql.schema : Schema, generateSchemaSDL;
import dunamis.relational.demo : MockDB;
import dunamis.relational.schema : Col, Entity, PrimaryKey, Table;
import dunamis.schema.computed : ComputedFieldsPlugin, ComputedFieldEntity, computedFieldsIn;
import dunamis.schema.filtering : FilterPlugin;
import dunamis.schema.pagination : PaginationPlugin;
import dunamis.schema.plugin : ApplyPlugins, ArrayFieldElementType;
import dunamis.schema.sorting : SortingPlugin;
static import dunamis.schema.computed_fixture;
import dunamis.schema.computed_fixture : fixtureDb, Greeting, Query, Post, User;
alias fixture = dunamis.schema.computed_fixture;


/// The documented placement: straight after Schema!, before the query plugins.
alias FinalSchema = ApplyPlugins!(Schema!Query,
    ComputedFieldsPlugin!fixture, FilterPlugin, SortingPlugin, PaginationPlugin);

private void seedFixture() {
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
    fixtureDb.setTableData("comments", `[
        {"id": 100, "text": "c1", "post_id": 10},
        {"id": 101, "text": "c2", "post_id": 10},
        {"id": 102, "text": "c3", "post_id": 11}
    ]`);
    fixtureDb.setTableData("likes", `[
        {"id": 1000, "post_id": 10},
        {"id": 1001, "post_id": 10},
        {"id": 1002, "post_id": 12}
    ]`);
}

private JSONValue executeFixture(Expr!JSONValue query) {
    auto ctx = new EvalContext();
    ctx.setRequestContext(Greeting("Hi"));
    return awaitSync(new Executor().execute(query, ctx));
}

// Discovery: public module-level functions taking an Expr first
unittest {
    enum string[] names = () {
        string[] result;
        static foreach (fn; computedFieldsIn!fixture)
            result ~= __traits(identifier, fn);
        return result;
    }();
    static assert(names == ["postCount", "shout", "authorName", "greeting", "commentTexts",
        "visiblePosts", "checkedTitle", "widened", "maybeSpan", "maybeSpans", "initial", "window", "windows",
        "audit", "likes", "label", "label", "_internal"], names.stringof);

    static assert(computedFieldsIn!(fixture.authorName).length == 1);
    // A function symbol contributes its overloads
    static assert(computedFieldsIn!(fixture.label).length == 2);
    static assert(is(ComputedFieldEntity!(fixture.authorName) == Post));
}

// SDL: fields, descriptions and arguments appear on the original type names
unittest {
    import std.algorithm : canFind;

    enum sdl = generateSchemaSDL!FinalSchema;
    static assert(sdl.canFind(`"""Number of posts written by the user"""` ~ "\n  postCount: Int!"), sdl);
    static assert(sdl.canFind(`shout(suffix: String = "!"): String!`), sdl);
    static assert(sdl.canFind("authorName: String!"), sdl);
    static assert(sdl.canFind("widened: Span!"), sdl);
    static assert(sdl.canFind("maybeSpan: Span\n"), sdl);
    static assert(sdl.canFind("maybeSpans: [Span!]\n"), sdl);
    static assert(sdl.canFind("initial: String\n"), sdl);
    static assert(sdl.canFind("visiblePosts"), sdl);
    // A result type only a computed field returns, with its entity member
    // typed as the schema's entity
    static assert(sdl.canFind("audit: PostAudit!"), sdl);
    static assert(sdl.canFind("type PostAudit {\n  title: String!\n  author: User!\n}"), sdl);
    // Likewise an entity type
    static assert(sdl.canFind("likes: [Like!]!"), sdl);
    static assert(sdl.canFind("type Like {\n  id: Int!\n  postId: Int!\n  post: Post!\n}"), sdl);
    static assert(!sdl.canFind("helper"), sdl);
    static assert(!sdl.canFind("notAField"), sdl);
    // (nor are members of the library's filter types)
    static assert(!sdl.canFind("toString"), sdl);
    // The query plugins applied after it see computed fields like any other
    static assert(sdl.canFind("users(") && sdl.canFind("filter:") && sdl.canFind("orderBy:"), sdl);
    static assert(sdl.canFind("  postCount: IntFilter\n"), sdl);
    static assert(sdl.canFind("  authorName: StringFilter\n"), sdl);
    // (but not those with required arguments)
    static assert(!sdl.canFind("  shout: StringFilter\n"), sdl);
}

// Execution: sorting, pagination and nested filters apply.
// (MockDB ignores SQL WHERE clauses, so root filters are covered by the Postgres integration suite.)
unittest {
    seedFixture();
    auto result = executeFixture(compileQuery!FinalSchema(`{
        users(orderBy: [{field: id, direction: ASC}], first: 1) {
            name
            postCount
            shout
            question: shout(suffix: "?")
            greeting
            commentTexts
            initial
            widened { from to }
            maybeSpan { from }
            maybeSpans { from last: to }
            window { label span { to } }
            windows { label span { from } }
            visiblePosts { title authorName }
            posts(filter: {title: {equalTo: "Hello"}}) { title authorName }
        }
        posts(orderBy: [{field: id, direction: DESC}], first: 1) { title authorName }
    }`));

    auto users = result["users"].array;
    assert(users.length == 1, result.toString());
    auto alice = users[0];
    assert(alice["name"].str == "Alice");
    assert(alice["postCount"].integer == 2, result.toString());
    assert(alice["shout"].str == "ALICE!");
    assert(alice["question"].str == "ALICE?");
    assert(alice["greeting"].str == "Hi, Alice");
    assert(alice["commentTexts"].str == "c1,c2,c3", result.toString());
    assert(alice["initial"].str == "A");
    assert(alice["widened"]["from"].integer == -1 && alice["widened"]["to"].integer == 6, result.toString());
    assert(alice["maybeSpan"]["from"].integer == 1);
    assert(alice["maybeSpans"].array.length == 2, result.toString());
    assert(alice["maybeSpans"][1]["from"].integer == 3 && alice["maybeSpans"][1]["last"].integer == 4, result.toString());
    assert("to" !in alice["maybeSpans"][0].object, result.toString());
    assert(alice["window"]["label"].str == "Alice" && alice["window"]["span"]["to"].integer == 5, result.toString());
    assert(alice["windows"][0]["label"].str == "a" && alice["windows"][0]["span"]["from"].integer == 1, result.toString());
    assert(alice["visiblePosts"].array.length == 1, result.toString());
    assert(alice["visiblePosts"][0]["title"].str == "Hello");
    assert(alice["visiblePosts"][0]["authorName"].str == "Alice");
    assert(alice["posts"].array.length == 1, result.toString());
    assert(alice["posts"][0]["authorName"].str == "Alice");

    auto posts = result["posts"].array;
    assert(posts.length == 1, result.toString());
    assert(posts[0]["title"].str == "Other" && posts[0]["authorName"].str == "Bob", result.toString());
}

// An entity inside a computed POD result is the schema's entity: its own
// computed fields and relations are selectable
unittest {
    seedFixture();
    auto result = executeFixture(compileQuery!FinalSchema(`{
        posts(orderBy: [{field: id, direction: ASC}]) {
            title label
            audit { title author { name label postCount } }
            likes { id post { title } }
        }
    }`));
    auto posts = result["posts"].array;
    assert(posts.length == 3, result.toString());
    assert(posts[0]["label"].str == "Hello", result.toString());
    assert(posts[0]["audit"]["author"]["label"].str == "Alice", result.toString());
    assert(posts[0]["likes"].array.length == 2, result.toString());
    assert(posts[0]["likes"][1]["post"]["title"].str == "Hello", result.toString());
    assert(posts[1]["likes"].array.length == 0, result.toString());
    assert(posts[0]["audit"]["title"].str == "Hello", result.toString());
    assert(posts[0]["audit"]["author"]["name"].str == "Alice", result.toString());
    assert(posts[0]["audit"]["author"]["postCount"].integer == 2, result.toString());
    assert(posts[2]["audit"]["author"]["name"].str == "Bob", result.toString());
}

// Nulls from Nullable results
unittest {
    seedFixture();
    auto result = executeFixture(compileQuery!FinalSchema(`{
        users(first: 1, offset: 1) { postCount initial maybeSpan { from } maybeSpans { from } posts { authorName } }
    }`));
    auto bob = result["users"][0];
    assert(bob["postCount"].integer == 1, result.toString());
    assert(bob["initial"].isNull, result.toString());
    assert(bob["maybeSpan"].isNull, result.toString());
    assert(bob["maybeSpans"].isNull, result.toString());
    assert(bob["posts"][0]["authorName"].str == "Bob");
}

// A throwing computed field becomes a field-level error; sibling fields are kept
// (checkedTitle is nullable, so the error does not bubble up to the post)
unittest {
    seedFixture();
    auto ctx = new EvalContext();
    auto result = awaitSync(new Executor().execute(
        compileQuery!FinalSchema(`{ posts { title checkedTitle } }`), ctx));
    assert(result["posts"].array.length == 3, result.toString());
    foreach (post; result["posts"].array)
        assert(!post["title"].isNull && post["checkedTitle"].isNull, result.toString());
    assert(ctx.errors.length == 1);
    assert(ctx.errors[0].message == "hidden post");
    assert(ctx.errors[0].path == [JSONValue("posts"), JSONValue("checkedTitle")]);
}

// Misuse is rejected at compile time
unittest {
    static auto name(Expr!User u) { return u.name; }
    static struct Unrelated { int x; }
    static auto orphan(Expr!Unrelated u) { return u; }
    static int notAField(int x) { return x; }

    static assert(__traits(compiles,
        generateSchemaSDL!(ApplyPlugins!(Schema!Query, ComputedFieldsPlugin!(fixture.authorName)))));
    static assert(!__traits(compiles,
        generateSchemaSDL!(ApplyPlugins!(Schema!Query, ComputedFieldsPlugin!name))));
    static assert(!__traits(compiles,
        generateSchemaSDL!(ApplyPlugins!(Schema!Query, ComputedFieldsPlugin!orphan))));
    static assert(!__traits(compiles, computedFieldsIn!notAField));
}

// The plugin works with the types of the schema it is applied to: after
// another plugin, functions written against user-declared types match no
// type (the plugin does not look beneath the previous plugin's wrappers),
// while functions written against that schema's own types are attached.
private alias Filtered = ApplyPlugins!(Schema!Query, FilterPlugin);
private alias FilteredUser = ArrayFieldElementType!(Filtered.Query.users);

auto nameLength(Expr!FilteredUser u) {
    return use((string name) => cast(int) name.length, u.name);
}

unittest {
    import std.algorithm : canFind;

    static assert(!__traits(compiles,
        generateSchemaSDL!(ApplyPlugins!(Filtered, ComputedFieldsPlugin!(fixture.authorName)))));

    alias Extended = ApplyPlugins!(Filtered, ComputedFieldsPlugin!nameLength);
    enum sdl = generateSchemaSDL!Extended;
    static assert(sdl.canFind("nameLength: Int!"), sdl);
    // Placed after FilterPlugin, the computed field is not filterable
    static assert(!sdl.canFind("nameLength: IntFilter"), sdl);

    seedFixture();
    auto result = executeFixture(compileQuery!Extended(`{ users { nameLength } }`));
    assert(result["users"][0]["nameLength"].integer == 5, result.toString());
}

// Result-only types are extended like the schema's own types
unittest {
    import dunamis.schema.computed_fixture : Window;
    alias P = ComputedFieldsPlugin!fixture;
    alias C = P!(Schema!Query);
    alias W = C.FieldTypeMap!Window;
    static assert(is(C.EntityTypeMap!W == C.WithComputed!W));
}

private long[] fixtureIds(string field, string args, bool optimize) {
    auto ctx = new EvalContext();
    ctx.setRequestContext(Greeting("Hi"));
    auto result = awaitSync(new Executor().execute(
        compileQuery!FinalSchema(`{ ` ~ field ~ `(` ~ args ~ `) { id } }`), ctx, optimize));
    long[] found;
    foreach (row; result[field].array)
        found ~= row["id"].integer;
    return found;
}

// Filters and orderings on computed fields: evaluated in memory where they
// cannot be expressed in SQL, never skipped, and in the documented order
// (filter, then orderBy, then the first/offset window) in both execution modes.
// MockDB applies a root ORDER BY / OFFSET / LIMIT pushed into SQL (but not
// WHERE clauses), so a window pushed beneath an in-memory filter or sort
// would show here.
unittest {
    import std.conv : to;

    foreach (optimize; [false, true]) {
        seedFixture();
        void check(string field, string args, long[] expected) {
            auto found = fixtureIds(field, args, optimize);
            assert(found == expected, (optimize ? "(optimized) " : "(naive) ") ~
                field ~ "(" ~ args ~ "): expected " ~ expected.to!string ~ ", got " ~ found.to!string);
        }

        // postCount: Alice 2, Bob 1, Carol 0
        check("users", `filter: {postCount: {equalTo: 1}}`, [2]);
        check("users", `filter: {postCount: {greaterThan: 0}}`, [1, 2]);
        check("users", `filter: {not: {postCount: {greaterThan: 0}}}`, [3]);
        check("users", `filter: {or: [{postCount: {equalTo: 0}}, {name: {equalTo: "Alice"}}]}`, [1, 3]);
        check("users", `filter: {initial: {isNull: true}}`, [2]);
        check("users", `filter: {initial: {equalTo: "C"}}`, [3]);
        check("users", `orderBy: [{field: postCount, direction: ASC}]`, [3, 2, 1]);
        check("users", `orderBy: [{field: postCount, direction: DESC}]`, [1, 2, 3]);
        check("users", `orderBy: [{field: shout, direction: DESC}]`, [3, 2, 1]);

        // With the window: filter, then sort, then first/offset
        check("users", `filter: {postCount: {lessThan: 2}}, first: 1`, [2]);
        check("users", `orderBy: [{field: postCount, direction: ASC}], first: 2`, [3, 2]);
        check("users", `orderBy: [{field: postCount, direction: ASC}], first: 1, offset: 1`, [2]);
        check("users", `filter: {postCount: {greaterThan: 0}}, orderBy: [{field: postCount, direction: ASC}], first: 1`, [2]);
        check("users", `filter: {name: {notEqualTo: "Bob"}}, orderBy: [{field: postCount, direction: ASC}], first: 1`, [3]);
        // A column ordering beneath an in-memory one
        check("users", `orderBy: [{field: postCount, direction: DESC}, {field: id, direction: DESC}], first: 2`, [1, 2]);

        // Computed fields reaching through relationships, on posts
        check("posts", `filter: {authorName: {equalTo: "Bob"}}`, [12]);
        check("posts", `orderBy: [{field: authorName, direction: DESC}, {field: id, direction: ASC}]`, [12, 10, 11]);
        check("posts", `orderBy: [{field: authorName, direction: DESC}, {field: id, direction: DESC}], first: 2`, [12, 11]);
        check("posts", `filter: {label: {startsWith: "H"}}, orderBy: [{field: label, direction: DESC}], first: 1`, [10]);
    }
}

// Nested (HasMany) fields filter and sort on computed fields too
unittest {
    foreach (optimize; [false, true]) {
        seedFixture();
        auto result = awaitSync(new Executor().execute(compileQuery!FinalSchema(`{
            users(orderBy: [{field: id, direction: ASC}], first: 1) {
                posts(filter: {authorName: {equalTo: "Alice"}}, orderBy: [{field: label, direction: DESC}], first: 1) { id }
            }
        }`), optimize));
        auto posts = result["users"][0]["posts"].array;
        assert(posts.length == 1 && posts[0]["id"].integer == 11, result.toString());
    }
}

// A field function using the facilities of plugins applied after
// ComputedFieldsPlugin goes through the final schema explicitly (with an
// explicit return type: the plugin needs the signature to build that schema).
private alias Windowed = ApplyPlugins!(Schema!Query,
    ComputedFieldsPlugin!firstPostTitles, FilterPlugin, SortingPlugin, PaginationPlugin);

Expr!(string[]) firstPostTitles(Expr!User u) {
    import std.typecons : Nullable;
    import dunamis.core.expr : broadcast, map, singleton;
    auto posts = Windowed.Query.posts(Windowed.Query().singleton(), first: Nullable!int(2));
    return map!(p => p.title)(posts).broadcast(u);
}

unittest {
    foreach (optimize; [false, true]) {
        seedFixture();
        auto result = awaitSync(new Executor().execute(compileQuery!Windowed(`{
            users { firstPostTitles }
        }`), optimize));
        auto users = result["users"].array;
        assert(users.length == 3, result.toString());
        foreach (user; users)
            assert(user["firstPostTitles"] == JSONValue(["Hello", "hidden"]), result.toString());
    }
}

// Range filters (`containsElement`) on a range-valued computed field, whose
// result type is only returned by computed fields: the range is tested
// through its own endpoint fields at the filter's level.
JSONValue dayToJson(string v) { return JSONValue(v); }
/// ditto
string dayFromJson(JSONValue j) { return j.str; }
import dunamis.core.types : CustomScalar;
alias Day = CustomScalar!(string, "Day", dayToJson, dayFromJson);
struct Period { Nullable!Day start; Nullable!Day end; }

private MockDB!() termDb;

@Entity!(termDb, "terms")
struct Term {
    @PrimaryKey int id;
    mixin Col!("label", string);
}

struct TermQuery {
    mixin Table!(Term, "terms");
}

auto period(Expr!Term t) {
    return use((string label) => label == "open"
        ? Period(Nullable!Day(Day("2020-06-01")), Nullable!Day.init)
        : Period(Nullable!Day(Day("2020-01-01")), Nullable!Day(Day("2021-01-01"))), t.label);
}

private alias TermSchema = ApplyPlugins!(Schema!TermQuery,
    ComputedFieldsPlugin!period, FilterPlugin, SortingPlugin, PaginationPlugin);

unittest {
    import std.conv : to;

    foreach (optimize; [false, true]) {
        termDb = new MockDB!();
        termDb.setTableData("terms", `[{"id": 1, "label": "closed"}, {"id": 2, "label": "open"}]`);
        long[] ids(string day) {
            auto result = awaitSync(new Executor().execute(compileQuery!TermSchema(
                `{ terms(filter: {period: {containsElement: "` ~ day ~ `"}}) { id } }`), optimize));
            long[] found;
            foreach (row; result["terms"].array)
                found ~= row["id"].integer;
            return found;
        }
        assert(ids("2020-03-01") == [1], ids("2020-03-01").to!string);
        assert(ids("2021-03-01") == [2], ids("2021-03-01").to!string);
        assert(ids("2020-07-01") == [1, 2], ids("2020-07-01").to!string);
        assert(ids("2019-07-01") == [], ids("2019-07-01").to!string);
    }
}
