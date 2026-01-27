module graphqld2.core.plan;

import std.typecons : Nullable, nullable;

// ============================================================================
// Source Context Interface
// ============================================================================

/// Base interface for source-specific planning contexts
interface SourcePlanContext {
}

// ============================================================================
// Core Plan Context
// ============================================================================

/// Key for looking up source contexts
private struct SourceKey {
    TypeInfo type;
    string sourceId;
}

/// Core planning context that coordinates across data sources.
/// Each data source registers its own sub-context with source-specific data.
class PlanContext {
    private {
        SourcePlanContext[SourceKey] _sourceContexts;
        int _nextLayerId;
    }

    /// Current layer being planned (managed by source contexts)
    int currentLayerId = 0;

    /// Current source ID (inherited by expressions)
    string currentSourceId = "default";

    /// Parent layer for each layer (for dependency tracking)
    int[] layerParent;

    /// Which source owns each layer
    string[] layerSource;

    /// Allocate a new layer ID
    int allocateLayer(int parent = -1, string sourceId = null) {
        auto id = _nextLayerId++;
        layerParent ~= parent;
        layerSource ~= (sourceId !is null) ? sourceId : currentSourceId;
        return id;
    }

    /// Get or create a source-specific context
    T source(T : SourcePlanContext)(string sourceId = null) {
        auto id = (sourceId !is null) ? sourceId : currentSourceId;
        auto key = SourceKey(typeid(T), id);
        if (key !in _sourceContexts) {
            _sourceContexts[key] = new T(this, id);
        }
        return cast(T) _sourceContexts[key];
    }

    /// Get all source contexts of a specific type
    T[] allSources(T : SourcePlanContext)() {
        T[] result;
        foreach (key, ctx; _sourceContexts) {
            if (key.type == typeid(T)) {
                result ~= cast(T) ctx;
            }
        }
        return result;
    }

    /// Execute with a different current layer and source, then restore
    void withLayer(int layerId, string sourceId, void delegate() fn) {
        auto savedLayer = currentLayerId;
        auto savedSource = currentSourceId;
        currentLayerId = layerId;
        currentSourceId = sourceId;
        fn();
        currentLayerId = savedLayer;
        currentSourceId = savedSource;
    }

    /// Execute with a different current layer (same source), then restore
    void withLayer(int layerId, void delegate() fn) {
        withLayer(layerId, currentSourceId, fn);
    }

    /// Debug: print the layer graph
    void dumpLayerGraph() {
        import std.stdio : writefln;
        writefln("Layer graph (%d layers):", _nextLayerId);
        foreach (i; 0 .. _nextLayerId) {
            writefln("  Layer %d: parent=%d, source=%s",
                i, layerParent[i], layerSource[i]);
        }
    }
}

// ============================================================================
// Tests
// ============================================================================

unittest {
    // Test basic layer allocation
    auto ctx = new PlanContext();

    auto layer0 = ctx.allocateLayer(-1, "db1");
    auto layer1 = ctx.allocateLayer(layer0, "db1");
    auto layer2 = ctx.allocateLayer(layer0, "db2");  // Different source

    assert(layer0 == 0);
    assert(layer1 == 1);
    assert(layer2 == 2);
    assert(ctx.layerParent == [-1, 0, 0]);
    assert(ctx.layerSource == ["db1", "db1", "db2"]);
}

unittest {
    // Test source context management
    static class TestSourceContext : SourcePlanContext {
        PlanContext parent;
        string sourceId;
        int data;

        this(PlanContext p, string id) {
            parent = p;
            sourceId = id;
        }
    }

    auto ctx = new PlanContext();

    auto src1 = ctx.source!TestSourceContext("db1");
    src1.data = 42;

    auto src2 = ctx.source!TestSourceContext("db2");
    src2.data = 100;

    // Same source ID returns same context
    assert(ctx.source!TestSourceContext("db1").data == 42);
    assert(ctx.source!TestSourceContext("db2").data == 100);

    // Different source IDs are independent
    assert(ctx.source!TestSourceContext("db1") !is ctx.source!TestSourceContext("db2"));
}
