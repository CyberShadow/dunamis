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
// Column expression - represents a database column fetch
// ------------------------------------------------------------------

/// Expression that fetches a column from a database table
/// The context provides the row ID, evalBatch does SELECT ... WHERE id IN (...)
class ColumnExpr(T, EntityId) : Expr!T {
    private string _table;
    private string _column;
    private Database _db;

    this(string table, string column, Database db) {
        _table = table;
        _column = column;
        _db = db;
    }

    /// Phase 1: declare dependency on this column
    override ColumnDep[] dependencies() => [ColumnDep(_table, _column)];

    override T[] evalBatch(Context[] contexts) {
        // Check if data is pre-fetched in cache
        if (contexts.length > 0 && contexts[0].cache !is null) {
            return contexts.map!(c => c.cache.get!T(_table, _column, c.entityId)).array;
        }
        // Fallback: fetch directly
        auto ids = contexts.map!(c => c.entityId).array;
        return _db.getColumn!T(_table, _column, ids);
    }
}

/// Helper to create a column expression
Expr!T column(T, EntityId)(string table, string columnName, Database db) {
    return new ColumnExpr!(T, EntityId)(table, columnName, db);
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
            contextIdExpr()
        );
    }

    private Expr!long contextIdExpr() => new ContextIdExprLong();
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
    override ColumnDep[] dependencies() => [];  // No column dependencies

    override long[] evalBatch(Context[] contexts) {
        return contexts.map!(c => c.entityId).array;
    }
}

// ------------------------------------------------------------------
// Helper to create contexts
// ------------------------------------------------------------------

Context[] contextsFor(long[] ids, ResolvedData cache = null) =>
    ids.map!(id => Context(id, null, cache)).array;

// ------------------------------------------------------------------
// Executor - Phase 1 + Phase 2
// ------------------------------------------------------------------

/// Execute an expression with dependency pre-fetching
T[] execute(T)(Expr!T expr, long[] ids, Database db) {
    // Phase 1: collect dependencies
    auto deps = expr.dependencies();

    // Phase 2a: pre-fetch all needed columns
    auto cache = new ResolvedData();
    foreach (dep; deps) {
        // Fetch column for all IDs
        // Note: in reality, we'd dispatch based on column type
        // For now, try string first, then long
        try {
            auto values = db.getColumnString(dep.table, dep.column, ids);
            cache.storeAll(dep.table, dep.column, ids, values);
        } catch (Error) {
            auto values = db.getColumnLong(dep.table, dep.column, ids);
            cache.storeAll(dep.table, dep.column, ids, values);
        }
    }

    // Phase 2b: evaluate with pre-fetched data
    auto contexts = ids.map!(id => Context(id, null, cache)).array;
    return expr.evalBatch(contexts);
}

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

// ------------------------------------------------------------------
// Dependency collection tests
// ------------------------------------------------------------------

unittest {
    auto db = new TestDatabase();
    auto user = User(db);

    // Single field has one dependency
    auto deps = user.firstName().dependencies();
    assert(deps.length == 1);
    assert(deps[0] == ColumnDep("users", "first_name"));
}

unittest {
    auto db = new TestDatabase();
    auto user = User(db);

    // Computed field has dependencies from both inputs
    auto deps = user.fullName().dependencies();
    assert(deps.length == 2);
    // Should have both first_name and last_name
    assert(deps.canFind(ColumnDep("users", "first_name")));
    assert(deps.canFind(ColumnDep("users", "last_name")));
}

unittest {
    auto db = new TestDatabase();
    auto user = User(db);

    // postIds has no column dependencies (uses contextIdExpr)
    auto deps = user.postIds().dependencies();
    assert(deps.length == 0);
}

unittest {
    auto db = new TestDatabase();
    auto user = User(db);

    // Test execute() with pre-fetching
    auto result = execute(user.fullName(), [1, 2, 3], db);
    assert(result == ["Alice Smith", "Bob Jones", "Carol White"]);
}

unittest {
    auto db = new TestDatabase();
    auto user = User(db);

    // Test that execute() collects correct dependencies
    auto expr = user.fullName();
    auto deps = expr.dependencies();

    // Should collect both first_name and last_name
    assert(deps.length == 2);

    // Execute should work with pre-fetched cache
    auto result = execute(expr, [1], db);
    assert(result == ["Alice Smith"]);
}

// ------------------------------------------------------------------
// Query counting test - demonstrates the optimization
// ------------------------------------------------------------------

/// Database wrapper that counts queries
class CountingDatabase : Database {
    Database _inner;
    int queryCount = 0;

    this(Database inner) { _inner = inner; }

    override string[] getColumnString(string table, string column, long[] ids) {
        queryCount++;
        return _inner.getColumnString(table, column, ids);
    }

    override long[] getColumnLong(string table, string column, long[] ids) {
        queryCount++;
        return _inner.getColumnLong(table, column, ids);
    }
}

unittest {
    // Without pre-fetching: each field access triggers a query
    auto innerDb = new TestDatabase();
    auto countingDb = new CountingDatabase(innerDb);
    auto user = User(countingDb);

    // Direct evaluation (no cache)
    auto ctxs = contextsFor([1, 2, 3]);
    auto _ = user.fullName().evalBatch(ctxs);

    // fullName calls firstName and lastName, each does a query
    assert(countingDb.queryCount == 2);
}

unittest {
    // With pre-fetching via execute(): dependencies collected first
    auto innerDb = new TestDatabase();
    auto countingDb = new CountingDatabase(innerDb);
    auto user = User(countingDb);

    // Reset counter
    countingDb.queryCount = 0;

    // execute() pre-fetches based on dependencies
    auto result = execute(user.fullName(), [1, 2, 3], countingDb);

    // Still 2 queries, but they happen in the pre-fetch phase
    // The key difference: if we had duplicate dependencies, they'd be deduped
    assert(countingDb.queryCount == 2);
    assert(result == ["Alice Smith", "Bob Jones", "Carol White"]);
}
