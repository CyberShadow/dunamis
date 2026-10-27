/**
 * Shared Test Schema
 *
 * Common entity definitions used by all integration tests.
 * Parameterized by the database type.
 */
module integration.schema;

import std.json : JSONValue;
import std.typecons : Nullable;

import dunamis.core;
import dunamis.core.expr : ternary, some, every;
import dunamis.relational.schema : Table, ForeignKey, BelongsTo, HasMany, Col;
import dunamis.relational.demo : DemoEntity, DemoId;
import dunamis.relational.mutation : insert;

import std.stdio : writeln, writefln;
import integration.test_framework : graphql, assertNoErrors;

/// Request context for testing request-scoped data in computed fields
struct RequestContext {
    string locale;
}

/// Request context: what an interleaved evaluation is about (see `viewer`).
struct Viewing {
    long userId;
    long taskId;
}

/// A POD returned in a nullable list
struct Label {
    string text;
}

// ============================================================================
// Interleaving (for evaluating one optimized tree for several requests)
// ============================================================================

import dunamis.core.expr : Expr, ExprBase, evalAs;
import dunamis.core.optimize : OptimizeContext;
import ae.utils.promise : Promise;

/// Lets several evaluations ("participants") of the same tree interleave
/// deterministically: a gated expression of a participant waits until every
/// participant that has not finished is waiting at a gate, and is then
/// released together with all of them. So each participant evaluates past a
/// gate only once all of them have evaluated everything before their gates —
/// e.g. bound the objects whose fields the gates guard.
final class InterleaveBarrier {
    private Promise!void[][] _waiting;
    private bool[] _finished;

    this(size_t participants) {
        _waiting.length = participants;
        _finished.length = participants;
    }

    /// A gate for `participant`.
    Promise!void wait(size_t participant) {
        auto gate = new Promise!void;
        _waiting[participant] ~= gate;
        check();
        return gate;
    }

    /// Record that `participant` finished its evaluation.
    void finish(size_t participant) {
        _finished[participant] = true;
        check();
    }

    private void check() {
        foreach (i, waiting; _waiting)
            if (!_finished[i] && waiting.length == 0)
                return;
        foreach (ref waiting; _waiting) {
            auto gates = waiting;
            waiting = null;
            foreach (gate; gates)
                gate.fulfill();
        }
    }
}

/// Request context identifying a participant of an InterleaveBarrier.
struct InterleaveGate {
    InterleaveBarrier barrier;
    size_t participant;
}

/// Evaluates its input once the participant's gate opens (immediately when
/// not evaluated as a participant).
final class GatedExpr(T) : Expr!T {
    import dunamis.core.eval : EvalContext;

    private ExprBase _input;

    this(Expr!T input) { _input = input; }

    override ExprBase[] dependencies() { return [_input]; }
    override void replaceDependency(size_t index, ExprBase dep) { _input = dep; }
    override Expr!T optimize(OptimizeContext ctx) {
        _input = (cast(Expr!T) _input).optimize(ctx);
        return this;
    }

    override Promise!(T[]) eval(EvalContext ctx) {
        auto input = _input;
        if (!ctx.hasRequestContext!InterleaveGate)
            return evalAs!T(input, ctx);
        auto gate = ctx.getRequestContext!InterleaveGate;
        return gate.barrier.wait(gate.participant).then(() => evalAs!T(input, ctx));
    }
}

Expr!T gated(T)(Expr!T input) { return new GatedExpr!T(input); }

/// Task status enum for testing enum support
enum TaskStatus {
    pending,
    inProgress,
    @StoredAs("done") completed,  // Stored under a label other than its name
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

    // Create posts (auto-generated CRUD with input objects)
    auto post1 = graphql(`mutation { createPost(input: {title: "Hello World", authorId: ` ~ aliceId.toString() ~ `}) { id } }`);
    assertNoErrors(post1);
    writeln("  Created post: Hello World");

    auto post2 = graphql(`mutation { createPost(input: {title: "GraphQL Rocks", authorId: ` ~ aliceId.toString() ~ `}) { id } }`);
    assertNoErrors(post2);
    writeln("  Created post: GraphQL Rocks");

    auto post3 = graphql(`mutation { createPost(input: {title: "D Programming", authorId: ` ~ bobId.toString() ~ `}) { id } }`);
    assertNoErrors(post3);
    writeln("  Created post: D Programming");

    // Create comments (for multi-hop belongsTo testing: comment -> post -> author)
    auto post1Id = post1["data"]["createPost"]["id"];
    auto comment1 = graphql(`mutation { createComment(input: {body: "Great post!", postId: ` ~ post1Id.toString() ~ `, authorId: ` ~ bobId.toString() ~ `}) { id } }`);
    assertNoErrors(comment1);
    writeln("  Created comment: Great post! (by Bob on Hello World)");

    auto comment2 = graphql(`mutation { createComment(input: {body: "Thanks for sharing", postId: ` ~ post2["data"]["createPost"]["id"].toString() ~ `, authorId: ` ~ charlieId.toString() ~ `}) { id } }`);
    assertNoErrors(comment2);
    writeln("  Created comment: Thanks for sharing (by Charlie on GraphQL Rocks)");

    // Create tasks with different statuses
    auto task1 = graphql(`mutation { createTask(input: {title: "Write tests", status: pending, assigneeId: ` ~ aliceId.toString() ~ `}) { id } }`);
    assertNoErrors(task1);
    writeln("  Created task: Write tests (pending)");

    auto task2 = graphql(`mutation { createTask(input: {title: "Review PR", status: inProgress, assigneeId: ` ~ aliceId.toString() ~ `}) { id } }`);
    assertNoErrors(task2);
    writeln("  Created task: Review PR (inProgress)");

    auto task3 = graphql(`mutation { createTask(input: {title: "Deploy app", status: completed, assigneeId: ` ~ bobId.toString() ~ `}) { id } }`);
    assertNoErrors(task3);
    writeln("  Created task: Deploy app (completed)");

    // Create tags (composite PK: category + name)
    auto tag1 = graphql(`mutation { createTag(category: "language", name: "D", description: "D programming language") { category name } }`);
    assertNoErrors(tag1);
    writeln("  Created tag: language/D");

    auto tag2 = graphql(`mutation { createTag(category: "language", name: "Rust", description: "Rust programming language") { category name } }`);
    assertNoErrors(tag2);
    writeln("  Created tag: language/Rust");

    auto tag3 = graphql(`mutation { createTag(category: "tool", name: "GraphQL", description: "Query language for APIs") { category name } }`);
    assertNoErrors(tag3);
    writeln("  Created tag: tool/GraphQL");

    // Create user badges (composite PK: user_id + badge_name)
    auto badge1 = graphql(`mutation { createUserBadge(userId: ` ~ aliceId.toString() ~ `, badgeName: "contributor", description: "Active contributor") { userId badgeName } }`);
    assertNoErrors(badge1);
    writeln("  Created badge: Alice/contributor");

    auto badge2 = graphql(`mutation { createUserBadge(userId: ` ~ aliceId.toString() ~ `, badgeName: "reviewer", description: "Code reviewer") { userId badgeName } }`);
    assertNoErrors(badge2);
    writeln("  Created badge: Alice/reviewer");

    auto badge3 = graphql(`mutation { createUserBadge(userId: ` ~ bobId.toString() ~ `, badgeName: "contributor", description: "Active contributor") { userId badgeName } }`);
    assertNoErrors(badge3);
    writeln("  Created badge: Bob/contributor");

    writeln("Seeding complete.");
}

/// Generate the test schema for a given database instance.
/// Usage: mixin TestSchema!db;
mixin template TestSchema(alias db) {
    import std.json : JSONValue;
    import std.typecons : Nullable;
    import dunamis.core.expr : Expr, context, use;
    import dunamis.core.expr.combinators : unionOf;
    import dunamis.core.types : ImplementedBy, AbstractField;
    import dunamis.graphql : Schema, SortingPlugin, FilterPlugin, PaginationPlugin, CrudMutationPlugin, ApplyPlugins;
    import dunamis.graphql.schema : GqlName;
    import dunamis.relational.schema : Table, ForeignKey, BelongsTo, HasMany, Col, getAll, hasMany;
    import dunamis.relational.demo : DemoEntity, DemoId, Int64;
    import dunamis.relational.mutation : insert;

    @DemoEntity!(db, "users")
    struct User {
        mixin DemoId;
        mixin Col!("firstName", string);
        mixin Col!("lastName", string);
        mixin Col!("age", int);
        mixin HasMany!("posts", Post, "author_id");
        /// Children with a composite key, keyed on part of it and ordered by the rest
        mixin HasMany!("badges", UserBadge, "user_id", ["badge_name"]);

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
            import dunamis.core.expr : ternary;
            return ternary(u.age.lt(13), "child",
                   ternary(u.age.lt(20), "teen", "adult"));
        }

        /// Computed field: does this user have any posts? (tests some)
        static auto hasPosts(Expr!User u) {
            import dunamis.core.expr : some;
            return some!((Expr!Post p) => p.title.ne(""))(u.posts);
        }

        /// Computed field: do all posts have titles? (tests every)
        /// Note: For users with no posts, this returns true (vacuous truth)
        static auto allPostsTitled(Expr!User u) {
            import dunamis.core.expr : every;
            return every!((Expr!Post p) => p.title.ne(""))(u.posts);
        }

        /// Computed field using request context for localization.
        static auto localizedGreeting(Expr!User u) {
            return use(
                (string firstName, .RequestContext reqCtx) {
                    if (reqCtx.locale == "fr") return "Bonjour " ~ firstName;
                    if (reqCtx.locale == "es") return "Hola " ~ firstName;
                    return "Hello " ~ firstName;
                },
                u.firstName,
                context!(.RequestContext)(u)
            );
        }

        /// Computed field that always throws (for testing error path tracking)
        static auto failingField(Expr!User u) {
            return use(
                (string firstName) {
                    throw new Exception("intentional error in failingField");
                    return "";
                },
                u.firstName
            );
        }

        /// Computed field with two inputs: the first fails for the whole
        /// batch as soon as the user's first name is known, while the second
        /// still needs several dependent round trips (posts, their authors,
        /// those authors' posts' titles). The field's error must not let the
        /// request finish — and its session be torn down — while the second
        /// input is still querying.
        static auto failsBesideSlowSibling(Expr!User u) {
            import dunamis.core.expr : map;
            return use(
                (string failed, string[][] coAuthorTitles) => failed,
                failingField(u),
                map!((Expr!Post p) => map!((Expr!Post q) => q.title)(p.author.posts))(u.posts)
            );
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

        // Fields evaluated past an interleaving gate (see InterleaveBarrier)
        static auto gatedId(Expr!User u) { return gated(use((User x) => x.id.value, u)); }
        static auto gatedFirstName(Expr!User u) { return gated(u.firstName); }

        /// A nullable list of objects: null for users without posts
        static auto gatedPostLabels(Expr!User u) {
            import std.conv : to;
            import dunamis.core.expr : map;
            return gated(use((string name, string[] titles) => titles.length == 0
                    ? Nullable!(.Label[]).init
                    : Nullable!(.Label[])([.Label(name ~ ": " ~ titles.length.to!string)]),
                u.firstName, map!((Expr!Post p) => p.title)(u.posts)));
        }

        /// Every user's full name (a root collection with an SQL computed
        /// column), for a single user.
        static auto everyonesFullName(Expr!User u) {
            import dunamis.core.expr : map;
            return use((string[] names, string _) => names,
                map!((Expr!User x) => x.fullName)(getAll!User()), u.firstName);
        }
    }

    @DemoEntity!(db, "posts")
    struct Post {
        mixin DemoId;
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
            import dunamis.core.expr : ternary;
            return ternary(p.author.age.lt(13), "child",
                   ternary(p.author.age.lt(20), "teen", "adult"));
        }
    }

    @DemoEntity!(db, "comments")
    struct Comment {
        mixin DemoId;
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

    @DemoEntity!(db, "tasks")
    struct Task {
        mixin DemoId;
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

        // Fields evaluated past an interleaving gate (see InterleaveBarrier)
        static auto gatedTitle(Expr!Task t) { return gated(t.title); }
        /// A nullable object
        static auto gatedAssignee(Expr!Task t) { return gated(t.assignee); }
    }

    /// Composite primary key entity: Tag with (category, name) PK
    @DemoEntity!(db, "tags")
    struct Tag {
        import dunamis.relational.schema.attrs : PrimaryKey, SqlColumn;

        @PrimaryKey @SqlColumn("category") string category;
        @PrimaryKey @SqlColumn("name") string name;
        string description;
    }

    /// Composite primary key entity with BelongsTo relationship
    /// PK is (user_id, badge_name), and user_id is also an FK to User
    @DemoEntity!(db, "user_badges")
    struct UserBadge {
        import dunamis.relational.schema.attrs : ForeignKeyRef, PrimaryKey, SqlColumn;

        @PrimaryKey @SqlColumn("user_id") @ForeignKeyRef!User long userId;
        @PrimaryKey @SqlColumn("badge_name") string badgeName;
        mixin Col!("description", string);
        mixin BelongsTo!("user", "userId");
    }

    /// Union type: SearchResult = User | Post
    @ImplementedBy!(User, Post)
    struct SearchResult {}

    /// Interface type: ContentNode (has id field, implemented by User and Post)
    @ImplementedBy!(User, Post)
    struct ContentNode {
        mixin AbstractField!("id", long);
    }

    struct Query {
        mixin Table!(User, "users");
        mixin Table!(Post, "posts");
        mixin Table!(Comment, "comments");
        mixin Table!(Task, "tasks");
        mixin Table!(Tag, "tags");
        mixin Table!(UserBadge, "userBadges");

        /// Returns all users and posts as a union
        static auto search(Expr!Query q) {
            return unionOf!SearchResult(users(q), posts(q));
        }

        /// Returns all users and posts as an interface
        static auto contentNodes(Expr!Query q) {
            return unionOf!ContentNode(users(q), posts(q));
        }

        /// Each post's author: a map whose elements are not the root rows
        static auto postAuthors(Expr!Query q) {
            import dunamis.core.expr : map;
            return map!((Expr!Post p) => p.author)(posts(q));
        }

        /// The user a request is about (a non-null object)
        static auto viewer(Expr!Query q) {
            return use((.Viewing v) => User(Int64(v.userId)), context!(.Viewing)(q));
        }

        /// The task a request is about
        static auto viewerTask(Expr!Query q) {
            return use((.Viewing v) => Task(Int64(v.taskId)), context!(.Viewing)(q));
        }
    }

    struct Mutation {
        /// The badge with the given key, built from it: an entity with a
        /// composite key returned by a mutation field, its columns read by key
        static Expr!UserBadge badgeByKey(Expr!Mutation m, Int64 userId, string badgeName) {
            import dunamis.core.expr : effect;
            return effect(() => UserBadge(userId.value, badgeName), m);
        }

        /// ditto, a list of them, with nulls for the empty names
        static Expr!(Nullable!UserBadge[]) badgesByKeys(Expr!Mutation m, Int64 userId, string[] badgeNames) {
            import dunamis.core.expr : effect;
            return effect(() {
                Nullable!UserBadge[] badges;
                foreach (name; badgeNames)
                    badges ~= name.length ? Nullable!UserBadge(UserBadge(userId.value, name)) : Nullable!UserBadge.init;
                return badges;
            }, m);
        }

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

        /// Create tag (composite PK: category + name)
        static auto createTag(Expr!Mutation parent, string category, string name, string description) {
            return insert!Tag([
                "category": JSONValue(category),
                "name": JSONValue(name),
                "description": JSONValue(description)
            ]);
        }

        /// Create user badge (composite PK: user_id + badge_name)
        static auto createUserBadge(Expr!Mutation parent, Int64 userId, string badgeName, string description) {
            return insert!UserBadge([
                "user_id": JSONValue(userId.value),
                "badge_name": JSONValue(badgeName),
                "description": JSONValue(description)
            ]);
        }
    }

    struct Subscription {
        import dunamis.core.expr.combinators : eventSource;

        static Expr!User userCreated(Expr!Subscription s) {
            return eventSource!User();
        }
    }

    // Computed fields from free functions (ComputedFieldsPlugin), which the
    // query plugins applied after it filter and sort on: in SQL where the
    // condition or ordering can be expressed there, in memory otherwise.
    // CrudMutationPlugin, which leaves the entity types as Schema made them,
    // goes before it: it casts the rows it writes to those types directly.

    /// The number of the user's posts (only computable in memory)
    auto postCount(Expr!User u) {
        import dunamis.core.expr : map;
        return use((string[] titles) => cast(int) titles.length, map!((Expr!Post p) => p.title)(u.posts));
    }

    /// "Last, First" (an expression on columns, compared in memory)
    auto surnameFirst(Expr!User u) {
        return u.lastName ~ ", " ~ u.firstName;
    }

    /// The user's age (a column, filtered and sorted in SQL)
    auto years(Expr!User u) {
        return u.age;
    }

    /// The age of the post's author (a related row's column: filtered in SQL)
    auto authorAge(Expr!Post p) {
        return p.author.age;
    }

    /// Every user's first name: a global root of the table the client's
    /// query also selects from, broadcast to each comment
    Expr!(string[]) everyonesFirstNames(Expr!Comment c) {
        import dunamis.core.expr : broadcast, map, singleton;
        return broadcast(map!userFirstName(Query().singleton().users()), c);
    }

    private Expr!string userFirstName(Expr!User u) {
        return u.firstName;
    }

    /// The users with another first name: a computed root field over
    /// another root field, whose condition is pushed into SQL, and which the
    /// query plugins extend like `users`
    Expr!(User[]) usersExcept(Expr!Query q, string firstName) {
        import dunamis.core.filtering : filterBy;
        return filterBy!((Expr!User u) => u.firstName.ne(firstName))(Query.users(q));
    }

    /// The number of users with another first name (a computed root field
    /// over another computed root field)
    Expr!int countExcept(Expr!Query q, string firstName) {
        import dunamis.core.expr : map;
        return use((string[] names) => cast(int) names.length, map!userFirstName(usersExcept(q, firstName)));
    }

    import dunamis.schema.computed : ComputedFieldsPlugin;
    alias TestComputedFields = ComputedFieldsPlugin!(postCount, surnameFirst, years, authorAge, everyonesFirstNames,
        usersExcept, countExcept);

    alias BaseSchema = Schema!(Query, Mutation, Subscription);
    alias MySchema = ApplyPlugins!(BaseSchema, CrudMutationPlugin, TestComputedFields, FilterPlugin, SortingPlugin, PaginationPlugin);
    /// The same with FilterPlugin last (filters apply to the requested
    /// window), served for requests with an `X-Plugin-Order: filter-last`
    /// header.
    alias FilterLastSchema = ApplyPlugins!(BaseSchema, CrudMutationPlugin, TestComputedFields, SortingPlugin, PaginationPlugin, FilterPlugin);
}
