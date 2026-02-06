# Dynamo

A GraphQL server for D that eliminates N+1 queries through expression-based query optimization.

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
5. **SQL optimization** - Expression pushdown and automatic JOINs for declared relationships

## Approach

The core library is built around expression trees (`Expr!T`) that are data-source agnostic. Different data sources can implement their own optimization strategies.

### SQL: Two-Phase Execution

For relational databases, the library uses a two-phase approach:

**Phase 1: Optimization**

Walk the expression tree and:
- Collect QueryNodes (one per MapExpr scope)
- Track columns needed from each table
- Build JOINs for belongsTo relationships
- Create child QueryNodes for hasMany relationships

**Phase 2: Evaluation**

- Execute prefetch queries (CTE-based SQL for all layers)
- Evaluate expressions against fetched data
- Assemble the response

### Declarative vs Dynamic Relationships

For **optimal performance**, relationships should be declared in the schema:
- Foreign key relationships known statically → JOINs and CTEs
- Prefetch all possible dependencies, discard unused ones
- O(fields) database round-trips, not O(objects)

However, **dynamic fetching is always possible**. Custom `Expr` implementations can perform arbitrary async operations (the API uses Promises). This is useful for:
- ML-based recommendations returning computed IDs
- External service lookups
- Complex business logic that can't be expressed declaratively

The trade-off: dynamic fetches don't benefit from the batch optimization and may reintroduce N+1 patterns for that specific field.

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
│  - Query compilation (runtime)      │
└─────────────────────────────────────┘
```

The Executor is data-source agnostic. Data sources travel with expressions - root expressions (like `getByIds!User`) carry their DataFetcher. The executor walks the expression tree to collect optimizers needed for each data source.

## Core Principles

### 1. Entities as Lightweight Proxies

Entity structs hold only the minimal state needed to identify an object—typically just an ID:

```d
struct User {
    mixin Entity!(db, "users");  // Adds nodeId field
    // nodeId contains: compile-time metadata (db, table) + runtime ID string

    mixin Col!("firstName", string);  // No data stored here—just generates accessor
    mixin Col!("lastName", string);
}
```

The struct itself stores no column data. Instead, it acts as a **proxy** for the database row:

- `user.firstName` doesn't read from memory—it returns an `Expr!string` that represents "the firstName column for this user"
- The actual data lives in the database until explicitly fetched

**Why this design?**

1. **Efficiency** - Only requested columns are fetched. If a query doesn't select `email`, that column is never read from the database. This matters when some columns are large (BLOBs, long text) or expensive to compute (view-backed tables with complex aggregations).

2. **Vectorization** - Operations happen on all objects at once, not one at a time. Traditional resolver-based systems call `fullName(user)` for each user sequentially. Here, `u.firstName ~ " " ~ u.lastName` becomes a single SQL expression evaluated for all users in one query.

3. **Compile-time safety** - Field access returns `Expr!T`, not `T`. This means typos like `user.fristName` fail at compile time, and the type system ensures expressions compose correctly.

**Deferred materialization**: In most cases, even these lightweight proxy objects are never instantiated. When you write:

```d
auto query = map!((Expr!User u) => u.firstName ~ " " ~ u.lastName)(Query.users());
```

The `Expr!User` is never evaluated to a concrete `User` struct. Instead, the optimizer transforms the entire expression tree into a single SELECT:

```sql
SELECT first_name || ' ' || last_name FROM users
```

Only the final string results are materialized. The "User objects" exist purely as compile-time type information that guides query generation.

### 2. Fields as Static Expr Methods

The canonical representation of all fields is a static method that takes `Expr!Entity` and returns `Expr!T`:

```d
struct User {
    // Column (generated by Col mixin)
    static auto firstName(Expr!User e) => e.column!string("firstName");

    // Relationship (generated by BelongsTo mixin)
    static auto department(Expr!User e) => e.belongsTo!Department("departmentId");

    // Computed field (hand-written)
    static auto fullName(Expr!User u) => u.firstName ~ " " ~ u.lastName;
}
```

Users can also define plain fields and plain methods as a convenience for data that doesn't need SQL optimization (see [Plain Fields](#plain-fields-vs-col-mixins) and [Plain Methods](#plain-methods)). These are normalized into the canonical static Expr method form before plugin processing, so the plugin system only ever sees one kind of field.

**Why this design?**

1. **Uniform representation** - The optimizer and plugins can analyze and transform field access patterns regardless of whether the data comes from a database column, a JOIN, or in-memory computation. All fields look the same to the expression tree, and plugins only need to handle one field kind.

2. **SQL pushdown** - Because fields return expressions (not values), the optimizer can compose them into SQL. `u.firstName ~ " " ~ u.lastName` isn't computed in D—it becomes `first_name || ' ' || last_name` in the SQL query itself.

3. **Compile-time validation** - Return types are checked at compile time. If `fullName` returns `Expr!int` but you try to concatenate it with a string, the compiler catches it immediately. Traditional resolver-based systems return `Json` and defer type errors to runtime.

### 3. Data Source Binding via Static Alias

Entity types bind to their data source through a compile-time alias to a static/module-level variable:

```d
static PostgresDB db;  // or MockDB, SQLiteDB, MySQLDB

struct User {
    mixin Entity!(db, "users");  // Binds User to db
    // ...
}
```

**Why this design?**

1. **Multiple data sources** - A single schema can span multiple databases or backends. Users from PostgreSQL, analytics from ClickHouse, cache from Redis—each entity declares its source, and the executor coordinates them:
   ```d
   static PostgresDB mainDb;
   static ClickHouseDB analyticsDb;

   struct User { mixin Entity!(mainDb, "users"); }
   struct PageView { mixin Entity!(analyticsDb, "page_views"); }
   ```

2. **Compile-time dialect selection** - The optimizer knows at compile time which SQL dialect to use. PostgreSQL gets `||` for concatenation, MySQL gets `CONCAT()`. No runtime dialect switching needed.

3. **Type-safe query generation** - The binding is checked at compile time. If you reference a non-existent data source or mismatched types, compilation fails.

### 4. Extensible Optimizer via Pattern Matching

The optimizer uses interface-based pattern matching to recognize and transform expression types:

- `ColumnAccessInfo` - Column reads that can be batched into SELECT
- `BelongsToInfo` - Many-to-one relationships that become JOINs
- `HasManyInfo` - One-to-many relationships that become child CTEs
- `BinaryOpInfo` - Operations that can be pushed down to SQL

Different data sources register their own optimizers. The relational package contributes `RelationalOptimizer` and `SqlOptimizer`; future packages (e.g., REST APIs, in-memory stores) can add their own without modifying core.

### 5. Plugins as Composable Type Transformers

A plugin is a compile-time function from Schema to Schema. Each plugin takes the output of the previous one, transforms its types, and produces a new schema. Plugins compose by chaining:

```d
alias MySchema = PaginationPlugin!(SortingPlugin!(FilterPlugin!(Schema!(Query, Mutation))));
```

**Key invariant: each plugin only sees the output of the previous plugin.** SortingPlugin never sees `User` — it sees `FilteredUser`. There is no mechanism to "look back" at original types. Entity types are discovered from the Query's field return types, and each plugin wraps the types it finds.

All types are treated uniformly — Query, Mutation, User, Post are all types with fields. The only distinction for Query/Mutation is that they are singletons (one instance per request), and this difference is encapsulated at the boundary rather than threaded through the plugin system.

**Why this design?**

1. **Composability** - Plugins are independent. Adding or removing a plugin doesn't require changes to other plugins. The order of composition determines the order of transformation.

2. **Simplicity** - Each plugin only needs to understand one input (the previous schema's output) and produce one output (the transformed schema). No coordination between plugins.

3. **Extensibility** - New plugins can add arbitrary capabilities (filtering, sorting, pagination, normalization, access control) without modifying existing code. The plugin interface is just: expose `Query`, `Mutation`, and `Config`.

## Example

```d
import dynamo.core;
import dynamo.relational;
import dynamo.graphql;

// Data source - static variable bound to entities via DemoEntity mixin
// Options: MockDB (testing), PostgresDB, SQLiteDB, MySQLDB
static MockDB!() db;

// Entity definitions with mixins
// DemoEntity is a convenience wrapper that adds an `id` column automatically.
// For full control, use the low-level Entity + Col + PrimaryKey mixins.
struct User {
    mixin DemoEntity!(db, "users");

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
    static auto fullName(Expr!User u) => u.firstName ~ " " ~ u.lastName;

    // Computed field with arguments - arguments are concrete values at planning time
    @GqlDescription("A personalized greeting")
    static auto greeting(Expr!User u, string prefix, string suffix = "!") {
        return constant(prefix, u) ~ " " ~ u.firstName ~ constant(suffix, u);
    }

    // Computed field with struct argument - generates input type automatically
    static auto formattedName(Expr!User u, FormatOptions options) {
        return options.prefix ~ u.firstName;
    }

    // Plain field - eagerly populated when entity is fetched
    // Use for small, frequently-accessed data that doesn't need SQL optimization
    Nullable!string nickname;

    // Plain method - instance method operating on fetched data
    // Evaluated in D, not pushed to SQL
    string displayName() => nickname.isNull ? "Anonymous" : nickname.get;
}

// Input types - regular D structs used as computed field arguments
struct FormatOptions {
    string prefix;                           // Required: String!
    Nullable!string suffix;                  // Optional (absent = null): String
    Nullable!(Nullable!bool) uppercase;      // Three-state (absent/null/value): Boolean
}

struct Post {
    mixin DemoEntity!(db, "posts");
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
    mixin DemoEntity!(db, "comments");

    @GqlName("body")
    mixin Col!("body_", string, "body");

    @GqlHidden mixin Col!("postId", ForeignKey!Post);
    @GqlHidden mixin Col!("authorId", ForeignKey!User);

    mixin BelongsTo!("post", "postId");
    mixin BelongsTo!("author", "authorId");
}

// Schema definition - the Query type defines root entry points
// Table mixin takes: Entity, fieldName (db is derived from Entity)
struct Query {
    mixin Table!(User, "users");
    mixin Table!(Post, "posts");
}

// Usage - initialize db and query from root
db = new MockDB!();  // Assign the static db variable
auto executor = new Executor();

// Query: { posts { title, author { fullName } } }
// Uses property-like syntax: p.title, p.author.fullName
auto query = map!(
    (Expr!Post p) => jsonObject(
        "title", p.title,
        "author", p.author.fullName
    )
)(Query.posts());  // Entry point from Query root (db bound via Entity)

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
    (Expr!User user) => jsonObject(
        "firstName", user.firstName,
        "posts", map!(
            (Expr!Post post) => jsonObject(
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

### Plain Fields vs Col Mixins

Dynamo offers two ways to define fields on entities:

**Col mixins** (lazy, SQL-optimized):
```d
mixin Col!("firstName", string);  // Returns Expr!string, optimized into SQL
```

**Plain fields** (eager, in-memory):
```d
Nullable!string nickname;  // Populated when entity is fetched
```

**When to use each:**

| Use Case | Approach |
|----------|----------|
| Large columns (BLOBs, long text) | `Col` - only fetched when selected |
| Columns used in SQL expressions | `Col` - enables pushdown |
| Small, frequently-accessed data | Plain field - simpler access |
| Data that doesn't need SQL optimization | Plain field |

Plain fields are:
- Automatically included in DDL generation (column name derived from field name via snake_case, or override with `@SqlColumn`)
- Populated when the entity is fetched from the database
- Exposed in the GraphQL schema
- Accessible directly (return `T`, not `Expr!T`)

```d
struct User {
    mixin DemoEntity!(db, "users");
    mixin Col!("firstName", string);     // Lazy: u.firstName returns Expr!string

    Nullable!string nickname;             // Eager: populated on fetch
    @SqlColumn("display_name") string displayName;  // Custom column name
}
```

### Plain Methods

Plain methods are instance methods that operate on populated entity data. Unlike computed fields (static methods taking `Expr!Entity`), plain methods work with concrete values and are evaluated in D at runtime.

```d
struct User {
    mixin DemoEntity!(db, "users");
    mixin Col!("firstName", string);
    Nullable!string nickname;  // Plain field

    // Plain method - operates on populated entity data
    string displayName() {
        return nickname.isNull ? "Anonymous" : nickname.get;
    }

    // Plain method - boolean helper
    bool hasNickname() => !nickname.isNull;

    // Plain method returning POD struct
    UserStats stats() => UserStats(posts.length, comments.length);

    // Computed field - uses Expr, can be optimized to SQL
    static auto fullName(Expr!User u) => u.firstName ~ " " ~ u.lastName;
}

// POD struct returned by plain method - automatically discovered for schema
struct UserStats {
    int postCount;
    int commentCount;

    // Plain methods work on POD structs too
    int totalActivity() => postCount + commentCount;
}
```

**When to use each:**

| Use Case | Approach |
|----------|----------|
| Logic that can be expressed in SQL | Computed field (`static auto fn(Expr!T)`) |
| Complex D logic on fetched data | Plain method |
| Simple derived values from plain fields | Plain method |
| Returning structured data (POD structs) | Plain method |
| Expressions involving multiple columns | Computed field (SQL optimization) |

Plain methods are:
- Automatically exposed in the GraphQL schema
- Evaluated after entity data is fetched from the database
- Not optimized into SQL (run in D)
- Can return POD structs (automatically discovered for schema generation)
- Support UDAs: `@GqlHidden`, `@GqlName`, `@GqlDescription`, `@GqlDeprecated`

### POD Types

Plain Old Data (POD) types are regular D structs without the `Entity` mixin. They can be used as return types from plain methods or as plain field types, and are automatically discovered and included in the GraphQL schema.

```d
// POD struct - no Entity mixin, no database table
struct UserStats {
    int postCount;
    int commentCount;

    // Plain methods work on POD structs
    int totalActivity() => postCount + commentCount;
    bool isActive() => totalActivity() > 10;
}

struct User {
    mixin DemoEntity!(db, "users");

    // Plain method returning POD struct
    UserStats stats() => UserStats(42, 99);
}
```

Generates GraphQL schema:

```graphql
type User {
  stats: UserStats!
}

type UserStats {
  postCount: Int!
  commentCount: Int!
  totalActivity: Int!
  isActive: Boolean!
}
```

POD types are:
- Automatically discovered through plain method return types and plain field types
- Included in GraphQL schema generation (as object types, not input types)
- NOT included in DDL generation (they don't represent database tables)
- Can have their own plain fields and plain methods
- Can be nested (POD containing POD)

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
static auto formattedName(Expr!User u, FormatOptions options) { ... }
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

### Runtime Query Compilation

Use `compileQuery` to compile GraphQL query strings at runtime:

```d
import dynamo.graphql : compileQuery;

db = new MockDB!();  // Initialize the static db
auto executor = new Executor();

// Simple query (db derived from Query → Entity → static db variable)
auto query = compileQuery!Query(`{
    users {
        firstName
        posts { title }
    }
}`);

auto result = executor.execute(query);
// Returns: {"users": [{"firstName": "Alice", "posts": [...]}, ...]}
```

**With variables:**

```d
// Define variables as JSONValue
auto variables = JSONValue([
    "greeting": JSONValue("Hello"),
    "format": JSONValue([
        "prefix": JSONValue("Dr. "),
        "suffix": JSONValue(", PhD")
    ])
]);

auto query = compileQuery!Query(`
    query GetUsers($greeting: String!, $format: FormatOptions!) {
        users {
            greeting(prefix: $greeting)
            formattedName(format: $format)
        }
    }
`, variables);

auto result = executor.execute(query);
```

**Multiple root fields:**

```d
auto query = compileQuery!Query(`{
    users { firstName }
    posts { title }
}`);

auto result = executor.execute(query);
// Returns: {"users": [...], "posts": [...]}
```

### Filtering

Use the `FilterPlugin` to add filtering support to your schema. Filter types are auto-generated for each entity:

```d
import dynamo.graphql.filtering : FilterPlugin;

// Wrap your schema with FilterPlugin to add filter arguments
alias MySchema = FilterPlugin!(Schema!(Query, Mutation));

auto query = compileQuery!MySchema(`{
    users(filter: {firstName: {equalTo: "Alice"}}) {
        firstName
        age
    }
}`);
```

**Available filter operators:**

| Type | Operators |
|------|-----------|
| String | `equalTo`, `notEqualTo`, `in`, `notIn`, `isNull`, `contains`, `startsWith`, `endsWith`, `containsInsensitive`, `startsWithInsensitive`, `endsWithInsensitive` |
| Int/Float | `equalTo`, `notEqualTo`, `in`, `notIn`, `isNull`, `lessThan`, `lessThanOrEqualTo`, `greaterThan`, `greaterThanOrEqualTo` |
| Boolean | `equalTo`, `notEqualTo`, `isNull` |
| Enum | `equalTo`, `notEqualTo`, `in`, `notIn`, `isNull` |

**Case-insensitive string matching:**

```graphql
# Find users with "ali" anywhere in firstName (matches "Alice", "Alicia", etc.)
users(filter: {firstName: {containsInsensitive: "ali"}}) { ... }

# Find users whose firstName starts with "a" (matches "Alice", "adam", etc.)
users(filter: {firstName: {startsWithInsensitive: "a"}}) { ... }

# Find users whose firstName ends with "CE" (matches "Alice", "Bruce", etc.)
users(filter: {firstName: {endsWithInsensitive: "CE"}}) { ... }
```

PostgreSQL uses native `ILIKE` for case-insensitive matching; MySQL and SQLite use `LOWER()` wrappers.

**Logical combinators:**

```graphql
# AND (implicit - multiple fields)
users(filter: {firstName: {startsWith: "A"}, age: {greaterThan: 18}}) { ... }

# OR (explicit array)
users(filter: {or: [{firstName: {equalTo: "Alice"}}, {firstName: {equalTo: "Bob"}}]}) { ... }

# NOT
users(filter: {not: {firstName: {equalTo: "Alice"}}}) { ... }

# Nested (AND, OR, NOT can be combined)
users(filter: {
    and: [
        {age: {greaterThan: 18}},
        {or: [{firstName: {startsWith: "A"}}, {firstName: {startsWith: "B"}}]}
    ]
}) { ... }
```

**Relationship filters:**

```graphql
# Users who have at least one post with "GraphQL" in the title
users(filter: {posts: {some: {title: {contains: "GraphQL"}}}}) { ... }

# Users where ALL posts have "Draft" in the title
users(filter: {posts: {every: {title: {contains: "Draft"}}}}) { ... }

# Users with NO posts containing "Spam"
users(filter: {posts: {none: {title: {contains: "Spam"}}}}) { ... }
```

### Introspection

Runtime introspection is built in. The standard `__schema`, `__type`, and `__typename` meta-fields work out of the box:

```graphql
# Type name on any object
{ users { __typename firstName } }
# Returns: {"users": [{"__typename": "User", "firstName": "Alice"}, ...]}

# Schema introspection
{
  __schema {
    queryType { name }
    types { name kind }
  }
}

# Type lookup
{
  __type(name: "User") {
    name
    kind
    fields {
      name
      type { name kind ofType { name } }
    }
  }
}
```

Introspection respects `@GqlHidden` (hidden fields are excluded), `@GqlDeprecated` (fields include `isDeprecated` and `deprecationReason`), and the `includeDeprecated` argument on `fields` and `enumValues`.

## Current Status

**Working:**
- Expression tree with batched evaluation (`Expr!T`)
- `use()` combinator for per-element computation
- Operator overloading (`~`, `==`, etc.)
- Entity definition mixins (`Entity`, `Col`, `BelongsTo`, `HasMany`)
- Plain fields (struct instance fields) as alternative to `Col` mixins for eager fetching
- Plain methods (instance methods) for D-side computed values on fetched entities
- POD types (plain D structs) discovered through plain method return types and plain field types
- Custom `Expr!T` nodes returning POD structs work in map/collection contexts
- `Table` mixin for Query root entry points
- `ForeignKey!Entity` type for type-safe FK columns
- `@GqlHidden` UDA to hide fields from GraphQL schema
- `@GqlName` UDA to override GraphQL field names (for D keyword conflicts)
- `@GqlDescription` UDA to add field descriptions (rendered as doc comments in SDL)
- `@GqlDeprecated` UDA to mark fields as deprecated (rendered with `@deprecated` directive)
- QueryNode-based SQL planning
- JOINs for belongsTo relationships
- Child queries (CTEs) for hasMany relationships
- Computed fields with SQL push-down (dialect-aware: `||` for PostgreSQL/SQLite, `CONCAT()` for MySQL)
- Computed fields in GraphQL schema (static functions taking `Expr!Entity`)
- Field arguments for computed fields (with defaults, introspected from D function signatures)
- Input types auto-generated from struct arguments (with `Nullable!(Nullable!T)` for three-state fields)
- Data-source agnostic Executor
- MockDB for testing (in-memory data)
- DebugSqlDB for SQL inspection (wraps another fetcher, prints generated SQL)
- PostgresDB using `ae.net.db.psql`
- SQLiteDB using `ae.sys.sqlite3`
- MySQLDB using `ae.net.db.mysql`
- GraphQL schema generation (`generateSchemaSDL!Query`)
- SQL DDL generation (`generateDDL!Query`)
- GraphQL query compilation (`compileQuery`) with:
  - Multiple root fields
  - Field arguments (scalars and input objects)
  - Variables (scalars and input objects)
- Mutations with `CrudMutations` mixin (INSERT/UPDATE/DELETE)
- `Schema!(Query, Mutation)` template for bundling query and mutation types
- Filtering with `FilterPlugin`:
  - Auto-generated filter types for each entity
  - String operators: `equalTo`, `contains`, `startsWith`, `endsWith` (and case-insensitive variants)
  - Numeric operators: `lessThan`, `greaterThan`, `equalTo`, `in`, etc.
  - Logical combinators: `and`, `or`, `not`
  - Relationship filters: `some`, `every`, `none`
- Sorting with `SortingPlugin`:
  - `orderBy` argument with `asc`/`desc` direction
  - Nested sorting for HasMany relationships
- Pagination with `PaginationPlugin`:
  - `first`/`after` cursor-based pagination
- Runtime introspection (`__schema`, `__type`, `__typename`)

## Future Directions

- **Polymorphism** - GraphQL union and interface types for heterogeneous collections
- **Expression deduplication** - Grafast-style peer analysis
- **Plan caching** - Reuse optimized plans for repeated queries
- **Error path tracking** - Track field paths through nested selections for precise error reporting (e.g., `["users", 0, "posts", 2, "title"]`)
- **Field override plugin layer** - Runtime mechanism to intercept and override any field resolution, enabling feature flags, A/B testing, gradual rollouts, or per-deployment customization without recompilation

## Related Work

- [graphqld](https://github.com/burner/graphqld) - GraphQL library for D using traditional resolver-based approach
- [Grafast](https://grafast.org/) (PostGraphile) - Similar "steps" concept for batched execution
- [Haxl](https://github.com/facebook/Haxl) - Haskell library for implicit batching
- [DataLoader](https://github.com/graphql/dataloader) - Per-request batching and caching

## Development

### Running Tests

```bash
# Full test suite (requires Nix)
nix flake check
```

This is the primary way to run tests. It runs:
- Unit tests
- PostgreSQL integration tests (spins up a real PostgreSQL instance)
- SQLite integration tests (uses in-memory database)
- MySQL integration tests (spins up a MariaDB instance)

Each integration test creates tables via DDL generation, seeds data via mutations,
starts an HTTP server, and runs GraphQL queries to verify end-to-end functionality.

**Quick iteration** (unit tests only, faster but incomplete):

```bash
dub test              # Unit tests only
dub test -d=sql       # With SQL debug output
dub test -d=graphql   # Show generated GraphQL schema
dub test -d=ddl       # Show generated SQL DDL
```
