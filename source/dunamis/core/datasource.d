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
    private bool _externalLeaseActive;
    private Promise!void[] _externalLeaseWaiters;
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

    /// Temporarily release resources while evaluation waits for external work.
    /// The logical session remains active and may later be resumed. Backends
    /// which do not retain scarce resources can use the no-op default.
    Promise!void suspend() { return resolve(); }

    /// Reacquire resources released by suspend(), preserving request-local
    /// session state and already-computed results.
    Promise!void resume() { return resolve(); }

    /// Serialize external work which temporarily suspends this session. A
    /// session may be shared by sibling expressions, but its transaction and
    /// connection lifecycle cannot safely be suspended concurrently.
    Promise!void acquireExternalLease() {
        if (!_externalLeaseActive) {
            _externalLeaseActive = true;
            return resolve();
        }
        auto waiter = new Promise!void;
        _externalLeaseWaiters ~= waiter;
        return waiter;
    }

    void releaseExternalLease() {
        if (_externalLeaseWaiters.length) {
            auto waiter = _externalLeaseWaiters[0];
            _externalLeaseWaiters = _externalLeaseWaiters[1 .. $];
            waiter.fulfill();
        } else {
            _externalLeaseActive = false;
        }
    }
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
