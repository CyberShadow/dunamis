module dunamis.examples;

import std.algorithm;
import std.array;
import std.conv;
import std.json;

import ae.utils.promise.await : awaitSync;

import dunamis.core;
import dunamis.relational;
import dunamis.relational.sql_dialect : SqlDialect;

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
    override string unaryOp(string op, string operandSql) {
        if (op == "!") return "(NOT " ~ operandSql ~ ")";
        return "(" ~ op ~ operandSql ~ ")";
    }
    override string caseWhen(string conditionSql, string trueSql, string falseSql) {
        return "(CASE WHEN " ~ conditionSql ~ " THEN " ~ trueSql ~ " ELSE " ~ falseSql ~ " END)";
    }
    override string isNullOp(string operandSql) {
        return "(" ~ operandSql ~ " IS NULL)";
    }
    override string existsSubquery(string subquery) {
        return "EXISTS (" ~ subquery ~ ")";
    }
    override string notExistsSubquery(string subquery) {
        return "NOT EXISTS (" ~ subquery ~ ")";
    }
    override string likeOp(string operandSql, string pattern, bool caseInsensitive) {
        if (caseInsensitive) {
            return "(LOWER(" ~ operandSql ~ ") LIKE LOWER('" ~ pattern ~ `') ESCAPE '\')`;
        }
        return "(" ~ operandSql ~ " LIKE '" ~ pattern ~ `' ESCAPE '\')`;
    }
    override string name() { return "Test"; }

    // Query SQL generation vocabulary (PostgreSQL-compatible for tests)
    override string escapeSqlString(string s) {
        import std.string : replace;
        return "'" ~ s.replace("'", "''") ~ "'";
    }
    override string jsonToSqlLiteral(JSONValue val) {
        final switch (val.type) {
            case JSONType.string: return escapeSqlString(val.str);
            case JSONType.integer: return val.integer.to!string;
            case JSONType.uinteger: return val.uinteger.to!string;
            case JSONType.float_: return val.floating.to!string;
            case JSONType.true_: return "TRUE";
            case JSONType.false_: return "FALSE";
            case JSONType.null_: return "NULL";
            case JSONType.array:
                auto elements = val.array.map!(v => jsonToSqlLiteral(v)).array;
                return "ARRAY[" ~ elements.join(",") ~ "]";
            case JSONType.object: return escapeSqlString(val.toString());
        }
    }
    override string rootIdFilter(string table, string[] pkColumns) {
        if (pkColumns.length == 1)
            return table ~ "." ~ pkColumns[0] ~ " = ANY($1)";
        auto cols = pkColumns.map!(c => table ~ "." ~ c).array.join(", ");
        return "(" ~ cols ~ ") IN ({{IDS}})";
    }
    override string jsonObjectFunc() { return "json_build_object"; }
    override string rowJsonFunc() { return ""; }
    override string emptyJsonArray() { return "'[]'::json"; }
    override string castToText(string sql) { return sql ~ "::text"; }
    override string aggregateLayerJson(int layerId, string orderByClause) {
        auto layerStr = layerId.to!string;
        if (orderByClause.length > 0) {
            return "(SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM (SELECT * FROM layer"
                ~ layerStr ~ " ORDER BY " ~ orderByClause ~ ") t)";
        }
        return "(SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM layer"
            ~ layerStr ~ " t)";
    }
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
    mixin Table!(Holiday, "holidays");
}


// ============================================================================
// Input Types - Structs used as computed field arguments
// ============================================================================

/// Example request context for computed fields that need request-scoped data
struct RequestContext {
    string locale;
}

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
@Entity!(db, "users")
struct User {
    import dunamis.graphql : GqlDescription, GqlDeprecated;

    mixin DemoId;

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

    /// Computed field using request context for localization.
    /// Reads the RequestContext from EvalContext at eval-time.
    static auto localizedGreeting(Expr!User u) {
        return use(
            (string firstName, RequestContext reqCtx) {
                if (reqCtx.locale == "fr") return "Bonjour " ~ firstName;
                if (reqCtx.locale == "es") return "Hola " ~ firstName;
                return "Hello " ~ firstName;
            },
            u.firstName,
            context!RequestContext(u)
        );
    }

    /// Computed field using tryUse — validates firstName per-element,
    /// producing GqlResult!string (errors become null with path tracking).
    static auto validatedName(Expr!User u) {
        return tryUse(
            (string firstName) {
                import std.string : indexOf;
                if (firstName.indexOf("o") != -1)
                    throw new Exception("Name contains 'o'");
                return firstName;
            },
            u.firstName
        );
    }

    /// Computed field accessing an unrelated global table.
    /// Uses singleton() to reach root entry points and broadcast()
    /// to replicate the global data for each user in the batch.
    static auto availability(Expr!User u) {
        return use(
            (string firstName, Holiday[] allHolidays) {
                return firstName ~ " has " ~ allHolidays.length.to!string ~ " holidays";
            },
            u.firstName,
            Query().singleton().holidays().broadcast(u)
        );
    }
}

/// Post entity - belongs to a User (author) and has many Comments
@Entity!(db, "posts")
struct Post {
    import dunamis.graphql : GqlHidden, GqlName;

    mixin DemoId;
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
@Entity!(db, "comments")
struct Comment {
    import dunamis.graphql : GqlHidden, GqlName;

    mixin DemoId;

    @GqlName("body")  // D keyword conflict: body_ in D → body in GraphQL
    mixin Col!("body_", string, "body");

    @GqlHidden  // Hide FK columns, expose only the relationships
    mixin Col!("postId", ForeignKey!Post);
    @GqlHidden
    mixin Col!("authorId", ForeignKey!User);

    mixin BelongsTo!("post", "postId");
    mixin BelongsTo!("author", "authorId");

    /// Computed: 2-hop belongsTo (comment -> post -> author)
    static auto postAuthorName(Expr!Comment c) {
        return c.post.author.fullName;
    }

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

/// Holiday entity - a global reference table with no relationship to users.
/// Demonstrates cross-collection access from computed fields.
@Entity!(db, "holidays")
struct Holiday {
    mixin DemoId;
    mixin Col!("name", string);
    mixin Col!("date", string);
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

    mock.setTableData("holidays", `[
        {"id": 1, "name": "New Year", "date": "2026-01-01"},
        {"id": 2, "name": "Independence Day", "date": "2026-07-04"},
        {"id": 3, "name": "Christmas", "date": "2026-12-25"}
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
    SELECT posts.id, posts.title::text AS title
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

    // Verify generated SQL
    enum expectedSQL = q"EOF
WITH
  layer0 AS (
    SELECT posts.id, posts.title::text AS title, posts.body::text AS body, posts.author_id, j0.id AS j0__id, j0.first_name::text AS j0__first_name, j0.last_name::text AS j0__last_name, ((j0.first_name || ' ') || j0.last_name) AS computed_0
    FROM posts
    LEFT JOIN users j0 ON posts.author_id = j0.id
    WHERE posts.id = ANY($1)
  )
SELECT json_build_object(
  'layer0', (SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM layer0 t)
)
EOF";
    assert(db.getSQL() == expectedSQL, db.getSQL());

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

    // Verify generated SQL - 2-layer CTE: posts with author JOIN, comments with author JOIN
    enum expectedSQL = q"EOF
WITH
  layer0 AS (
    SELECT posts.id, posts.title::text AS title, posts.body::text AS body, posts.author_id, j0.id AS j0__id, j0.first_name::text AS j0__first_name, j0.last_name::text AS j0__last_name, ((j0.first_name || ' ') || j0.last_name) AS computed_0
    FROM posts
    LEFT JOIN users j0 ON posts.author_id = j0.id
    WHERE posts.id = ANY($1)
  ),
  layer1 AS (
    SELECT comments.id, comments.post_id, comments.body::text AS body, comments.author_id, j0.id AS j0__id, j0.first_name::text AS j0__first_name, j0.last_name::text AS j0__last_name, ((j0.first_name || ' ') || j0.last_name) AS computed_1
    FROM comments
    LEFT JOIN users j0 ON comments.author_id = j0.id
    WHERE comments.post_id IN (SELECT id FROM layer0)
  )
SELECT json_build_object(
  'layer0', (SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM layer0 t),
  'layer1', (SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM layer1 t)
)
EOF";
    assert(db.getSQL() == expectedSQL, db.getSQL());

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

    // Verify generated SQL
    enum expectedSQL = q"EOF
WITH
  layer0 AS (
    SELECT users.id, users.first_name::text AS first_name
    FROM users
    WHERE users.id = ANY($1)
  ),
  layer1 AS (
    SELECT posts.id, posts.author_id, posts.title::text AS title
    FROM posts
    WHERE posts.author_id IN (SELECT id FROM layer0)
  )
SELECT json_build_object(
  'layer0', (SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM layer0 t),
  'layer1', (SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM layer1 t)
)
EOF";
    assert(db.getSQL() == expectedSQL, db.getSQL());

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

    // Verify generated SQL
    enum expectedSQL = q"EOF
WITH
  layer0 AS (
    SELECT users.id, users.first_name::text AS first_name
    FROM users
    WHERE users.id = ANY($1)
  ),
  layer1 AS (
    SELECT posts.id, posts.author_id, posts.title::text AS title
    FROM posts
    WHERE posts.author_id IN (SELECT id FROM layer0)
  ),
  layer2 AS (
    SELECT comments.id, comments.author_id, comments.body::text AS body
    FROM comments
    WHERE comments.author_id IN (SELECT id FROM layer0)
  )
SELECT json_build_object(
  'layer0', (SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM layer0 t),
  'layer1', (SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM layer1 t),
  'layer2', (SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM layer2 t)
)
EOF";
    assert(db.getSQL() == expectedSQL, db.getSQL());

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
    import dunamis.graphql : compileQuery, Schema;

    createMockDB();  // Sets up the static db
    auto executor = new Executor();

    auto query = compileQuery!(Schema!Query)(`{
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

    // Verify generated SQL
    enum expectedSQL = q"EOF
WITH
  layer0 AS (
    SELECT users.id, users.first_name::text AS first_name, users.last_name::text AS last_name, users.email::text AS email
    FROM users
    WHERE 1=1
  )
SELECT json_build_object(
  'layer0', (SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM layer0 t)
)
EOF";
    assert(db.getSQL() == expectedSQL, db.getSQL());

    debug(sql) {
        writeln("\n=== Test: Basic query with scalar fields ===");
        db.printSQL();
    }
}

// Test: Query with computed field (fullName)
unittest {
    import std.stdio : writeln;
    import dunamis.graphql : compileQuery, Schema;

    createMockDB();
    auto executor = new Executor();

    auto query = compileQuery!(Schema!Query)(`{
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

    // Verify generated SQL
    enum expectedSQL = q"EOF
WITH
  layer0 AS (
    SELECT users.id, users.first_name::text AS first_name, users.last_name::text AS last_name, ((first_name || ' ') || last_name) AS computed_0
    FROM users
    WHERE 1=1
  ),
  layer1 AS (
    SELECT posts.id, posts.author_id, posts.title::text AS title
    FROM posts
    WHERE posts.author_id IN (SELECT id FROM layer0)
  )
SELECT json_build_object(
  'layer0', (SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM layer0 t),
  'layer1', (SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM layer1 t)
)
EOF";
    assert(db.getSQL() == expectedSQL, db.getSQL());

    debug(sql) {
        writeln("\n=== Test: Query with computed field ===");
        db.printSQL();
    }
}

// Test: 3-level nesting (users -> posts -> comments)
unittest {
    import std.stdio : writeln;
    import dunamis.graphql : compileQuery, Schema;

    createMockDB();
    auto executor = new Executor();

    auto query = compileQuery!(Schema!Query)(`{
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

    // Verify generated SQL
    enum expectedSQL = q"EOF
WITH
  layer0 AS (
    SELECT users.id, users.first_name::text AS first_name, users.last_name::text AS last_name, ((first_name || ' ') || last_name) AS computed_0
    FROM users
    WHERE 1=1
  ),
  layer1 AS (
    SELECT posts.id, posts.author_id, posts.title::text AS title
    FROM posts
    WHERE posts.author_id IN (SELECT id FROM layer0)
  ),
  layer2 AS (
    SELECT comments.id, comments.post_id, comments.body::text AS body
    FROM comments
    WHERE comments.post_id IN (SELECT id FROM layer1)
  )
SELECT json_build_object(
  'layer0', (SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM layer0 t),
  'layer1', (SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM layer1 t),
  'layer2', (SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM layer2 t)
)
EOF";
    assert(db.getSQL() == expectedSQL, db.getSQL());

    debug(sql) {
        writeln("\n=== Test: 3-level nesting (users -> posts -> comments) ===");
        db.printSQL();
    }
}

// Test: Computed field with arguments
unittest {
    import std.stdio : writeln;
    import dunamis.graphql : compileQuery, Schema;

    createMockDB();
    auto executor = new Executor();

    // User.greeting takes (prefix: String!, suffix: String = "!")
    auto query = compileQuery!(Schema!Query)(`{
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

    // Verify generated SQL - arguments become SQL string literals
    enum expectedSQL = q"EOF
WITH
  layer0 AS (
    SELECT users.id, users.first_name::text AS first_name, (('Hello ' || first_name) || '!') AS computed_0
    FROM users
    WHERE 1=1
  )
SELECT json_build_object(
  'layer0', (SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM layer0 t)
)
EOF";
    assert(db.getSQL() == expectedSQL, db.getSQL());

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
    auto sqlOpt = new SqlOptimizer(testDialect());
    sqlOpt.optimize(optimized, optCtx);

    // Get the relational optimization context
    auto relCtx = optCtx.getSourceContext!RelationalOptimizeContext();

    // Verify computed column was created
    auto nodes = relCtx.allNodes();
    assert(nodes.length == 1);

    auto computed = nodes[0].computedColumns;
    assert(computed.length >= 1, "Should have at least 1 computed column for fullName");

    // Verify the full SQL output
    auto sql = toSQL(relCtx.nodesInOrder(), testDialect());
    enum expectedSQL = q"EOF
WITH
  layer0 AS (
    SELECT users.id, users.first_name::text AS first_name, users.last_name::text AS last_name, ((first_name || ' ') || last_name) AS computed_0
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

// Computed columns belong to the optimized tree: a data source's SqlOptimizer
// serves every request, and optimizing another query in between must not
// change the SQL of a tree optimized earlier.
unittest {
    import std.algorithm : canFind;

    auto sqlOpt = new SqlOptimizer(testDialect());
    QueryNode[] optimizeWith(E)(E query) {
        auto optCtx = new OptimizeContext();
        auto optimized = query.optimize(optCtx);
        sqlOpt.optimize(optimized, optCtx);
        return optCtx.getSourceContext!RelationalOptimizeContext().nodesInOrder();
    }

    auto nodesA = optimizeWith(map!((Expr!User user) => user.fullName)(getByIds!User([1, 2])));
    auto nodesB = optimizeWith(map!((Expr!User user) => user.lastName ~ ", " ~ user.firstName)(
        getByIds!User([3])));

    auto sqlA = toSQL(nodesA, testDialect());
    auto sqlB = toSQL(nodesB, testDialect());
    assert(sqlA.canFind("((first_name || ' ') || last_name) AS computed_0"), sqlA);
    assert(!sqlA.canFind("', '"), sqlA);
    assert(sqlB.canFind("((last_name || ', ') || first_name) AS computed_0"), sqlB);
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

    // Verify generated SQL - same structure as compileQuery version but with getByIds
    enum expectedSQL = q"EOF
WITH
  layer0 AS (
    SELECT users.id, users.first_name::text AS first_name, (('Hello ' || first_name) || '!') AS computed_0
    FROM users
    WHERE users.id = ANY($1)
  )
SELECT json_build_object(
  'layer0', (SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM layer0 t)
)
EOF";
    assert(db.getSQL() == expectedSQL, db.getSQL());

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
    import dunamis.graphql;

    // Generate complete schema SDL - Schema normalizes all types first
    enum schema = generateSchemaSDL!(Schema!Query);

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
  holidays: [Holiday!]!
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
  localizedGreeting: String!
  validatedName: String!
  availability: String!
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
  postAuthorName: String!
  html: String!
}

type Holiday {
  id: Int64!
  name: String!
  date: String!
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
    import dunamis.graphql;

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
    import dunamis.graphql;

    enum queryFields = getFields!Query;

    // Should have: users, posts, comments, holidays
    assert(queryFields.length == 4);

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
    import dunamis.postgres.ddl : generateDDL;

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

CREATE TABLE holidays (
  id BIGSERIAL PRIMARY KEY,
  name TEXT NOT NULL,
  date TEXT NOT NULL
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
    import dunamis.postgres.ddl : generateCreateTable;

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

// Test predicate-based sorting with sortBy (ASC, using getAll)
unittest {
    import dunamis.core.sorting : sortBy;

    auto mock = new MockDB!()();
    mock.setTableData("users", `[
        {"id": 1, "first_name": "Charlie", "last_name": "Zebra"},
        {"id": 2, "first_name": "Alice", "last_name": "Young"},
        {"id": 3, "first_name": "Bob", "last_name": "Xavier"}
    ]`);

    db = new DebugSqlDB!()(mock, testDialect());
    auto executor = new Executor();

    // Sort by firstName ASC using getAll
    auto query = map!(
        (Expr!User u) => u.firstName
    )(sortBy!((a, b) => a.firstName.lt(b.firstName))(getAll!User()));

    auto names = awaitSync(executor.execute(query));

    // Should be sorted: Alice, Bob, Charlie
    assert(names.length == 3);
    assert(names[0] == "Alice", "First should be Alice, got: " ~ names[0]);
    assert(names[1] == "Bob", "Second should be Bob, got: " ~ names[1]);
    assert(names[2] == "Charlie", "Third should be Charlie, got: " ~ names[2]);

    // Verify generated SQL
    enum expectedSQL = q"EOF
WITH
  layer0 AS (
    SELECT users.id, users.first_name::text AS first_name
    FROM users
    WHERE 1=1
    ORDER BY users.first_name
  )
SELECT json_build_object(
  'layer0', (SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM (SELECT * FROM layer0 ORDER BY first_name) t)
)
EOF";
    assert(db.getSQL() == expectedSQL, db.getSQL());

    debug(sql) {
        import std.stdio : writeln;
        writeln("\n=== Test: Column-based sorting (first_name ASC) ===");
        db.printSQL();
    }
}

// Test descending sort
unittest {
    import dunamis.core.sorting : sortBy;

    auto mock = new MockDB!()();
    mock.setTableData("users", `[
        {"id": 1, "first_name": "Charlie"},
        {"id": 2, "first_name": "Alice"},
        {"id": 3, "first_name": "Bob"}
    ]`);

    db = new DebugSqlDB!()(mock, testDialect());
    auto executor = new Executor();

    // Sort by firstName DESC
    auto query = map!(
        (Expr!User u) => u.firstName
    )(sortBy!((a, b) => a.firstName.gt(b.firstName))(getAll!User()));

    auto names = awaitSync(executor.execute(query));

    // Should be sorted: Charlie, Bob, Alice
    assert(names.length == 3);
    assert(names[0] == "Charlie", "First should be Charlie, got: " ~ names[0]);
    assert(names[1] == "Bob", "Second should be Bob, got: " ~ names[1]);
    assert(names[2] == "Alice", "Third should be Alice, got: " ~ names[2]);

    // Verify generated SQL
    enum expectedSQL = q"EOF
WITH
  layer0 AS (
    SELECT users.id, users.first_name::text AS first_name
    FROM users
    WHERE 1=1
    ORDER BY users.first_name DESC
  )
SELECT json_build_object(
  'layer0', (SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM (SELECT * FROM layer0 ORDER BY first_name DESC) t)
)
EOF";
    assert(db.getSQL() == expectedSQL, db.getSQL());
}

// Test predicate-based sorting with sortBy
unittest {
    import dunamis.core.sorting : sortBy;

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
    import dunamis.core.sorting : sortBy;

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
    import dunamis.core.sorting : sortBy;
    import dunamis.core.pagination : limit, offset;

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

    // Sort by firstName ASC, then skip 1 and take 2
    auto query = map!(
        (Expr!User u) => u.firstName
    )(limit(offset(sortBy!((a, b) => a.firstName.lt(b.firstName))(getAll!User()), 1), 2));

    auto names = awaitSync(executor.execute(query));

    // Should be: Bob, Charlie (sorted: Alice, Bob, Charlie, David, Eve → skip 1 → Bob, Charlie, David, Eve → take 2 → Bob, Charlie)
    assert(names.length == 2);
    assert(names[0] == "Bob", "First should be Bob, got: " ~ names[0]);
    assert(names[1] == "Charlie", "Second should be Charlie, got: " ~ names[1]);

    // Verify generated SQL
    enum expectedSQL = q"EOF
WITH
  layer0 AS (
    SELECT users.id, users.first_name::text AS first_name
    FROM users
    WHERE 1=1
    ORDER BY users.first_name
    LIMIT 2
    OFFSET 1
  )
SELECT json_build_object(
  'layer0', (SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM (SELECT * FROM layer0 ORDER BY first_name) t)
)
EOF";
    assert(db.getSQL() == expectedSQL, db.getSQL());

    debug(sql) {
        import std.stdio : writeln;
        writeln("\n=== Test: Sorting + pagination ===");
        db.printSQL();
    }
}

// ============================================================================
// some/every Tests
// ============================================================================

// Test some() - basic predicate matching
unittest {
    auto mock = new MockDB!()();
    mock.setTableData("users", `[
        {"id": 1, "first_name": "Alice"},
        {"id": 2, "first_name": "Bob"}
    ]`);
    mock.setTableData("posts", `[
        {"id": 1, "author_id": 1, "title": "Hello", "body": "World"},
        {"id": 2, "author_id": 1, "title": "", "body": "Empty title"},
        {"id": 3, "author_id": 2, "title": "", "body": "Bob's post"}
    ]`);

    db = new DebugSqlDB!()(mock, testDialect());
    auto executor = new Executor();

    // Test: which users have at least one post with non-empty title
    auto query = map!(
        (Expr!User u) => jsonObject(
            "name", u.firstName,
            "hasTitledPost", some!((Expr!Post p) => p.title.ne(""))(u.posts)
        )
    )(getByIds!User([1, 2]));

    auto result = awaitSync(executor.execute(query));

    assert(result.length == 2);
    // Alice has post with title "Hello" → true
    assert(result[0]["name"].str == "Alice");
    assert(result[0]["hasTitledPost"].boolean == true, "Alice should have at least one post with title");
    // Bob has only posts with empty titles → false
    assert(result[1]["name"].str == "Bob");
    assert(result[1]["hasTitledPost"].boolean == false, "Bob should not have any posts with title");

    // Verify generated SQL - some() becomes EXISTS subquery
    enum expectedSQL = q"EOF
WITH
  layer0 AS (
    SELECT users.id, users.first_name::text AS first_name, EXISTS (SELECT 1 FROM posts WHERE posts.author_id = users.id AND (posts.title <> '')) AS computed_0
    FROM users
    WHERE users.id = ANY($1)
  )
SELECT json_build_object(
  'layer0', (SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM layer0 t)
)
EOF";
    assert(db.getSQL() == expectedSQL, db.getSQL());

    debug(sql) {
        import std.stdio : writeln;
        writeln("\n=== Test: some() with title predicate ===");
        db.printSQL();
    }
}

// Test every() - all items must match
unittest {
    auto mock = new MockDB!()();
    mock.setTableData("users", `[
        {"id": 1, "first_name": "Alice"},
        {"id": 2, "first_name": "Bob"},
        {"id": 3, "first_name": "Charlie"}
    ]`);
    mock.setTableData("posts", `[
        {"id": 1, "author_id": 1, "title": "Post 1", "body": "Content"},
        {"id": 2, "author_id": 1, "title": "Post 2", "body": "Content"},
        {"id": 3, "author_id": 2, "title": "Hello", "body": "Content"},
        {"id": 4, "author_id": 2, "title": "", "body": "No title"}
    ]`);
    // Charlie has no posts

    db = new DebugSqlDB!()(mock, testDialect());
    auto executor = new Executor();

    // Test: which users have ALL posts with non-empty title
    auto query = map!(
        (Expr!User u) => jsonObject(
            "name", u.firstName,
            "allPostsTitled", every!((Expr!Post p) => p.title.ne(""))(u.posts)
        )
    )(getByIds!User([1, 2, 3]));

    auto result = awaitSync(executor.execute(query));

    assert(result.length == 3);
    // Alice: all posts have titles → true
    assert(result[0]["name"].str == "Alice");
    assert(result[0]["allPostsTitled"].boolean == true, "Alice's posts should all have titles");
    // Bob: has one post without title → false
    assert(result[1]["name"].str == "Bob");
    assert(result[1]["allPostsTitled"].boolean == false, "Bob should have at least one untitled post");
    // Charlie: no posts (vacuous truth) → true
    assert(result[2]["name"].str == "Charlie");
    assert(result[2]["allPostsTitled"].boolean == true, "Charlie with no posts should satisfy every()");

    // Verify generated SQL - every() becomes EXISTS with NOT predicate
    enum expectedSQL = q"EOF
WITH
  layer0 AS (
    SELECT users.id, users.first_name::text AS first_name, EXISTS (SELECT 1 FROM posts WHERE posts.author_id = users.id AND (NOT (posts.title <> ''))) AS computed_0
    FROM users
    WHERE users.id = ANY($1)
  )
SELECT json_build_object(
  'layer0', (SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM layer0 t)
)
EOF";
    assert(db.getSQL() == expectedSQL, db.getSQL());

    debug(sql) {
        import std.stdio : writeln;
        writeln("\n=== Test: every() with title predicate ===");
        db.printSQL();
    }
}

// Test some() with empty collection
unittest {
    auto mock = new MockDB!()();
    mock.setTableData("users", `[
        {"id": 1, "first_name": "Alice"}
    ]`);
    mock.setTableData("posts", `[]`);  // No posts at all

    db = new DebugSqlDB!()(mock, testDialect());
    auto executor = new Executor();

    // Test: some() on empty collection should return false
    auto query = map!(
        (Expr!User u) => some!((Expr!Post p) => p.title.ne(""))(u.posts)
    )(getByIds!User([1]));

    auto result = awaitSync(executor.execute(query));

    assert(result.length == 1);
    assert(result[0] == false, "some() on empty collection should be false");
}

// Test every() with empty collection (vacuous truth)
unittest {
    auto mock = new MockDB!()();
    mock.setTableData("users", `[
        {"id": 1, "first_name": "Alice"}
    ]`);
    mock.setTableData("posts", `[]`);  // No posts at all

    db = new DebugSqlDB!()(mock, testDialect());
    auto executor = new Executor();

    // Test: every() on empty collection should return true (vacuous truth)
    auto query = map!(
        (Expr!User u) => every!((Expr!Post p) => p.title.ne(""))(u.posts)
    )(getByIds!User([1]));

    auto result = awaitSync(executor.execute(query));

    assert(result.length == 1);
    assert(result[0] == true, "every() on empty collection should be true (vacuous truth)");
}

// ============================================================================
// SQL Snapshot Tests - Optimization Pattern Coverage
// ============================================================================
//
// These tests verify that specific query patterns produce the expected SQL,
// making optimization decisions (JOINs, CTEs, pushdown) explicit and testable.

// Test belongsTo JOIN - single hop (post with author.firstName via JOIN)
unittest {
    auto db = createMockDB();
    auto executor = new Executor();

    // Accessing a belongsTo relationship field should produce a JOIN, not a separate CTE
    auto query = map!(
        (Expr!Post p) => jsonObject(
            "title", p.title,
            "authorName", p.author.firstName
        )
    )(getByIds!Post([1, 2]));

    auto result = awaitSync(executor.execute(query));
    assert(result.length == 2);
    assert(result[0]["title"].str == "Hello World");
    assert(result[0]["authorName"].str == "Alice");
    assert(result[1]["title"].str == "D Programming");
    assert(result[1]["authorName"].str == "Bob");

    // Verify generated SQL - belongsTo produces LEFT JOIN, not a separate CTE
    enum expectedSQL = q"EOF
WITH
  layer0 AS (
    SELECT posts.id, posts.title::text AS title, posts.author_id, j0.id AS j0__id, j0.first_name::text AS j0__first_name
    FROM posts
    LEFT JOIN users j0 ON posts.author_id = j0.id
    WHERE posts.id = ANY($1)
  )
SELECT json_build_object(
  'layer0', (SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM layer0 t)
)
EOF";
    assert(db.getSQL() == expectedSQL, db.getSQL());
}

// Test belongsTo JOIN from Comment - single hop (comment.author.firstName)
unittest {
    auto db = createMockDB();
    auto executor = new Executor();

    // Comment -> author via belongsTo JOIN
    auto query = map!(
        (Expr!Comment c) => jsonObject(
            "body", c.body_,
            "authorName", c.author.firstName
        )
    )(getByIds!Comment([101, 102]));

    auto result = awaitSync(executor.execute(query));
    assert(result.length == 2);
    assert(result[0]["body"].str == "Great post!");
    assert(result[0]["authorName"].str == "Bob");
    assert(result[1]["body"].str == "Thanks for sharing!");
    assert(result[1]["authorName"].str == "Carol");

    // Verify generated SQL - single-hop belongsTo JOIN from comments to users
    enum expectedSQL = q"EOF
WITH
  layer0 AS (
    SELECT comments.id, comments.body::text AS body, comments.author_id, j0.id AS j0__id, j0.first_name::text AS j0__first_name
    FROM comments
    LEFT JOIN users j0 ON comments.author_id = j0.id
    WHERE comments.id = ANY($1)
  )
SELECT json_build_object(
  'layer0', (SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM layer0 t)
)
EOF";
    assert(db.getSQL() == expectedSQL, db.getSQL());
}

// Test multi-hop belongsTo chain (comment.post.author.firstName - 2 JOINs)
unittest {
    auto db = createMockDB();
    auto executor = new Executor();

    // Two-hop belongsTo: comment -> post -> author
    auto query = map!(
        (Expr!Comment c) => jsonObject(
            "body", c.body_,
            "postAuthor", c.post.author.firstName
        )
    )(getByIds!Comment([101, 102]));

    auto result = awaitSync(executor.execute(query));

    assert(result.length == 2);
    assert(result[0]["body"].str == "Great post!");
    // Both comments 101 and 102 are on post 1, authored by Alice
    assert(result[0]["postAuthor"].str == "Alice");
    assert(result[1]["postAuthor"].str == "Alice");

    // Verify generated SQL - two chained LEFT JOINs, second references first join alias
    enum expectedSQL = q"EOF
WITH
  layer0 AS (
    SELECT comments.id, comments.body::text AS body, comments.post_id, j0.id AS j0__id, j0.author_id AS j0__author_id, j1.id AS j1__id, j1.first_name::text AS j1__first_name
    FROM comments
    LEFT JOIN posts j0 ON comments.post_id = j0.id
    LEFT JOIN users j1 ON j0.author_id = j1.id
    WHERE comments.id = ANY($1)
  )
SELECT json_build_object(
  'layer0', (SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM layer0 t)
)
EOF";
    assert(db.getSQL() == expectedSQL, db.getSQL());
}

// Test multi-hop belongsTo via compileQuery (comment.post.author - 2 JOINs)
unittest {
    import dunamis.graphql : compileQuery, Schema;

    createMockDB();  // Sets up the static db
    auto executor = new Executor();

    auto query = compileQuery!(Schema!Query)(`{
        comments {
            body
            postAuthorName
        }
    }`);

    auto result = awaitSync(executor.execute(query));

    auto comments = result["comments"].array;
    assert(comments.length == 3);
    // Comment 101 is on post 1 (by Alice), comment 103 is on post 2 (by Bob)
    // Verify postAuthorName resolves through 2-hop chain
    assert(comments[0]["postAuthorName"].str == "Alice Smith", comments[0]["postAuthorName"].str);
    assert(comments[2]["postAuthorName"].str == "Bob Jones", comments[2]["postAuthorName"].str);
}

// Test multi-hop belongsTo via nested GraphQL sub-selection (comment.post.author)
unittest {
    import dunamis.graphql : compileQuery, Schema;

    createMockDB();
    auto executor = new Executor();

    auto query = compileQuery!(Schema!Query)(`{
        comments {
            body
            post {
                title
                author { firstName }
            }
        }
    }`);

    auto result = awaitSync(executor.execute(query));

    auto comments = result["comments"].array;
    assert(comments.length == 3, "Expected 3 comments, got " ~ comments.length.to!string);
    // Comment 101 is on post 1 ("Hello World") by Alice
    assert(comments[0]["post"]["title"].str == "Hello World", comments[0]["post"]["title"].str);
    assert(comments[0]["post"]["author"]["firstName"].str == "Alice",
        "Expected Alice, got: " ~ comments[0]["post"]["author"]["firstName"].str);
}

// Test getAll root expression (no ID filtering)
unittest {
    auto db = createMockDB();
    auto executor = new Executor();

    auto query = map!(
        (Expr!User u) => u.firstName
    )(getAll!User());

    auto result = awaitSync(executor.execute(query));
    assert(result.length == 3);

    // Verify generated SQL - getAll produces WHERE 1=1 (no ID filtering)
    enum expectedSQL = q"EOF
WITH
  layer0 AS (
    SELECT users.id, users.first_name::text AS first_name
    FROM users
    WHERE 1=1
  )
SELECT json_build_object(
  'layer0', (SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM layer0 t)
)
EOF";
    assert(db.getSQL() == expectedSQL, db.getSQL());
}

// Test computed field with arguments - SQL push-down verification
unittest {
    auto db = createMockDB();
    auto executor = new Executor();

    // greeting("Hello") should push constant string args into SQL as literals
    auto query = map!(
        (Expr!User u) => u.greeting("Hello")
    )(getByIds!User([1, 2]));

    auto result = awaitSync(executor.execute(query));
    assert(result.length == 2);
    assert(result[0] == "Hello Alice!");
    assert(result[1] == "Hello Bob!");

    // Verify generated SQL - constant args become SQL string literals in computed column
    enum expectedSQL = q"EOF
WITH
  layer0 AS (
    SELECT users.id, users.first_name::text AS first_name, (('Hello ' || first_name) || '!') AS computed_0
    FROM users
    WHERE users.id = ANY($1)
  )
SELECT json_build_object(
  'layer0', (SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM layer0 t)
)
EOF";
    assert(db.getSQL() == expectedSQL, db.getSQL());
}

// ============================================================================
// Plugin + compileQuery SQL Generation Tests
// ============================================================================
//
// These tests verify that compileQuery with plugins (SortingPlugin,
// PaginationPlugin) generates optimized CTE-based SQL. Before the
// EntityCastExpr fix, all plugin-wrapped compileQuery paths fell back
// to naive row-by-row evaluation (no SQL generation at all).

// Test: compileQuery with SortingPlugin generates CTE with ORDER BY
unittest {
    import dunamis.graphql : compileQuery, Schema;
    import dunamis.schema.sorting : SortingPlugin;
    import dunamis.graphql.schema : Schema;

    createMockDB();
    auto executor = new Executor();

    alias SortedSchema = SortingPlugin!(Schema!Query);

    auto query = compileQuery!SortedSchema(`{
        users(orderBy: [{field: firstName, direction: ASC}]) {
            firstName
        }
    }`);

    auto result = awaitSync(executor.execute(query));

    auto users = result["users"].array;
    assert(users.length == 3);
    assert(users[0]["firstName"].str == "Alice");
    assert(users[1]["firstName"].str == "Bob");
    assert(users[2]["firstName"].str == "Carol");

    // Verify CTE-based SQL was generated (proves optimization is active)
    auto sql = db.getSQL();
    assert(sql.length > 0, "Expected CTE SQL to be generated (optimization active)");
    assert(sql.canFind("ORDER BY"), "Expected ORDER BY in generated SQL: " ~ sql);
    assert(sql.canFind("first_name"), "Expected first_name column in SQL: " ~ sql);
}

// Test: compileQuery with PaginationPlugin generates CTE with LIMIT/OFFSET
unittest {
    import dunamis.graphql : compileQuery, Schema;
    import dunamis.schema.pagination : PaginationPlugin;
    import dunamis.graphql.schema : Schema;

    createMockDB();
    auto executor = new Executor();

    alias PaginatedSchema = PaginationPlugin!(Schema!Query);

    auto query = compileQuery!PaginatedSchema(`{
        users(first: 2) {
            firstName
        }
    }`);

    auto result = awaitSync(executor.execute(query));

    auto users = result["users"].array;
    assert(users.length == 2, "Should have 2 users with first:2");

    // Verify CTE-based SQL has LIMIT
    auto sql = db.getSQL();
    assert(sql.length > 0, "Expected CTE SQL to be generated (optimization active)");
    assert(sql.canFind("LIMIT 2"), "Expected LIMIT 2 in generated SQL: " ~ sql);
}

// Test: compileQuery with nested HasMany generates multi-layer CTE
unittest {
    import dunamis.graphql : compileQuery, Schema;
    import dunamis.graphql.schema : Schema;

    createMockDB();
    auto executor = new Executor();

    auto query = compileQuery!(Schema!Query)(`{
        users {
            firstName
            posts {
                title
            }
        }
    }`);

    auto result = awaitSync(executor.execute(query));

    auto users = result["users"].array;
    assert(users.length == 3);
    // Alice has 2 posts
    assert(users[0]["posts"].array.length == 2);

    // Verify multi-layer CTE (parent + child)
    auto sql = db.getSQL();
    assert(sql.length > 0, "Expected CTE SQL to be generated");
    assert(sql.canFind("layer0"), "Expected layer0 (users) in SQL: " ~ sql);
    assert(sql.canFind("layer1"), "Expected layer1 (posts) in SQL: " ~ sql);
}

// ============================================================================
// Cross-Collection Access Tests
// ============================================================================

// Test: Computed field accessing an unrelated global table via broadcast()
unittest {
    import std.stdio : writeln;

    auto db = createMockDB();
    auto executor = new Executor();

    // User.availability accesses the holidays table (unrelated to users)
    // via singleton(Query.init).holidays() + broadcast()
    auto query = map!(
        (Expr!User u) => jsonObject(
            "firstName", u.firstName,
            "availability", u.availability
        )
    )(getByIds!User([1, 2]));

    auto result = awaitSync(executor.execute(query));

    assert(result.length == 2);
    assert(result[0]["firstName"].str == "Alice");
    assert(result[0]["availability"].str == "Alice has 3 holidays");
    assert(result[1]["firstName"].str == "Bob");
    assert(result[1]["availability"].str == "Bob has 3 holidays");

    debug(sql) {
        writeln("\n=== Test: Cross-collection access (User.availability) ===");
        db.printSQL();
    }
}

// Test: Direct broadcast() usage — extract data at expression level, then broadcast
unittest {
    auto db = createMockDB();
    auto executor = new Executor();

    // Extract holiday names via UFCS chain, then broadcast to each user
    auto holidayNames = Query().singleton().holidays()
        .map!((Expr!Holiday h) => h.name);

    auto query = map!(
        (Expr!User u) => use(
            (string userName, string[] allHolidayNames) {
                import std.array : join;
                return userName ~ ": " ~ allHolidayNames.join(", ");
            },
            u.firstName,
            holidayNames.broadcast(u)
        )
    )(getByIds!User([1, 2, 3]));

    auto result = awaitSync(executor.execute(query));

    assert(result.length == 3);
    assert(result[0] == "Alice: New Year, Independence Day, Christmas");
    assert(result[1] == "Bob: New Year, Independence Day, Christmas");
    assert(result[2] == "Carol: New Year, Independence Day, Christmas");
}

// ============================================================================
// Request Context Tests
// ============================================================================

// Test: Request context with French locale
unittest {
    auto db = createMockDB();
    auto executor = new Executor();

    auto query = map!(
        (Expr!User u) => u.localizedGreeting
    )(getByIds!User([1, 2]));

    auto evalCtx = new EvalContext();
    evalCtx.setRequestContext(RequestContext("fr"));
    auto result = awaitSync(executor.execute(query, evalCtx));

    assert(result.length == 2);
    assert(result[0] == "Bonjour Alice");
    assert(result[1] == "Bonjour Bob");
}

// Test: Request context with Spanish locale
unittest {
    auto db = createMockDB();
    auto executor = new Executor();

    auto query = map!(
        (Expr!User u) => u.localizedGreeting
    )(getByIds!User([1, 2]));

    auto evalCtx = new EvalContext();
    evalCtx.setRequestContext(RequestContext("es"));
    auto result = awaitSync(executor.execute(query, evalCtx));

    assert(result.length == 2);
    assert(result[0] == "Hola Alice");
    assert(result[1] == "Hola Bob");
}

// Test: Request context with default (English) locale
unittest {
    auto db = createMockDB();
    auto executor = new Executor();

    auto query = map!(
        (Expr!User u) => u.localizedGreeting
    )(getByIds!User([1, 2]));

    auto evalCtx = new EvalContext();
    evalCtx.setRequestContext(RequestContext("en"));
    auto result = awaitSync(executor.execute(query, evalCtx));

    assert(result.length == 2);
    assert(result[0] == "Hello Alice");
    assert(result[1] == "Hello Bob");
}

// Test: GqlResult auto-materialization in GraphQL compiler
// Fields returning GqlResult!T are automatically materialized to Nullable!T,
// with errors recorded in the response.
unittest {
    import dunamis.graphql : compileQuery, Schema;

    createMockDB();
    auto executor = new Executor();

    // validatedName uses tryUse: "Bob" and "Carol" contain 'o' so they error.
    // Since validatedName is String! (non-null), the error causes null bubbling:
    // the parent User becomes null; users is [User!]!, so the null item makes
    // the list null, and users being non-null makes the whole result null.
    auto query = compileQuery!(Schema!Query)(`{
        users {
            firstName
            validatedName
        }
    }`);

    auto evalCtx = new EvalContext();
    auto result = awaitSync(executor.execute(query, evalCtx));

    assert(result.isNull, "Non-null field errors should bubble up to the result");

    // Errors should have been recorded with paths
    assert(evalCtx.hasErrors);
    auto errors = evalCtx.errors;
    assert(errors.length == 2);
    assert(errors[0].message == "Name contains 'o'");
    assert(errors[1].message == "Name contains 'o'");
}

// Test: null bubbling also applies to aliased non-null fields.
// Nullability must be looked up by the schema field name, not the alias.
unittest {
    import dunamis.graphql : compileQuery, Schema;

    createMockDB();
    auto executor = new Executor();

    auto query = compileQuery!(Schema!Query)(`{
        users {
            name: firstName
            checked: validatedName
        }
    }`);

    auto evalCtx = new EvalContext();
    auto result = awaitSync(executor.execute(query, evalCtx));

    // validatedName is String!, so its error nulls the user (and, through
    // [User!]! and the non-null root field, the whole result) even when aliased
    assert(result.isNull, "Aliased non-null field errors should bubble up to the result");

    assert(evalCtx.errors.length == 2);
    assert(evalCtx.errors[0].message == "Name contains 'o'");
    assert(evalCtx.errors[1].message == "Name contains 'o'");
}
