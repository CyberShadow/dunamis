module graphqld2.plan;

import std.algorithm;
import std.array;
import std.conv;
import std.typecons;

/// A Layer represents one level of entity traversal in the query.
/// Each layer corresponds to a table/entity type.
struct Layer {
    int id;
    string entityName;        // e.g., "User", "Post", "Comment"
    string table;             // e.g., "users", "posts", "comments"
    string[] columns;         // Columns needed at this layer

    /// How this layer connects to its parent (null for root)
    Nullable!JoinInfo join;

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

/// Accumulated during the planning phase.
/// Collects all data requirements from the expression tree.
class PlanContext {
    Layer[] layers;
    int currentLayerId = 0;

    /// Create root layer for an entity
    void setRoot(string entityName, string table) {
        layers = [Layer(0, entityName, table)];
        currentLayerId = 0;
    }

    /// Get current layer
    ref Layer currentLayer() {
        return layers[currentLayerId];
    }

    /// Register that we need a column in the current layer
    void requireColumn(string column) {
        // Always include 'id' for joining
        currentLayer.requireColumn("id");
        currentLayer.requireColumn(column);
    }

    /// Enter a hasMany relationship (e.g., User -> Posts)
    /// Returns the new layer ID
    int enterHasMany(string childEntity, string childTable, string foreignKey) {
        // Check if we already have this layer
        foreach (i, ref layer; layers) {
            if (!layer.join.isNull &&
                layer.join.get.parentLayerId == currentLayerId &&
                layer.join.get.foreignKey == foreignKey &&
                layer.join.get.type == JoinType.hasMany) {
                return cast(int)i;
            }
        }

        auto newId = cast(int)layers.length;
        layers ~= Layer(
            newId,
            childEntity,
            childTable,
            [],  // columns
            nullable(JoinInfo(currentLayerId, foreignKey, "id", JoinType.hasMany))
        );
        // Child layer needs the FK for grouping results
        layers[newId].requireColumn(foreignKey);
        layers[newId].requireColumn("id");
        return newId;
    }

    /// Enter a belongsTo relationship (e.g., Post -> User)
    /// Returns the new layer ID
    int enterBelongsTo(string parentEntity, string parentTable, string foreignKey) {
        // Check if we already have this layer
        foreach (i, ref layer; layers) {
            if (!layer.join.isNull &&
                layer.join.get.parentLayerId == currentLayerId &&
                layer.join.get.foreignKey == foreignKey &&
                layer.join.get.type == JoinType.belongsTo) {
                return cast(int)i;
            }
        }

        // For belongsTo, we need the FK in the current (child) layer
        currentLayer.requireColumn(foreignKey);

        auto newId = cast(int)layers.length;
        layers ~= Layer(
            newId,
            parentEntity,
            parentTable,
            [],  // columns
            nullable(JoinInfo(currentLayerId, foreignKey, "id", JoinType.belongsTo))
        );
        layers[newId].requireColumn("id");
        return newId;
    }

    /// Execute a function with a different current layer, then restore
    void withLayer(int layerId, void delegate() fn) {
        auto saved = currentLayerId;
        currentLayerId = layerId;
        fn();
        currentLayerId = saved;
    }

    /// Debug: print the plan
    void dump() {
        import std.stdio : writefln;
        writefln("Plan with %d layers:", layers.length);
        foreach (layer; layers) {
            writefln("  Layer %d: %s (%s)", layer.id, layer.entityName, layer.table);
            writefln("    Columns: %s", layer.columns);
            if (!layer.join.isNull) {
                auto j = layer.join.get;
                writefln("    Join: %s from layer %d via %s", j.type, j.parentLayerId, j.foreignKey);
            }
        }
    }
}

unittest {
    auto ctx = new PlanContext();
    ctx.setRoot("User", "users");
    ctx.requireColumn("first_name");
    ctx.requireColumn("last_name");

    auto postLayerId = ctx.enterHasMany("Post", "posts", "author_id");
    ctx.withLayer(postLayerId, {
        ctx.requireColumn("title");
        ctx.requireColumn("body");
    });

    assert(ctx.layers.length == 2);
    assert(ctx.layers[0].columns.canFind("first_name"));
    assert(ctx.layers[1].columns.canFind("title"));
    assert(ctx.layers[1].join.get.foreignKey == "author_id");
}
