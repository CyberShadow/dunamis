module dunamis.core.datasource;

import ae.utils.promise;

/// Base class for data sources that need lifecycle management.
///
/// The Executor collects all data sources from the expression tree before
/// evaluation and calls setup()/teardown() to bracket execution.
///
/// Override setup() to begin transactions, set session variables, etc.
/// Override teardown() to commit or rollback based on success/failure.
///
/// Example (PostgreSQL with session variables):
/// ---
/// class MyDB : PostgresDB!() {
///     string userId;
///
///     override Promise!void setup() {
///         return super.setup()  // BEGIN
///             .then((_) => execute("SET LOCAL app.user_id = '" ~ userId ~ "'"));
///     }
/// }
/// ---
class DataSource {
    /// Called before execution begins.
    /// Override to BEGIN transaction, SET LOCAL variables, etc.
    Promise!void setup() { return resolve(); }

    /// Called after execution completes.
    /// success=true: execution succeeded (COMMIT).
    /// success=false: execution failed (ROLLBACK).
    Promise!void teardown(bool success) { return resolve(); }
}
