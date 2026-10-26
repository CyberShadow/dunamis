/// Unit-test fixture for ComputedFieldsPlugin: a small schema plus computed
/// fields declared as free functions in this module (see computed_tests.d).
module dunamis.schema.computed_fixture;

version (unittest):

import std.array : join;
import std.typecons : Nullable;
import std.uni : toUpper;

import dunamis.core.expr : Expr, constant, context, map, use;
import dunamis.core.filtering : filterBy;
import dunamis.graphql.schema : GqlDescription;
import dunamis.relational.demo : MockDB;
import dunamis.relational.schema : BelongsTo, Col, Entity, ForeignKey, HasMany, PrimaryKey, Table, hasMany;

MockDB!() fixtureDb;

struct Greeting { string word; }
struct Span { int from; int to; }
struct Window { string label; Span span; } // Only returned by computed fields
/// Only returned by a computed field; refers to an entity.
struct PostAudit { string title; User author; }

@Entity!(fixtureDb, "comments")
struct Comment {
    @PrimaryKey int id;
    mixin Col!("text", string);
    mixin Col!("postId", ForeignKey!Post);
}

@Entity!(fixtureDb, "posts")
struct Post {
    @PrimaryKey int id;
    mixin Col!("title", string);
    mixin Col!("authorId", ForeignKey!User);
    mixin BelongsTo!("author", "authorId");
    mixin HasMany!("comments", Comment, "post_id");
}

@Entity!(fixtureDb, "users")
struct User {
    @PrimaryKey int id;
    mixin Col!("name", string);
    mixin HasMany!("posts", Post, "author_id");

    static auto span(Expr!User u) {
        return use((string name) => Span(0, cast(int) name.length), u.name);
    }
}

/// Only reachable through a computed field.
@Entity!(fixtureDb, "likes")
struct Like {
    @PrimaryKey int id;
    mixin Col!("postId", ForeignKey!Post);
    mixin BelongsTo!("post", "postId");
}

struct Query {
    mixin Table!(User, "users");
    mixin Table!(Post, "posts");
}

// ---- Computed fields ----

@GqlDescription("Number of posts written by the user")
auto postCount(Expr!User u) {
    return use((string[] titles) => cast(int) titles.length,
        map!((Expr!Post p) => p.title)(u.posts));
}

auto shout(Expr!User u, string suffix = "!") {
    return use((string name, string s) => name.toUpper ~ s, u.name, constant(suffix, u));
}

auto authorName(Expr!Post p) {
    return p.author.name;
}

auto greeting(Expr!User u) {
    return use((string name, Greeting g) => g.word ~ ", " ~ name, u.name, context!Greeting(u));
}

auto commentTexts(Expr!User u) {
    return use((string[][] texts) => texts.join.join(","),
        map!((Expr!Post p) => map!((Expr!Comment c) => c.text)(p.comments))(u.posts));
}

auto visiblePosts(Expr!User u) {
    return filterBy!((Expr!Post p) => p.title.ne("hidden"))(u.posts);
}

auto checkedTitle(Expr!Post p) {
    return use((string title) {
        if (title == "hidden") throw new Exception("hidden post");
        return Nullable!string(title);
    }, p.title);
}

auto widened(Expr!User u) {
    return use((Span s) => Span(s.from - 1, s.to + 1), u.span);
}

auto maybeSpan(Expr!User u) {
    return use((string name) => name == "Bob" ? Nullable!Span.init : Nullable!Span(Span(1, 2)), u.name);
}

auto maybeSpans(Expr!User u) {
    return use((string name) => name == "Bob" ? Nullable!(Span[]).init : Nullable!(Span[])([Span(1, 2), Span(3, 4)]), u.name);
}

auto initial(Expr!User u) {
    return use((string name) => name == "Bob" ? Nullable!string.init : Nullable!string(name[0 .. 1]), u.name);
}

auto window(Expr!User u) {
    return use((string name) => Window(name, Span(0, cast(int) name.length)), u.name);
}

auto windows(Expr!User u) {
    return use((string name) => name == "Bob" ? Nullable!(Window[]).init : Nullable!(Window[])([Window("a", Span(1, 2))]), u.name);
}

auto audit(Expr!Post p) {
    return use((string title, int authorId) => PostAudit(title, User(authorId)), p.title, p.authorId);
}

auto likes(Expr!Post p) {
    return hasMany!(Like, "post_id")(p);
}

/// One field name for several types
auto label(Expr!User u) {
    return u.name;
}

auto label(Expr!Post p) {
    return p.title;
}

// A public function is a field whatever its name (visibility, not naming,
// tells library internals apart: ARCHITECTURE.md, Principle 8)
auto _internal(Expr!User u) {
    return u.name;
}

// ---- Not fields ----

private auto helper(Expr!User u) {
    return u.name;
}

string notAField(string s) {
    return s;
}
