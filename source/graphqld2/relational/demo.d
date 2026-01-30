module graphqld2.relational.demo;

/// High-level opinionated conveniences for demos and examples.
/// These make common assumptions (like auto-generated BIGINT id) that
/// may not fit all use cases. For full control, use the low-level
/// primitives in graphqld2.relational.schema.

import graphqld2.relational.schema : Entity, PrimaryKey;

// ============================================================================
// Demo Entity Mixin
// ============================================================================

/// High-level convenience mixin for demos and examples.
/// Adds Entity metadata plus a standard `id` column (BIGINT primary key).
///
/// For full control over primary keys (natural keys, composite keys, etc.),
/// use the low-level Entity + Col + PrimaryKey mixins instead.
///
/// Example:
/// ---
/// struct User {
///     mixin DemoEntity!"users";
///     mixin Col!("email", string);
/// }
/// ---
mixin template DemoEntity(string tableName, IdType = long, string typeName = "", string sourceId = "default") {
    import graphqld2.relational.schema : Entity, PrimaryKey;

    mixin Entity!(tableName, typeName, sourceId);

    /// Column metadata for the primary key (id)
    struct _colField_id {
        enum name = "id";
        enum column = "id";
        alias type = IdType;
        enum isForeignKey = false;
        enum isNullable = false;
        enum isPrimaryKey = true;
    }

    mixin PrimaryKey!"id";
}
