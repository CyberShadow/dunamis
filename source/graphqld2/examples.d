module graphqld2.examples;

import std.algorithm;
import std.array;
import std.conv;
import std.json;

import ae.utils.promise.await : awaitSync;

import graphqld2.core;
import graphqld2.relational;
import graphqld2.relational.sql_dialect : SqlDialect;

// ============================================================================
// Data Source Configuration
// ============================================================================

/// Simple test dialect for examples - uses PostgreSQL-compatible SQL
private class TestDialect : SqlDialect {
    override string binaryOp(string op, string leftSql, string rightSql) {
        string sqlOp = op;
        switch (op) {
            case "~": sqlOp = "||"; break;   // String concatenation
            case "==": sqlOp = "="; break;   // Equality
            case "!=": sqlOp = "<>"; break;  // Inequality
            case "&&": sqlOp = "AND"; break; // Logical and
            case "||": sqlOp = "OR"; break;  // Logical or
            default: break;
        }
        return "(" ~ leftSql ~ " " ~ sqlOp ~ " " ~ rightSql ~ ")";
    }
    override string name() { return "Test"; }
}

/// Singleton test dialect instance
private SqlDialect testDialect() {
    __gshared TestDialect instance;
    if (instance is null) instance = new TestDialect();
    return instance;
}

/// Static data source instance - bound by alias in Table mixins.
/// This is set by createMockDB() before running queries.
static DebugSqlDB!() db;

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
// Input Types - Structs used as computed field arguments
// ============================================================================

/// Example input type for formatting options
struct FormatOptions {
    import std.typecons : Nullable;

    string prefix;                           // Required: String!
    Nullable!string suffix;                  // Optional (absent = null): String
    Nullable!(Nullable!bool) uppercase;      // Three-state (absent/null/value): Boolean
}

// ============================================================================
// Domain Model - Demonstrates business logic with relationships
// ============================================================================

/// User entity
struct User {
    import graphqld2.graphql : GqlDescription, GqlDeprecated;

    mixin DemoEntity!(db, "users");

    @GqlDescription("The user's first name")
    mixin Col!("firstName", string);

    @GqlDescription("The user's last name")
    mixin Col!("lastName", string);

    @GqlDescription("Primary email address")
    @GqlDeprecated("Use the emails field instead")
    mixin Col!("email", string);

    @GqlDescription("Posts authored by this user")
    mixin HasMany!("posts", Post, "author_id");

    mixin HasMany!("comments", Comment, "author_id");

    /// Computed field using operator overloading and property-like access
    static auto fullName(Expr!User u) => u.firstName ~ " " ~ u.lastName;

    /// Computed field with arguments - demonstrates field argument support
    @GqlDescription("A personalized greeting")
    static auto greeting(Expr!User u, string prefix, string suffix = "!") {
        return prefix ~ " " ~ u.firstName ~ suffix;
    }

    /// Computed field with struct argument - demonstrates input type generation
    @GqlDescription("Formatted name with options")
    static auto formattedName(Expr!User u, FormatOptions options) {
        // For now, just use prefix - full implementation would handle all options
        return options.prefix ~ u.firstName;
    }
}

/// Post entity - belongs to a User (author) and has many Comments
struct Post {
    import graphqld2.graphql : GqlHidden, GqlName;

    mixin DemoEntity!(db, "posts");
    mixin Col!("title", string);

    @GqlName("body")  // D keyword conflict: body_ in D → body in GraphQL
    mixin Col!("body_", string, "body");

    @GqlHidden  // Hide FK column, expose only the relationship
    mixin Col!("authorId", ForeignKey!User);
    mixin BelongsTo!("author", "authorId");

    mixin HasMany!("comments", Comment, "post_id");

    /// Computed: render full post as HTML with author and comments
    static auto html(Expr!Post p) {
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
                (Expr!Comment c) => c.html
            )(p.comments)
        );
    }

    /// Computed: short summary for listings
    static auto summary(Expr!Post p) {
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
    import graphqld2.graphql : GqlHidden, GqlName;

    mixin DemoEntity!(db, "comments");

    @GqlName("body")  // D keyword conflict: body_ in D → body in GraphQL
    mixin Col!("body_", string, "body");

    @GqlHidden  // Hide FK columns, expose only the relationships
    mixin Col!("postId", ForeignKey!Post);
    @GqlHidden
    mixin Col!("authorId", ForeignKey!User);

    mixin BelongsTo!("post", "postId");
    mixin BelongsTo!("author", "authorId");

    /// Computed: render comment as HTML with author name
    static auto html(Expr!Comment c) {
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
// Expression Tree Tests (Low-Level API)
// ============================================================================
//
// These tests demonstrate the low-level expression tree API, which provides
// full control over query construction. Use this API when you need:
// - Features not yet supported by the compiler (BelongsTo, field arguments)
// - Direct SQL verification
// - Complex computed fields
// - Custom query patterns (getByIds, etc.)

/// Helper to create and set up the mock database with sample data.
/// Sets the module-level `db` static variable for use by Query.
/// Returns the same instance for legacy test compatibility.
private DebugSqlDB!() createMockDB() {
    auto mock = new MockDB!()();

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

    // Set the module-level static for Query to use
    db = new DebugSqlDB!()(mock, testDialect());
    return db;
}

unittest {
    import std.stdio : writeln;

    auto db = createMockDB();
    auto executor = new Executor();

    auto query = map!(
        (Expr!Post p) => p.title
    )(getByIds!Post([1, 2]));

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
        (Expr!Post p) => p.summary
    )(getByIds!Post([1, 2]));

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
        (Expr!Post p) => p.html
    )(getByIds!Post([1]));

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
        (Expr!User user) => jsonObject(
            "firstName", user.firstName,
            "posts", map!(
                (Expr!Post post) => jsonObject(
                    "title", post.title
                )
            )(user.posts)
        )
    )(getByIds!User([1, 2]));

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
        (Expr!User user) => jsonObject(
            "firstName", user.firstName,
            "posts", map!(
                (Expr!Post post) => jsonObject(
                    "title", post.title
                )
            )(user.posts),
            "comments", map!(
                (Expr!Comment comment) => jsonObject(
                    "body", comment.body_
                )
            )(user.comments)
        )
    )(getByIds!User([1, 2]));

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
// High-Level GraphQL Query Tests (using compiler)
// ============================================================================
//
// These tests demonstrate the library from an end-user perspective,
// using compileQuery to execute GraphQL queries.

// Test: Basic query with scalar fields
unittest {
    import std.stdio : writeln;
    import graphqld2.graphql : compileQuery;

    createMockDB();  // Sets up the static db
    auto executor = new Executor();

    auto query = compileQuery!Query(`{
        users {
            firstName
            lastName
            email
        }
    }`);

    auto result = awaitSync(executor.execute(query));

    auto users = result["users"].array;
    assert(users.length == 3);  // All users
    assert(users[0]["firstName"].str == "Alice");
    assert(users[0]["email"].str == "alice@example.com");
    assert(users[1]["firstName"].str == "Bob");
    assert(users[2]["firstName"].str == "Carol");

    debug(sql) {
        writeln("\n=== Test: Basic query with scalar fields ===");
        db.printSQL();
    }
}

// Test: Query with computed field (fullName)
unittest {
    import std.stdio : writeln;
    import graphqld2.graphql : compileQuery;

    createMockDB();
    auto executor = new Executor();

    auto query = compileQuery!Query(`{
        users {
            fullName
            posts {
                title
            }
        }
    }`);

    auto result = awaitSync(executor.execute(query));

    auto users = result["users"].array;
    assert(users.length == 3);
    assert(users[0]["fullName"].str == "Alice Smith");
    assert(users[0]["posts"].array.length == 2);  // Alice has posts 1 and 3
    assert(users[1]["fullName"].str == "Bob Jones");
    assert(users[1]["posts"].array.length == 1);  // Bob has post 2
    assert(users[2]["fullName"].str == "Carol White");
    assert(users[2]["posts"].array.length == 0);  // Carol has no posts

    debug(sql) {
        writeln("\n=== Test: Query with computed field ===");
        db.printSQL();
    }
}

// Test: 3-level nesting (users -> posts -> comments)
unittest {
    import std.stdio : writeln;
    import graphqld2.graphql : compileQuery;

    createMockDB();
    auto executor = new Executor();

    auto query = compileQuery!Query(`{
        users {
            fullName
            posts {
                title
                comments {
                    body
                }
            }
        }
    }`);

    auto result = awaitSync(executor.execute(query));

    auto users = result["users"].array;
    assert(users.length == 3);

    // Alice has 2 posts
    assert(users[0]["fullName"].str == "Alice Smith");
    assert(users[0]["posts"].array.length == 2);

    // Alice's first post (Hello World) has 2 comments
    auto aliceFirstPost = users[0]["posts"].array[0];
    assert(aliceFirstPost["title"].str == "Hello World");
    assert(aliceFirstPost["comments"].array.length == 2);

    debug(sql) {
        writeln("\n=== Test: 3-level nesting (users -> posts -> comments) ===");
        db.printSQL();
    }
}

// Test: Computed field with arguments
unittest {
    import std.stdio : writeln;
    import graphqld2.graphql : compileQuery;

    createMockDB();
    auto executor = new Executor();

    // User.greeting takes (prefix: String!, suffix: String = "!")
    auto query = compileQuery!Query(`{
        users {
            firstName
            greeting(prefix: "Hello")
        }
    }`);

    auto result = awaitSync(executor.execute(query));

    auto users = result["users"].array;
    assert(users.length == 3);
    assert(users[0]["firstName"].str == "Alice");
    assert(users[0]["greeting"].str == "Hello Alice!");
    assert(users[1]["greeting"].str == "Hello Bob!");
    assert(users[2]["greeting"].str == "Hello Carol!");

    debug(sql) {
        writeln("\n=== Test: Computed field with arguments ===");
        db.printSQL();
    }
}

// Test SQL push-down for computed fullName field
unittest {
    import std.stdio : writeln;

    // Query: { users { fullName } }
    // fullName = firstName ~ " " ~ lastName
    auto query = map!(
        (Expr!User user) => user.fullName
    )(getByIds!User([1, 2]));

    // Phase 1: Standard optimization (creates QueryNodes and ProjectColumnExprs)
    auto optCtx = new OptimizeContext();
    auto optimized = query.optimize(optCtx);

    // Phase 2: SQL push-down (replaces BinaryOpExprs with ProjectComputedExprs)
    // Use a simple test dialect for unit tests
    static class TestDialect : SqlDialect {
        override string binaryOp(string op, string leftSql, string rightSql) {
            if (op == "~") return "(" ~ leftSql ~ " || " ~ rightSql ~ ")";
            return "(" ~ leftSql ~ " " ~ op ~ " " ~ rightSql ~ ")";
        }
        override string name() { return "Test"; }
    }
    auto sqlOpt = new SqlOptimizer(new TestDialect());
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

// Test computed field with arguments
unittest {
    import std.stdio : writeln;

    auto db = createMockDB();
    auto executor = new Executor();

    // Query: { users { greeting(prefix: "Hello") } }
    // Uses opDispatch to call User.greeting with arguments
    auto query = map!(
        (Expr!User user) => user.greeting("Hello")  // Uses default suffix "!"
    )(getByIds!User([1, 2]));

    auto result = awaitSync(executor.execute(query));

    assert(result.length == 2);
    assert(result[0] == "Hello Alice!");
    assert(result[1] == "Hello Bob!");

    debug(sql) {
        writeln("\n=== Test: Computed field with arguments (greeting) ===");
        db.printSQL();
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
    // D keyword conflicts are resolved with @GqlName (body_ → body),
    // and User fields demonstrate @GqlDescription and @GqlDeprecated.
    // Primary key fields render as their actual type (Int64!) rather than ID!.
    enum expected = q"EOF
scalar Int64

type Query {
  users: [User!]!
  posts: [Post!]!
  comments: [Comment!]!
}

type User {
  id: Int64!
  """The user's first name"""
  firstName: String!
  """The user's last name"""
  lastName: String!
  """Primary email address"""
  email: String! @deprecated(reason: "Use the emails field instead")
  """Posts authored by this user"""
  posts: [Post!]!
  comments: [Comment!]!
  fullName: String!
  """A personalized greeting"""
  greeting(prefix: String!, suffix: String = "!"): String!
  """Formatted name with options"""
  formattedName(options: FormatOptions!): String!
}

type Post {
  id: Int64!
  title: String!
  body: String!
  author: User!
  comments: [Comment!]!
  html: String!
  summary: String!
}

type Comment {
  id: Int64!
  body: String!
  post: Post!
  author: User!
  html: String!
}

input FormatOptions {
  prefix: String!
  suffix: String
  uppercase: Boolean
}

EOF";
    assert(schema == expected, "Generated schema does not match expected:\n---ACTUAL---\n" ~ schema ~ "\n---EXPECTED---\n" ~ expected);
}

// Test individual type generation
unittest {
    import graphqld2.graphql;

    // Test User type fields
    enum userFields = getFields!User;

    // Should have: id, firstName, lastName, email, posts, comments
    assert(userFields.length >= 6);

    // Check specific fields exist
    bool hasFirstName = false;
    bool hasPosts = false;
    foreach (f; userFields) {
        if (f.name == "firstName") {
            hasFirstName = true;
            assert(f.graphqlType == "String!");  // Non-nullable column
        }
        if (f.name == "posts") {
            hasPosts = true;
            assert(f.graphqlType == "[Post!]!");  // Non-nullable list of non-nullable items
        }
    }
    assert(hasFirstName, "User should have firstName field");
    assert(hasPosts, "User should have posts field");
}

// Test Query type introspection
unittest {
    import graphqld2.graphql;

    enum queryFields = getFields!Query;

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
// SQL DDL Generation Tests (PostgreSQL)
// ============================================================================

unittest {
    import std.stdio : writeln;
    import graphqld2.postgres.ddl : generateDDL;

    // Generate DDL for all tables
    enum ddl = generateDDL!Query;

    debug(ddl) {
        writeln("\n=== Generated PostgreSQL DDL ===");
        writeln(ddl);
    }

    enum expected = q"EOF
-- Generated PostgreSQL DDL
-- Phase 1: Create tables

CREATE TABLE users (
  id BIGSERIAL PRIMARY KEY,
  first_name TEXT NOT NULL,
  last_name TEXT NOT NULL,
  email TEXT NOT NULL
);

CREATE TABLE posts (
  id BIGSERIAL PRIMARY KEY,
  title TEXT NOT NULL,
  body TEXT NOT NULL,
  author_id BIGINT NOT NULL
);

CREATE TABLE comments (
  id BIGSERIAL PRIMARY KEY,
  body TEXT NOT NULL,
  post_id BIGINT NOT NULL,
  author_id BIGINT NOT NULL
);

-- Phase 2: Add foreign key constraints

ALTER TABLE posts ADD CONSTRAINT posts_fk0 FOREIGN KEY (author_id) REFERENCES users(id);
ALTER TABLE comments ADD CONSTRAINT comments_fk0 FOREIGN KEY (post_id) REFERENCES posts(id);
ALTER TABLE comments ADD CONSTRAINT comments_fk1 FOREIGN KEY (author_id) REFERENCES users(id);
EOF";
    assert(ddl == expected, "Generated DDL does not match expected:\n---ACTUAL---\n" ~ ddl ~ "\n---EXPECTED---\n" ~ expected);
}

// Test individual table DDL
unittest {
    import graphqld2.postgres.ddl : generateCreateTable;

    enum usersDDL = generateCreateTable!User;

    enum expected = q"EOF
CREATE TABLE users (
  id BIGSERIAL PRIMARY KEY,
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
            assert(col.dType == "long");
        }
        if (col.name == "first_name") {
            hasFirstName = true;
            assert(col.dType == "string");
            assert(!col.nullable);
        }
    }
    assert(hasId, "Should have id column");
    assert(hasFirstName, "Should have first_name column");
}

// ============================================================================
// Sorting Tests
// ============================================================================

// Test column-based sorting with orderBy
unittest {
    import graphqld2.core.sorting : orderBy, OrderBySpec, SortDirection;

    auto mock = new MockDB!()();
    mock.setTableData("users", `[
        {"id": 1, "first_name": "Charlie", "last_name": "Zebra"},
        {"id": 2, "first_name": "Alice", "last_name": "Young"},
        {"id": 3, "first_name": "Bob", "last_name": "Xavier"}
    ]`);

    db = new DebugSqlDB!()(mock, testDialect());
    auto executor = new Executor();

    // Sort by first_name ASC using getAll
    auto query = map!(
        (Expr!User u) => u.firstName
    )(orderBy(getAll!User(), "first_name", SortDirection.ASC));

    auto names = awaitSync(executor.execute(query));

    // Should be sorted: Alice, Bob, Charlie
    assert(names.length == 3);
    assert(names[0] == "Alice", "First should be Alice, got: " ~ names[0]);
    assert(names[1] == "Bob", "Second should be Bob, got: " ~ names[1]);
    assert(names[2] == "Charlie", "Third should be Charlie, got: " ~ names[2]);

    debug(sql) {
        import std.stdio : writeln;
        writeln("\n=== Test: Column-based sorting (first_name ASC) ===");
        db.printSQL();
    }
}

// Test descending sort
unittest {
    import graphqld2.core.sorting : orderBy, SortDirection;

    auto mock = new MockDB!()();
    mock.setTableData("users", `[
        {"id": 1, "first_name": "Charlie"},
        {"id": 2, "first_name": "Alice"},
        {"id": 3, "first_name": "Bob"}
    ]`);

    db = new DebugSqlDB!()(mock, testDialect());
    auto executor = new Executor();

    // Sort by first_name DESC
    auto query = map!(
        (Expr!User u) => u.firstName
    )(orderBy(getAll!User(), "first_name", SortDirection.DESC));

    auto names = awaitSync(executor.execute(query));

    // Should be sorted: Charlie, Bob, Alice
    assert(names.length == 3);
    assert(names[0] == "Charlie", "First should be Charlie, got: " ~ names[0]);
    assert(names[1] == "Bob", "Second should be Bob, got: " ~ names[1]);
    assert(names[2] == "Alice", "Third should be Alice, got: " ~ names[2]);
}

// Test predicate-based sorting with sortBy
unittest {
    import graphqld2.core.sorting : sortBy;

    auto mock = new MockDB!()();
    mock.setTableData("users", `[
        {"id": 1, "first_name": "Charlie"},
        {"id": 2, "first_name": "Alice"},
        {"id": 3, "first_name": "Bob"}
    ]`);

    db = new DebugSqlDB!()(mock, testDialect());
    auto executor = new Executor();

    // Sort by firstName using predicate (a.lt(b) for ASC)
    // Note: D class comparison operators can't be overridden, so we use .lt() method
    auto query = map!(
        (Expr!User u) => u.firstName
    )(sortBy!((a, b) => a.firstName.lt(b.firstName))(getAll!User()));

    auto names = awaitSync(executor.execute(query));

    // Should be sorted: Alice, Bob, Charlie
    assert(names.length == 3);
    assert(names[0] == "Alice", "First should be Alice, got: " ~ names[0]);
    assert(names[1] == "Bob", "Second should be Bob, got: " ~ names[1]);
    assert(names[2] == "Charlie", "Third should be Charlie, got: " ~ names[2]);

    debug(sql) {
        import std.stdio : writeln;
        writeln("\n=== Test: Predicate-based sorting (firstName ASC) ===");
        db.printSQL();
    }
}

// Test predicate-based sorting DESC
unittest {
    import graphqld2.core.sorting : sortBy;

    auto mock = new MockDB!()();
    mock.setTableData("users", `[
        {"id": 1, "first_name": "Charlie"},
        {"id": 2, "first_name": "Alice"},
        {"id": 3, "first_name": "Bob"}
    ]`);

    db = new DebugSqlDB!()(mock, testDialect());
    auto executor = new Executor();

    // Sort by firstName using predicate (a.gt(b) for DESC)
    auto query = map!(
        (Expr!User u) => u.firstName
    )(sortBy!((a, b) => a.firstName.gt(b.firstName))(getAll!User()));

    auto names = awaitSync(executor.execute(query));

    // Should be sorted: Charlie, Bob, Alice
    assert(names.length == 3);
    assert(names[0] == "Charlie", "First should be Charlie, got: " ~ names[0]);
    assert(names[1] == "Bob", "Second should be Bob, got: " ~ names[1]);
    assert(names[2] == "Alice", "Third should be Alice, got: " ~ names[2]);
}

// Test sorting combined with pagination (limit/offset)
unittest {
    import graphqld2.core.sorting : orderBy, SortDirection;
    import graphqld2.core.pagination : limit, offset;

    auto mock = new MockDB!()();
    mock.setTableData("users", `[
        {"id": 1, "first_name": "Alice"},
        {"id": 2, "first_name": "Bob"},
        {"id": 3, "first_name": "Charlie"},
        {"id": 4, "first_name": "David"},
        {"id": 5, "first_name": "Eve"}
    ]`);

    db = new DebugSqlDB!()(mock, testDialect());
    auto executor = new Executor();

    // Sort by first_name ASC, then skip 1 and take 2
    auto query = map!(
        (Expr!User u) => u.firstName
    )(limit(offset(orderBy(getAll!User(), "first_name", SortDirection.ASC), 1), 2));

    auto names = awaitSync(executor.execute(query));

    // Should be: Bob, Charlie (sorted: Alice, Bob, Charlie, David, Eve → skip 1 → Bob, Charlie, David, Eve → take 2 → Bob, Charlie)
    assert(names.length == 2);
    assert(names[0] == "Bob", "First should be Bob, got: " ~ names[0]);
    assert(names[1] == "Charlie", "Second should be Charlie, got: " ~ names[1]);

    debug(sql) {
        import std.stdio : writeln;
        writeln("\n=== Test: Sorting + pagination ===");
        db.printSQL();
    }
}

