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
│  - Schema SDL generation            │
│  - SQL DDL generation               │
│  - Query parsing (planned)          │
└─────────────────────────────────────┘
```

The Executor is data-source agnostic. Data sources travel with expressions - root expressions (like `getByIds!User`) carry their DataFetcher. The executor walks the expression tree to collect optimizers needed for each data source.

## Example

```d
import graphqld2.core;
import graphqld2.relational;
import graphqld2.graphql;

// Schema definition - the Query type defines root entry points
struct Query {
    mixin Table!(User, "users");
    mixin Table!(Post, "posts");
}

// Entity definitions with mixins
// DemoEntity is a convenience wrapper that adds an `id` column automatically.
// For full control, use the low-level Entity + Col + PrimaryKey mixins.
struct User {
    mixin DemoEntity!"users";

    @GqlDescription("The user's first name")
    mixin Col!("firstName", string);

    @GqlDescription("The user's last name")
    mixin Col!("lastName", string);

    @GqlDescription("Primary email address")
    @GqlDeprecated("Use the emails field instead")
    mixin Col!("email", string);

    mixin HasMany!("posts", Post, "author_id");
    mixin HasMany!("comments", Comment, "author_id");

    // Computed field - uses property-like access via opDispatch
    static auto fullName(RefExpr!User u) => u.firstName ~ " " ~ u.lastName;

    // Computed field with arguments - arguments are concrete values at planning time
    @GqlDescription("A personalized greeting")
    static auto greeting(RefExpr!User u, string prefix, string suffix = "!") {
        return constant(prefix, u) ~ " " ~ u.firstName ~ constant(suffix, u);
    }

    // Computed field with struct argument - generates input type automatically
    static auto formattedName(RefExpr!User u, FormatOptions options) {
        return options.prefix ~ u.firstName;
    }
}

// Input types - regular D structs used as computed field arguments
struct FormatOptions {
    string prefix;                           // Required: String!
    Nullable!string suffix;                  // Optional (absent = null): String
    Nullable!(Nullable!bool) uppercase;      // Three-state (absent/null/value): Boolean
}

struct Post {
    mixin DemoEntity!"posts";
    mixin Col!("title", string);

    @GqlName("body")  // D keyword conflict: body_ → body in GraphQL
    mixin Col!("body_", string, "body");

    @GqlHidden  // Hide FK column from GraphQL, expose only the relationship
    mixin Col!("authorId", ForeignKey!User);
    mixin BelongsTo!("author", "authorId");

    mixin HasMany!("comments", Comment, "post_id");
    // For nullable FKs:
    // mixin Col!("editorId", Nullable!(ForeignKey!User));  // Nullable FK column
    // mixin BelongsTo!("editor", "editorId");              // Automatically nullable
}

struct Comment {
    mixin DemoEntity!"comments";

    @GqlName("body")
    mixin Col!("body_", string, "body");

    @GqlHidden mixin Col!("postId", ForeignKey!Post);
    @GqlHidden mixin Col!("authorId", ForeignKey!User);

    mixin BelongsTo!("post", "postId");
    mixin BelongsTo!("author", "authorId");
}

// Usage - query from root
auto db = new MockDataFetcher();
auto executor = new Executor();

// Query: { posts { title, author { fullName } } }
// Uses property-like syntax: p.title, p.author.fullName
auto query = map!(
    (RefExpr!Post p) => jsonObject(
        "title", p.title,
        "author", p.author.fullName
    )
)(Query.posts(db));  // Entry point from Query root

auto result = executor.execute(query);

// Generate GraphQL schema from D types
pragma(msg, generateSchemaSDL!Query);
// Output:
// type Query {
//   users: [User!]!
//   posts: [Post!]!
// }
// type User { ... }
// type Post { ... }

// Generate SQL DDL
pragma(msg, generateDDL!Query);
// Output:
// CREATE TABLE users ( ... );
// CREATE TABLE posts ( ... FOREIGN KEY (author_id) REFERENCES users(id) );
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
    (RefExpr!User user) => jsonObject(
        "firstName", user.firstName,
        "posts", map!(
            (RefExpr!Post post) => jsonObject(
                "title", post.title
            )
        )(user.posts)
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

### Input Types

Struct arguments to computed fields are automatically discovered and generated as GraphQL input types:

```d
// D struct definition
struct FormatOptions {
    string prefix;                           // Required field
    Nullable!string suffix;                  // Optional (absent = null)
    Nullable!(Nullable!bool) uppercase;      // Three-state: absent/null/value
}

// Used in computed field
static auto formattedName(RefExpr!User u, FormatOptions options) { ... }
```

Generates GraphQL schema:

```graphql
input FormatOptions {
  prefix: String!
  suffix: String
  uppercase: Boolean
}

type User {
  formattedName(options: FormatOptions!): String!
}
```

**Type mapping for input fields:**

| D Type | GraphQL | Semantics |
|--------|---------|-----------|
| `T` | `T!` | Required, non-null |
| `Nullable!T` | `T` | Optional, absent = null |
| `Nullable!(Nullable!T)` | `T` | Three-state: absent/null/value |

The three-state mapping (`Nullable!(Nullable!T)`) supports patch mutation semantics where:
- **Absent** = don't change this field
- **Null** = set to NULL
- **Value** = set to this value

This distinction is semantic (handled in your resolver logic), not schema-level—GraphQL represents both `Nullable!T` and `Nullable!(Nullable!T)` as nullable types.

## Current Status

**Working:**
- Expression tree with batched evaluation (`Expr!T`)
- `use()` combinator for per-element computation
- Operator overloading (`~`, `==`, etc.)
- Entity definition mixins (`Entity`, `Col`, `BelongsTo`, `HasMany`)
- `Table` mixin for Query root entry points
- `ForeignKey!Entity` type for type-safe FK columns
- `@GqlHidden` UDA to hide fields from GraphQL schema
- `@GqlName` UDA to override GraphQL field names (for D keyword conflicts)
- `@GqlDescription` UDA to add field descriptions (rendered as doc comments in SDL)
- `@GqlDeprecated` UDA to mark fields as deprecated (rendered with `@deprecated` directive)
- QueryNode-based SQL planning
- JOINs for belongsTo relationships
- Child queries (CTEs) for hasMany relationships
- Computed fields with SQL push-down (concatenation becomes `||` in SQL)
- Computed fields in GraphQL schema (static functions taking `RefExpr!Entity`)
- Field arguments for computed fields (with defaults, introspected from D function signatures)
- Input types auto-generated from struct arguments (with `Nullable!(Nullable!T)` for three-state fields)
- Data-source agnostic Executor
- MockDataFetcher for testing
- DebugSqlFetcher for SQL inspection (with SQL push-down support)
- GraphQL schema generation (`generateSchemaSDL!Query`)
- SQL DDL generation (`generateDDL!Query`)

**Not yet implemented:**
- GraphQL query parsing
- Mutations (depends on query parsing)
- Response serialization
- Real database DataFetcher (PostgreSQL, etc.)
- Filtering/pagination (WHERE, LIMIT, OFFSET)
- Polymorphism (GraphQL union/interface types)
- Runtime introspection (`__schema`, `__type`, `__typename`)

## Running Tests

```bash
dub test

# With SQL debug output
dub test -d=sql

# Show generated GraphQL schema
dub test -d=graphql

# Show generated SQL DDL
dub test -d=ddl
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
