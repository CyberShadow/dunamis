module graphqld2.relational.demo;

/// High-level opinionated conveniences for demos and examples.
/// These make common assumptions (like auto-generated BIGINT id) that
/// may not fit all use cases. For full control, use the low-level
/// primitives in graphqld2.relational.schema.

import std.conv : to;

import graphqld2.core.types : CustomScalar;
import graphqld2.relational.schema : Entity, PrimaryKey;

// Re-export MockDB for convenience
public import graphqld2.relational.eval_context : MockDB;

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
/// static MyDB db;
///
/// struct User {
///     mixin DemoEntity!(db, "users");           // ID is Int64
///     mixin Col!("email", string);
/// }
///
/// struct Item {
///     mixin DemoEntity!(db, "items", string);   // ID is string (UUID)
/// }
/// ---
mixin template DemoEntity(alias db, string tableName, IdType = Int64, string typeName = "") {
    import graphqld2.relational.schema : Entity, PrimaryKey, column;
    import graphqld2.core.expr : Expr;

    mixin Entity!(db, tableName, typeName);

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

// ============================================================================
// CRUD Mutation Mixins
// ============================================================================

/// Generate CRUD mutations for an entity type.
/// Creates: create<Entity>, update<Entity>, delete<Entity>
///
/// Example:
/// ---
/// struct Mutation {
///     mixin CrudMutations!User;
///     // Generates:
///     //   createUser(input: CreateUserInput!): User!
///     //   updateUser(id: ID!, input: UpdateUserInput): User
///     //   deleteUser(id: ID!): Boolean!
/// }
/// ---
mixin template CrudMutations(Entity) {
    import std.format : format;
    import std.json : JSONValue;
    import graphqld2.core.expr : Expr;
    import graphqld2.relational.mutation : insert, update, delete_;

    // createEntity(input: {...}): Entity!
    mixin(format(
        `static auto create%s(Expr!(typeof(this)) parent, JSONValue[string] input) {
            return insert!%s(input);
        }`,
        Entity._typeName, Entity.stringof
    ));

    // updateEntity(id: Int64!, input: {...}): Entity
    mixin(format(
        `static auto update%s(Expr!(typeof(this)) parent, Int64 id, JSONValue[string] input) {
            return update!%s([id.value], input).single();
        }`,
        Entity._typeName, Entity.stringof
    ));

    // deleteEntity(id: Int64!): Boolean!
    mixin(format(
        `static auto delete%s(Expr!(typeof(this)) parent, Int64 id) {
            return delete_!%s([id.value]);
        }`,
        Entity._typeName, Entity.stringof
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
    import graphqld2.core : Executor;
    import graphqld2.core.eval : EvalContext;
    import graphqld2.relational.schema : Col;
    import graphqld2.relational.mutation : insert, update, delete_;

    // Test entity
    static MockDB!() db;

    static struct User {
        mixin DemoEntity!(db, "users");
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

        auto updateExpr = update!User([1], [
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

        auto deleteExpr = delete_!User([1]);

        auto ctx = new EvalContext();
        auto result = awaitSync(deleteExpr.eval(ctx));

        assert(result.length == 1);
        assert(result[0] == true);
    }
}

// Test CrudMutations mixin
unittest {
    import graphqld2.relational.schema : Col;

    static MockDB!() db;

    static struct User {
        mixin DemoEntity!(db, "users");
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
    import graphqld2.relational.schema : Col;

    static MockDB!() db;

    static struct User {
        mixin DemoEntity!(db, "users");
        mixin Col!("name", string);
    }

    static struct Post {
        mixin DemoEntity!(db, "posts");
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
