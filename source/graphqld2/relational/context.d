module graphqld2.relational.context;

import std.algorithm;
import std.array;
import std.conv;
import std.json;
import std.typecons : nullable;

import graphqld2.core.plan;
import graphqld2.core.eval;
import graphqld2.relational.types;

// ============================================================================
// Relational Plan Context
// ============================================================================

/// Relational-specific planning context.
/// Manages layers, columns, and join information.
class RelationalPlanContext : SourcePlanContext {
    private {
        PlanContext _parent;
        string _sourceId;
    }

    Layer[] layers;

    this(PlanContext parent, string sourceId) {
        _parent = parent;
        _sourceId = sourceId;
    }

    @property string sourceId() { return _sourceId; }

    /// Create root layer for an entity
    /// filter: how to filter root entities (default byIds for backward compat)
    /// filterIds: IDs to filter by (for byId/byIds)
    int setRoot(string entityName, string table,
                FilterType filter = FilterType.byIds,
                long[] filterIds = []) {
        auto layerId = _parent.allocateLayer(-1, _sourceId);
        if (layerId >= layers.length)
            layers.length = layerId + 1;

        auto layer = Layer(layerId, entityName, table);
        layer.rootFilter = filter;
        layer.rootFilterIds = filterIds;
        layers[layerId] = layer;
        return layerId;
    }

    /// Get a layer by ID
    ref Layer layer(int id) {
        return layers[id];
    }

    /// Register that we need a column in a layer
    void requireColumn(int layerId, string column) {
        if (layerId >= layers.length)
            layers.length = layerId + 1;
        // Always include 'id' for joining
        layers[layerId].requireColumn("id");
        layers[layerId].requireColumn(column);
    }

    /// Enter a hasMany relationship (e.g., User -> Posts)
    /// Returns the new layer ID
    int enterHasMany(int parentLayerId, string childEntity, string childTable, string foreignKey) {
        // Check if we already have this layer
        foreach (i, ref layer; layers) {
            if (!layer.join.isNull &&
                layer.join.get.parentLayerId == parentLayerId &&
                layer.join.get.foreignKey == foreignKey &&
                layer.join.get.type == JoinType.hasMany) {
                return cast(int)i;
            }
        }

        auto newId = _parent.allocateLayer(parentLayerId, _sourceId);
        if (newId >= layers.length)
            layers.length = newId + 1;
        layers[newId] = Layer(
            newId,
            childEntity,
            childTable,
            [],  // columns
            nullable(JoinInfo(parentLayerId, foreignKey, "id", JoinType.hasMany))
        );
        // Child layer needs the FK for grouping results
        layers[newId].requireColumn(foreignKey);
        layers[newId].requireColumn("id");
        return newId;
    }

    /// Enter a belongsTo relationship (e.g., Post -> User)
    /// Returns the new layer ID
    int enterBelongsTo(int parentLayerId, string targetEntity, string targetTable, string foreignKey) {
        // Check if we already have this layer
        foreach (i, ref layer; layers) {
            if (!layer.join.isNull &&
                layer.join.get.parentLayerId == parentLayerId &&
                layer.join.get.foreignKey == foreignKey &&
                layer.join.get.type == JoinType.belongsTo) {
                return cast(int)i;
            }
        }

        // For belongsTo, we need the FK in the parent (current) layer
        requireColumn(parentLayerId, foreignKey);

        auto newId = _parent.allocateLayer(parentLayerId, _sourceId);
        if (newId >= layers.length)
            layers.length = newId + 1;
        layers[newId] = Layer(
            newId,
            targetEntity,
            targetTable,
            [],  // columns
            nullable(JoinInfo(parentLayerId, foreignKey, "id", JoinType.belongsTo))
        );
        layers[newId].requireColumn("id");
        return newId;
    }

    /// Debug: print the plan
    void dump() {
        import std.stdio : writefln;
        writefln("Plan for source '%s' with %d layers:", _sourceId, layers.length);
        foreach (layer; layers) {
            if (layer == Layer.init) continue;
            writefln("  Layer %d: %s (%s)", layer.id, layer.entityName, layer.table);
            writefln("    Columns: %s", layer.columns);
            if (layer.rootFilter != FilterType.none) {
                writefln("    Root filter: %s %s", layer.rootFilter, layer.rootFilterIds);
            }
            if (!layer.join.isNull) {
                auto j = layer.join.get;
                writefln("    Join: %s from layer %d via %s", j.type, j.parentLayerId, j.foreignKey);
            }
        }
    }
}

// ============================================================================
// Relational Eval Context
// ============================================================================

/// Relational-specific evaluation context.
/// Manages fetched data and provides column/relationship lookups.
class RelationalEvalContext : SourceEvalContext {
    private {
        EvalContext _parent;
        string _sourceId;
        Layer[] _layers;

        /// Raw data per layer: layerId -> array of row objects
        JSONValue[][int] _layerData;

        /// Index for hasMany lookups: layerId -> foreignKey -> parentId -> rows
        JSONValue[][long][string][int] _hasManyIndex;

        /// Index for belongsTo lookups: layerId -> id -> row
        JSONValue[long][int] _belongsToIndex;
    }

    this(EvalContext parent, string sourceId) {
        _parent = parent;
        _sourceId = sourceId;
    }

    @property string sourceId() { return _sourceId; }

    /// Set the layers for this context (from planning phase)
    void setLayers(Layer[] layers) {
        _layers = layers;
    }

    /// Load data from a JSON result (from the database)
    /// Expected format: {"layer0": [...], "layer1": [...], ...}
    override void loadData(JSONValue data) {
        foreach (layer; _layers) {
            if (layer == Layer.init) continue;
            auto key = "layer" ~ layer.id.to!string;
            if (key in data) {
                auto rows = data[key].array;
                _layerData[layer.id] = rows;
                buildIndices(layer, rows);
            } else {
                _layerData[layer.id] = [];
            }
        }
    }

    private void buildIndices(Layer layer, JSONValue[] rows) {
        if (layer.join.isNull)
            return;

        auto join = layer.join.get;

        if (join.type == JoinType.hasMany) {
            // Index by foreign key for hasMany lookups
            JSONValue[][long][string] fkIndex;
            foreach (row; rows) {
                auto fkValue = row[join.foreignKey].get!long;
                if (join.foreignKey !in fkIndex)
                    fkIndex[join.foreignKey] = (JSONValue[][long]).init;
                fkIndex[join.foreignKey][fkValue] ~= row;
            }
            _hasManyIndex[layer.id] = fkIndex;
        }
        else if (join.type == JoinType.belongsTo) {
            // Index by ID for belongsTo lookups
            JSONValue[long] idIndex;
            foreach (row; rows) {
                auto id = row["id"].get!long;
                idIndex[id] = row;
            }
            _belongsToIndex[layer.id] = idIndex;
        }
    }

    /// Get column values for current IDs in current layer
    T[] getColumn(T)(int layerId, string column, long[] ids) {
        auto rows = _layerData.get(layerId, []);

        // Build id -> row index for current layer
        JSONValue[long] rowById;
        foreach (row; rows) {
            rowById[row["id"].get!long] = row;
        }

        // Return values in order of ids
        T[] result;
        foreach (id; ids) {
            if (auto rowPtr = id in rowById) {
                result ~= extractValue!T((*rowPtr)[column]);
            } else {
                result ~= T.init;  // Missing data
            }
        }
        return result;
    }

    /// Get related entities via hasMany relationship
    /// Returns: for each ID, an array of child IDs
    long[][] getHasManyIds(int childLayerId, string foreignKey, long[] parentIds) {
        auto index = _hasManyIndex.get(childLayerId, null);
        if (index is null)
            return parentIds.map!(id => cast(long[])[]).array;

        auto fkIndex = index.get(foreignKey, null);
        if (fkIndex is null)
            return parentIds.map!(id => cast(long[])[]).array;

        long[][] result;
        foreach (parentId; parentIds) {
            if (auto rows = parentId in fkIndex) {
                result ~= (*rows).map!(r => r["id"].get!long).array;
            } else {
                result ~= [];
            }
        }
        return result;
    }

    /// Get related entity via belongsTo relationship
    /// Returns: for each ID, the parent ID (or 0 if null)
    long[] getBelongsToIds(int layerId, string foreignKey, long[] childIds) {
        auto rows = _layerData.get(layerId, []);

        JSONValue[long] rowById;
        foreach (row; rows) {
            rowById[row["id"].get!long] = row;
        }

        long[] result;
        foreach (id; childIds) {
            if (auto rowPtr = id in rowById) {
                auto fkVal = (*rowPtr)[foreignKey];
                if (fkVal.type == JSONType.null_)
                    result ~= 0;
                else
                    result ~= fkVal.get!long;
            } else {
                result ~= 0;
            }
        }
        return result;
    }

    private T extractValue(T)(JSONValue val) {
        static if (is(T == string)) {
            return val.type == JSONType.null_ ? "" : val.get!string;
        } else static if (is(T == long)) {
            return val.type == JSONType.null_ ? 0 : val.get!long;
        } else static if (is(T == int)) {
            return val.type == JSONType.null_ ? 0 : cast(int)val.get!long;
        } else static if (is(T == bool)) {
            return val.type == JSONType.null_ ? false : val.get!bool;
        } else static if (is(T == double)) {
            if (val.type == JSONType.null_) return 0.0;
            if (val.type == JSONType.integer) return cast(double)val.get!long;
            return val.get!double;
        } else {
            static assert(false, "Unsupported type: " ~ T.stringof);
        }
    }
}

// ============================================================================
// Tests
// ============================================================================

unittest {
    // Test evaluation with RelationalEvalContext
    import std.json : parseJSON;

    auto evalCtx = new EvalContext();
    evalCtx.currentSourceId = "default";

    auto relEval = evalCtx.source!RelationalEvalContext();
    relEval.setLayers([
        Layer(0, "User", "users", ["id", "first_name"])
    ]);

    relEval.loadData(parseJSON(`{
        "layer0": [
            {"id": 1, "first_name": "Alice"},
            {"id": 2, "first_name": "Bob"}
        ]
    }`));

    evalCtx.currentLayerId = 0;
    evalCtx.currentIds = [1, 2];

    auto names = relEval.getColumn!string(0, "first_name", [1, 2]);
    assert(names == ["Alice", "Bob"]);
}
