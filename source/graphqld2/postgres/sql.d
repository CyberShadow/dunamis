module graphqld2.postgres.sql;

import std.algorithm;
import std.array;
import std.conv;
import std.format;
import std.range;
import std.typecons : nullable;

import graphqld2.relational.types;

/// Builds PostgreSQL queries from a query plan
class SqlBuilder {
    /// Generate a CTE-based query that fetches all layers in one query
    /// Root layer filter info (FilterType, IDs) comes from the layers themselves.
    string buildQuery(Layer[] layers) {
        if (layers.length == 0)
            return "";

        auto sql = appender!string;

        // Build CTEs for each layer
        sql ~= "WITH\n";

        string[] ctes;
        foreach (layer; layers) {
            if (layer == Layer.init) continue;
            ctes ~= buildLayerCte(layer, layers);
        }
        sql ~= ctes.join(",\n");

        // Final SELECT: aggregate all layers into JSON
        sql ~= "\nSELECT json_build_object(\n";
        string[] jsonParts;
        foreach (layer; layers) {
            if (layer == Layer.init) continue;
            jsonParts ~= format!"  'layer%d', (SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM layer%d t)"(
                layer.id, layer.id);
        }
        sql ~= jsonParts.join(",\n");
        sql ~= "\n)";

        return sql.data;
    }

    private string buildLayerCte(Layer layer, Layer[] allLayers) {
        auto sql = appender!string;

        sql ~= format!"  layer%d AS (\n"(layer.id);
        sql ~= "    SELECT ";

        // Select columns
        auto cols = layer.columns.map!(c => format!"%s.%s"(layer.table, c)).array;
        sql ~= cols.join(", ");

        sql ~= format!"\n    FROM %s\n"(layer.table);

        // WHERE clause depends on layer type
        if (layer.rootFilter != FilterType.none) {
            // Root layer: filter based on FilterType
            final switch (layer.rootFilter) {
                case FilterType.none:
                    break;  // Shouldn't happen
                case FilterType.all:
                    // No WHERE clause - fetch all
                    break;
                case FilterType.byId:
                    // Single ID from rootFilterIds
                    if (layer.rootFilterIds.length > 0) {
                        sql ~= format!"    WHERE %s.id = %d\n"(layer.table, layer.rootFilterIds[0]);
                    }
                    break;
                case FilterType.byIds:
                    // Multiple IDs - inline as array literal
                    if (layer.rootFilterIds.length > 0) {
                        sql ~= format!"    WHERE %s.id = ANY(%s)\n"(
                            layer.table, formatIdArray(layer.rootFilterIds));
                    }
                    break;
            }
        } else if (!layer.join.isNull) {
            auto join = layer.join.get;
            auto parentLayer = allLayers[join.parentLayerId];

            if (join.type == JoinType.hasMany) {
                // hasMany: child.fk IN (SELECT id FROM parent_layer)
                sql ~= format!"    WHERE %s.%s IN (SELECT id FROM layer%d)\n"(
                    layer.table, join.foreignKey, join.parentLayerId);
            } else {
                // belongsTo: child.id IN (SELECT fk FROM parent_layer)
                sql ~= format!"    WHERE %s.id IN (SELECT %s FROM layer%d)\n"(
                    layer.table, join.foreignKey, join.parentLayerId);
            }
        }

        sql ~= "  )";
        return sql.data;
    }

    /// Format root IDs as a PostgreSQL array literal
    static string formatIdArray(long[] ids) {
        return "ARRAY[" ~ ids.map!(id => id.to!string).join(",") ~ "]::bigint[]";
    }
}

unittest {
    // Create root layer with byIds filter
    auto rootLayer = Layer(0, "User", "users", ["id", "first_name", "last_name"]);
    rootLayer.rootFilter = FilterType.byIds;
    rootLayer.rootFilterIds = [1, 2, 3];

    auto layers = [
        rootLayer,
        Layer(1, "Post", "posts", ["id", "author_id", "title"],
              nullable(JoinInfo(0, "author_id", "id", JoinType.hasMany)))
    ];

    auto builder = new SqlBuilder();
    auto sql = builder.buildQuery(layers);

    // Should contain CTEs for both layers
    assert(sql.canFind("layer0 AS"));
    assert(sql.canFind("layer1 AS"));

    // Should select the right columns
    assert(sql.canFind("users.first_name"));
    assert(sql.canFind("posts.title"));

    // Should have proper join condition
    assert(sql.canFind("posts.author_id IN (SELECT id FROM layer0)"));

    // Should have root filter with IDs
    assert(sql.canFind("ARRAY[1,2,3]::bigint[]"));

    // Should aggregate to JSON
    assert(sql.canFind("json_build_object"));
}

unittest {
    // Test belongsTo relationship
    auto rootLayer = Layer(0, "Post", "posts", ["id", "author_id", "title"]);
    rootLayer.rootFilter = FilterType.byIds;
    rootLayer.rootFilterIds = [1];

    auto layers = [
        rootLayer,
        Layer(1, "User", "users", ["id", "first_name"],
              nullable(JoinInfo(0, "author_id", "id", JoinType.belongsTo)))
    ];

    auto builder = new SqlBuilder();
    auto sql = builder.buildQuery(layers);

    // belongsTo should look up by FK value from parent layer
    assert(sql.canFind("users.id IN (SELECT author_id FROM layer0)"));
}

unittest {
    // Test FilterType.all (no WHERE clause)
    auto rootLayer = Layer(0, "User", "users", ["id", "first_name"]);
    rootLayer.rootFilter = FilterType.all;

    auto builder = new SqlBuilder();
    auto sql = builder.buildQuery([rootLayer]);

    // Should NOT have WHERE clause for FilterType.all
    assert(!sql.canFind("WHERE"));
    assert(sql.canFind("FROM users"));
}
