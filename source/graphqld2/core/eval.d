module graphqld2.core.eval;

import std.algorithm;
import std.array;
import std.conv;
import std.json;

// ============================================================================
// Source Eval Context Interface
// ============================================================================

/// Base interface for source-specific evaluation contexts
interface SourceEvalContext {
    /// Load data from a JSON result
    void loadData(JSONValue data);
}

// ============================================================================
// Core Eval Context
// ============================================================================

/// Key for looking up source contexts
private struct SourceKey {
    TypeInfo type;
    string sourceId;
}

/// Core evaluation context that coordinates across data sources.
/// Each data source registers its own sub-context with source-specific data.
class EvalContext {
    private {
        SourceEvalContext[SourceKey] _sourceContexts;
    }

    /// Current entity IDs being processed
    long[] currentIds;

    /// Which layer we're currently evaluating in
    int currentLayerId;

    /// Current source ID
    string currentSourceId = "default";

    /// Get or create a source-specific eval context
    T source(T : SourceEvalContext)(string sourceId = null) {
        auto id = (sourceId !is null) ? sourceId : currentSourceId;
        auto key = SourceKey(typeid(T), id);
        if (key !in _sourceContexts) {
            static if (__traits(compiles, new T(this, id))) {
                _sourceContexts[key] = new T(this, id);
            } else {
                _sourceContexts[key] = new T(id);
            }
        }
        return cast(T) _sourceContexts[key];
    }

    /// Register a pre-created source context
    void registerSource(T : SourceEvalContext)(string sourceId, T ctx) {
        auto key = SourceKey(typeid(T), sourceId);
        _sourceContexts[key] = ctx;
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

    /// Execute with different current state and source, then restore
    void withState(int layerId, long[] ids, string sourceId, void delegate() fn) {
        auto savedLayer = currentLayerId;
        auto savedIds = currentIds;
        auto savedSource = currentSourceId;
        currentLayerId = layerId;
        currentIds = ids;
        currentSourceId = sourceId;
        fn();
        currentLayerId = savedLayer;
        currentIds = savedIds;
        currentSourceId = savedSource;
    }
}

// ============================================================================
// Tests
// ============================================================================

unittest {
    // Test source context management
    static class TestEvalContext : SourceEvalContext {
        string sourceId;
        int data;

        this(string id) {
            sourceId = id;
        }

        override void loadData(JSONValue data) {
            // no-op for test
        }
    }

    auto ctx = new EvalContext();

    auto src1 = ctx.source!TestEvalContext("db1");
    src1.data = 42;

    auto src2 = ctx.source!TestEvalContext("db2");
    src2.data = 100;

    assert(ctx.source!TestEvalContext("db1").data == 42);
    assert(ctx.source!TestEvalContext("db2").data == 100);
}

unittest {
    // Test withState
    auto ctx = new EvalContext();
    ctx.currentLayerId = 0;
    ctx.currentIds = [1, 2, 3];
    ctx.currentSourceId = "db1";

    ctx.withState(5, [10, 20], "db2", {
        assert(ctx.currentLayerId == 5);
        assert(ctx.currentIds == [10, 20]);
        assert(ctx.currentSourceId == "db2");
    });

    // Restored
    assert(ctx.currentLayerId == 0);
    assert(ctx.currentIds == [1, 2, 3]);
    assert(ctx.currentSourceId == "db1");
}
