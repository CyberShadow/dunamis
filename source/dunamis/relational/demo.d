module dunamis.relational.demo;

/// High-level opinionated conveniences for demos and examples.
/// These make common assumptions (like auto-generated BIGINT id) that
/// may not fit all use cases. For full control, use the low-level
/// primitives in dunamis.relational.schema.

import std.conv : to;
import std.json : JSONValue, JSONType;

import dunamis.core.types : CustomScalar;
import dunamis.relational.schema : Entity, EntityID;

// Re-export MockDB and DebugSqlDB for convenience
public import dunamis.relational.mock : MockDB, DebugSqlDB;

// ============================================================================
// Custom Scalars for Demo
// ============================================================================

/// Int64 custom scalar for 64-bit integer support.
/// GraphQL's Int is 32-bit, so we need a custom scalar for long values.
///
/// Example:
/// ---
/// @DemoEntity!(db, "table")
/// struct MyEntity {
///     mixin DemoId;                       // Uses Int64 as ID type
///     mixin Col!("bigValue", Int64);      // Use Int64 for columns
/// }
/// ---
alias Int64 = CustomScalar!(
    long, "Int64",
    (long v) => JSONValue(v),
    (JSONValue j) => j.type == JSONType.integer ? j.integer : j.str.to!long
);

// ============================================================================
// DemoEntity UDA
// ============================================================================

/// UDA for demo/example entity structs. Wraps the Entity UDA interface
/// with the same duck-typed detection (has `.db` and `.table` members).
///
/// Use this together with `DemoId` mixin for a convenient entity declaration:
///
/// Example:
/// ---
/// static MyDB db;
///
/// @DemoEntity!(db, "users")
/// struct User {
///     mixin DemoId;                  // Adds @PrimaryKey id column (Int64)
///     mixin Col!("email", string);
/// }
///
/// @DemoEntity!(db, "items")
/// struct Item {
///     mixin DemoId!string;           // Adds @PrimaryKey id column (string)
/// }
/// ---
struct DemoEntity(alias _db, string _tableName, string _typeName = "") {
    alias db = _db;
    enum table = _tableName;
    enum typeName = _typeName;
}

// ============================================================================
// DemoId Mixin
// ============================================================================

/// Convenience mixin that adds a standard `id` primary key column.
///
/// By default, uses Int64 for the ID type (64-bit integer with proper
/// GraphQL scalar support). You can override this with any type.
///
/// For full control over primary keys (natural keys, composite keys, etc.),
/// use explicit `@PrimaryKey` fields instead.
mixin template DemoId(IdType = Int64) {
    import dunamis.relational.schema.attrs : PrimaryKey, AutoIncrement, SqlColumn;

    /// Primary key field - auto-increment, identifies this entity instance
    @PrimaryKey @AutoIncrement @SqlColumn("id") IdType id;
}

// ============================================================================
// CRUD Mutation Mixins
// ============================================================================

/// Generate CRUD mutations for an entity type.
/// Creates: create<Entity>, update<Entity>, delete<Entity>
///
/// For automatic CRUD generation via plugin composition, consider using
/// `CrudMutationPlugin` from `dunamis.schema.crud` instead:
/// ---
/// alias MySchema = CrudMutationPlugin!(Schema!(Query, Mutation));
/// ---
///
/// This mixin is useful when you need explicit control over which entities
/// get CRUD mutations, or when building custom mutation patterns.
///
/// Example:
/// ---
/// struct Mutation {
///     mixin CrudMutations!User;
///     // Generates:
///     //   createUser(input: JSON!): User!
///     //   updateUser(id: Int64!, input: JSON!): User!
///     //   deleteUser(id: Int64!): Boolean!
/// }
/// ---
mixin template CrudMutations(Entity) {
    import std.conv : to;
    import std.format : format;
    import std.json : JSONValue;
    import dunamis.core.expr : Expr;
    import dunamis.relational.demo : Int64;
    import dunamis.relational.mutation : insert, update, delete_;

    import dunamis.relational.schema : EntityID;

    // createEntity(input: {...}): Entity!
    mixin(format(
        `static auto create%s(Expr!(typeof(this)) parent, JSONValue[string] input) {
            return insert!%s(input);
        }`,
        EntityID!Entity.typeName, Entity.stringof
    ));

    // updateEntity(id: Int64!, input: {...}): Entity
    mixin(format(
        `static auto update%s(Expr!(typeof(this)) parent, Int64 id, JSONValue[string] input) {
            return update!%s([id.value.to!string], input).single();
        }`,
        EntityID!Entity.typeName, Entity.stringof
    ));

    // deleteEntity(id: Int64!): Boolean!
    mixin(format(
        `static auto delete%s(Expr!(typeof(this)) parent, Int64 id) {
            return delete_!%s([id.value.to!string]);
        }`,
        EntityID!Entity.typeName, Entity.stringof
    ));
}

/// Generate CRUD mutations for multiple entities.
/// Usage: mixin AllCrudMutations!(User, Post, Comment);
mixin template AllCrudMutations(Entities...) {
    static foreach (Entity; Entities) {
        mixin CrudMutations!Entity;
    }
}

// ============================================================================
// Unit Tests
// ============================================================================

// Test low-level INSERT/UPDATE/DELETE operations
unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dunamis.core : Executor;
    import dunamis.core.eval : EvalContext;
    import dunamis.relational.schema : Col, isValid;
    import dunamis.relational.mutation : insert, update, delete_;

    // Test entity
    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("name", string);
        mixin Col!("email", string);
    }

    // Test INSERT at expression level
    {
        db = new MockDB!();
        db.setTableData("users", `[]`);

        auto insertExpr = insert!User([
            "name": JSONValue("Alice"),
            "email": JSONValue("alice@test.com")
        ]);

        auto ctx = new EvalContext();
        auto result = awaitSync(insertExpr.eval(ctx));

        // Should return one entity
        assert(result.length == 1);
        assert(result[0].isValid());
    }

    // Test UPDATE at expression level
    {
        db = new MockDB!();
        db.setTableData("users", `[
            {"id": 1, "name": "Alice", "email": "alice@test.com"},
            {"id": 2, "name": "Bob", "email": "bob@test.com"}
        ]`);

        auto updateExpr = update!User(["1"], [
            "name": JSONValue("Alice Updated")
        ]);

        auto ctx = new EvalContext();
        auto result = awaitSync(updateExpr.eval(ctx));

        // Should return one array with one entity
        assert(result.length == 1);
        assert(result[0].length == 1);
        assert(result[0][0].isValid());
    }

    // Test DELETE at expression level
    {
        db = new MockDB!();
        db.setTableData("users", `[
            {"id": 1, "name": "Alice"},
            {"id": 2, "name": "Bob"}
        ]`);

        auto deleteExpr = delete_!User(["1"]);

        auto ctx = new EvalContext();
        auto result = awaitSync(deleteExpr.eval(ctx));

        assert(result.length == 1);
        assert(result[0] == true);
    }
}

// Test CrudMutations mixin
unittest {
    import dunamis.relational.schema : Entity, Col;

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("name", string);
    }

    static struct Mutation {
        mixin CrudMutations!User;
    }

    // Verify methods exist
    static assert(__traits(hasMember, Mutation, "createUser"));
    static assert(__traits(hasMember, Mutation, "updateUser"));
    static assert(__traits(hasMember, Mutation, "deleteUser"));
}

// Test AllCrudMutations mixin
unittest {
    import dunamis.relational.schema : Entity, Col;

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("name", string);
    }

    @DemoEntity!(db, "posts")
    static struct Post {
        mixin DemoId;
        mixin Col!("title", string);
    }

    static struct Mutation {
        mixin AllCrudMutations!(User, Post);
    }

    // Verify all methods exist
    static assert(__traits(hasMember, Mutation, "createUser"));
    static assert(__traits(hasMember, Mutation, "updateUser"));
    static assert(__traits(hasMember, Mutation, "deleteUser"));
    static assert(__traits(hasMember, Mutation, "createPost"));
    static assert(__traits(hasMember, Mutation, "updatePost"));
    static assert(__traits(hasMember, Mutation, "deletePost"));
}
