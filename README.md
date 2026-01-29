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

### Phase 1: Optimization

Walk the expression tree and:
- Collect QueryNodes (one per MapExpr scope)
- Track columns needed from each table
- Build JOINs for belongsTo relationships
- Create child QueryNodes for hasMany relationships

### Phase 2: Evaluation

- Execute prefetch queries (CTE-based SQL for all layers)
- Evaluate expressions against fetched data
- Assemble the response

### Key Constraint

> The compute phase cannot return object IDs that we then need to fetch.

All relationships must be declared in the schema, not computed at runtime. This means:
- Foreign key relationships are known statically
- We fetch all possible dependencies, discard unused ones
- No dynamic "fetch this ID I just computed" patterns

This is an acceptable trade-off for most CRUD applications.

## Architecture

```
┌─────────────────────────────────────┐
│           Core Layer                │
│  - Expr!T expression trees          │
│  - Data-source agnostic Executor    │
│  - OptimizeContext / EvalContext    │
└─────────────────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────┐
│        Relational Layer             │
│  - Entity mixins (Col, BelongsTo)   │
│  - QueryNode SQL planning           │
│  - CTE-based query generation       │
│  - DataFetcher abstraction          │
└─────────────────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────┐
│         GraphQL Layer               │
│  - Schema generation (planned)      │
│  - Query parsing (planned)          │
└─────────────────────────────────────┘
```

The Executor is data-source agnostic. Data sources travel with expressions - root expressions (like `getByIds!User`) carry their DataFetcher. The executor walks the expression tree to collect optimizers needed for each data source.

## Example

```d
import graphqld2.core;
import graphqld2.relational;

// Entity definitions with mixins
struct User {
    mixin Entity!"users";
    mixin Col!("firstName", string);
    mixin Col!("lastName", string);
    mixin Col!("email", string);
    mixin HasMany!("posts", Post, "author_id");
    mixin HasMany!("comments", Comment, "author_id");

    // Computed field
    static auto fullName(Expr!Ref u) => firstName(u) ~ " " ~ lastName(u);
}

struct Post {
    mixin Entity!"posts";
    mixin Col!("title", string);
    mixin Col!("body_", string, "body");
    mixin BelongsTo!("author", User, "author_id");
    mixin HasMany!("comments", Comment, "post_id");
}

struct Comment {
    mixin Entity!"comments";
    mixin Col!("body_", string, "body");
    mixin BelongsTo!("author", User, "author_id");
}

// Usage
auto db = new MockDataFetcher();
auto executor = new Executor();

// Query: { posts { title, author { fullName } } }
auto query = map!(
    (Expr!Ref p) => jsonObject(
        "title", Post.title(p),
        "author", User.fullName(Post.author(p))
    )
)(getByIds!Post([1, 2], db));

auto result = executor.execute(query);
```

The above generates a single SQL query with JOINs:

```sql
SELECT posts.id, posts.title, j0.first_name, j0.last_name
FROM posts
LEFT JOIN users AS j0 ON posts.author_id = j0.id
WHERE posts.id IN (1, 2)
```

### Nested Relationships (HasMany)

```d
// Query: { users { firstName, posts { title } } }
auto query = map!(
    (Expr!Ref user) => jsonObject(
        "firstName", User.firstName(user),
        "posts", map!(
            (Expr!Ref post) => jsonObject(
                "title", Post.title(post)
            )
        )(User.posts(user))
    )
)(getByIds!User([1, 2], db));
```

Generates CTE-based SQL:

```sql
WITH layer0 AS (
    SELECT users.id, users.first_name
    FROM users WHERE users.id IN (1, 2)
),
layer1 AS (
    SELECT posts.id, posts.title, posts.author_id
    FROM posts WHERE posts.author_id IN (SELECT id FROM layer0)
)
SELECT * FROM layer0;
SELECT * FROM layer1;
```

## Current Status

**Working:**
- Expression tree with batched evaluation (`Expr!T`)
- `use()` combinator for per-element computation
- Operator overloading (`~`, `==`, etc.)
- Entity definition mixins (`Entity`, `Col`, `BelongsTo`, `HasMany`)
- QueryNode-based SQL planning
- JOINs for belongsTo relationships
- Child queries (CTEs) for hasMany relationships
- Computed fields with SQL push-down (concatenation becomes `||` in SQL)
- Data-source agnostic Executor
- MockDataFetcher for testing
- DebugSqlFetcher for SQL inspection

**Not yet implemented:**
- GraphQL schema generation from types
- GraphQL query parsing
- Response serialization
- Real database DataFetcher (PostgreSQL, etc.)
- Filtering/pagination (WHERE, LIMIT, OFFSET)
- Polymorphism (GraphQL union/interface types)

## Running Tests

```bash
dub test

# With SQL debug output
dub test -d=sql
```

## Future Directions

- **Expression deduplication** - Grafast-style peer analysis
- **Plan caching** - Reuse optimized plans for repeated queries
- **Pagination** - LIMIT/OFFSET/cursor support
- **Async/parallel execution** - For independent fetches
- **Real database adapters** - PostgreSQL, MySQL, SQLite

## Related Work

- [Grafast](https://grafast.org/) (PostGraphile) - Similar "steps" concept for batched execution
- [Haxl](https://github.com/facebook/Haxl) - Haskell library for implicit batching
- [DataLoader](https://github.com/graphql/dataloader) - Per-request batching and caching
