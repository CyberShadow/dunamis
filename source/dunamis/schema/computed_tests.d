/// Unit tests for ComputedFieldsPlugin, over the fields in computed_fixture.d.
module dunamis.schema.computed_tests;

version (unittest):

import std.json : JSONValue, parseJSON;
import std.meta : AliasSeq;
import std.typecons : Nullable;

import ae.utils.promise.await : awaitSync;

import dunamis.core : EvalContext, Executor;
import dunamis.core.expr : Expr, ExprBase, use;
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
        "audit", "likes", "label", "label", "_internal", "notes", "digest", "noteCount", "siblingTexts",
        "greetedUsers", "shownCheckedTitles", "cells", "maybeCells", "grid", "postGrid", "strictTitle"],
        names.stringof);

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
    // Likewise an entity type, whose lists the plugins after
    // ComputedFieldsPlugin extend like any other
    static assert(sdl.canFind("likes(filter: LikeFilter = null, orderBy: [_OrderByStruct_Post_likes!] = [], " ~
        "first: Int = null, offset: Int = null): [Like!]!"), sdl);
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

// An abstract type declared in a source module, which no field returns: a
// type of the schema (with its members, as the schema's types), which type
// conditions name
unittest {
    import std.algorithm : canFind;
    import dunamis.schema.computed : abstractTypesIn;

    static assert(is(abstractTypesIn!fixture == AliasSeq!(fixture.Labelled)));
    enum sdl = generateSchemaSDL!FinalSchema;
    static assert(sdl.canFind("interface Labelled {\n  label: String!\n}"), sdl);
    static assert(sdl.canFind("type User implements Labelled {"), sdl);
    static assert(sdl.canFind("type Post implements Labelled {"), sdl);

    seedFixture();
    auto result = executeFixture(compileQuery!FinalSchema(`{
        users(orderBy: [{field: id, direction: ASC}], first: 1) { name ...Label }
        posts(orderBy: [{field: id, direction: ASC}], first: 1) { ... on Labelled { caption: label } }
    }
    fragment Label on Labelled { label }`));
    assert(result == parseJSON(`{"users": [{"name": "Alice", "label": "Alice"}], "posts": [{"caption": "Hello"}]}`),
        result.toString());
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

/// More users, posts and comments: users with several, one and no posts,
/// and a post without comments amid others.
private void seedNotesFixture() {
    fixtureDb = new MockDB!();
    fixtureDb.setTableData("users", `[
        {"id": 1, "name": "Alice"},
        {"id": 2, "name": "Bob"},
        {"id": 3, "name": "Carol"},
        {"id": 4, "name": "Dave"}
    ]`);
    fixtureDb.setTableData("posts", `[
        {"id": 10, "title": "Hello", "author_id": 1},
        {"id": 11, "title": "hidden", "author_id": 1},
        {"id": 12, "title": "Other", "author_id": 2},
        {"id": 13, "title": "Later", "author_id": 2},
        {"id": 14, "title": "Mine", "author_id": 4}
    ]`);
    fixtureDb.setTableData("comments", `[
        {"id": 100, "text": "c1", "post_id": 10},
        {"id": 101, "text": "c2", "post_id": 10},
        {"id": 102, "text": "c3", "post_id": 11},
        {"id": 103, "text": "c4", "post_id": 13},
        {"id": 104, "text": "c5", "post_id": 14}
    ]`);
    fixtureDb.setTableData("likes", `[]`);
}

private JSONValue executeNotes(string query, bool optimize) {
    auto ctx = new EvalContext();
    ctx.setRequestContext(Greeting("Hi"));
    auto result = awaitSync(new Executor().execute(compileQuery!FinalSchema(query), ctx, optimize));
    assert(ctx.errors.length == 0, ctx.errors[0].message ~ " in " ~ result.toString());
    return result;
}

// Lists of PODs with entity members (also nullable ones), and a POD list in
// a POD: the entities are the schema's, with their columns, relations and
// computed fields selectable, also under aliases
unittest {
    import std.algorithm : canFind;

    enum sdl = generateSchemaSDL!FinalSchema;
    static assert(sdl.canFind("): [CommentNote!]!\n"), sdl);
    static assert(sdl.canFind("type CommentNote {\n  text: String!\n  author: User!\n  editor: User\n}"), sdl);
    static assert(sdl.canFind("  digest: PostDigest!\n"), sdl);
    static assert(sdl.canFind("  reviewer: User\n"), sdl);

    foreach (optimize; [false, true]) {
        seedNotesFixture();
        auto result = executeNotes(`{
            posts(orderBy: [{field: id, direction: ASC}]) {
                id
                notes {
                    text
                    author { name label postCount posts { title } }
                    editor { name }
                    editedBy: editor { label postCount }
                }
                digest { notes { text writer: author { name } } reviewer { name } fieldName }
            }
        }`, optimize);
        auto posts = result["posts"].array;
        assert(posts.length == 5, result.toString());

        auto hello = posts[0];
        assert(hello["id"].integer == 10, result.toString());
        auto notes = hello["notes"].array;
        assert(notes.length == 2, result.toString());
        assert(notes[0]["text"].str == "c1" && notes[1]["text"].str == "c2", result.toString());
        foreach (note; notes) {
            assert(note["author"]["name"].str == "Alice", result.toString());
            assert(note["author"]["label"].str == "Alice", result.toString());
            assert(note["author"]["postCount"].integer == 2, result.toString());
            assert(note["author"]["posts"] == JSONValue([["title": "Hello"], ["title": "hidden"]]), result.toString());
        }
        assert(notes[0]["editor"]["name"].str == "Bob", result.toString());
        assert(notes[0]["editedBy"]["label"].str == "Bob" && notes[0]["editedBy"]["postCount"].integer == 2,
            result.toString());
        assert(notes[1]["editor"].isNull && notes[1]["editedBy"].isNull, result.toString());
        assert(hello["digest"]["reviewer"]["name"].str == "Carol", result.toString());
        assert(hello["digest"]["notes"].array.length == 2, result.toString());
        assert(hello["digest"]["notes"][1]["writer"]["name"].str == "Alice", result.toString());
        assert(hello["digest"]["fieldName"].str == "title", result.toString());

        // No comments: no notes, amid posts with notes
        assert(posts[2]["id"].integer == 12 && posts[2]["notes"].array.length == 0, result.toString());
        assert(posts[2]["digest"]["notes"].array.length == 0 && posts[2]["digest"]["reviewer"].isNull,
            result.toString());
        assert(posts[3]["notes"][0]["text"].str == "c4", result.toString());
        assert(posts[3]["notes"][0]["author"]["name"].str == "Bob", result.toString());
        assert(posts[4]["notes"][0]["author"]["name"].str == "Dave", result.toString());
        assert(posts[4]["notes"][0]["author"]["postCount"].integer == 1, result.toString());
    }
}

// A computed field over a child collection calling another computed field,
// beside the same field selected on the children: the batches stay aligned
// for parents with several, one and no children, and children without
// grandchildren
unittest {
    foreach (optimize; [false, true]) {
        seedNotesFixture();
        auto result = executeNotes(`{
            users(orderBy: [{field: id, direction: ASC}]) {
                id noteCount
                posts { id notes { text } }
            }
        }`, optimize);
        auto users = result["users"].array;
        assert(users.length == 4, result.toString());
        long[] counts;
        foreach (user; users)
            counts ~= user["noteCount"].integer;
        assert(counts == [3, 1, 0, 1], result.toString());
        assert(users[0]["posts"].array.length == 2, result.toString());
        assert(users[0]["posts"][1]["notes"] == JSONValue([["text": "c3"]]), result.toString());
        assert(users[1]["posts"][0]["id"].integer == 12 && users[1]["posts"][0]["notes"].array.length == 0,
            result.toString());
        assert(users[1]["posts"][1]["notes"] == JSONValue([["text": "c4"]]), result.toString());
        assert(users[2]["posts"].array.length == 0, result.toString());
        assert(users[3]["posts"][0]["notes"] == JSONValue([["text": "c5"]]), result.toString());
    }
}

// A computed field reaching back up and down the tree it is selected in
unittest {
    foreach (optimize; [false, true]) {
        seedNotesFixture();
        auto result = executeNotes(`{
            users(orderBy: [{field: id, direction: ASC}]) {
                posts { comments { text siblingTexts } }
            }
        }`, optimize);
        auto users = result["users"].array;
        foreach (post; users[0]["posts"].array)
            foreach (comment; post["comments"].array)
                assert(comment["siblingTexts"].str == "c1,c2,c3", result.toString());
        assert(users[0]["posts"][0]["comments"].array.length == 2, result.toString());
        assert(users[1]["posts"][0]["comments"].array.length == 0, result.toString());
        assert(users[1]["posts"][1]["comments"][0]["siblingTexts"].str == "c4", result.toString());
        assert(users[3]["posts"][0]["comments"][0]["siblingTexts"].str == "c5", result.toString());
    }
}

// A global root, indexed by a `use` (into a final class which is no object
// type of the schema) and broadcast inside nested maps, with the request
// context: evaluated once per selection, not per element
unittest {
    import std.conv : to;
    import dunamis.schema.computed_fixture : userIndexBuilds;

    foreach (optimize; [false, true]) {
        seedNotesFixture();
        userIndexBuilds = 0;
        auto result = executeNotes(`{
            users(orderBy: [{field: id, direction: ASC}]) {
                posts { comments { text greetedUsers } }
            }
        }`, optimize);
        size_t comments;
        foreach (user; result["users"].array)
            foreach (post; user["posts"].array)
                foreach (comment; post["comments"].array) {
                    assert(comment["greetedUsers"].str == "Hi Alice+Bob+Carol+Dave", result.toString());
                    comments++;
                }
        assert(comments == 5, result.toString());
        assert(userIndexBuilds == 1, (optimize ? "(optimized) " : "(naive) ") ~
            "users indexed " ~ userIndexBuilds.to!string ~ " times: " ~ result.toString());
    }
}

// A collection restricted with filterBy on a `use` + context predicate
// before a computed field which throws for the excluded elements: the
// excluded elements are not evaluated, so there is no error
unittest {
    foreach (optimize; [false, true]) {
        seedNotesFixture();
        auto result = executeNotes(`{
            users(orderBy: [{field: id, direction: ASC}]) { shownCheckedTitles }
        }`, optimize);
        auto users = result["users"].array;
        assert(users[0]["shownCheckedTitles"] == JSONValue(["Hello"]), result.toString());
        assert(users[1]["shownCheckedTitles"] == JSONValue(["Other", "Later"]), result.toString());
        assert(users[2]["shownCheckedTitles"].array.length == 0, result.toString());
        assert(users[3]["shownCheckedTitles"] == JSONValue(["Mine"]), result.toString());
    }
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

// A field set (a struct) contributes the sources it has public aliases of,
// in order, and the public static field functions it declares
unittest {
    import std.meta : staticMap;

    enum identifierOf(alias fn) = __traits(identifier, fn);

    static struct ModuleSet { alias fields = fixture; }
    static assert([staticMap!(identifierOf, computedFieldsIn!ModuleSet)] ==
        [staticMap!(identifierOf, computedFieldsIn!fixture)]);

    static struct FunctionSet {
        alias label = fixture.label;
        alias authorName = fixture.authorName;
        static Expr!string nickname(Expr!User u) { return u.name; }
        private static Expr!string _helper(Expr!User u) { return u.name; }
        static struct Nested { alias shout = fixture.shout; }
    }
    static assert([staticMap!(identifierOf, computedFieldsIn!FunctionSet)] ==
        ["label", "label", "authorName", "nickname", "shout"]);

    static struct NotASource { alias x = int; }
    static assert(!__traits(compiles, computedFieldsIn!NotASource));

    // The schema is the same as with the sources themselves
    static struct AuthorNameSet { alias authorName = fixture.authorName; }
    static assert(generateSchemaSDL!(ApplyPlugins!(Schema!Query, ComputedFieldsPlugin!AuthorNameSet)) ==
        generateSchemaSDL!(ApplyPlugins!(Schema!Query, ComputedFieldsPlugin!(fixture.authorName))));
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
        // (A filter on a column, e.g. on `label`, is pushed into the root
        // query's WHERE clause, which MockDB does not apply: the integration
        // tests check those, see testRootFilterWithoutSelectedColumns.)
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

// Filters a value type declares (`@FilteredBy`) on a computed field of the
// type, which only computed fields return: the filter's condition tests the
// value through the type's own endpoint fields at the filter's level.
JSONValue dayToJson(string v) { return JSONValue(v); }
/// ditto
string dayFromJson(JSONValue j) { return j.str; }
import dunamis.core.types : CustomScalar;
import dunamis.schema.filtering : FilteredBy;
alias Day = CustomScalar!(string, "Day", dayToJson, dayFromJson);
@FilteredBy!PeriodFilter
struct Period { Nullable!Day start; Nullable!Day end; }

/// Whether a half-open period [start, end) (unbounded where null) contains a day.
bool periodContains(Nullable!Day start, Nullable!Day end, string day) {
    return (start.isNull || start.get.value <= day) && (end.isNull || day < end.get.value);
}

struct PeriodFilter {
    Nullable!Day containsElement;
    Nullable!bool isNull;

    Expr!bool condition(V)(Expr!V period, ExprBase lengthSource) const {
        import dunamis.core.expr : constant;
        if (containsElement.isNull)
            return null;
        return use(&periodContains, V.start(period), V.end(period),
            constant(containsElement.get.value, lengthSource));
    }
}

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

/// A list of values of the type: filtered by lists of its declared filter.
auto periods(Expr!Term t) {
    return use((string label) => label == "open"
        ? [Period(Nullable!Day(Day("2020-06-01")), Nullable!Day.init)]
        : [Period(Nullable!Day(Day("2019-01-01")), Nullable!Day(Day("2019-02-01"))),
           Period(Nullable!Day(Day("2020-01-01")), Nullable!Day(Day("2021-01-01")))], t.label);
}

private alias TermSchema = ApplyPlugins!(Schema!TermQuery,
    ComputedFieldsPlugin!(period, periods), FilterPlugin, SortingPlugin, PaginationPlugin);

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

        long[] idsOfList(string operator, string day) {
            auto result = awaitSync(new Executor().execute(compileQuery!TermSchema(
                `{ terms(filter: {periods: {` ~ operator ~ `: {containsElement: "` ~ day ~ `"}}}) { id } }`),
                optimize));
            long[] found;
            foreach (row; result["terms"].array)
                found ~= row["id"].integer;
            return found;
        }
        assert(idsOfList("some", "2019-01-15") == [1], idsOfList("some", "2019-01-15").to!string);
        assert(idsOfList("some", "2020-07-01") == [1, 2], idsOfList("some", "2020-07-01").to!string);
        assert(idsOfList("every", "2020-07-01") == [2], idsOfList("every", "2020-07-01").to!string);
        assert(idsOfList("none", "2019-01-15") == [2], idsOfList("none", "2019-01-15").to!string);

        // The list's own filter argument is the declared filter too.
        auto result = awaitSync(new Executor().execute(compileQuery!TermSchema(
            `{ terms { id periods(filter: {containsElement: "2019-01-15"}) { start } } }`), optimize));
        assert(result["terms"] == parseJSON(`[
            {"id": 1, "periods": [{"start": "2019-01-01"}]},
            {"id": 2, "periods": []}
        ]`), result.toString());
    }

    import std.algorithm : canFind;
    enum sdl = generateSchemaSDL!TermSchema;
    static assert(sdl.canFind("input PeriodFilter {\n  containsElement: Day\n  isNull: Boolean\n}"), sdl);
    static assert(sdl.canFind("  period: PeriodFilter\n"), sdl);
    // A list of periods is filtered by lists of the declared filter, not by
    // a filter of the type's fields (which would be another "PeriodFilter").
    static assert(sdl.canFind("  periods: PeriodFilterListFilter\n"), sdl);
    static assert(sdl.canFind("input PeriodFilterListFilter {\n  some: PeriodFilter\n"), sdl);
    static assert(!sdl.canFind("  start: StringFilter"), sdl);
    static assert(sdl.canFind("  periods(filter: PeriodFilter"), sdl);

    // Introspection serves the declared filter under its name.
    termDb = new MockDB!();
    termDb.setTableData("terms", `[]`);
    auto result = awaitSync(new Executor().execute(compileQuery!TermSchema(
        `{ __type(name: "PeriodFilter") { inputFields { name } } }`)));
    assert(result["__type"]["inputFields"] ==
        parseJSON(`[{"name": "containsElement"}, {"name": "isNull"}]`), result.toString());
}

// Nested lists and nullable list items, as results and as POD members:
// selection sets apply to the items at any depth, entities in them are the
// schema's, and null bubbling goes through each list level
unittest {
    import std.algorithm : canFind;

    enum sdl = generateSchemaSDL!FinalSchema;
    static assert(sdl.canFind("  cells: [[Cell]!]!\n"), sdl);
    static assert(sdl.canFind("  maybeCells: [Cell]!\n"), sdl);
    static assert(sdl.canFind("type Grid {\n  header: [String!]!\n  cells: [[Cell]!]!\n}"), sdl);
    static assert(sdl.canFind("type Cell {\n  text: String!\n  owner: User\n}"), sdl);
    static assert(sdl.canFind("  postGrid: [[PostRef!]!]\n"), sdl);
    static assert(sdl.canFind("type PostRef {\n  post: Post!\n}"), sdl);

    // Introspection: the same wrappers, and the item types
    {
        auto result = executeFixture(compileQuery!FinalSchema(`{
            user: __type(name: "User") {
                fields { name type { kind ofType { kind ofType { kind ofType { kind ofType { kind name } } } } } }
            }
            cell: __type(name: "Cell") { kind fields { name } }
        }`));
        JSONValue typeOf(string field) {
            foreach (f; result["user"]["fields"].array)
                if (f["name"].str == field)
                    return f["type"];
            assert(false, field ~ " not found in " ~ result.toString());
        }
        auto cells = typeOf("cells");
        assert(cells["kind"].str == "NON_NULL" && cells["ofType"]["kind"].str == "LIST" &&
            cells["ofType"]["ofType"]["kind"].str == "NON_NULL" &&
            cells["ofType"]["ofType"]["ofType"]["kind"].str == "LIST" &&
            cells["ofType"]["ofType"]["ofType"]["ofType"]["kind"].str == "OBJECT" &&
            cells["ofType"]["ofType"]["ofType"]["ofType"]["name"].str == "Cell", result.toString());
        auto postGrid = typeOf("postGrid");
        assert(postGrid["kind"].str == "LIST" && postGrid["ofType"]["kind"].str == "NON_NULL" &&
            postGrid["ofType"]["ofType"]["kind"].str == "LIST" &&
            postGrid["ofType"]["ofType"]["ofType"]["kind"].str == "NON_NULL", result.toString());
        assert(result["cell"]["kind"].str == "OBJECT" && result["cell"]["fields"].array.length == 2,
            result.toString());
    }

    foreach (optimize; [false, true]) {
        seedNotesFixture();
        auto ctx = new EvalContext();
        ctx.setRequestContext(Greeting("Hi"));
        auto result = awaitSync(new Executor().execute(compileQuery!FinalSchema(`{
            users(orderBy: [{field: id, direction: ASC}]) {
                name
                cells { text owner { name postCount } }
                maybeCells { label: text owner { name } }
                grid { header cells { text } }
                postGrid { post { id title } }
            }
        }`), ctx, optimize));
        assert(ctx.errors.length == 0, ctx.errors[0].message);
        auto users = result["users"].array;
        assert(users.length == 4, result.toString());

        auto alice = users[0];
        auto row = JSONValue([JSONValue(["text": JSONValue("Alice"),
            "owner": JSONValue(["name": JSONValue("Alice"), "postCount": JSONValue(2)])]), JSONValue(null)]);
        assert(alice["cells"] == JSONValue([row, JSONValue.emptyArray, JSONValue([JSONValue(null)])]),
            result.toString());
        assert(alice["maybeCells"] == JSONValue([JSONValue(null),
            JSONValue(["label": JSONValue("Alice"), "owner": JSONValue(null)])]), result.toString());
        assert(alice["grid"] == JSONValue(["header": JSONValue([JSONValue("Alice")]),
            "cells": JSONValue([JSONValue([JSONValue(["text": JSONValue("Alice")]), JSONValue(null)]),
                JSONValue.emptyArray, JSONValue([JSONValue(null)])])]), result.toString());
        // Bob: two posts; Carol: none
        JSONValue post(long id, string title) {
            return JSONValue(["post": JSONValue(["id": JSONValue(id), "title": JSONValue(title)])]);
        }
        assert(users[1]["postGrid"] == JSONValue([JSONValue([post(12, "Other"), post(13, "Later")]),
            JSONValue.emptyArray]), result.toString());
        assert(users[2]["postGrid"] == JSONValue([JSONValue.emptyArray, JSONValue.emptyArray]), result.toString());
        assert(users[2]["cells"][0][0]["text"].str == "Carol", result.toString());

        // strictTitle fails (for the batch of all posts, because of the
        // hidden one): each non-null post nulls its PostRef, which nulls its
        // row ([PostRef!]!), which nulls the list ([[PostRef!]!]), which is
        // nullable; empty rows have nothing to null
        ctx = new EvalContext();
        ctx.setRequestContext(Greeting("Hi"));
        result = awaitSync(new Executor().execute(compileQuery!FinalSchema(`{
            users(orderBy: [{field: id, direction: ASC}]) { name postGrid { post { id strictTitle } } }
        }`), ctx, optimize));
        users = result["users"].array;
        assert(users.length == 4, result.toString());
        assert(users[0]["postGrid"].isNull && users[1]["postGrid"].isNull && users[3]["postGrid"].isNull,
            result.toString());
        assert(users[2]["postGrid"] == JSONValue([JSONValue.emptyArray, JSONValue.emptyArray]), result.toString());
        assert(users[3]["name"].str == "Dave", result.toString());
        assert(ctx.errors.length == 1 && ctx.errors[0].message == "hidden post", result.toString());
    }
}
