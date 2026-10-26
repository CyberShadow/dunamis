/// Unit tests for ComputedFieldsPlugin, over the fields in computed_fixture.d.
module dunamis.schema.computed_tests;

version (unittest):

import std.json : JSONValue;

import ae.utils.promise.await : awaitSync;

import dunamis.core : EvalContext, Executor;
import dunamis.core.expr : Expr;
import dunamis.graphql.compiler : compileQuery;
import dunamis.graphql.schema : Schema, generateSchemaSDL;
import dunamis.relational.demo : MockDB;
import dunamis.schema.computed : ComputedFieldsPlugin, ComputedFieldEntity, computedFieldsIn;
import dunamis.schema.filtering : FilterPlugin;
import dunamis.schema.pagination : PaginationPlugin;
import dunamis.schema.plugin : ApplyPlugins;
import dunamis.schema.sorting : SortingPlugin;
static import dunamis.schema.computed_fixture;
import dunamis.schema.computed_fixture : fixtureDb, Greeting, Query, Post, User;
alias fixture = dunamis.schema.computed_fixture;


alias PluginLast = ApplyPlugins!(Schema!Query,
    FilterPlugin, SortingPlugin, PaginationPlugin, ComputedFieldsPlugin!fixture);
alias PluginFirst = ApplyPlugins!(Schema!Query,
    ComputedFieldsPlugin!fixture, FilterPlugin, SortingPlugin, PaginationPlugin);

private void seedFixture() {
    fixtureDb = new MockDB!();
    fixtureDb.setTableData("users", `[
        {"id": 1, "name": "Alice"},
        {"id": 2, "name": "Bob"}
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
        "audit", "likes", "label", "label"], names.stringof);

    static assert(computedFieldsIn!(fixture.authorName).length == 1);
    // A function symbol contributes its overloads
    static assert(computedFieldsIn!(fixture.label).length == 2);
    static assert(is(ComputedFieldEntity!(fixture.authorName) == Post));
}

// SDL: fields, descriptions and arguments appear on the original type names
unittest {
    import std.algorithm : canFind;

    enum sdl = generateSchemaSDL!PluginLast;
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
    // Earlier plugins' vocabulary is unchanged
    static assert(sdl.canFind("users(") && sdl.canFind("filter:") && sdl.canFind("orderBy:"), sdl);
    static assert(!sdl.canFind("postCount: IntFilter"), sdl);

    // Placing the plugin first is supported too
    enum sdlFirst = generateSchemaSDL!PluginFirst;
    static assert(sdlFirst.canFind("postCount: Int!"), sdlFirst);
}

// Execution with the plugin placed last: sorting, pagination and nested filters still apply.
// (MockDB ignores SQL WHERE clauses, so root filters are covered by the Postgres integration suite.)
unittest {
    seedFixture();
    auto result = executeFixture(compileQuery!PluginLast(`{
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
    auto result = executeFixture(compileQuery!PluginLast(`{
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

// Execution with the plugin placed first; nulls from Nullable results
unittest {
    seedFixture();
    auto result = executeFixture(compileQuery!PluginFirst(`{
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
        compileQuery!PluginLast(`{ posts { title checkedTitle } }`), ctx));
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
