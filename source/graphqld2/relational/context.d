module graphqld2.relational.context;

// This module is kept for backwards compatibility but the new architecture
// uses the simplified Ref-based system in core/eval.d and relational/schema.d
//
// The complex layer-based RelationalPlanContext and RelationalEvalContext
// are no longer needed - the new system uses:
// - core/types.d: Ref struct for entity references
// - core/eval.d: EvalContext, DataFetcher, QueryResult
// - relational/schema.d: ColumnAccessExpr, HasManyAccessExpr, BelongsToAccessExpr
