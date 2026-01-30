module graphqld2.examples;

import std.algorithm;
import std.array;
import std.conv;
import std.json;

import ae.utils.promise.await : awaitSync;

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
    mixin DemoEntity!"users";
    mixin Col!("firstName", string);
    mixin Col!("lastName", string);
    mixin Col!("email", string);
    mixin HasMany!("posts", Post, "author_id");
    mixin HasMany!("comments", Comment, "author_id");

    /// Computed field using operator overloading and property-like access
    static auto fullName(RefExpr!User u) => u.firstName ~ " " ~ u.lastName;
}

/// Post entity - belongs to a User (author) and has many Comments
struct Post {
    import graphqld2.graphql : GqlHidden;

    mixin DemoEntity!"posts";
    mixin Col!("title", string);
    mixin Col!("body_", string, "body");  // D keyword, explicit column name

    @GqlHidden  // Hide FK column, expose only the relationship
    mixin Col!("authorId", ForeignKey!User);
    mixin BelongsTo!("author", "authorId");

    mixin HasMany!("comments", Comment, "post_id");

    /// Computed: render full post as HTML with author and comments
    static auto html(RefExpr!Post p) {
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
            p.title,
            p.body_,
            p.author.fullName,
            map!(
                (RefExpr!Comment c) => c.html
            )(p.comments)
        );
    }

    /// Computed: short summary for listings
    static auto summary(RefExpr!Post p) {
        return use(
            (string title, string body_, string authorName) {
                auto truncated = body_.length > 100 ? body_[0..100] ~ "..." : body_;
                return title ~ " by " ~ authorName ~ " - " ~ truncated;
            },
            p.title,
            p.body_,
            p.author.fullName
        );
    }
}

/// Comment entity - belongs to a Post and has an author (User)
struct Comment {
    import graphqld2.graphql : GqlHidden;

    mixin DemoEntity!"comments";
    mixin Col!("body_", string, "body");  // D keyword, explicit column name

    @GqlHidden  // Hide FK columns, expose only the relationships
    mixin Col!("postId", ForeignKey!Post);
    @GqlHidden
    mixin Col!("authorId", ForeignKey!User);

    mixin BelongsTo!("post", "postId");
    mixin BelongsTo!("author", "authorId");

    /// Computed: render comment as HTML with author name
    static auto html(RefExpr!Comment c) {
        return use(
            (string body_, string authorName) =>
                `<div class="comment">
                <span class="author">` ~ authorName ~ `</span>
                <p>` ~ body_ ~ `</p>
            </div>`,
            c.body_,
            c.author.fullName
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
        (RefExpr!Post p) => p.title
    )(getByIds!Post([1, 2], db));

    auto titles = awaitSync(executor.execute(query));
    assert(titles == ["Hello World", "D Programming"]);

    // Verify generated SQL
    enum expectedSQL = q"EOF
WITH
  layer0 AS (
    SELECT posts.id, posts.title
    FROM posts
    WHERE posts.id = ANY($1)
  )
SELECT json_build_object(
  'layer0', (SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM layer0 t)
)
EOF";
    assert(db.getSQL() == expectedSQL, "Generated SQL does not match expected");

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
        (RefExpr!Post p) => p.summary
    )(getByIds!Post([1, 2], db));

    auto summaries = awaitSync(executor.execute(query));
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
        (RefExpr!Post p) => p.html
    )(getByIds!Post([1], db));

    auto htmls = awaitSync(executor.execute(query));

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
        (RefExpr!User user) => jsonObject(
            "firstName", user.firstName,
            "posts", map!(
                (RefExpr!Post post) => jsonObject(
                    "title", post.title
                )
            )(user.posts)
        )
    )(getByIds!User([1, 2], db));

    auto result = awaitSync(executor.execute(query));

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
        (RefExpr!User user) => jsonObject(
            "firstName", user.firstName,
            "posts", map!(
                (RefExpr!Post post) => jsonObject(
                    "title", post.title
                )
            )(user.posts),
            "comments", map!(
                (RefExpr!Comment comment) => jsonObject(
                    "body", comment.body_
                )
            )(user.comments)
        )
    )(getByIds!User([1, 2], db));

    auto result = awaitSync(executor.execute(query));

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
        (RefExpr!User user) => jsonObject(
            "firstName", user.firstName,
            "lastName", user.lastName,
            "email", user.email
        )
    )(Query.users(db));

    auto result = awaitSync(executor.execute(query));

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
        (RefExpr!User user) => jsonObject(
            "fullName", user.fullName,
            "posts", map!(
                (RefExpr!Post post) => jsonObject(
                    "title", post.title
                )
            )(user.posts)
        )
    )(Query.users(db));

    auto result = awaitSync(executor.execute(query));

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
        (RefExpr!User user) => jsonObject(
            "fullName", user.fullName,
            "posts", map!(
                (RefExpr!Post post) => jsonObject(
                    "title", post.title,
                    "comments", map!(
                        (RefExpr!Comment comment) => jsonObject(
                            "body", comment.body_
                        )
                    )(post.comments)
                )
            )(user.posts)
        )
    )(Query.users(db));

    auto result = awaitSync(executor.execute(query));

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

    // Query: { users { fullName } }
    // fullName = firstName ~ " " ~ lastName
    auto query = map!(
        (RefExpr!User user) => user.fullName
    )(getByIds!User([1, 2]));

    // Phase 1: Standard optimization (creates QueryNodes and ProjectColumnExprs)
    auto optCtx = new OptimizeContext();
    auto optimized = query.optimize(optCtx);

    // Phase 2: SQL push-down (replaces BinaryOpExprs with ProjectComputedExprs)
    auto sqlOpt = new SqlOptimizer();
    sqlOpt.optimize(optimized, optCtx);

    // Get the relational optimization context
    auto relCtx = optCtx.getSourceContext!RelationalOptimizeContext();

    // Verify computed column was created
    auto nodes = relCtx.allNodes();
    assert(nodes.length == 1);

    auto computed = sqlOpt.getComputedColumns(nodes[0].id);
    assert(computed.length >= 1, "Should have at least 1 computed column for fullName");

    // Verify the full SQL output
    auto sql = toSQL(relCtx.nodesInOrder(), sqlOpt);
    enum expectedSQL = q"EOF
WITH
  layer0 AS (
    SELECT users.id, users.first_name, users.last_name, ((first_name || ' ') || last_name) AS computed_0
    FROM users
    WHERE users.id = ANY($1)
  )
SELECT json_build_object(
  'layer0', (SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM layer0 t)
)
EOF";
    assert(sql == expectedSQL, "Generated SQL does not match expected:\n---ACTUAL---\n" ~ sql ~ "\n---EXPECTED---\n" ~ expectedSQL);

    debug(sql) {
        writeln("\n=== Test: SQL push-down for computed fullName ===");
        writeln(sql);
    }
}

// ============================================================================
// GraphQL Schema Generation Tests
// ============================================================================

unittest {
    import std.stdio : writeln;
    import graphqld2.graphql;

    // Generate complete schema SDL - automatically discovers all types from Query
    enum schema = generateSchemaSDL!Query;

    debug(graphql) {
        writeln("\n=== Generated GraphQL Schema ===");
        writeln(schema);
    }

    // Note: FK columns (authorId, postId) are hidden with @GqlHidden,
    // only the relationships (author, post) are exposed
    enum expected = q"EOF
scalar Int64

type Query {
  users: [User!]!
  posts: [Post!]!
  comments: [Comment!]!
}

type User {
  id: ID!
  firstName: String!
  lastName: String!
  email: String!
  posts: [Post!]!
  comments: [Comment!]!
}

type Post {
  id: ID!
  title: String!
  body_: String!
  author: User!
  comments: [Comment!]!
}

type Comment {
  id: ID!
  body_: String!
  post: Post!
  author: User!
}

EOF";
    assert(schema == expected, "Generated schema does not match expected:\n---ACTUAL---\n" ~ schema ~ "\n---EXPECTED---\n" ~ expected);
}

// Test individual type generation
unittest {
    import graphqld2.graphql;

    // Test User type fields
    enum userFields = getEntityFields!User;

    // Should have: id, firstName, lastName, email, posts, comments
    assert(userFields.length >= 6);

    // Check specific fields exist
    bool hasFirstName = false;
    bool hasPosts = false;
    foreach (f; userFields) {
        if (f.name == "firstName") {
            hasFirstName = true;
            assert(f.graphqlType == "String!");  // Non-nullable column
            assert(f.kind == FieldKind.column);
        }
        if (f.name == "posts") {
            hasPosts = true;
            assert(f.graphqlType == "[Post!]!");  // Non-nullable list of non-nullable items
            assert(f.kind == FieldKind.hasMany);
        }
    }
    assert(hasFirstName, "User should have firstName field");
    assert(hasPosts, "User should have posts field");
}

// Test Query type introspection
unittest {
    import graphqld2.graphql;

    enum queryFields = getQueryFields!Query;

    // Should have: users, posts, comments
    assert(queryFields.length == 3);

    bool hasUsers = false;
    foreach (f; queryFields) {
        if (f.name == "users") {
            hasUsers = true;
            assert(f.graphqlType == "[User!]!");  // Non-nullable list of non-nullable items
        }
    }
    assert(hasUsers, "Query should have users field");
}

// ============================================================================
// SQL DDL Generation Tests
// ============================================================================

unittest {
    import std.stdio : writeln;

    // Generate DDL for all tables
    enum ddl = generateDDL!Query;

    debug(ddl) {
        writeln("\n=== Generated SQL DDL ===");
        writeln(ddl);
    }

    enum expected = q"EOF
-- Generated DDL for schema
-- Tables are ordered by dependency (referenced tables first)

CREATE TABLE users (
  id BIGINT PRIMARY KEY,
  first_name TEXT NOT NULL,
  last_name TEXT NOT NULL,
  email TEXT NOT NULL
);

CREATE TABLE posts (
  id BIGINT PRIMARY KEY,
  title TEXT NOT NULL,
  body TEXT NOT NULL,
  author_id BIGINT NOT NULL,
  FOREIGN KEY (author_id) REFERENCES users(id)
);

CREATE TABLE comments (
  id BIGINT PRIMARY KEY,
  body TEXT NOT NULL,
  post_id BIGINT NOT NULL,
  author_id BIGINT NOT NULL,
  FOREIGN KEY (post_id) REFERENCES posts(id),
  FOREIGN KEY (author_id) REFERENCES users(id)
);

EOF";
    assert(ddl == expected, "Generated DDL does not match expected:\n---ACTUAL---\n" ~ ddl ~ "\n---EXPECTED---\n" ~ expected);
}

// Test individual table DDL
unittest {
    enum usersDDL = generateCreateTable!User;

    enum expected = q"EOF
CREATE TABLE users (
  id BIGINT PRIMARY KEY,
  first_name TEXT NOT NULL,
  last_name TEXT NOT NULL,
  email TEXT NOT NULL
);
EOF";
    assert(usersDDL == expected, "Generated User DDL does not match expected:\n---ACTUAL---\n" ~ usersDDL ~ "\n---EXPECTED---\n" ~ expected);
}

// Test column extraction
unittest {
    enum userCols = getColumnDefs!User;

    // Should have: id, first_name, last_name, email
    assert(userCols.length >= 4);

    bool hasId = false;
    bool hasFirstName = false;
    foreach (col; userCols) {
        if (col.name == "id") {
            hasId = true;
            assert(col.isPrimaryKey);
            assert(col.sqlType == "BIGINT");
        }
        if (col.name == "first_name") {
            hasFirstName = true;
            assert(col.sqlType == "TEXT");
            assert(!col.nullable);
        }
    }
    assert(hasId, "Should have id column");
    assert(hasFirstName, "Should have first_name column");
}
