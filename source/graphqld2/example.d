module graphqld2.example;

import graphqld2.expr;
import std.algorithm;
import std.array;
import std.conv;

// ------------------------------------------------------------------
// Database abstraction - column-level fetching
// ------------------------------------------------------------------

/// Simulated database - just returns column values for given IDs
/// In reality: SELECT column_name FROM table WHERE id IN (...)
/// Using abstract class since interfaces can't have templated methods
abstract class Database {
    abstract string[] getColumnString(string table, string column, long[] ids);
    abstract long[] getColumnLong(string table, string column, long[] ids);

    // Template dispatcher
    T[] getColumn(T)(string table, string column, long[] ids) {
        static if (is(T == string))
            return getColumnString(table, column, ids);
        else static if (is(T == long))
            return getColumnLong(table, column, ids);
        else
            static assert(false, "Unsupported column type: " ~ T.stringof);
    }
}

/// Test implementation with hardcoded data
class TestDatabase : Database {
    override string[] getColumnString(string table, string column, long[] ids) {
        if (table == "users") {
            if (column == "first_name") return ids.map!(id => ["Alice", "Bob", "Carol"][cast(size_t)(id - 1)]).array;
            if (column == "last_name") return ids.map!(id => ["Smith", "Jones", "White"][cast(size_t)(id - 1)]).array;
            if (column == "email") return ids.map!(id => ["alice@ex.com", "bob@ex.com", "carol@ex.com"][cast(size_t)(id - 1)]).array;
        }
        if (table == "posts") {
            if (column == "title") return ids.map!(id => ["Hello World", "D Programming", "GraphQL Tips"][cast(size_t)(id - 1)]).array;
            if (column == "body") return ids.map!(id => ["My first post", "D is great", "Use batching"][cast(size_t)(id - 1)]).array;
        }
        assert(false, "Unknown string column: " ~ table ~ "." ~ column);
    }

    override long[] getColumnLong(string table, string column, long[] ids) {
        if (table == "posts") {
            if (column == "author_id") return ids.map!(id => [1L, 1L, 2L][cast(size_t)(id - 1)]).array;
        }
        assert(false, "Unknown long column: " ~ table ~ "." ~ column);
    }
}

// ------------------------------------------------------------------
// Column helper - creates a useAll expression for database column fetch
// ------------------------------------------------------------------

/// Helper to create a column expression using useAll
/// This is just a useAll over context IDs -> column values
Expr!T column(T, EntityId)(string table, string columnName, Database db) {
    return useAll(
        (long[] ids) => db.getColumn!T(table, columnName, ids),
        contextIdLong()
    );
}

/// Get current context's entity ID as long
Expr!long contextIdLong() {
    return new ContextIdExprLong();
}

// ------------------------------------------------------------------
// Entity ID types (just for type safety, no struct needed)
// ------------------------------------------------------------------

struct UserId { long value; }
struct PostId { long value; }

// ------------------------------------------------------------------
// Schema definition - fields as expressions
// ------------------------------------------------------------------

/// User fields - each is an independent column fetch
struct User {
    Database db;

    this(Database db) { this.db = db; }

    Expr!string firstName() => column!(string, UserId)("users", "first_name", db);
    Expr!string lastName() => column!(string, UserId)("users", "last_name", db);
    Expr!string email() => column!(string, UserId)("users", "email", db);

    /// Computed field - depends on other fields
    Expr!string fullName() => use(
        (string first, string last) => first ~ " " ~ last,
        firstName(),
        lastName()
    );

    /// Relationship: user -> posts
    /// Returns post IDs for each user
    Expr!(long[]) postIds() {
        // This would be: SELECT id FROM posts WHERE author_id IN (user_ids)
        // For now, hardcoded
        return useAll(
            (long[] userIds) => userIds.map!(uid =>
                [1L, 2L, 3L].filter!(pid =>
                    [1L: 1L, 2L: 1L, 3L: 2L].get(pid, 0L) == uid  // post_id -> author_id
                ).array
            ).array,
            contextIdLong()
        );
    }
}

/// Post fields
struct Post {
    Database db;

    this(Database db) { this.db = db; }

    Expr!string title() => column!(string, PostId)("posts", "title", db);
    Expr!string body() => column!(string, PostId)("posts", "body", db);
    Expr!long authorId() => column!(long, PostId)("posts", "author_id", db);
}

/// Simple context ID expression that returns entityId as long
class ContextIdExprLong : Expr!long {
    override long[] evalBatch(Context[] contexts) {
        return contexts.map!(c => c.entityId).array;
    }
}

// ------------------------------------------------------------------
// Helper to create contexts
// ------------------------------------------------------------------

Context[] contextsFor(long[] ids) => ids.map!(id => Context(id, null)).array;

// ------------------------------------------------------------------
// Unit tests
// ------------------------------------------------------------------

unittest {
    auto db = new TestDatabase();
    auto user = User(db);

    // Single user field
    auto ctxs = contextsFor([1]);
    assert(user.firstName().evalBatch(ctxs) == ["Alice"]);
}

unittest {
    auto db = new TestDatabase();
    auto user = User(db);

    // Batched - ONE database call for all users
    auto ctxs = contextsFor([1, 2, 3]);
    assert(user.firstName().evalBatch(ctxs) == ["Alice", "Bob", "Carol"]);
    assert(user.lastName().evalBatch(ctxs) == ["Smith", "Jones", "White"]);
}

unittest {
    auto db = new TestDatabase();
    auto user = User(db);

    // Computed field
    auto ctxs = contextsFor([1, 2]);
    assert(user.fullName().evalBatch(ctxs) == ["Alice Smith", "Bob Jones"]);
}

unittest {
    auto db = new TestDatabase();
    auto post = Post(db);

    // Post fields
    auto ctxs = contextsFor([1, 2, 3]);
    assert(post.title().evalBatch(ctxs) == ["Hello World", "D Programming", "GraphQL Tips"]);
    assert(post.authorId().evalBatch(ctxs) == [1L, 1L, 2L]);
}

unittest {
    auto db = new TestDatabase();
    auto user = User(db);
    auto post = Post(db);

    // Nested query: get user 1's posts, then their titles
    auto userCtxs = contextsFor([1]);
    auto postIdArrays = user.postIds().evalBatch(userCtxs);
    auto postIds = postIdArrays[0];  // [1, 2]

    auto postCtxs = contextsFor(postIds);
    auto titles = post.title().evalBatch(postCtxs);
    assert(titles == ["Hello World", "D Programming"]);
}
