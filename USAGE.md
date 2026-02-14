# Usage Guide

## Full Example

This example shows a complete schema with all major features. Individual sections below explain each feature in detail.

```d
import dunamis.core;
import dunamis.relational;
import dunamis.graphql;

// Data source — static variable bound to entities via @Entity UDA
// Options: MockDB (testing), PostgresDB, SQLiteDB, MySQLDB
static MockDB!() db;

// Entity definitions with UDA + mixins
// @DemoEntity binds an entity to its data source and table.
// DemoId adds a standard `id` primary key column (Int64).
// For full control, use @Entity + explicit @PrimaryKey fields.
@DemoEntity!(db, "users")
struct User {
    mixin DemoId;

    @GqlDescription("The user's first name")
    mixin Col!("firstName", string);

    @GqlDescription("The user's last name")
    mixin Col!("lastName", string);

    @GqlDescription("Primary email address")
    @GqlDeprecated("Use the emails field instead")
    mixin Col!("email", string);

    mixin HasMany!("posts", Post, "author_id");
    mixin HasMany!("comments", Comment, "author_id");

    // Computed field — uses property-like access via opDispatch
    static auto fullName(Expr!User u) => u.firstName ~ " " ~ u.lastName;

    // Computed field with arguments — arguments are concrete values at planning time
    @GqlDescription("A personalized greeting")
    static auto greeting(Expr!User u, string prefix, string suffix = "!") {
        return constant(prefix, u) ~ " " ~ u.firstName ~ constant(suffix, u);
    }

    // Computed field with struct argument — generates input type automatically
    static auto formattedName(Expr!User u, FormatOptions options) {
        return options.prefix ~ u.firstName;
    }

    // Plain field — eagerly populated when entity is fetched
    // Use for small, frequently-accessed data that doesn't need SQL optimization
    Nullable!string nickname;

    // Plain method — instance method operating on fetched data
    // Evaluated in D, not pushed to SQL
    string displayName() => nickname.isNull ? "Anonymous" : nickname.get;
}

// Input types — regular D structs used as computed field arguments
struct FormatOptions {
    string prefix;                           // Required: String!
    Nullable!string suffix;                  // Optional (absent = null): String
    Nullable!(Nullable!bool) uppercase;      // Three-state (absent/null/value): Boolean
}

@DemoEntity!(db, "posts")
struct Post {
    mixin DemoId;
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

@DemoEntity!(db, "comments")
struct Comment {
    mixin DemoId;

    @GqlName("body")
    mixin Col!("body_", string, "body");

    @GqlHidden mixin Col!("postId", ForeignKey!Post);
    @GqlHidden mixin Col!("authorId", ForeignKey!User);

    mixin BelongsTo!("post", "postId");
    mixin BelongsTo!("author", "authorId");
}

// Schema definition — the Query type defines root entry points
// Table mixin takes: Entity, fieldName (db is derived from Entity)
struct Query {
    mixin Table!(User, "users");
    mixin Table!(Post, "posts");
}
```

## Relationships

### BelongsTo (Many-to-One)

Use `ForeignKey!Entity` for the FK column and `BelongsTo` for the relationship. Mark the FK column `@GqlHidden` to expose only the relationship in the schema:

```d
@DemoEntity!(db, "posts")
struct Post {
    mixin DemoId;
    mixin Col!("title", string);

    @GqlHidden  // Hide FK column from GraphQL, expose only the relationship
    mixin Col!("authorId", ForeignKey!User);
    mixin BelongsTo!("author", "authorId");
}
```

BelongsTo relationships are optimized into JOINs:

```d
auto query = map!(
    (Expr!Post p) => jsonObject(
        "title", p.title,
        "author", p.author.fullName
    )
)(Query.posts());
```

```sql
SELECT posts.id, posts.title, j0.first_name, j0.last_name
FROM posts
LEFT JOIN users AS j0 ON posts.author_id = j0.id
```

For nullable FKs:

```d
mixin Col!("editorId", Nullable!(ForeignKey!User));  // Nullable FK column
mixin BelongsTo!("editor", "editorId");              // Automatically nullable
```

**`@GqlName` for D keyword conflicts:**

When a column name conflicts with a D keyword, use a different D name and map it:

```d
@GqlName("body")  // Exposed as "body" in GraphQL
mixin Col!("body_", string, "body");  // D name: body_, SQL column: body
```

### HasMany (One-to-Many)

```d
@DemoEntity!(db, "users")
struct User {
    mixin DemoId;
    mixin Col!("firstName", string);
    mixin HasMany!("posts", Post, "author_id");
}
```

Nested HasMany relationships generate CTE-based SQL:

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
)(Query.users());
```

```sql
WITH layer0 AS (
    SELECT users.id, users.first_name FROM users
),
layer1 AS (
    SELECT posts.id, posts.title, posts.author_id
    FROM posts WHERE posts.author_id IN (SELECT id FROM layer0)
)
SELECT * FROM layer0;
SELECT * FROM layer1;
```

## Plain Fields vs Col Mixins

Dunamis offers two ways to define fields on entities:

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
| Large columns (BLOBs, long text) | `Col` — only fetched when selected |
| Columns used in SQL expressions | `Col` — enables pushdown |
| Small, frequently-accessed data | Plain field — simpler access |
| Data that doesn't need SQL optimization | Plain field |

Plain fields are:
- Automatically included in DDL generation (column name derived from field name via snake_case, or override with `@SqlColumn`)
- Populated when the entity is fetched from the database
- Exposed in the schema (and in GraphQL, unless marked `@GqlHidden`)
- Accessible directly (return `T`, not `Expr!T`)

```d
@DemoEntity!(db, "users")
struct User {
    mixin DemoId;
    mixin Col!("firstName", string);     // Lazy: u.firstName returns Expr!string

    Nullable!string nickname;             // Eager: populated on fetch
    @SqlColumn("display_name") string displayName;  // Custom column name
}
```

## Plain Methods

Plain methods are instance methods that operate on populated entity data. Unlike computed fields (static methods taking `Expr!Entity`), plain methods work with concrete values and are evaluated in D at runtime.

```d
@DemoEntity!(db, "users")
struct User {
    mixin DemoId;
    mixin Col!("firstName", string);
    Nullable!string nickname;

    // Plain method — operates on populated entity data
    string displayName() {
        return nickname.isNull ? "Anonymous" : nickname.get;
    }

    // Plain method — boolean helper
    bool hasNickname() => !nickname.isNull;

    // Plain method returning POD struct
    UserStats stats() => UserStats(posts.length, comments.length);

    // Computed field — uses Expr, can be optimized to SQL
    static auto fullName(Expr!User u) => u.firstName ~ " " ~ u.lastName;
}

// POD struct returned by plain method — automatically discovered for schema
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
- Automatically exposed in the schema (and in GraphQL, unless marked `@GqlHidden`)
- Evaluated after entity data is fetched from the database
- Not optimized into SQL (run in D)
- Can return POD structs (automatically discovered for schema generation)
- Support presentation UDAs: `@GqlHidden`, `@GqlName`, `@GqlDescription`, `@GqlDeprecated`

## POD Types

Plain Old Data (POD) types are regular D structs without the `Entity` mixin. They can be used as return types from plain methods or as plain field types, and are automatically discovered and included in the GraphQL schema.

```d
struct UserStats {
    int postCount;
    int commentCount;

    int totalActivity() => postCount + commentCount;
    bool isActive() => totalActivity() > 10;
}

@DemoEntity!(db, "users")
struct User {
    mixin DemoId;
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
- Included in schema generation (as object types, not input types)
- NOT included in DDL generation (they don't represent database tables)
- Can have their own plain fields and plain methods
- Can be nested (POD containing POD)

## Input Types

Struct arguments to computed fields are automatically discovered and generated as GraphQL input types:

```d
struct FormatOptions {
    string prefix;                           // Required field
    Nullable!string suffix;                  // Optional (absent = null)
    Nullable!(Nullable!bool) uppercase;      // Three-state: absent/null/value
}

// Used in computed field
static auto formattedName(Expr!User u, FormatOptions options) {
    return options.prefix ~ u.firstName;
}
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

This distinction is semantic (handled in your resolver logic), not schema-level — GraphQL represents both `Nullable!T` and `Nullable!(Nullable!T)` as nullable types.

## Union & Interface Types

Union and interface types allow a single field to return objects of different entity types. Use `@ImplementedBy` to declare which concrete types belong to the abstract type, and `unionOf!` to build the expression.

### Unions

A union has no fields of its own — clients use typed fragments to access member-specific fields:

```d
import dunamis.core.types : ImplementedBy, Implements;
import dunamis.core.expr.combinators : unionOf;

// Declare a union: SearchResult = User | Post
@ImplementedBy!(User, Post)
struct SearchResult {}

struct Query {
    mixin Table!(User, "users");
    mixin Table!(Post, "posts");

    // Return all users and posts as a union
    static auto search(Expr!Query q) {
        return unionOf!SearchResult(users(q), posts(q));
    }
}
```

Generates GraphQL schema:

```graphql
union SearchResult = User | Post

type Query {
  search: [SearchResult!]!
}
```

Query with typed fragments:

```graphql
{
  search {
    __typename
    ... on User { firstName lastName }
    ... on Post { title }
  }
}
```

Returns:

```json
{
  "search": [
    {"__typename": "User", "firstName": "Alice", "lastName": "Smith"},
    {"__typename": "User", "firstName": "Bob", "lastName": "Jones"},
    {"__typename": "Post", "title": "Hello World"}
  ]
}
```

### Interfaces

An interface declares shared fields using `AbstractField`. Concrete types must have matching fields (enforced by the schema):

```d
import dunamis.core.types : ImplementedBy, AbstractField;

// Declare an interface with a shared "id" field
@ImplementedBy!(User, Post)
struct ContentNode {
    mixin AbstractField!("id", long);
}

struct Query {
    mixin Table!(User, "users");
    mixin Table!(Post, "posts");

    static auto contentNodes(Expr!Query q) {
        return unionOf!ContentNode(users(q), posts(q));
    }
}
```

Generates GraphQL schema:

```graphql
interface ContentNode {
  id: Int!
}

type User implements ContentNode {
  id: Int!
  firstName: String!
  ...
}

type Post implements ContentNode {
  id: Int!
  title: String!
  ...
}

type Query {
  contentNodes: [ContentNode!]!
}
```

Query — shared fields are accessible directly, member-specific fields via fragments:

```graphql
{
  contentNodes {
    __typename
    id
    ... on User { firstName }
    ... on Post { title }
  }
}
```

### Named Fragments

Both unions and interfaces support named fragments:

```graphql
query {
  search {
    __typename
    ...UserFields
    ...PostFields
  }
}
fragment UserFields on User {
  firstName
  fullName
}
fragment PostFields on Post {
  title
  author { firstName }
}
```

### Declaring Membership

There are two ways to declare which concrete types belong to an abstract type:

**`@ImplementedBy` on the abstract type** — lists all members centrally:

```d
@ImplementedBy!(User, Post)
struct SearchResult {}
```

**`@Implements` on the concrete type** — each member declares itself:

```d
@Implements!SearchResult
struct Comment {
    // ...
}
```

Both can be combined. `@ImplementedBy` provides the base member list, and `@Implements` adds additional members. This is useful when you want to extend a union or interface without modifying its definition:

```d
// Core schema defines the union with two members
@ImplementedBy!(User, Post)
struct SearchResult {}

// A separate module adds Comment to the union
@Implements!SearchResult
struct Comment { ... }

// At runtime, SearchResult = User | Post | Comment
```

A concrete type can implement multiple abstract types:

```d
@Implements!(SearchResult, ContentNode)
struct Article { ... }
```

### Union vs Interface

| | Union | Interface |
|---|---|---|
| Declaration | `@ImplementedBy!(A, B) struct U {}` | `@ImplementedBy!(A, B) struct I { mixin AbstractField!(...); }` |
| Shared fields | None | Declared via `AbstractField` |
| Bare field access | Only `__typename` | `__typename` + shared fields |
| GraphQL SDL | `union U = A \| B` | `interface I { ... }` + `type A implements I { ... }` |
| GraphQL kind | `UNION` | `INTERFACE` |

The distinction is automatic: if the abstract type has schema fields (`AbstractField` mixins), it's an interface; otherwise it's a union.

### Plugin Compatibility

Union and interface types work with all plugins (`FilterPlugin`, `SortingPlugin`, `PaginationPlugin`). Plugins wrap abstract types through the schema chain automatically — the `@ImplementedBy` UDA is remapped to reference the plugin-wrapped member types.

## Schema & DDL Generation

Generate GraphQL schema and SQL DDL at compile time:

```d
// Generate GraphQL schema from D types
pragma(msg, generateSchemaSDL!(Schema!Query));
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

## Runtime Query Compilation

Use `compileQuery` to compile GraphQL query strings at runtime:

```d
import dunamis.graphql : compileQuery;

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
```

**Multiple root fields:**

```d
auto query = compileQuery!Query(`{
    users { firstName }
    posts { title }
}`);
// Returns: {"users": [...], "posts": [...]}
```

## Filtering

Use the `FilterPlugin` to add filtering support to your schema. Filter types are auto-generated for each entity:

```d
import dunamis.graphql.filtering : FilterPlugin;

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

PostgreSQL uses native `ILIKE`; MySQL and SQLite use `LOWER()` wrappers.

**Logical combinators:**

```graphql
# AND (implicit — multiple fields)
users(filter: {firstName: {startsWith: "A"}, age: {greaterThan: 18}}) { ... }

# OR
users(filter: {or: [{firstName: {equalTo: "Alice"}}, {firstName: {equalTo: "Bob"}}]}) { ... }

# NOT
users(filter: {not: {firstName: {equalTo: "Alice"}}}) { ... }

# Nested
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

## Introspection

Runtime introspection is built in. The standard `__schema`, `__type`, and `__typename` meta-fields work out of the box:

```graphql
{ users { __typename firstName } }
# Returns: {"users": [{"__typename": "User", "firstName": "Alice"}, ...]}

{
  __schema {
    queryType { name }
    types { name kind }
  }
}

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

## Cross-Collection Access

Computed fields can access unrelated tables — tables with no declared relationship to the current entity. Use `singleton()` to reach root entry points, and `broadcast()` to replicate global data across the current batch:

```d
@Entity!(db, "holidays")
struct Holiday {
    @PrimaryKey long id;
    mixin Col!("name", string);
    mixin Col!("date", string);
}

@Entity!(db, "users")
struct User {
    @PrimaryKey long id;
    mixin Col!("firstName", string);

    // Access the holidays table — no relationship needed
    static auto availability(Expr!User u) {
        return use(
            (string firstName, Holiday[] allHolidays) {
                return firstName ~ " has " ~ allHolidays.length.to!string ~ " holidays";
            },
            u.firstName,
            Query().singleton().holidays().broadcast(u)
        );
    }
}
```

**How it works:**

1. `Query().singleton()` creates an `Expr!Query` — the same expression type used at the schema root
2. `.holidays()` calls `Query.holidays(q)` via `opDispatch`, returning the holidays collection
3. `.broadcast(u)` replicates the single result for each user in the batch, aligning batch dimensions for `use()`
4. The optimizer handles the holidays expression inside `use()` — it evaluates as a separate query

**Why `broadcast()` is needed:**

The `use()` combinator expects all inputs to have the same batch size. When evaluating users, `u.firstName` produces one result per user (batch size N). But the holidays collection produces one result total (batch size 1). `broadcast()` bridges this gap by replicating the single result N times — analogous to how `constant()` replicates a literal value.

**Extracting data at the expression level:**

```d
static auto availability(Expr!User u) {
    auto holidayNames = Query().singleton().holidays()
        .map!((Expr!Holiday h) => h.name);

    return use(
        (string firstName, string[] names) {
            return firstName ~ ": " ~ names.join(", ");
        },
        u.firstName,
        holidayNames.broadcast(u)
    );
}
```

**Pre- vs post-processed schema access:**

```d
// Raw schema — entities as declared, no plugin wrapping
Query().singleton().holidays()

// Plugin-processed schema — with filtering, sorting, pagination wrappers
alias FinalSchema = ApplyPlugins!(Schema!(Query, Mutation), FilterPlugin, SortingPlugin, PaginationPlugin);
FinalSchema.Query().singleton().holidays()
```

For most computed fields, raw schema access is appropriate — you want all data from the global table, not a filtered/paginated subset.

## Request Context

Computed fields can access request-scoped data like the authenticated user, tenant ID, or locale. Define a context struct, pass it via `EvalContext`, and read it with `context!T()`:

```d
// Define request context structs
struct AuthCtx { string userId; bool isAdmin; }
struct TenantCtx { string tenantId; string locale; }

@Entity!(db, "users")
struct User {
    @PrimaryKey long id;
    mixin Col!("firstName", string);

    // Computed field using request context
    static auto localizedGreeting(Expr!User u) {
        return use(
            (string firstName, TenantCtx tenant) =>
                tenant.locale == "fr" ? "Bonjour " ~ firstName : "Hello " ~ firstName,
            u.firstName,
            context!TenantCtx(u)
        );
    }

    // Multiple context types in one field
    static auto canEdit(Expr!Post p) {
        return use(
            (long authorId, AuthCtx auth) =>
                authorId.to!string == auth.userId || auth.isAdmin,
            p.authorId,
            context!AuthCtx(p)
        );
    }
}
```

**Passing context at execution time:**

```d
auto executor = new Executor();
auto query = compileQuery!Query(`{ users { localizedGreeting } }`);

// Create EvalContext and set request-scoped values
auto ctx = new EvalContext();
ctx.setRequestContext(AuthCtx("user-1", false));
ctx.setRequestContext(TenantCtx("tenant-abc", "fr"));

// Pass EvalContext to execute
auto result = executor.execute(query, ctx);
// Returns: {"users": [{"localizedGreeting": "Bonjour Alice"}, ...]}

// Without context (existing API unchanged)
auto result2 = executor.execute(query);  // Uses new EvalContext() internally
```

**Key properties:**

- **Structs only** — context values are value types (natural copy semantics)
- **Multiple types** — call `setRequestContext` once per type; retrieve with `context!T(expr)`
- **Assert on missing** — forgetting to set a context type produces a clear error message
- **No SQL pushdown** — context values are runtime data, correctly opaque to the optimizer
- **No schema impact** — context fields appear in the schema like any computed field, but the context dependency is invisible to introspection

## Field Overrides

`FieldOverridePlugin` enables runtime field overrides without recompilation — useful for feature flags, A/B testing, gradual rollouts, or per-deployment customization. Override delegates receive the batch of default values and can transform or replace them.

**Setup:**

```d
// 1. Apply plugin (typically last, after Filter/Sort/Pagination)
alias FinalSchema = ApplyPlugins!(Schema!(Query, Mutation),
    FilterPlugin, SortingPlugin, PaginationPlugin,
    FieldOverridePlugin,
);

// 2. Register overrides (once per deployment/config change)
auto overrides = new FieldOverrides();

// Type-safe: validates field exists and return type matches at compile time
overrides.set!(User, "greeting")(
    delegate string[](string[] defaults, EvalContext ctx) {
        return defaults.map!(d => d ~ " (beta)").array;
    }
);

// String-based: for Query/Mutation fields or dynamic registration
overrides.set!string("Query", "version_",
    delegate string[](string[] defaults, EvalContext ctx) => ["2.0"]
);
```

**Per-request execution:**

```d
auto query = compileQuery!FinalSchema(`{ users { greeting } }`);

auto ctx = new EvalContext();
ctx.setRequestContext(FieldOverrideConfig(overrides));
auto result = executor.execute(query, ctx);
```

**Feature flag pattern** — combine with request context:

```d
struct FeatureFlags { bool betaGreeting; }

overrides.set!(User, "greeting")(
    delegate string[](string[] defaults, EvalContext ctx) {
        if (ctx.getRequestContext!FeatureFlags().betaGreeting)
            return defaults.map!(d => d ~ " [BETA]").array;
        return defaults;
    }
);

// Per request: set both contexts
auto ctx = new EvalContext();
ctx.setRequestContext(FeatureFlags(true));
ctx.setRequestContext(FieldOverrideConfig(overrides));
auto result = executor.execute(query, ctx);
```

**Key properties:**

- **Typed delegates** — overrides receive `T[]` (batch of default values) and return `T[]`, matching the field's actual return type
- **Transparent to optimizer** — `OverrideExpr` is invisible to SQL optimization; columns, JOINs, and CTEs work as if no overrides exist
- **Schema-preserving** — GraphQL SDL is unchanged; overrides only affect runtime behavior
- **Composable** — works with all other plugins (filtering, sorting, pagination) applied before it
- **Optional** — without `FieldOverrideConfig` in EvalContext, all fields pass through unchanged with zero overhead

## Query Validation

`compileQuery` runs a validation phase before compilation that checks all structural rules and reports **all** errors at once (not just the first one). If validation fails, a `ValidationException` is thrown carrying the full error list with source locations.

```d
try {
    auto query = compileQuery!MySchema(`{ users { nonExistent } }`);
} catch (ValidationException e) {
    // e.errors contains all validation errors
    foreach (err; e.errors) {
        writeln(err.message);       // "Unknown field 'nonExistent' on type User"
        writeln(err.line, ":", err.column);  // source location
        writeln(err.toJson());      // {"message": "...", "locations": [{"line": ..., "column": ...}]}
    }
}
```

`ValidationException` extends `CompilerException`, so existing `catch (CompilerException)` blocks continue to work.

**Checks performed:**

- **Duplicate operation names** — multiple operations with the same name
- **Duplicate fragment names** — multiple fragments with the same name
- **Undefined variables** — `$var` used in query but not declared in operation signature
- **Unused variables** — `$var` declared but never referenced (including in fragments and directives)
- **Unknown fields** — field not found on the target type (Query, Mutation, or entity)
- **Unknown arguments** — argument not accepted by the computed field
- **Missing required arguments** — non-optional, non-nullable argument not provided
- **Duplicate arguments** — same argument name provided twice
- **Selection set on scalar** — `{ subfields }` on a field that returns a scalar type
- **Missing selection set on object** — no `{ subfields }` on a field that returns an object or array of objects

## Error Handling

Field-level errors produce partial results instead of failing the entire request. When a field expression throws during evaluation, the field is set to `null` and the error is recorded with its path in the response:

```json
{
  "data": {
    "users": [
      {"firstName": "Alice", "riskyField": null},
      {"firstName": "Bob", "riskyField": null}
    ]
  },
  "errors": [
    {"message": "computation failed", "path": ["users", "riskyField"]}
  ]
}
```

Errors are collected on `EvalContext` during evaluation. The server includes both `data` and `errors` in the response when errors are present (HTTP status 200, per the GraphQL spec). Errors from query compilation or data source failures still produce full error responses with no data.

**Key properties:**

- **Field-level granularity** — each field in a selection set is independently error-caught; one field's failure doesn't affect siblings
- **Path tracking** — error paths trace through nested selections (e.g., `["users", "posts", "title"]`)
- **Transparent** — no changes needed to entity definitions or computed fields; error catching is automatic
- **Sequential mutations** — mutation fields also catch errors independently and continue to the next field

### Per-Element Errors with GqlResult

For computed fields that can fail independently per element in a batch, use `GqlResult!T`:

```d
static auto riskyField(Expr!User u) {
    return use(
        (string name) => name.length > 0
            ? GqlResult!string.ok(name)
            : GqlResult!string.err("empty name"),
        u.firstName,
    );
}
```

`GqlResult!T` propagates errors through D operators automatically — if any operand is an error, the result is an error:

```d
// If riskyField errors, the concatenation result is also an error
static auto decorated(Expr!User u) {
    return u.riskyField ~ "!";  // Expr!(GqlResult!string) ~ string → Expr!(GqlResult!string)
}
```

Use `tryUse` to automatically catch exceptions per-element and wrap them in `GqlResult`:

```d
static auto parsed(Expr!User u) {
    return tryUse(
        (string s) => s.to!int,  // throws for unparseable strings
        u.rawValue,
    );
    // Returns Expr!(GqlResult!int) — failed elements get GqlResult.err(exception.msg)
}
```

#### Auto-Materialization in GraphQL

The GraphQL compiler automatically detects fields returning `GqlResult!T` and inserts
`materializeResult()` with proper error paths and array index sources. No manual wiring
is needed — just return `GqlResult!T` from your computed field:

```d
@Entity!(db, "users")
struct User {
    mixin DemoId;
    mixin Col!("firstName", string);

    static auto validatedName(Expr!User u) {
        return tryUse(
            (string name) {
                if (name.length == 0) throw new Exception("empty name");
                return name;
            },
            u.firstName
        );
        // Returns Expr!(GqlResult!string)
        // GraphQL schema shows: validatedName: String!  (inner type's nullability)
        // Errors get paths like ["users", 0, "validatedName"]
    }
}
```

`GqlResult!T` uses the inner type's nullability in the GraphQL schema:
- `GqlResult!string` → `String!` (non-null, same as plain `string`)
- `GqlResult!(Nullable!string)` → `String` (nullable)

When a non-null `GqlResult` field errors, null bubbling applies: the error is recorded,
the field becomes null, and the entire parent object becomes null (per the GraphQL spec).
Use `GqlResult!(Nullable!T)` if you want errors to stay at the field level without bubbling.

#### Manual Materialization

For non-GraphQL usage (direct D expression trees), you can call `materializeResult()` explicitly:

```d
auto expr = materializeResult!string(someGqlResultExpr,
    [JSONValue("users"), JSONValue("name")]);
// Produces Expr!(Nullable!string) — errors become null + recorded in EvalContext
```

When used inside a `map!()` expression, `map!` automatically links the index source
so error paths include the element's array index:

```d
auto query = map!((Expr!User u) {
    auto result = tryUse((string name) => name.toUpper, u.firstName);
    return materializeResult!string(result,
        [JSONValue("users"), JSONValue("name")]);
})(users);
// If element 2 fails, error path is ["users", 2, "name"] (not ["users", "name"])
```
