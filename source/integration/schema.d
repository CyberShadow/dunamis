/**
 * Shared Test Schema
 *
 * Common entity definitions used by all integration tests.
 * Parameterized by the database type.
 */
module integration.schema;

import std.json : JSONValue;
import std.typecons : Nullable;

import dynamo.core;
import dynamo.core.expr : ternary, some, every;
import dynamo.relational.schema : Table, ForeignKey, BelongsTo, HasMany, Col;
import dynamo.relational.demo : DemoEntity, CrudMutations;
import dynamo.relational.mutation : insert;

import std.stdio : writeln, writefln;
import integration.test_framework : graphql, assertNoErrors;

/// Task status enum for testing enum support
enum TaskStatus {
    pending,
    inProgress,
    completed,
    cancelled
}

/// Recursive filter input type (tests self-referential via array)
struct FilterInput {
    Nullable!string field;
    Nullable!string equals;
    FilterInput[] and;  // Self-reference via array
    FilterInput[] or;   // Self-reference via array
}

/// Linked list node (tests self-referential via pointer)
struct NodeInput {
    string value;
    NodeInput* next;  // Self-reference via pointer
}

/// POD struct for testing type discovery (returned by plain method)
struct UserStats {
    int postCount;
    int commentCount;

    /// Plain method on POD struct
    int totalActivity() => postCount + commentCount;
}

/// Seed the database with test data via GraphQL mutations.
/// Works with any backend since it uses the HTTP API.
void seedDatabase() {
    writeln("Seeding data via mutations...");

    // Create users with different ages for testing logic expressions
    // Alice: age 25 (adult), with nickname for testing eager fields
    auto alice = graphql(`mutation { createUserWithNickname(firstName: "Alice", lastName: "Smith", age: 25, nickname: "Ally") { id } }`);
    assertNoErrors(alice);
    auto aliceId = alice["data"]["createUserWithNickname"]["id"];
    writefln("  Created Alice age=25 nickname=Ally (id=%s)", aliceId);

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

    // Create comments (for multi-hop belongsTo testing: comment -> post -> author)
    auto post1Id = post1["data"]["createPost"]["id"];
    auto comment1 = graphql(`mutation { createComment(input: {body: "Great post!", post_id: ` ~ post1Id.toString() ~ `, author_id: ` ~ bobId.toString() ~ `}) { id } }`);
    assertNoErrors(comment1);
    writeln("  Created comment: Great post! (by Bob on Hello World)");

    auto comment2 = graphql(`mutation { createComment(input: {body: "Thanks for sharing", post_id: ` ~ post2["data"]["createPost"]["id"].toString() ~ `, author_id: ` ~ charlieId.toString() ~ `}) { id } }`);
    assertNoErrors(comment2);
    writeln("  Created comment: Thanks for sharing (by Charlie on GraphQL Rocks)");

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
    import dynamo.core.expr : Expr;
    import dynamo.graphql : Schema, SortingPlugin, FilterPlugin;
    import dynamo.graphql.schema : GqlName;
    import dynamo.relational.schema : Table, ForeignKey, BelongsTo, HasMany, Col, getAll, hasMany;
    import dynamo.relational.demo : DemoEntity, CrudMutations;
    import dynamo.relational.mutation : insert;

    struct User {
        mixin DemoEntity!(db, "users");
        mixin Col!("firstName", string);
        mixin Col!("lastName", string);
        mixin Col!("age", int);
        mixin HasMany!("posts", Post, "author_id");

        /// Plain field: populated when entity is fetched (not via lazy column access)
        Nullable!string nickname;

        /// Plain method: display name based on nickname
        string displayName() {
            return nickname.isNull ? "Anonymous" : nickname.get;
        }

        /// Plain method: check if user has a nickname
        bool hasNickname() => !nickname.isNull;

        /// Plain method returning POD struct (tests type discovery)
        UserStats stats() => UserStats(42, 99);

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
            import dynamo.core.expr : ternary;
            return ternary(u.age.lt(13), "child",
                   ternary(u.age.lt(20), "teen", "adult"));
        }

        /// Computed field: does this user have any posts? (tests some)
        static auto hasPosts(Expr!User u) {
            import dynamo.core.expr : some;
            return some!((Expr!Post p) => p.title.ne(""))(u.posts);
        }

        /// Computed field: do all posts have titles? (tests every)
        /// Note: For users with no posts, this returns true (vacuous truth)
        static auto allPostsTitled(Expr!User u) {
            import dynamo.core.expr : every;
            return every!((Expr!Post p) => p.title.ne(""))(u.posts);
        }

        /// Test recursive input: returns user's firstName (simplified test)
        /// Real impl would apply filter logic
        static auto matchesFilter(Expr!User u, FilterInput filter) {
            return u.firstName;
        }

        /// Test pointer input: returns user's firstName (simplified test)
        /// Real impl would traverse the linked list
        static auto traverseList(Expr!User u, NodeInput* head) {
            return u.firstName;
        }
    }

    struct Post {
        mixin DemoEntity!(db, "posts");
        mixin Col!("title", string);
        mixin Col!("authorId", ForeignKey!User);
        mixin BelongsTo!("author", "authorId");
        mixin HasMany!("comments", Comment, "post_id");

        /// Computed field: is the author an adult? (tests pushdown through BelongsTo)
        static auto authorIsAdult(Expr!Post p) {
            return p.author.age.ge(18);
        }

        /// Computed field: author's age category (tests ternary pushdown through BelongsTo)
        static auto authorAgeCategory(Expr!Post p) {
            import dynamo.core.expr : ternary;
            return ternary(p.author.age.lt(13), "child",
                   ternary(p.author.age.lt(20), "teen", "adult"));
        }
    }

    struct Comment {
        mixin DemoEntity!(db, "comments");
        @GqlName("body") mixin Col!("body_", string, "body");
        mixin Col!("postId", ForeignKey!Post);
        mixin Col!("authorId", ForeignKey!User);
        mixin BelongsTo!("post", "postId");
        mixin BelongsTo!("author", "authorId");

        /// Computed field: 2-hop belongsTo chain (comment -> post -> author)
        static auto postAuthorName(Expr!Comment c) {
            return c.post.author.fullName;
        }
    }

    struct Task {
        mixin DemoEntity!(db, "tasks");
        mixin Col!("title", string);
        mixin Col!("status", TaskStatus);
        mixin Col!("assigneeId", Nullable!(ForeignKey!User));
        mixin BelongsTo!("assignee", "assigneeId");

        /// Computed field: is this task unassigned? (tests isNull)
        static auto isUnassigned(Expr!Task t) {
            return t.assigneeId.isNull();
        }

        /// Computed field: is this task assigned? (tests isNotNull convenience)
        static auto isAssigned(Expr!Task t) {
            return t.assigneeId.isNotNull();
        }
    }

    struct Query {
        mixin Table!(User, "users");
        mixin Table!(Post, "posts");
        mixin Table!(Comment, "comments");
        mixin Table!(Task, "tasks");
    }

    struct Mutation {
        mixin CrudMutations!User;
        mixin CrudMutations!Post;
        mixin CrudMutations!Comment;
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

        /// Create user with nickname for testing eager fields
        static auto createUserWithNickname(Expr!Mutation parent, string firstName, string lastName, int age, string nickname) {
            return insert!User([
                "first_name": JSONValue(firstName),
                "last_name": JSONValue(lastName),
                "age": JSONValue(age),
                "nickname": JSONValue(nickname)
            ]);
        }
    }

    alias BaseSchema = Schema!(Query, Mutation);
    // Compose FilterPlugin and SortingPlugin: filter first, then sort
    alias MySchema = SortingPlugin!(FilterPlugin!BaseSchema);
}
