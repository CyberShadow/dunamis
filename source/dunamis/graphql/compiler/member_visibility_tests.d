/// Tests that schema discovery tells library internals from user-declared
/// members by visibility, not by name (ARCHITECTURE.md, Principle 8): user
/// members named with a leading underscore are fields like any other, and
/// relationship mixins add only the member they declare.
module dunamis.graphql.compiler.member_visibility_tests;

version (unittest):

import std.algorithm : canFind;
import std.conv : to;
import std.json : JSONType, JSONValue;

import ae.utils.promise.await : awaitSync;

import dunamis.core : Executor;
import dunamis.core.discovery : getSchemaFields;
import dunamis.graphql.compiler : compileQuery;
import dunamis.graphql.schema : Schema, generateSchemaSDL;
import dunamis.relational.demo : MockDB;
import dunamis.relational.schema : BelongsTo, Col, Entity, ForeignKeyCol, HasMany, PrimaryKey, Table;
import dunamis.schema.filtering : FilterPlugin;
import dunamis.schema.pagination : PaginationPlugin;
import dunamis.schema.plugin : ApplyPlugins;
import dunamis.schema.sorting : SortingPlugin;

private MockDB!() mvDb;

@Entity!(mvDb, "mv_authors")
private struct MvAuthor {
    @PrimaryKey int id;
    mixin Col!("_nick", string, "nick");
    mixin HasMany!("posts", MvPost, "author_id");
}

@Entity!(mvDb, "mv_posts")
private struct MvPost {
    @PrimaryKey int id;
    mixin ForeignKeyCol!("authorId", MvAuthor);
    mixin BelongsTo!("author", "authorId");
}

/// MvPost without its relationship
@Entity!(mvDb, "mv_posts")
private struct MvPostColumns {
    @PrimaryKey int id;
    mixin ForeignKeyCol!("authorId", MvAuthor);
}

private struct MvQuery {
    mixin Table!(MvAuthor, "authors");
    mixin Table!(MvPost, "posts");
}

// BelongsTo adds exactly one member: the relationship
static assert([__traits(allMembers, MvPost)] == [__traits(allMembers, MvPostColumns)] ~ "author",
    [__traits(allMembers, MvPost)].to!string);

private alias MvSchema = ApplyPlugins!(Schema!MvQuery, FilterPlugin, SortingPlugin, PaginationPlugin);

// A user field named with a leading underscore is a field, through every plugin
unittest {
    enum sdl = generateSchemaSDL!MvSchema;
    static assert(sdl.canFind("_nick: String!"), sdl);
    // ...but library internals (members that are not fields) are not
    static assert(!sdl.canFind("__"), sdl);

    auto introspection = awaitSync(new Executor().execute(compileQuery!MvSchema(
        `{ __schema { types { name fields { name } inputFields { name } } } }`)));
    foreach (type; introspection["__schema"]["types"].array)
        foreach (kind; ["fields", "inputFields"])
            if (type[kind].type == JSONType.array)
                foreach (field; type[kind].array)
                    assert(!field["name"].str.canFind("__"), type.toString());

    mvDb = new MockDB!();
    mvDb.setTableData("mv_authors", `[{"id": 1, "nick": "al"}, {"id": 2, "nick": "bo"}]`);
    mvDb.setTableData("mv_posts", `[{"id": 10, "author_id": 2}]`);

    foreach (optimize; [false, true]) {
        auto filtered = awaitSync(new Executor().execute(compileQuery!MvSchema(
            `{ authors(filter: {_nick: {equalTo: "bo"}}) { id _nick } }`), optimize));
        assert(filtered["authors"] == JSONValue([JSONValue(["id": JSONValue(2), "_nick": JSONValue("bo")])]),
            filtered.toString());
    }

    foreach (optimize; [false, true]) {
        auto result = awaitSync(new Executor().execute(compileQuery!MvSchema(
            `{ authors(orderBy: [{field: _nick, direction: DESC}]) { _nick } posts { author { _nick } } }`), optimize));
        assert(result["authors"] == JSONValue([JSONValue(["_nick": JSONValue("bo")]), JSONValue(["_nick": JSONValue("al")])]),
            result.toString());
        assert(result["posts"][0]["author"]["_nick"] == JSONValue("bo"), result.toString());
    }
}
