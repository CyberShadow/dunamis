module graphqld2.relational.demo;

/// High-level opinionated conveniences for demos and examples.
/// These make common assumptions (like auto-generated BIGINT id) that
/// may not fit all use cases. For full control, use the low-level
/// primitives in graphqld2.relational.schema.

import std.conv : to;

import graphqld2.core.types : CustomScalar;
import graphqld2.relational.schema : Entity, PrimaryKey;

// ============================================================================
// Custom Scalars for Demo
// ============================================================================

/// Int64 custom scalar for 64-bit integer support.
/// GraphQL's Int is 32-bit, so we need a custom scalar for long values.
///
/// Example:
/// ---
/// struct Entity {
///     mixin DemoEntity!("table", Int64);  // Use Int64 as ID type
///     mixin Col!("bigValue", Int64);      // Use Int64 for columns
/// }
/// ---
alias Int64 = CustomScalar!(
    long, "Int64",
    (long v) => v.to!string,
    (string s) => s.to!long
);

// ============================================================================
// Demo Entity Mixin
// ============================================================================

/// High-level convenience mixin for demos and examples.
/// Adds Entity metadata plus a standard `id` column (BIGINT primary key).
///
/// By default, uses Int64 for the ID type (64-bit integer with proper
/// GraphQL scalar support). You can override this with any type.
///
/// For full control over primary keys (natural keys, composite keys, etc.),
/// use the low-level Entity + Col + PrimaryKey mixins instead.
///
/// Example:
/// ---
/// struct User {
///     mixin DemoEntity!"users";           // ID is Int64
///     mixin Col!("email", string);
/// }
///
/// struct Item {
///     mixin DemoEntity!("items", string); // ID is string (UUID)
/// }
/// ---
mixin template DemoEntity(string tableName, IdType = Int64, string typeName = "", string sourceId = "default") {
    import graphqld2.relational.schema : Entity, PrimaryKey, column;
    import graphqld2.core.expr : Expr;

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

    /// ID accessor - reads the id column
    static auto id(Expr!(typeof(this)) e) {
        return e.column!(IdType, typeof(this))("id");
    }

    mixin PrimaryKey!"id";
}
