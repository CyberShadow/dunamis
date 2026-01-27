module graphqld2.example2;

import std.algorithm;
import std.array;
import std.conv;
import std.json;

import graphqld2.core;
import graphqld2.relational;
import graphqld2.executor;

// ============================================================================
// Domain Model - Demonstrates business logic with relationships
// ============================================================================

/// Comment entity - belongs to a Post and has an author (User)
struct Comment {
    mixin Entity!"comments";

    static Expr!string body_() => column!string("body");
    static Expr!long authorId() => column!long("author_id");

    static auto author() => belongsTo!(User, "author_id");

    /// Computed: render comment as HTML with author name
    static auto html() => use(
        (string body_, string authorName) =>
            `<div class="comment">
                <span class="author">` ~ authorName ~ `</span>
                <p>` ~ body_ ~ `</p>
            </div>`,
        body_(),
        author().fullName()
    );
}

/// User entity
struct User {
    mixin Entity!"users";

    static Expr!string firstName() => column!string("first_name");
    static Expr!string lastName() => column!string("last_name");
    static Expr!string email() => column!string("email");

    static auto fullName() => use(
        (string first, string last) => first ~ " " ~ last,
        firstName(),
        lastName()
    );

    static auto posts() => hasMany!(Post, "author_id");
}

/// Post entity - belongs to a User (author) and has many Comments
struct Post {
    mixin Entity!"posts";

    static Expr!string title() => column!string("title");
    static Expr!string body_() => column!string("body");
    static Expr!long authorId() => column!long("author_id");

    static auto author() => belongsTo!(User, "author_id");
    static auto comments() => hasMany!(Comment, "post_id");

    /// Computed: render full post as HTML with author and comments
    static auto html() => use(
        (string title, string body_, string authorName, string[] commentHtmls) =>
            `<article class="post">
                <header>
                    <h1>` ~ title ~ `</h1>
                    <p class="byline">By ` ~ authorName ~ `</p>
                </header>
                <div class="content">` ~ body_ ~ `</div>
                <section class="comments">
                    <h2>Comments (` ~ commentHtmls.length.to!string ~ `)</h2>
                    ` ~ commentHtmls.join("\n") ~ `
                </section>
            </article>`,
        title(),
        body_(),
        author().fullName(),
        comments().html()
    );

    /// Computed: short summary for listings
    static auto summary() => use(
        (string title, string body_, string authorName) {
            auto truncated = body_.length > 100 ? body_[0..100] ~ "..." : body_;
            return title ~ " by " ~ authorName ~ " - " ~ truncated;
        },
        title(),
        body_(),
        author().fullName()
    );
}

// ============================================================================
// Test with mock database
// ============================================================================

unittest {
    // Create test database with sample data
    auto db = new TestDatabase();
    db.setResponse("*", `{
        "layer0": [
            {"id": 1, "title": "Hello World", "body": "This is my first post!", "author_id": 1},
            {"id": 2, "title": "D Programming", "body": "D is a great language for systems programming.", "author_id": 2}
        ],
        "layer1": [
            {"id": 1, "first_name": "Alice", "last_name": "Smith"},
            {"id": 2, "first_name": "Bob", "last_name": "Jones"}
        ],
        "layer2": [
            {"id": 101, "post_id": 1, "body": "Great post!", "author_id": 2},
            {"id": 102, "post_id": 1, "body": "Thanks for sharing!", "author_id": 3},
            {"id": 103, "post_id": 2, "body": "I agree!", "author_id": 1}
        ],
        "layer3": [
            {"id": 1, "first_name": "Alice", "last_name": "Smith"},
            {"id": 2, "first_name": "Bob", "last_name": "Jones"},
            {"id": 3, "first_name": "Carol", "last_name": "White"}
        ]
    }`);

    // Test simple field
    {
        auto executor = new Executor!Post(db);
        auto titles = executor.execute(Post.title(), [1L, 2L]);
        assert(titles == ["Hello World", "D Programming"]);
    }

    // Test computed field with belongsTo
    {
        auto executor = new Executor!Post(db);
        auto summaries = executor.execute(Post.summary(), [1L, 2L]);

        assert(summaries[0].canFind("Hello World"));
        assert(summaries[0].canFind("Alice Smith"));
        assert(summaries[1].canFind("D Programming"));
        assert(summaries[1].canFind("Bob Jones"));
    }
}

// Test Post.html - full 4-layer query with nested relationships
unittest {
    auto db = new TestDatabase();
    db.setResponse("*", `{
        "layer0": [
            {"id": 1, "title": "Hello World", "body": "First post", "author_id": 1}
        ],
        "layer1": [
            {"id": 1, "first_name": "Alice", "last_name": "Smith"}
        ],
        "layer2": [
            {"id": 101, "post_id": 1, "body": "Great!", "author_id": 2}
        ],
        "layer3": [
            {"id": 2, "first_name": "Bob", "last_name": "Jones"}
        ]
    }`);

    auto executor = new Executor!Post(db);
    auto htmls = executor.execute(Post.html(), [1L]);

    assert(htmls.length == 1);
    assert(htmls[0].canFind("Hello World"));
    assert(htmls[0].canFind("Alice Smith"));
    assert(htmls[0].canFind("Great!"));
    assert(htmls[0].canFind("Bob Jones"));
}
