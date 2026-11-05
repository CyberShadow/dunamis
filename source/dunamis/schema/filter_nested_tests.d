/// Unit tests for nested relationship filters: belongs-to and to-many
/// (some/every/none) filters within each other, to any depth, over a schema
/// with cycles (`User.manager` is a `User`, `User.posts` / `Post.author`).
module dunamis.schema.filter_nested_tests;

version (unittest):

import std.algorithm : canFind;
import std.conv : to;
import std.typecons : Nullable;

import ae.utils.promise.await : awaitSync;

import dunamis.core : Executor;
import dunamis.graphql.compiler : compileQuery;
import dunamis.graphql.schema : Schema, generateSchemaSDL;
import dunamis.relational.demo : MockDB;
import dunamis.relational.schema : BelongsTo, Col, Entity, ForeignKeyCol, HasMany, PrimaryKey, Table;
import dunamis.schema.filtering : EntityFilter, FilterPlugin;
import dunamis.schema.pagination : PaginationPlugin;
import dunamis.schema.plugin : ApplyPlugins;
import dunamis.schema.sorting : SortingPlugin;

private MockDB!() nfDb;

@Entity!(nfDb, "nf_departments")
private struct NfDepartment {
    @PrimaryKey int id;
    mixin Col!("name", string);
    mixin HasMany!("employees", NfUser, "department_id");
}

@Entity!(nfDb, "nf_users")
private struct NfUser {
    @PrimaryKey int id;
    mixin Col!("name", string);
    mixin ForeignKeyCol!("departmentId", NfDepartment);
    mixin BelongsTo!("department", "departmentId");
    mixin ForeignKeyCol!("managerId", NfUser, Nullable!int);
    mixin BelongsTo!("manager", "managerId");
    mixin HasMany!("posts", NfPost, "author_id");
}

@Entity!(nfDb, "nf_posts")
private struct NfPost {
    @PrimaryKey int id;
    mixin Col!("title", string);
    mixin ForeignKeyCol!("authorId", NfUser);
    mixin BelongsTo!("author", "authorId");
    mixin HasMany!("comments", NfComment, "post_id");
}

@Entity!(nfDb, "nf_comments")
private struct NfComment {
    @PrimaryKey int id;
    mixin Col!("body", string);
    mixin Col!("note", Nullable!string);
    mixin ForeignKeyCol!("postId", NfPost);
    mixin BelongsTo!("post", "postId");
}

private struct NfQuery {
    mixin Table!(NfDepartment, "departments");
    mixin Table!(NfUser, "users");
    mixin Table!(NfPost, "posts");
    mixin Table!(NfComment, "comments");
}

private alias NfSchema = ApplyPlugins!(Schema!NfQuery, FilterPlugin, SortingPlugin, PaginationPlugin);

/// Departments: 1 R&D, 2 Sales.
/// Users: 1 Alice (R&D), 2 Bob (R&D, managed by Alice), 3 Carol (Sales,
/// managed by Bob), 4 Dave (Sales).
/// Posts: 1 "D Language" and 4 "Diving" by Alice, 2 "Databases" by Bob,
/// 3 "Sales tips" by Carol.
/// Comments: 1 "great read" on post 1 (no note), 2 "meh" on post 3 (note
/// "x"), 3 "Great!" on post 2 (note "y").
private void seed() {
    nfDb = new MockDB!();
    nfDb.setTableData("nf_departments", `[
        {"id": 1, "name": "R&D"}, {"id": 2, "name": "Sales"}
    ]`);
    nfDb.setTableData("nf_users", `[
        {"id": 1, "name": "Alice", "department_id": 1, "manager_id": null},
        {"id": 2, "name": "Bob", "department_id": 1, "manager_id": 1},
        {"id": 3, "name": "Carol", "department_id": 2, "manager_id": 2},
        {"id": 4, "name": "Dave", "department_id": 2, "manager_id": null}
    ]`);
    nfDb.setTableData("nf_posts", `[
        {"id": 1, "title": "D Language", "author_id": 1},
        {"id": 2, "title": "Databases", "author_id": 2},
        {"id": 3, "title": "Sales tips", "author_id": 3},
        {"id": 4, "title": "Diving", "author_id": 1}
    ]`);
    nfDb.setTableData("nf_comments", `[
        {"id": 1, "body": "great read", "note": null, "post_id": 1},
        {"id": 2, "body": "meh", "note": "x", "post_id": 3},
        {"id": 3, "body": "Great!", "note": "y", "post_id": 2}
    ]`);
}

private void check(string field, string filter, long[] expected) {
    // (The Postgres integration suite covers these filters' SQL.)
    foreach (optimize; [false, true]) {
        seed();
        auto result = awaitSync(new Executor().execute(compileQuery!NfSchema(
            `{ ` ~ field ~ `(filter: ` ~ filter ~ `, orderBy: [{field: id, direction: ASC}]) { id } }`), optimize));
        long[] found;
        foreach (row; result[field].array)
            found ~= row["id"].integer;
        assert(found == expected, (optimize ? "(optimized) " : "(naive) ") ~ field ~ "(filter: " ~
            filter ~ "): expected " ~ expected.to!string ~ ", got " ~ found.to!string);
    }
}

// One filter type per entity, referring to the others' to any depth.
unittest {
    static assert(is(typeof(*EntityFilter!NfPost.init.author) == EntityFilter!NfUser));
    static assert(is(typeof(*EntityFilter!NfUser.init.manager) == EntityFilter!NfUser));

    enum sdl = generateSchemaSDL!NfSchema;
    static assert(sdl.canFind("input NfPostFilter {"), sdl);
    static assert(sdl.canFind("  author: NfUserFilter\n"), sdl);
    static assert(sdl.canFind("  manager: NfUserFilter\n"), sdl);
    static assert(sdl.canFind("  posts: NfUserToManyNfPostFilter\n"), sdl);
    static assert(sdl.canFind("input NfUserToManyNfPostFilter {\n  some: NfPostFilter\n"), sdl);
    static assert(sdl.canFind("  note: StringFilter\n"), sdl);
    static assert(!sdl.canFind("Shallow"), sdl);
}

// Belongs-to within belongs-to, including the self-referential manager.
unittest {
    check("posts", `{author: {department: {name: {equalTo: "R&D"}}}}`, [1, 2, 4]);
    check("users", `{manager: {manager: {name: {equalTo: "Alice"}}}}`, [3]);
    check("comments", `{post: {author: {department: {name: {equalTo: "Sales"}}}}}`, [2]);
}

// To-many within to-many.
unittest {
    check("users", `{posts: {some: {comments: {some: {body: {includes: "great"}}}}}}`, [1]);
    check("users", `{posts: {some: {comments: {some: {body: {includesInsensitive: "great"}}}}}}`, [1, 2]);
    check("departments", `{employees: {some: {posts: {some: {comments: {some: {note: {equalTo: "x"}}}}}}}}`, [2]);
    check("users", `{posts: {none: {comments: {some: {id: {isNull: false}}}}}}`, [4]);
}

// Belongs-to within to-many, and to-many within belongs-to.
unittest {
    check("departments", `{employees: {some: {manager: {name: {equalTo: "Alice"}}}}}`, [1]);
    check("departments", `{employees: {some: {manager: {name: {equalTo: "Bob"}}}}}`, [2]);
    check("departments", `{employees: {every: {manager: {name: {equalTo: "Bob"}}}}}`, []);
    check("comments", `{post: {author: {posts: {every: {title: {startsWith: "D"}}}}}}`, [1, 3]);
    check("posts", `{comments: {some: {post: {author: {manager: {name: {equalTo: "Alice"}}}}}}}`, [2]);
}

// Logical combinators around relationship filters. A missing related row
// matches no filter on it.
unittest {
    check("users", `{not: {manager: {name: {equalTo: "Alice"}}}}`, [1, 3, 4]);
    check("users", `{manager: {id: {isNull: false}}}`, [2, 3]);
    check("users", `{or: [{department: {name: {equalTo: "Sales"}}}, {posts: {some: {title: {like: "D_v%"}}}}]}`,
        [1, 3, 4]);
    check("users", `{and: [{department: {name: {equalTo: "R&D"}}}, {not: {posts: {some: {id: {isNull: false}}}}}]}`, []);
}

// Nullable columns: isNull, and other operators matching non-null values only.
unittest {
    check("comments", `{note: {isNull: true}}`, [1]);
    check("comments", `{note: {isNull: false}}`, [2, 3]);
    check("comments", `{note: {equalTo: "x"}}`, [2]);
    check("comments", `{note: {notEqualTo: "x"}}`, [3]);
    check("comments", `{note: {in: ["x", "y"]}}`, [2, 3]);
    check("comments", `{note: {notIn: ["x"]}}`, [3]);
    check("comments", `{note: {lessThan: "y"}}`, [2]);
    check("comments", `{body: {isNull: false}}`, [1, 2, 3]);
    check("comments", `{body: {isNull: true}}`, []);
}

// A cycle through to-many relationships reached from another one: the
// filter of shelves refers to the list filter of books, whose filter refers
// to that of authors, which refers to the list filter of books again (while
// it is still being declared).
@Entity!(nfDb, "nf_shelves")
private struct NfShelf {
    @PrimaryKey int id;
    mixin Col!("name", string);
    mixin HasMany!("books", NfBook, "shelf_id");
}

@Entity!(nfDb, "nf_books")
private struct NfBook {
    @PrimaryKey int id;
    mixin Col!("title", string);
    mixin ForeignKeyCol!("shelfId", NfShelf);
    mixin ForeignKeyCol!("writerId", NfWriter);
    mixin BelongsTo!("writer", "writerId");
}

@Entity!(nfDb, "nf_writers")
private struct NfWriter {
    @PrimaryKey int id;
    mixin Col!("name", string);
    mixin HasMany!("books", NfBook, "writer_id");
}

private struct NfShelfQuery {
    mixin Table!(NfShelf, "shelves");
    mixin Table!(NfWriter, "writers");
}

unittest {
    alias S = ApplyPlugins!(Schema!NfShelfQuery, FilterPlugin, SortingPlugin, PaginationPlugin);
    nfDb = new MockDB!();
    nfDb.setTableData("nf_shelves", `[{"id": 1, "name": "A"}, {"id": 2, "name": "B"}]`);
    nfDb.setTableData("nf_writers", `[{"id": 1, "name": "W1"}, {"id": 2, "name": "W2"}]`);
    nfDb.setTableData("nf_books", `[
        {"id": 1, "title": "x", "shelf_id": 1, "writer_id": 1},
        {"id": 2, "title": "y", "shelf_id": 1, "writer_id": 2},
        {"id": 3, "title": "z", "shelf_id": 2, "writer_id": 2}
    ]`);
    auto result = awaitSync(new Executor().execute(compileQuery!S(`{
        shelves(filter: {books: {some: {writer: {books: {some: {title: {equalTo: "x"}}}}}}}) { name }
    }`), false));
    assert(result.toString() == `{"shelves":[{"name":"A"}]}`, result.toString());
}

// LIKE patterns.
unittest {
    check("posts", `{title: {like: "D%"}}`, [1, 2, 4]);
    check("posts", `{title: {like: "D_v%"}}`, [4]);
    check("posts", `{title: {like: "%tips"}}`, [3]);
    check("users", `{posts: {none: {title: {like: "D%"}}}}`, [3, 4]);
}
