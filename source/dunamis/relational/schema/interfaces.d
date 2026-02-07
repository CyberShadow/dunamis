module dunamis.relational.schema.interfaces;

import dunamis.core.expr.base : ExprBase;
import dunamis.core.types : AnyRef;
import dunamis.relational.eval_context : DataFetcher;
import dunamis.relational.query_node : FilterType;

// ============================================================================
// Base classes for runtime type checking
// ============================================================================

/// Interface for column access expressions (for chain walking and optimizer analysis)
interface ColumnAccessInfo {
    /// The input expression this column is accessed from
    @property ExprBase inputExpr();

    /// The SQL column name (e.g., "first_name")
    @property string sqlColumn();
}

/// Interface for belongsTo expressions (for chain walking)
interface BelongsToInfo {
    @property ExprBase inputExpr();
    /// Returns an Expr!AnyRef that converts the input (Child entities) to AnyRef.
    /// Created by the concrete class which knows the Child type at compile time.
    @property ExprBase inputAsAnyRefExpr();
    @property string childTable();
    @property string parentTable();
    @property string parentTypeName();
    @property string fkColumn();
}

/// Interface for hasMany expressions to expose their metadata.
interface HasManyInfo {
    /// The input expression (points to parent entity)
    @property ExprBase inputExpr();

    /// Returns an Expr!AnyRef that converts the input (Parent entities) to AnyRef.
    /// Created by the concrete class which knows the Parent type at compile time.
    @property ExprBase inputAsAnyRefExpr();

    /// Foreign key column in child table
    @property string fkColumn();

    /// Child entity type name
    @property string childTypeName();

    /// Child table name
    @property string childTable();

    /// Parent entity type name (for ref encoding)
    @property string parentTypeName();
}

// ============================================================================
// Root Expressions
// ============================================================================

/// Interface for root expressions (GetByIds, GetAll) to expose filter info.
/// Used by optimizer to configure QueryNodes correctly.
interface RootExprInfo {
    /// The filter type (all, byIds)
    FilterType filterType();

    /// For byIds: the refs to filter by
    AnyRef[] filterRefs();

    /// Entity type name for the root query
    string entityTypeName();

    /// Entity table name for the root query
    string entityTable();

    /// The data fetcher for this root (may be null for legacy usage)
    DataFetcher dataFetcher();
}

/// Source ID for an entity - uses table name as unique identifier.
/// This is used to key into RelationalEvalContext for multi-source scenarios.
template entitySourceId(Entity) {
    import dunamis.relational.schema.types : EntityID;
    enum entitySourceId = EntityID!Entity.table;
}
