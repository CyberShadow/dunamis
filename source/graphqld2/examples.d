module graphqld2.examples;

import std.algorithm;
import std.array;
import std.conv;
import std.json;

import graphqld2.core;
import graphqld2.relational;

// ============================================================================
// Schema Definition - Query root with all entry points
// ============================================================================

/// The Query root - defines all entry points into the schema.
/// This mirrors what a GraphQL schema's Query type would look like.
struct Query {
    mixin Table!(User, "users");
    mixin Table!(Post, "posts");
    mixin Table!(Comment, "comments");
}

// ============================================================================
// Domain Model - Demonstrates business logic with relationships
// ============================================================================

/// User entity
struct User {
    mixin Entity!"users";
    mixin Col!("firstName", string);
    mixin Col!("lastName", string);
    mixin Col!("email", string);
    mixin HasMany!("posts", Post, "author_id");
    mixin HasMany!("comments", Comment, "author_id");

    /// Computed field using operator overloading
    static auto fullName(Expr!Ref u) => firstName(u) ~ " " ~ lastName(u);
}

/// Post entity - belongs to a User (author) and has many Comments
struct Post {
    mixin Entity!"posts";
    mixin Col!("title", string);
    mixin Col!("body_", string, "body");  // D keyword, explicit column name
    mixin Col!("authorId", long);
    mixin BelongsTo!("author", User, "author_id");
    mixin HasMany!("comments", Comment, "post_id");

    /// Computed: render full post as HTML with author and comments
    static auto html(Expr!Ref p) {
        return use(
            (string title, string body_, string authorName, string[] commentHtmls) {
                auto commentsHtml = commentHtmls.join("\n");
                return `<article class="post">
                <header>
                    <h1>` ~ title ~ `</h1>
                    <p class="byline">By ` ~ authorName ~ `</p>
                </header>
                <div class="content">` ~ body_ ~ `</div>
                <section class="comments">
                    <h2>Comments (` ~ commentHtmls.length.to!string ~ `)</h2>
                    ` ~ commentsHtml ~ `
                </section>
            </article>`;
            },
            title(p),
            body_(p),
            User.fullName(author(p)),
            map!(
                (Expr!Ref c) => Comment.html(c)
            )(comments(p))
        );
    }

    /// Computed: short summary for listings
    static auto summary(Expr!Ref p) {
        return use(
            (string title, string body_, string authorName) {
                auto truncated = body_.length > 100 ? body_[0..100] ~ "..." : body_;
                return title ~ " by " ~ authorName ~ " - " ~ truncated;
            },
            title(p),
            body_(p),
            User.fullName(author(p))
        );
    }
}

/// Comment entity - belongs to a Post and has an author (User)
struct Comment {
    mixin Entity!"comments";
    mixin Col!("body_", string, "body");  // D keyword, explicit column name
    mixin Col!("authorId", long);
    mixin BelongsTo!("author", User, "author_id");

    /// Computed: render comment as HTML with author name
    static auto html(Expr!Ref c) {
        return use(
            (string body_, string authorName) =>
                `<div class="comment">
                <span class="author">` ~ authorName ~ `</span>
                <p>` ~ body_ ~ `</p>
            </div>`,
            body_(c),
            User.fullName(author(c))
        );
    }
}

// ============================================================================
// Test with mock database
// ============================================================================

/// Helper to create a mock database with sample data.
/// Returns a DebugSqlFetcher that prints SQL when run with -d=sql
private DebugSqlFetcher createMockDB() {
    auto mock = new MockDataFetcher();

    mock.setTableData("users", `[
        {"id": 1, "first_name": "Alice", "last_name": "Smith", "email": "alice@example.com"},
        {"id": 2, "first_name": "Bob", "last_name": "Jones", "email": "bob@example.com"},
        {"id": 3, "first_name": "Carol", "last_name": "White", "email": "carol@example.com"}
    ]`);

    mock.setTableData("posts", `[
        {"id": 1, "title": "Hello World", "body": "This is my first post!", "author_id": 1},
        {"id": 2, "title": "D Programming", "body": "D is a great language for systems programming.", "author_id": 2},
        {"id": 3, "title": "GraphQL Tips", "body": "Here are some tips for GraphQL.", "author_id": 1}
    ]`);

    mock.setTableData("comments", `[
        {"id": 101, "post_id": 1, "body": "Great post!", "author_id": 2},
        {"id": 102, "post_id": 1, "body": "Thanks for sharing!", "author_id": 3},
        {"id": 103, "post_id": 2, "body": "I agree!", "author_id": 1}
    ]`);

    return new DebugSqlFetcher(mock);
}

unittest {
    import std.stdio : writeln;

    auto db = createMockDB();
    auto executor = new Executor();

    auto query = map!(
        (Expr!Ref p) => Post.title(p)
    )(getByIds!Post([1, 2], db));

    auto titles = executor.execute(query);
    assert(titles == ["Hello World", "D Programming"]);

    debug(sql) {
        writeln("\n=== Test: Simple field (Post.title) ===");
        db.printSQL();
    }
}

unittest {
    import std.stdio : writeln;

    auto db = createMockDB();
    auto executor = new Executor();

    auto query = map!(
        (Expr!Ref p) => Post.summary(p)
    )(getByIds!Post([1, 2], db));

    auto summaries = executor.execute(query);
    assert(summaries[0].canFind("Hello World"));
    assert(summaries[0].canFind("Alice Smith"));
    assert(summaries[1].canFind("D Programming"));
    assert(summaries[1].canFind("Bob Jones"));

    debug(sql) {
        writeln("\n=== Test: Computed field with belongsTo (Post.summary) ===");
        db.printSQL();
    }
}

// Test Post.html - full 4-layer query with nested relationships
unittest {
    import std.stdio : writeln;

    auto db = createMockDB();
    auto executor = new Executor();

    auto query = map!(
        (Expr!Ref p) => Post.html(p)
    )(getByIds!Post([1], db));

    auto htmls = executor.execute(query);

    assert(htmls.length == 1);
    assert(htmls[0].canFind("Hello World"));
    assert(htmls[0].canFind("Alice Smith"));
    assert(htmls[0].canFind("Great post!"));
    assert(htmls[0].canFind("Bob Jones"));

    debug(sql) {
        writeln("\n=== Test: Full 4-layer query (Post.html with comments) ===");
        db.printSQL();
    }
}

// Test nested map with hasMany
unittest {
    import std.stdio : writeln;

    auto db = createMockDB();
    auto executor = new Executor();

    // Query: { users { firstName, posts { title } } }
    auto query = map!(
        (Expr!Ref user) => jsonObject(
            "firstName", User.firstName(user),
            "posts", map!(
                (Expr!Ref post) => jsonObject(
                    "title", Post.title(post)
                )
            )(User.posts(user))
        )
    )(getByIds!User([1, 2], db));

    auto result = executor.execute(query);

    assert(result.length == 2);

    // Alice has 2 posts (Hello World and GraphQL Tips)
    assert(result[0]["firstName"].str == "Alice");
    assert(result[0]["posts"].array.length == 2);

    // Bob has 1 post
    assert(result[1]["firstName"].str == "Bob");
    assert(result[1]["posts"].array.length == 1);

    debug(sql) {
        writeln("\n=== Test: Nested hasMany (users -> posts) ===");
        db.printSQL();
    }
}

// Test forking hasMany - user has both posts and comments
unittest {
    import std.stdio : writeln;

    auto db = createMockDB();
    auto executor = new Executor();

    // Query: { users { firstName, posts { title }, comments { body } } }
    auto query = map!(
        (Expr!Ref user) => jsonObject(
            "firstName", User.firstName(user),
            "posts", map!(
                (Expr!Ref post) => jsonObject(
                    "title", Post.title(post)
                )
            )(User.posts(user)),
            "comments", map!(
                (Expr!Ref comment) => jsonObject(
                    "body", Comment.body_(comment)
                )
            )(User.comments(user))
        )
    )(getByIds!User([1, 2], db));

    auto result = executor.execute(query);

    assert(result.length == 2);

    // Alice: 2 posts, 1 comment (on post 2)
    assert(result[0]["firstName"].str == "Alice");
    assert(result[0]["posts"].array.length == 2);
    assert(result[0]["comments"].array.length == 1);

    // Bob: 1 post, 1 comment (on post 1)
    assert(result[1]["firstName"].str == "Bob");
    assert(result[1]["posts"].array.length == 1);
    assert(result[1]["comments"].array.length == 1);

    debug(sql) {
        writeln("\n=== Test: Forking hasMany (users -> posts, users -> comments) ===");
        db.printSQL();
    }
}

// ============================================================================
// Query Root Pattern Tests
// ============================================================================

// Test using Query root - mirrors GraphQL query structure
unittest {
    import std.stdio : writeln;

    auto db = createMockDB();
    auto executor = new Executor();

    // GraphQL equivalent:
    // query {
    //   users {
    //     firstName
    //     lastName
    //     email
    //   }
    // }
    auto query = map!(
        (Expr!Ref user) => jsonObject(
            "firstName", User.firstName(user),
            "lastName", User.lastName(user),
            "email", User.email(user)
        )
    )(Query.users(db));

    auto result = executor.execute(query);

    assert(result.length == 3);  // All users
    assert(result[0]["firstName"].str == "Alice");
    assert(result[0]["email"].str == "alice@example.com");
    assert(result[1]["firstName"].str == "Bob");
    assert(result[2]["firstName"].str == "Carol");

    debug(sql) {
        writeln("\n=== Test: Query.users (getAll) ===");
        db.printSQL();
    }
}

// Test nested query from Query root - simpler version first
unittest {
    import std.stdio : writeln;

    auto db = createMockDB();
    auto executor = new Executor();

    // Simpler: users -> posts (2 levels)
    auto query = map!(
        (Expr!Ref user) => jsonObject(
            "fullName", User.fullName(user),
            "posts", map!(
                (Expr!Ref post) => jsonObject(
                    "title", Post.title(post)
                )
            )(User.posts(user))
        )
    )(Query.users(db));

    auto result = executor.execute(query);

    assert(result.length == 3);
    assert(result[0]["fullName"].str == "Alice Smith");
    assert(result[0]["posts"].array.length == 2);  // Alice has posts 1 and 3
    assert(result[1]["fullName"].str == "Bob Jones");
    assert(result[1]["posts"].array.length == 1);  // Bob has post 2
    assert(result[2]["fullName"].str == "Carol White");
    assert(result[2]["posts"].array.length == 0);  // Carol has no posts

    debug(sql) {
        writeln("\n=== Test: Query.users -> posts (2 levels) ===");
        db.printSQL();
    }
}

// Test 3-level nesting: users -> posts -> comments
unittest {
    import std.stdio : writeln;

    auto db = createMockDB();
    auto executor = new Executor();

    auto query = map!(
        (Expr!Ref user) => jsonObject(
            "fullName", User.fullName(user),
            "posts", map!(
                (Expr!Ref post) => jsonObject(
                    "title", Post.title(post),
                    "comments", map!(
                        (Expr!Ref comment) => jsonObject(
                            "body", Comment.body_(comment)
                        )
                    )(Post.comments(post))
                )
            )(User.posts(user))
        )
    )(Query.users(db));

    auto result = executor.execute(query);

    assert(result.length == 3);

    // Alice has 2 posts
    assert(result[0]["fullName"].str == "Alice Smith");
    assert(result[0]["posts"].array.length == 2);

    // Alice's first post (Hello World) has 2 comments
    auto aliceFirstPost = result[0]["posts"].array[0];
    assert(aliceFirstPost["title"].str == "Hello World");
    assert(aliceFirstPost["comments"].array.length == 2);

    debug(sql) {
        writeln("\n=== Test: Query.users -> posts -> comments (3 levels) ===");
        db.printSQL();
    }
}

// Test SQL push-down for computed fullName field
unittest {
    import std.stdio : writeln;

    debug(sql) writeln("\n=== Test: SQL push-down for computed fullName ===");

    // Query: { users { fullName } }
    // fullName = firstName ~ " " ~ lastName
    auto query = map!(
        (Expr!Ref user) => User.fullName(user)
    )(getByIds!User([1, 2]));

    // Phase 1: Standard optimization (creates QueryNodes and ProjectColumnExprs)
    auto optCtx = new OptimizeContext();
    auto optimized = query.optimize(optCtx);

    // Phase 2: SQL push-down (replaces BinaryOpExprs with ProjectComputedExprs)
    auto sqlOpt = new SqlOptimizer();
    sqlOpt.optimize(optimized, optCtx);

    // Get the relational optimization context
    auto relCtx = optCtx.getSourceContext!RelationalOptimizeContext();

    // Show the full SQL query with computed columns
    debug(sql) {
        writeln(toSQL(relCtx.nodesInOrder(), sqlOpt));
    }

    // Verify computed column was created
    auto nodes = relCtx.allNodes();
    assert(nodes.length == 1);

    auto computed = sqlOpt.getComputedColumns(nodes[0].id);
    assert(computed.length >= 1, "Should have at least 1 computed column for fullName");

    // The SQL expression should be string concatenation
    assert(computed[0].sqlExpr.canFind("||"),
        "SQL should use || for concatenation, got: " ~ computed[0].sqlExpr);
    assert(computed[0].sqlExpr.canFind("first_name"),
        "SQL should reference first_name");
    assert(computed[0].sqlExpr.canFind("last_name"),
        "SQL should reference last_name");
}
