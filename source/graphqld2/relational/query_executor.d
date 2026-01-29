module graphqld2.relational.query_executor;

import std.algorithm;
import std.array;
import std.conv;
import std.json;

import graphqld2.core.types;
import graphqld2.core.eval;
import graphqld2.core.optimize;
import graphqld2.relational.eval_context;
import graphqld2.relational.query_node;
import graphqld2.relational.sql_optimizer;

// ============================================================================
// Relational Query Executor
// ============================================================================

/// Executes QueryNodes against a relational database.
/// This is the SQL-specific implementation of query execution.
class RelationalQueryExecutor {
    private DataFetcher _fetcher;

    this(DataFetcher fetcher) {
        _fetcher = fetcher;
    }

    /// Execute all QueryNodes and store results in EvalContext.
    /// Nodes must be in topological order (parents before children).
    void executeAll(QueryNode[] nodes, EvalContext evalCtx, SqlOptimizer sqlOpt = null) {
        // Get the relational evaluation context
        auto relCtx = evalCtx.getSourceContext!RelationalEvalContext();

        debug(sql) {
            import std.stdio : writeln, writefln;
            writefln("=== Executing %d QueryNode(s) ===\n", nodes.length);
            if (sqlOpt !is null) {
                writeln(toSQL(nodes, sqlOpt));
            } else {
                writeln(toSQL(nodes));
            }
            writeln();
        }

        foreach (node; nodes) {
            auto result = executeQueryNode(node, relCtx, sqlOpt);
            relCtx.storeQueryResult(node.id, result);
        }

        debug(sql) {
            import std.stdio : writeln;
            writeln("=== Query execution complete ===\n");
        }
    }

    /// Execute a single QueryNode and return its QueryResult.
    private QueryResult executeQueryNode(QueryNode node, RelationalEvalContext relCtx, SqlOptimizer sqlOpt) {
        auto result = new QueryResult();
        Ref[] refs;

        // Step 1: Determine the refs for this node
        if (node.isRoot) {
            final switch (node.rootFilter) {
                case FilterType.none:
                    // Not configured as root - shouldn't happen
                    break;

                case FilterType.all:
                    // Fetch all IDs from table
                    auto ids = _fetcher.fetchAllIds(node.table);
                    refs = ids.map!(id => makeRef(node.typeName, id)).array;
                    result.initialize(node.typeName, refs);
                    break;

                case FilterType.byId:
                case FilterType.byIds:
                    refs = node.rootFilterRefs.dup;
                    result.initialize(node.typeName, refs);
                    break;
            }
        } else {
            // Child node: get children via fetchChildren
            auto parentResult = relCtx.getQueryResult(node.parent.id);
            if (parentResult !is null) {
                auto parentRefs = parentResult.allRefs();

                // fetchChildren returns Ref[][] grouped by parent
                auto childGroups = _fetcher.fetchChildren(
                    node.table, node.typeName, node.parentFk, parentRefs);

                // Flatten to get all child refs
                foreach (group; childGroups) {
                    refs ~= group;
                }

                // Initialize with parent grouping info
                auto fkValues = _fetcher.fetchColumnJson(node.table, node.parentFk, refs);
                result.initializeAsChild(node.typeName, refs, parentRefs, node.parentFk, fkValues);
            }
        }

        // Step 2: Fetch each column from base table
        foreach (column; node.columns) {
            auto values = _fetcher.fetchColumnJson(node.table, column, refs);
            result.loadColumn(column, refs, values);
        }

        // Step 3: Fetch columns from JOINed tables
        foreach (joinInfo; node.joins) {
            auto joinAlias = joinInfo.alias_;
            auto joinedCols = node.joinedColumns.get(joinAlias, null);
            if (joinedCols is null) continue;

            // Get FK values to determine which joined rows we need
            auto fkValues = _fetcher.fetchColumnJson(node.table, joinInfo.fk, refs);

            // Convert FK values to refs for the joined table
            Ref[] joinedRefs;
            foreach (fkVal; fkValues) {
                if (fkVal.type == JSONType.null_) {
                    joinedRefs ~= Ref.init;
                } else {
                    long fkId = fkVal.type == JSONType.integer ? fkVal.integer : fkVal.str.to!long;
                    joinedRefs ~= makeRef(joinInfo.targetType, fkId);
                }
            }

            // Fetch each column from the joined table
            foreach (column; joinedCols) {
                auto values = _fetcher.fetchColumnJson(joinInfo.targetTable, column, joinedRefs);
                // Store with alias prefix
                result.loadColumn(joinAlias ~ "." ~ column, refs, values);
            }
        }

        // Step 4: Evaluate computed columns (SQL push-down results)
        // Note: In a real SQL database, these would be fetched as part of the query.
        // With MockDataFetcher, we evaluate them in D since we can't execute real SQL.
        if (sqlOpt !is null) {
            foreach (computed; sqlOpt.getComputedColumns(node.id)) {
                // For mock execution, we'd need to evaluate the expression
                // In real SQL, this column would already be in the result set
                // For now, we store a placeholder - real implementation would
                // parse and evaluate the SQL expression or fetch from actual DB
            }
        }

        return result;
    }
}
