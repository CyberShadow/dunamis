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

/// User entity
struct User {
    mixin Entity!"users";
    mixin Col!("firstName", string);
    mixin Col!("lastName", string);
    mixin Col!("email", string);
    mixin HasMany!("posts", Post, "author_id");

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

unittest {
    // Create mock fetcher with sample data
    auto fetcher = new MockDataFetcher();

    fetcher.setTableData("posts", `[
        {"id": 1, "title": "Hello World", "body": "This is my first post!", "author_id": 1},
        {"id": 2, "title": "D Programming", "body": "D is a great language for systems programming.", "author_id": 2}
    ]`);

    fetcher.setTableData("users", `[
        {"id": 1, "first_name": "Alice", "last_name": "Smith"},
        {"id": 2, "first_name": "Bob", "last_name": "Jones"},
        {"id": 3, "first_name": "Carol", "last_name": "White"}
    ]`);

    fetcher.setTableData("comments", `[
        {"id": 101, "post_id": 1, "body": "Great post!", "author_id": 2},
        {"id": 102, "post_id": 1, "body": "Thanks for sharing!", "author_id": 3},
        {"id": 103, "post_id": 2, "body": "I agree!", "author_id": 1}
    ]`);

    auto executor = new Executor(fetcher);

    // Test simple field
    {
        auto query = map!(
            (Expr!Ref p) => Post.title(p)
        )(getByIds!Post([1, 2]));

        auto titles = executor.execute(query);
        assert(titles == ["Hello World", "D Programming"]);
    }

    // Test computed field with belongsTo
    {
        auto query = map!(
            (Expr!Ref p) => Post.summary(p)
        )(getByIds!Post([1, 2]));

        auto summaries = executor.execute(query);
        assert(summaries[0].canFind("Hello World"));
        assert(summaries[0].canFind("Alice Smith"));
        assert(summaries[1].canFind("D Programming"));
        assert(summaries[1].canFind("Bob Jones"));
    }
}

// Test Post.html - full 4-layer query with nested relationships
unittest {
    auto fetcher = new MockDataFetcher();

    fetcher.setTableData("posts", `[
        {"id": 1, "title": "Hello World", "body": "First post", "author_id": 1}
    ]`);

    fetcher.setTableData("users", `[
        {"id": 1, "first_name": "Alice", "last_name": "Smith"},
        {"id": 2, "first_name": "Bob", "last_name": "Jones"}
    ]`);

    fetcher.setTableData("comments", `[
        {"id": 101, "post_id": 1, "body": "Great!", "author_id": 2}
    ]`);

    auto executor = new Executor(fetcher);

    auto query = map!(
        (Expr!Ref p) => Post.html(p)
    )(getByIds!Post([1]));

    auto htmls = executor.execute(query);

    assert(htmls.length == 1);
    assert(htmls[0].canFind("Hello World"));
    assert(htmls[0].canFind("Alice Smith"));
    assert(htmls[0].canFind("Great!"));
    assert(htmls[0].canFind("Bob Jones"));
}

// Test nested map with hasMany
unittest {
    auto fetcher = new MockDataFetcher();

    fetcher.setTableData("users", `[
        {"id": 1, "first_name": "Alice", "last_name": "Smith"},
        {"id": 2, "first_name": "Bob", "last_name": "Jones"}
    ]`);

    fetcher.setTableData("posts", `[
        {"id": 1, "author_id": 1, "title": "Post 1"},
        {"id": 2, "author_id": 1, "title": "Post 2"},
        {"id": 3, "author_id": 2, "title": "Post 3"}
    ]`);

    auto executor = new Executor(fetcher);

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
    )(getByIds!User([1, 2]));

    auto result = executor.execute(query);

    assert(result.length == 2);

    // Alice has 2 posts
    assert(result[0]["firstName"].str == "Alice");
    assert(result[0]["posts"].array.length == 2);

    // Bob has 1 post
    assert(result[1]["firstName"].str == "Bob");
    assert(result[1]["posts"].array.length == 1);
}
