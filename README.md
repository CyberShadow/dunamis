# graphqld2

Exploratory project for a next major version of a D GraphQL server library.

## Problem

Traditional GraphQL server implementations suffer from the N+1 query problem. A naive resolver-per-field approach leads to:

```
query {
  users {        # 1 query: SELECT * FROM users
    posts {      # N queries: SELECT * FROM posts WHERE author_id = ?
      comments { # N*M queries: SELECT * FROM comments WHERE post_id = ?
        ...
      }
    }
  }
}
```

Solutions like DataLoader help but require manual batching logic and don't fundamentally change the per-object resolver model.

## Goals

1. **Schema from D types** - Introspect D structs/classes to generate GraphQL schema
2. **Bulk resolution** - All field computations happen once per field, for all objects
3. **Constant DB calls per query** - Number of database round-trips is O(fields), not O(objects)
4. **Declarative relationships** - Object relations defined at schema level, not computed at runtime

## Approach: Two-Phase Execution

### Phase 1: Build the computation graph

Walk the GraphQL query and construct an expression tree that describes:
- What data needs to be fetched
- What computations need to happen
- Dependencies between fields

At this point, we know *what* to fetch but don't have the data yet.

### Phase 2: Execute and resolve

- Batch-fetch all required data (grouped by type/table)
- Evaluate the expression tree with resolved data
- Assemble the response

### Key Constraint

> The compute phase cannot return object IDs that we then need to fetch.

All relationships must be declared in the schema, not computed at runtime. This means:
- Foreign key relationships are known statically
- We fetch all possible dependencies, discard unused ones
- No dynamic "fetch this ID I just computed" patterns

This is an acceptable trade-off for most CRUD applications.

## Design: Expression Trees

Fields are defined as `Expr!T` - expression trees that can be:
1. Analyzed for dependencies (Phase 1)
2. Evaluated in batches (Phase 2)

```d
abstract class Expr(T) {
    /// Phase 2: evaluate for a batch of parent contexts
    abstract T[] evalBatch(Context[] contexts);

    // TODO: Phase 1
    // abstract Dependency[] dependencies();
}
```

### Core Expression Types

| Type | Description |
|------|-------------|
| `ConstExpr!T` | Constant value, same for all contexts |
| `ContextIdExpr!T` | Reads entity ID from context (like `this`) |
| `BinaryOpExpr` | Binary operations (+, ~, ==, etc.) |
| `UseExpr` | Per-element computation: `(A, B) => R` |
| `UseAllExpr` | Batch computation: `(A[], B[]) => R[]` |

### The Context

Each `Context` represents one "row" being processed - typically one entity. It carries:
- The entity ID for this row
- (Future: resolved data stores, root query access)

```d
struct Context {
    long entityId;
    TypeInfo entityType;

    static Context forEntity(T)(Id!T id);
    Id!T getId(T)() const;
}
```

### Combinators

**`use(fn, expr1, expr2, ...)`** - Per-element computation

```d
Expr!string fullName() => use(
    (string first, string last) => first ~ " " ~ last,
    firstName(),
    lastName()
);
```

**`useAll(fn, expr1, expr2, ...)`** - Batch computation (key for DB access)

```d
Expr!string firstName() => useAll(
    (Id!User[] ids) => db.query("SELECT first_name FROM users WHERE id IN (?)", ids),
    contextId!User()
);
```

**`contextId!T()`** - Get current entity's ID (like `this`/`self`)

## Architecture Layers

```
┌─────────────────────────────────────┐
│         GraphQL API Layer           │
│  - Schema generation from types     │
│  - Query parsing                    │
│  - Response serialization           │
└─────────────────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────┐
│      Expression / Computation       │
│  - Expr!T tree building             │
│  - Dependency analysis              │
│  - Batch evaluation                 │
└─────────────────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────┐
│           ORM / Data Layer          │
│  - Entity definitions               │
│  - Relationship declarations        │
│  - Batch data fetching              │
└─────────────────────────────────────┘
```

Note: Entity IDs (`Id!T`) live in the ORM layer, not GraphQL. GraphQL sees opaque object references.

## Current Status

**Working:**
- `Expr!T` base class and evaluation
- `ConstExpr`, `ContextIdExpr`, `BinaryOpExpr`
- `use` and `useAll` combinators (variadic)
- Basic operator overloads
- Batched field resolution
- Simple relationship traversal

**Not yet implemented:**
- Phase 1 dependency collection
- Array operations (`filter`, `map`, `flatMap` on `Expr!(T[])`)
- Conditional expressions (`when`)
- Root query access (for cross-cutting data needs)
- GraphQL schema generation
- Query parsing and execution
- Response serialization

## Example

```d
// ORM layer - entity field definitions
struct User {
    static Expr!string firstName() => useAll(
        (Id!User[] ids) => fetchUserField!"firstName"(ids),
        contextId!User()
    );

    static Expr!string lastName() => useAll(
        (Id!User[] ids) => fetchUserField!"lastName"(ids),
        contextId!User()
    );

    static Expr!string fullName() => use(
        (string first, string last) => first ~ " " ~ last,
        firstName(),
        lastName()
    );

    static Expr!(Id!Post[]) postIds() => useAll(
        (Id!User[] ids) => fetchPostIdsForUsers(ids),
        contextId!User()
    );
}

// Usage - batched evaluation
auto contexts = [1, 2, 3].map!(id => Context.forEntity(Id!User(id))).array;

// ONE "database query" for all three users:
auto names = User.fullName().evalBatch(contexts);
// => ["Alice Smith", "Bob Jones", "Carol White"]
```

## Future Directions

- **Generic ORM abstraction** for batch data fetching
- **Mixin-based field exposure** to reduce boilerplate
- **Push-down optimizations** (push filters to SQL)
- **Async/parallel execution** for independent fetches
- **Caching and deduplication** of identical sub-expressions

## Related Work

- [Grafast](https://grafast.org/) (PostGraphile) - Similar "steps" concept for batched execution
- [Haxl](https://github.com/facebook/Haxl) - Haskell library for implicit batching
- [DataLoader](https://github.com/graphql/dataloader) - Per-request batching and caching
