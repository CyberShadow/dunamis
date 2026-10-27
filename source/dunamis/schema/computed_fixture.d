/// Unit-test fixture for ComputedFieldsPlugin: a small schema plus computed
/// fields declared as free functions in this module (see computed_tests.d).
module dunamis.schema.computed_fixture;

version (unittest):

import std.array : join;
import std.typecons : Nullable;
import std.uni : toUpper;

import dunamis.core.expr : Expr, broadcast, constant, context, map, singleton, use;
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
/// Only returned by computed fields, in lists: refers to entities, one of
/// them nullable.
struct CommentNote { string text; User author; Nullable!User editor; }
/// Only returned by a computed field: a POD list in a POD.
struct PostDigest { CommentNote[] notes; Nullable!User reviewer; }

@Entity!(fixtureDb, "comments")
struct Comment {
    @PrimaryKey int id;
    mixin Col!("text", string);
    mixin Col!("postId", ForeignKey!Post);
    mixin BelongsTo!("post", "postId");
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

// Fields over entities in POD results and over child collections, as
// application code writes them: named helpers, explicit result types.

/// The post's comments as notes: written by the post's author, edited by
/// Bob (user 2) if the comment says so.
Expr!(CommentNote[]) notes(Expr!Post p) {
    return use(&notesOf, map!commentText(p.comments), p.authorId);
}

private Expr!string commentText(Expr!Comment c) {
    return c.text;
}

private CommentNote[] notesOf(string[] texts, int authorId) {
    CommentNote[] result;
    foreach (text; texts)
        result ~= CommentNote(text, User(authorId), text == "c1" ? Nullable!User(User(2)) : Nullable!User.init);
    return result;
}

/// The notes in a POD, reviewed by Carol (user 3) for the post titled "Hello".
Expr!PostDigest digest(Expr!Post p) {
    return use(&digestOf, notes(p), p.title);
}

private PostDigest digestOf(CommentNote[] notes, string title) {
    return PostDigest(notes, title == "Hello" ? Nullable!User(User(3)) : Nullable!User.init);
}

/// A computed field over a child collection calling another computed field.
Expr!int noteCount(Expr!User u) {
    return use(&countNotes, map!notes(u.posts));
}

private int countNotes(CommentNote[][] notes) {
    int count;
    foreach (postNotes; notes)
        count += cast(int) postNotes.length;
    return count;
}

/// The texts of all comments on posts by the comment's post's author
/// (reaching back up and down the tree it is selected in).
Expr!string siblingTexts(Expr!Comment c) {
    return use(&joinTexts, map!postCommentTexts(c.post.author.posts));
}

private Expr!(string[]) postCommentTexts(Expr!Post p) {
    return map!commentText(p.comments);
}

private string joinTexts(string[][] texts) {
    return texts.join.join(",");
}

/// Final class (not an object type of the schema) only passed between
/// `use` calls: an index of all users, built once per evaluation.
final class UserIndex {
    string[] names;
}

/// The number of times `indexUsers` ran.
__gshared size_t userIndexBuilds;

private UserIndex indexUsers(string[] names) {
    userIndexBuilds++;
    auto index = new UserIndex;
    index.names = names;
    return index;
}

private Expr!string userName(Expr!User u) {
    return u.name;
}

/// A global root (all users), indexed once and broadcast to each comment,
/// combined with the request context.
Expr!string greetedUsers(Expr!Comment c) {
    return use(&greetAll,
        broadcast(use(&indexUsers, map!userName(Query().singleton().users())), c),
        context!Greeting(c));
}

private string greetAll(UserIndex index, Greeting greeting) {
    return greeting.word ~ " " ~ index.names.join("+");
}

/// A collection restricted with a `use` + context predicate before a
/// computed field which throws for the excluded elements.
Expr!(Nullable!string[]) shownCheckedTitles(Expr!User u) {
    return map!checkedTitle(filterBy!isShown(u.posts));
}

private Expr!bool isShown(Expr!Post p) {
    return use(&shown, p.title, context!Greeting(p));
}

private bool shown(string title, Greeting greeting) {
    return title != "hidden";
}

// ---- Not fields ----

private auto helper(Expr!User u) {
    return u.name;
}

string notAField(string s) {
    return s;
}
