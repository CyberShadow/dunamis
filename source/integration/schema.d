/**
 * Shared Test Schema
 *
 * Common entity definitions used by all integration tests.
 * Parameterized by the database type.
 */
module integration.schema;

import std.json : JSONValue;

import graphqld2.core;
import graphqld2.graphql : Schema;
import graphqld2.relational.schema : Table, ForeignKey, BelongsTo, HasMany, Col;
import graphqld2.relational.demo : DemoEntity, CrudMutations;
import graphqld2.relational.mutation : insert;

import std.stdio : writeln, writefln;
import integration.test_framework : graphql, assertNoErrors;

/// Seed the database with test data via GraphQL mutations.
/// Works with any backend since it uses the HTTP API.
void seedDatabase() {
    writeln("Seeding data via mutations...");

    // Create users
    auto alice = graphql(`mutation { createUserWithName(firstName: "Alice", lastName: "Smith") { id } }`);
    assertNoErrors(alice);
    auto aliceId = alice["data"]["createUserWithName"]["id"];
    writefln("  Created Alice (id=%s)", aliceId);

    auto bob = graphql(`mutation { createUserWithName(firstName: "Bob", lastName: "Jones") { id } }`);
    assertNoErrors(bob);
    auto bobId = bob["data"]["createUserWithName"]["id"];
    writefln("  Created Bob (id=%s)", bobId);

    // Create posts
    auto post1 = graphql(`mutation { createPost(input: {title: "Hello World", author_id: ` ~ aliceId.toString() ~ `}) { id } }`);
    assertNoErrors(post1);
    writeln("  Created post: Hello World");

    auto post2 = graphql(`mutation { createPost(input: {title: "GraphQL Rocks", author_id: ` ~ aliceId.toString() ~ `}) { id } }`);
    assertNoErrors(post2);
    writeln("  Created post: GraphQL Rocks");

    auto post3 = graphql(`mutation { createPost(input: {title: "D Programming", author_id: ` ~ bobId.toString() ~ `}) { id } }`);
    assertNoErrors(post3);
    writeln("  Created post: D Programming");

    writeln("Seeding complete.");
}

/// Generate the test schema for a given database instance.
/// Usage: mixin TestSchema!db;
mixin template TestSchema(alias db) {
    import std.json : JSONValue;
    import graphqld2.core.expr : Expr;
    import graphqld2.graphql : Schema;
    import graphqld2.relational.schema : Table, ForeignKey, BelongsTo, HasMany, Col, getAll, hasMany;
    import graphqld2.relational.demo : DemoEntity, CrudMutations;
    import graphqld2.relational.mutation : insert;

    struct User {
        mixin DemoEntity!(db, "users");
        mixin Col!("firstName", string);
        mixin Col!("lastName", string);
        mixin HasMany!("posts", Post, "author_id");

        static auto fullName(Expr!User u) {
            return u.firstName ~ " " ~ u.lastName;
        }
    }

    struct Post {
        mixin DemoEntity!(db, "posts");
        mixin Col!("title", string);
        mixin Col!("authorId", ForeignKey!User);
        mixin BelongsTo!("author", "authorId");
    }

    struct Query {
        mixin Table!(User, "users");
        mixin Table!(Post, "posts");
    }

    struct Mutation {
        mixin CrudMutations!User;
        mixin CrudMutations!Post;

        static auto createUserWithName(Expr!Mutation parent, string firstName, string lastName) {
            return insert!User([
                "first_name": JSONValue(firstName),
                "last_name": JSONValue(lastName)
            ]);
        }
    }

    alias MySchema = Schema!(Query, Mutation);
}
