/**
 * Shared Test Schema
 *
 * Common entity definitions used by all integration tests.
 * Parameterized by the database type.
 */
module integration.schema;

import std.json : JSONValue;
import std.typecons : Nullable;

import graphqld2.core;
import graphqld2.core.expr : ternary;
import graphqld2.relational.schema : Table, ForeignKey, BelongsTo, HasMany, Col;
import graphqld2.relational.demo : DemoEntity, CrudMutations;
import graphqld2.relational.mutation : insert;

import std.stdio : writeln, writefln;
import integration.test_framework : graphql, assertNoErrors;

/// Task status enum for testing enum support
enum TaskStatus {
    pending,
    inProgress,
    completed,
    cancelled
}

/// Seed the database with test data via GraphQL mutations.
/// Works with any backend since it uses the HTTP API.
void seedDatabase() {
    writeln("Seeding data via mutations...");

    // Create users with different ages for testing logic expressions
    // Alice: age 25 (adult)
    auto alice = graphql(`mutation { createUserWithAge(firstName: "Alice", lastName: "Smith", age: 25) { id } }`);
    assertNoErrors(alice);
    auto aliceId = alice["data"]["createUserWithAge"]["id"];
    writefln("  Created Alice age=25 (id=%s)", aliceId);

    // Bob: age 15 (teenager)
    auto bob = graphql(`mutation { createUserWithAge(firstName: "Bob", lastName: "Jones", age: 15) { id } }`);
    assertNoErrors(bob);
    auto bobId = bob["data"]["createUserWithAge"]["id"];
    writefln("  Created Bob age=15 (id=%s)", bobId);

    // Charlie: age 8 (child)
    auto charlie = graphql(`mutation { createUserWithAge(firstName: "Charlie", lastName: "Brown", age: 8) { id } }`);
    assertNoErrors(charlie);
    auto charlieId = charlie["data"]["createUserWithAge"]["id"];
    writefln("  Created Charlie age=8 (id=%s)", charlieId);

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

    // Create tasks with different statuses
    auto task1 = graphql(`mutation { createTask(input: {title: "Write tests", status: "pending", assignee_id: ` ~ aliceId.toString() ~ `}) { id } }`);
    assertNoErrors(task1);
    writeln("  Created task: Write tests (pending)");

    auto task2 = graphql(`mutation { createTask(input: {title: "Review PR", status: "inProgress", assignee_id: ` ~ aliceId.toString() ~ `}) { id } }`);
    assertNoErrors(task2);
    writeln("  Created task: Review PR (inProgress)");

    auto task3 = graphql(`mutation { createTask(input: {title: "Deploy app", status: "completed", assignee_id: ` ~ bobId.toString() ~ `}) { id } }`);
    assertNoErrors(task3);
    writeln("  Created task: Deploy app (completed)");

    writeln("Seeding complete.");
}

/// Generate the test schema for a given database instance.
/// Usage: mixin TestSchema!db;
mixin template TestSchema(alias db) {
    import std.json : JSONValue;
    import std.typecons : Nullable;
    import graphqld2.core.expr : Expr;
    import graphqld2.graphql : Schema, SortingPlugin;
    import graphqld2.relational.schema : Table, ForeignKey, BelongsTo, HasMany, Col, getAll, hasMany;
    import graphqld2.relational.demo : DemoEntity, CrudMutations;
    import graphqld2.relational.mutation : insert;

    struct User {
        mixin DemoEntity!(db, "users");
        mixin Col!("firstName", string);
        mixin Col!("lastName", string);
        mixin Col!("age", int);
        mixin HasMany!("posts", Post, "author_id");

        /// Computed field: full name concatenation
        static auto fullName(Expr!User u) {
            return u.firstName ~ " " ~ u.lastName;
        }

        /// Computed field: is user an adult (age >= 18)?
        static auto isAdult(Expr!User u) {
            return u.age.ge(18);
        }

        /// Computed field: is user a teenager (13 <= age < 20)?
        static auto isTeenager(Expr!User u) {
            return u.age.ge(13).and(u.age.lt(20));
        }

        /// Computed field: age category based on ternary expressions
        static auto ageCategory(Expr!User u) {
            import graphqld2.core.expr : ternary;
            return ternary(u.age.lt(13), "child",
                   ternary(u.age.lt(20), "teen", "adult"));
        }
    }

    struct Post {
        mixin DemoEntity!(db, "posts");
        mixin Col!("title", string);
        mixin Col!("authorId", ForeignKey!User);
        mixin BelongsTo!("author", "authorId");
    }

    struct Task {
        mixin DemoEntity!(db, "tasks");
        mixin Col!("title", string);
        mixin Col!("status", TaskStatus);
        mixin Col!("assigneeId", Nullable!(ForeignKey!User));
        mixin BelongsTo!("assignee", "assigneeId");
    }

    struct Query {
        mixin Table!(User, "users");
        mixin Table!(Post, "posts");
        mixin Table!(Task, "tasks");
    }

    struct Mutation {
        mixin CrudMutations!User;
        mixin CrudMutations!Post;
        mixin CrudMutations!Task;

        static auto createUserWithName(Expr!Mutation parent, string firstName, string lastName) {
            return insert!User([
                "first_name": JSONValue(firstName),
                "last_name": JSONValue(lastName),
                "age": JSONValue(25)  // Default age
            ]);
        }

        /// Create user with explicit age for testing logic expressions
        static auto createUserWithAge(Expr!Mutation parent, string firstName, string lastName, int age) {
            return insert!User([
                "first_name": JSONValue(firstName),
                "last_name": JSONValue(lastName),
                "age": JSONValue(age)
            ]);
        }
    }

    alias BaseSchema = Schema!(Query, Mutation);
    alias MySchema = SortingPlugin!BaseSchema;
}
