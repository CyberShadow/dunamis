module graphqld2.relational.types;

// This module is kept for backwards compatibility but most types have been
// simplified in the new architecture.
//
// The Layer/JoinInfo types were used by the old planning system.
// The new system uses the Ref-based approach where:
// - Entity refs are opaque strings (e.g., "User:123")
// - Access expressions fetch data directly during eval
// - Optimization replaces access expressions with projections that
//   read from pre-fetched QueryResults
