module dunamis.core.datasource;

import ae.utils.promise;

import dunamis.core.optimize : ExprOptimizer;

/// Per-request session for a data source.
///
/// Each query/mutation execution gets its own DataSession, created by
/// DataSource.createSession(). The session owns the transaction lifecycle:
/// setup() begins the transaction, teardown() commits or rolls back.
///
/// Multiple concurrent requests each get their own session, even if they
/// share the same DataSource (connection pool, in-memory store, etc.).
class DataSession {
    /// Called before execution begins.
    /// Override to BEGIN transaction, SET LOCAL variables, etc.
    Promise!void setup() { return resolve(); }

    /// Called after execution completes.
    /// success=true: execution succeeded (COMMIT).
    /// success=false: execution failed (ROLLBACK).
    Promise!void teardown(bool success) { return resolve(); }
}

/// Base class for data sources that need lifecycle management.
///
/// A DataSource is a long-lived singleton (connection pool, config, in-memory
/// store) bound to entities at compile time via @Entity!(db, "table").
///
/// The Executor collects all data sources from the expression tree, creates
/// per-request sessions via createSession(), and manages their lifecycle.
///
/// Example (PostgreSQL with session variables):
/// ---
/// class MyDB : PostgresDB!() {
///     override DataSession createSession() {
///         return new MySession(conn);
///     }
/// }
/// ---
class DataSource {
    /// Create a per-request session for this data source.
    /// Override in subclasses to return a session with actual database connection
    /// and transaction support.
    DataSession createSession() { return new DataSession(); }

    /// Get the optimizers this data source needs.
    /// Default: no additional optimizers.
    /// SQL-backed data sources override to return [sqlOptimizer].
    ExprOptimizer[] requestedOptimizers() {
        return [];
    }
}
