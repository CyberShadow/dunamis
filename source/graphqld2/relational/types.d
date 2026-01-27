module graphqld2.relational.types;

import std.algorithm;
import std.typecons : Nullable;

// ============================================================================
// Layer and Join Types
// ============================================================================

/// A Layer represents one level of entity traversal in the query.
/// Each layer corresponds to a table/entity type.
struct Layer {
    int id;
    string entityName;        // e.g., "User", "Post", "Comment"
    string table;             // e.g., "users", "posts", "comments"
    string[] columns;         // Columns needed at this layer

    /// How this layer connects to its parent (null for root)
    Nullable!JoinInfo join;

    /// For root layers: how to filter entities
    FilterType rootFilter = FilterType.none;
    long[] rootFilterIds;

    /// Add a column requirement (deduplicates)
    void requireColumn(string col) {
        if (!columns.canFind(col))
            columns ~= col;
    }
}

/// Describes how a layer joins to its parent
struct JoinInfo {
    int parentLayerId;
    string foreignKey;        // Column in this table (e.g., "author_id")
    string parentKey;         // Column in parent table (e.g., "id")
    JoinType type;
}

enum JoinType {
    hasMany,      // Parent has many children (1:N)
    belongsTo,    // Child belongs to parent (N:1)
}

/// How a root layer filters its entities
enum FilterType {
    none,         // Not a root layer (uses join instead)
    all,          // No filter - fetch all entities
    byId,         // Filter by single ID
    byIds,        // Filter by multiple IDs
}
