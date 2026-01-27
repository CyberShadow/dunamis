module graphqld2.eval;

import std.algorithm;
import std.array;
import std.conv;
import std.json;
import std.typecons;

import graphqld2.plan;

/// Context available during the evaluation phase.
/// Contains all pre-fetched data indexed by layer.
class EvalContext {
    private {
        Layer[] _layers;

        /// Raw data per layer: layerId -> array of row objects
        JSONValue[][int] _layerData;

        /// Index for hasMany lookups: layerId -> foreignKey -> parentId -> rows
        JSONValue[][long][string][int] _hasManyIndex;

        /// Index for belongsTo lookups: layerId -> childForeignKeyValue -> parent row
        JSONValue[long][int] _belongsToIndex;
    }

    /// Current entity IDs being processed (context for evaluation)
    long[] currentIds;

    /// Which layer we're currently evaluating in
    int currentLayerId;

    this(Layer[] layers) {
        _layers = layers;
    }

    /// Load data from a JSON result (from the database)
    /// Expected format: {"layer0": [...], "layer1": [...], ...}
    void loadData(JSONValue data) {
        foreach (layer; _layers) {
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
    T[] getColumn(T)(string column) {
        auto rows = _layerData.get(currentLayerId, []);

        // Build id -> row index for current layer
        JSONValue[long] rowById;
        foreach (row; rows) {
            rowById[row["id"].get!long] = row;
        }

        // Return values in order of currentIds
        T[] result;
        foreach (id; currentIds) {
            if (auto rowPtr = id in rowById) {
                result ~= extractValue!T((*rowPtr)[column]);
            } else {
                result ~= T.init;  // Missing data
            }
        }
        return result;
    }

    /// Get related entities via hasMany relationship
    /// Returns: for each current ID, an array of child IDs
    long[][] getHasManyIds(int childLayerId, string foreignKey) {
        auto index = _hasManyIndex.get(childLayerId, null);
        if (index is null)
            return currentIds.map!(id => cast(long[])[]).array;

        auto fkIndex = index.get(foreignKey, null);
        if (fkIndex is null)
            return currentIds.map!(id => cast(long[])[]).array;

        long[][] result;
        foreach (parentId; currentIds) {
            if (auto rows = parentId in fkIndex) {
                result ~= (*rows).map!(r => r["id"].get!long).array;
            } else {
                result ~= [];
            }
        }
        return result;
    }

    /// Get related entity via belongsTo relationship
    /// Returns: for each current ID, the parent ID (or 0 if null)
    long[] getBelongsToIds(int parentLayerId, string foreignKey) {
        // Get the FK values from current layer's rows
        auto rows = _layerData.get(currentLayerId, []);

        JSONValue[long] rowById;
        foreach (row; rows) {
            rowById[row["id"].get!long] = row;
        }

        long[] result;
        foreach (id; currentIds) {
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

    /// Execute with different current state, then restore
    void withState(int layerId, long[] ids, void delegate() fn) {
        auto savedLayer = currentLayerId;
        auto savedIds = currentIds;
        currentLayerId = layerId;
        currentIds = ids;
        fn();
        currentLayerId = savedLayer;
        currentIds = savedIds;
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

unittest {
    import std.json : parseJSON;

    auto layers = [
        Layer(0, "User", "users", ["id", "first_name"]),
        Layer(1, "Post", "posts", ["id", "author_id", "title"],
              nullable(JoinInfo(0, "author_id", "id", JoinType.hasMany)))
    ];

    auto ctx = new EvalContext(layers);

    auto data = parseJSON(`{
        "layer0": [
            {"id": 1, "first_name": "Alice"},
            {"id": 2, "first_name": "Bob"}
        ],
        "layer1": [
            {"id": 10, "author_id": 1, "title": "Post A"},
            {"id": 11, "author_id": 1, "title": "Post B"},
            {"id": 12, "author_id": 2, "title": "Post C"}
        ]
    }`);

    ctx.loadData(data);
    ctx.currentLayerId = 0;
    ctx.currentIds = [1, 2];

    // Get column values
    auto names = ctx.getColumn!string("first_name");
    assert(names == ["Alice", "Bob"]);

    // Get hasMany related IDs
    auto postIds = ctx.getHasManyIds(1, "author_id");
    assert(postIds == [[10, 11], [12]]);
}
