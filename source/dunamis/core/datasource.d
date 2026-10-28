module dunamis.core.datasource;

import ae.utils.promise;

import dunamis.core.optimize : ExprOptimizer;

/// Lifecycle phase for a data session.
enum SetupMode {
    query,    /// Normal query/mutation: BEGIN transaction
    listen,   /// Set up change listeners (LISTEN channels, hooks)
    respond,  /// Respond to event: BEGIN with point-in-time snapshot
}

/// Represents a data change event from a data source.
///
/// DB implementations subclass to attach opaque state for point-in-time reads
/// (e.g., PostgreSQL snapshot ID, MockDB snapshot reference).
/// The subscription engine passes ChangeEvent through opaquely — produced by
/// the data source in listen mode, consumed in respond mode.
class ChangeEvent {
    /// The kind of change that occurred.
    enum Kind { created, updated, deleted }

    string table;
    Kind kind;
    string[] ids;
}

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
    /// For subscriptions, mode controls the lifecycle phase:
    ///   query:   normal BEGIN (queries and mutations)
    ///   listen:  set up change listeners (LISTEN, hooks)
    ///   respond: BEGIN with point-in-time snapshot from event
    Promise!void setup(SetupMode mode = SetupMode.query) { return resolve(); }

    /// Called after execution completes.
    /// success=true: execution succeeded (COMMIT).
    /// success=false: execution failed (ROLLBACK).
    Promise!void teardown(SetupMode mode = SetupMode.query, bool success = true) { return resolve(); }

    /// Begin an atomic section of the session's work (for example a root
    /// mutation field): the work done until `endAtomic` is either kept or,
    /// if the section fails, undone. Returns a token for `endAtomic`; 0 if
    /// the session cannot undo the section's work (the default: sessions
    /// without transactions). Sections may nest.
    Promise!ulong beginAtomic() { return resolve(0UL); }

    /// End the atomic section begun with the token `token`: keep its work
    /// (success=true), or undo it (success=false). A no-op for the token 0.
    Promise!void endAtomic(ulong token, bool success) { return resolve(); }
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
