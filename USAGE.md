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

The FK may also be a plain field, e.g. part of a composite primary key, carrying its column and target as UDAs:

```d
@DemoEntity!(db, "user_badges")
struct UserBadge {
    @PrimaryKey @SqlColumn("user_id") @ForeignKeyRef!User long userId;
    @PrimaryKey @SqlColumn("badge_name") string badgeName;
    mixin BelongsTo!("user", "userId");
}
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

Children are unordered unless the relationship names child columns to order each parent's children by. The FK may be part of the children's (composite) primary key:

```d
mixin HasMany!("badges", UserBadge, "user_id", ["badge_name"]);
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

This distinction is semantic (handled in your resolver logic), not schema-level — GraphQL represents both `Nullable!T` and `Nullable!(Nullable!T)` as nullable types. (An absent field is `Nullable!(Nullable!T).init`; an explicit `null` is a present `Nullable!T.init`.)

Lists of `Nullable!T` items are lists of nullable items (`Nullable!int[]` is `[Int]!`). A value which is not a list given for a list is a list of that one item (GraphQL input coercion).

**Defaults:** `@GqlDefault("<value literal>")` on an input field presents its default in the schema (SDL, introspection); the value is the field's D initializer, which an absent field keeps:

```d
struct Changes {
    @GqlDefault("[]") Change[] changes;   // changes: [Change!]! = []
}
```

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

**Optimize once, evaluate many times:**

Evaluation never modifies an optimized expression tree (per-evaluation state
lives in the `EvalContext` and the data sessions), so a tree can be optimized
once and then evaluated any number of times, also concurrently, each time
with a fresh `EvalContext`:

```d
auto optimized = executor.optimize(compileQuery!Query(`{ users { firstName } }`));
auto result1 = executor.execute(optimized, new EvalContext(), false);
auto result2 = executor.execute(optimized, new EvalContext(), false);
```

Note that argument values (including variables) are part of the compiled tree.

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
auto result = executor.execute(query);
```

**Available filter operators:**

| Type | Operators |
|------|-----------|
| String | `equalTo`, `notEqualTo`, `in`, `notIn`, `isNull`, `lessThan`, `lessThanOrEqualTo`, `greaterThan`, `greaterThanOrEqualTo`, `contains`, `startsWith`, `endsWith`, `containsInsensitive` (alias `includesInsensitive`), `startsWithInsensitive`, `endsWithInsensitive`, `like` (SQL `LIKE` pattern: `%`, `_`, `\` escapes) |
| Int/Float | `equalTo`, `notEqualTo`, `in`, `notIn`, `isNull`, `lessThan`, `lessThanOrEqualTo`, `greaterThan`, `greaterThanOrEqualTo` |
| Boolean | `equalTo`, `notEqualTo`, `isNull` |
| Enum | `equalTo`, `notEqualTo`, `in`, `notIn`, `isNull` |

Nullable columns have the filter of their values' type. `isNull` tests for
null; the other operators only match non-null values (as SQL comparisons do),
so e.g. `notEqualTo` does not match null. Columns of custom scalar types are
filtered through `StringFilter`; operators that do not apply to a column's
type (e.g. `contains` on a date) are rejected.

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

Relationship filters take the related entity's own filter, so they nest to
any depth, also through cycles in the schema: each entity has one filter type
(`PostFilter`), which refers to the filters of related entities. A to-one
(belongs-to) relationship is filtered by its target's filter, and matches
nothing where the relationship is null; a to-many relationship is filtered by
`some`/`every`/`none` over the related entities' filter
(`PostFilterListFilter`). All object types are filtered alike, whatever their
data source: a field (taking no arguments) of a value object type, e.g. a
struct-valued column or an object computed in D, is filtered by that type's
filter as a relationship is.

```graphql
# Comments on posts by authors in the "R&D" department
comments(filter: {post: {author: {department: {name: {equalTo: "R&D"}}}}}) { ... }

# Orders with an item whose product's supplier is in a country
orders(filter: {items: {some: {product: {supplier: {country: {equalTo: "DE"}}}}}}) { ... }

# Users with a post commented on by Bob
users(filter: {posts: {some: {comments: {some: {author: {firstName: {equalTo: "Bob"}}}}}}}) { ... }
```

On root fields, relationship filters are pushed into SQL as subqueries
(`fk IN (SELECT pk FROM parent WHERE ...)` for to-one relationships, `EXISTS`
for `some` and its negations); filters which cannot be expressed in SQL (e.g.
over computed fields) are evaluated in memory.

**Filters declared by value types:** a value type with filter operators of
its own (e.g. a range type, with containment) declares its filter input type
with `@FilteredBy`; its fields are then filtered as columns, by that type. The
filter type's `condition` builds the condition its operators put on a value,
from the value type's fields as the filter plugin sees them:

```d
@FilteredBy!SpanFilter
struct Span { int from; int to; }

struct SpanFilter {
    Nullable!int contains;
    Nullable!bool isNull;  // optional; handled like that of the built-in filters

    Expr!bool condition(V)(Expr!V span, ExprBase lengthSource) const {
        if (contains.isNull) return null;  // puts no condition
        auto point = constant(contains.get, lengthSource);
        return V.from(span).le(point).and(point.lt(V.to(span)));
    }
}
```

A database storing such a type in a representation of its own (e.g. a
PostgreSQL range column, which arrives as text) is read with the decoder the
type declares with `@DecodedBy!decode` (`dunamis.relational.schema`), a
function from the column's JSON value to the type.

**Unknown filter fields:** like all input objects, filters must only contain
fields their type defines (in literals and in variables); anything else is a
validation error, reported with its location before the query is executed:

```json
{"errors": [{"message": "Field \"titel\" is not defined by type \"PostFilter\".",
             "locations": [{"line": 1, "column": 18}]}]}
```

**Filtering and pagination:** plugins apply their arguments in the order the
plugins were applied in: each plugin wraps the field as the previous plugins
left it. This is deliberate. Code building expression trees directly chooses
the order of operations itself; for the flat arguments of a GraphQL field,
the plugin order is that choice. With the documented order
(`FilterPlugin, SortingPlugin, PaginationPlugin`), a field's `filter`
selects the rows that are then sorted and its `first`/`offset` window is
taken from. With `PaginationPlugin` before `FilterPlugin`, the filter is
applied to the window instead.

On root fields, the filter, sort and window are pushed into the SQL query as far
as that preserves the order of operations: a filter that cannot be expressed in
SQL as a whole (e.g. a relationship filter) is evaluated in memory, its
SQL-expressible `AND` conditions still narrow the query (when no window is
beneath the filter), and a window above it is then applied in memory too.

**Filters and sorts evaluated in memory** (those of nested fields, and those
not pushed into SQL) are evaluated in batches, as a map's body is: a
`filterBy` predicate once for all the items of all the lists it filters, a
`sortBy` comparison once for all the pairs of items of each list (or, for
lists with more than `SortByExpr.maxBatchedComparisons` pairs, one comparison
at a time). The values a predicate reads are fetched with the rows of the
collection it applies to: its columns (and those of rows reached through
`BelongsTo`) are columns of that collection's query. So, as in a map's body,
a value in a predicate which is not derived from the item (e.g. read from a
root collection) must be aligned with the batch with `broadcast()`. A
predicate which refers to its item from within a scope of its own (e.g. a
nested filter's predicate comparing with it) is evaluated for one item (or
pair) at a time.

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

**Conditional collections:** `onlyIf(condition, collection)` is the collection where `condition` holds, else an empty list (for each item of the condition's batch); the collection is evaluated only if the condition holds for some item. Since it is all or none of the collection, a field's filter, sort and window apply to it as to the collection itself (for a root collection, they are pushed into its SQL query):

```d
struct Snapshot {
    bool visible;
    // All holidays, if the snapshot is visible
    static Expr!(Holiday[]) holidays(Expr!Snapshot s) {
        return onlyIf(fieldAccess!"visible"(s), Query().singleton().holidays());
    }
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

## Computed Fields from Free Functions

Computed fields do not have to be declared inside the entity struct. `ComputedFieldsPlugin` attaches free functions of the form `auto field(Expr!Entity e, args...)` to the schema type built from `Entity`, so fields can live in modules of their own (for example, one module per field) without the entity module importing them:

```d
module app.fields.post_titles;

import std.array : join;
import dunamis.core.expr : Expr, constant, map, use;
import dunamis.graphql.schema : GqlDescription;
import app.entities : User, Post;

/// Fields are public; helpers stay private and are not picked up.
@GqlDescription("Titles of the user's posts")
auto postTitles(Expr!User u, string separator = ", ") {
    return use((string[] titles, string sep) => titles.join(sep),
        map!((Expr!Post p) => p.title)(u.posts), constant(separator, u));
}
```

```d
alias FinalSchema = ApplyPlugins!(Schema!(Query, Mutation),
    ComputedFieldsPlugin!(app.fields.post_titles, app.fields.other),
    FilterPlugin, SortingPlugin, PaginationPlugin,
);
```

**Placement:** apply the plugin first, straight after `Schema!` (and after `CrudMutationPlugin`, if used: it leaves the entity types as `Schema!` made them, and casts the rows it writes to them directly). Like every plugin, it works with the types of the schema it is given (see ARCHITECTURE.md, Principle 6): straight after `Schema!`, those are the user-declared types as `Schema!` normalized them, so functions are written against the user-declared types. The plugins applied after it see computed fields like any other field:

- `FilterPlugin` offers filters on computed scalar fields without required arguments (`users(filter: {postCount: {greaterThan: 1}})`), and `SortingPlugin` orderings on the sortable ones (`users(orderBy: [{field: postCount, direction: DESC}])`). On root fields, a condition SQL can express (e.g. on a field that is a column, or a related row's column, `p.author.age`) is pushed into the SQL query, as is an ordering by a field that is a column of the row itself; any other condition or ordering is evaluated in memory, never skipped. On root fields the documented order of a field's arguments holds either way: the `first`/`offset` window is only pushed into SQL if everything beneath it was (see [Filtering and pagination](#filtering)).
- Array-returning computed fields take `filter`, `orderBy` and `first`/`offset` arguments like relationships do.

Placed after another plugin, `ComputedFieldsPlugin` only knows that plugin's types: functions must then be written against them (e.g. the element type of `ApplyPlugins!(Schema!Query, FilterPlugin).Query.users`), and their fields are not filterable or sortable by the plugins before it. A function written against a user-declared type then matches no type: there is no mechanism to reach beneath the previous plugin's types.

**How it works:**

- Sources are modules, function symbols and/or field sets. A module contributes every public function declared in it (not imported into it) whose first parameter is an `Expr`. A function symbol contributes all its overloads, so one field name can be declared for several types. A field set is a struct naming sources: it contributes the sources it has public aliases of (modules, functions, other field sets), in order, and the public static field functions it declares.
- The names of the types and functions the plugin (and every plugin after it) generates include the plugin's sources, so they grow with the number of sources (a function symbol adds its name and type), and with them the compiler's memory. With many sources, pass one field set naming them instead:

  ```d
  struct AppFields {
      alias postTitles = app.fields.post_titles;
      alias other = app.fields.other;
  }
  alias FinalSchema = ApplyPlugins!(Schema!(Query, Mutation),
      ComputedFieldsPlugin!AppFields, FilterPlugin, SortingPlugin, PaginationPlugin);
  ```
- A function is attached to the type of the given schema that it is written against, or that directly wraps the type it is written against (for the types `Schema!` produces, the user-declared type). Inside the function, `Entity` is seen exactly as declared (`u.posts` is `Expr!(Post[])`), and entity or POD results (`Expr!Post`, `Expr!(Post[])`, `Expr!(Nullable!DateRange)`, `Expr!(Nullable!(DateRange[]))` for a nullable list `[DateRange!]`, `Expr!(Nullable!Cell[])` for a list of nullable items `[Cell]!`, `Expr!(Nullable!Cell[][])` for a nested list `[[Cell]!]!`) are mapped to the schema's types likewise, including their own computed fields. Selection sets apply to the items of lists at any depth. (Lists of nullable items are not filtered by `FilterPlugin`.)
- Result types that only computed fields return (a POD, or an entity reached through a computed relation such as `hasMany!(Like, "post_id")(p)`) are added to the schema. Their members are mapped likewise, so an entity member of a POD (`struct Audit { User user; }`, constructed as `User(id)`) is selectable as the schema's `User`. Such types pass through the plugins applied after `ComputedFieldsPlugin`, like the schema's own types.
- The GraphQL field name is the function name; extra parameters become arguments (with defaults), and `@GqlName`, `@GqlDescription`, `@GqlDeprecated` on the function are honoured.
- Abstract types (unions and interfaces, with `@ImplementedBy`) declared in a source module (public), or aliased by a field set, are types of the schema even if no field returns them, written against the user-declared types like the functions: e.g. an interface whose field is a computed field of each of its members, which clients name in fragments. (A type with `@IncludesTypes!(Types...)` makes `Types` part of any schema it is part of; the plugin puts that on the query root.) In the selection of an object, a fragment whose type condition is an abstract type the object's type is a member of applies to it.

  ```d
  @ImplementedBy!(User, Post)
  struct Labelled { mixin AbstractField!("label", string); }
  auto label(Expr!User u) => u.name;
  auto label(Expr!Post p) => p.title;
  // { users { ...L } posts { ...L } } fragment L on Labelled { label }
  ```
- A function whose entity is not a type of the given schema (nor wrapped by one), or whose name collides with an existing field, is a compile error.

**Root fields:** the root types are types of the schema like any other, so functions written against the user-declared `Query` or `Mutation` become fields of the query or mutation root, with the same rules (arguments, results, plugins applied after the plugin):

```d
module app.fields.root;

/// A query field over other root fields (`Query.users(q)`, the field
/// functions of this module).
Expr!(Nullable!User) userNamed(Expr!Query q, string name) {
    return use(&findUser, map!userId(Query.users(q)), map!userName(Query.users(q)), constant(name, q));
}

/// A list root field: FilterPlugin, SortingPlugin and PaginationPlugin add
/// their arguments to it, as to `users`.
Expr!(User[]) usersExcept(Expr!Query q, string name) {
    return filterBy!((Expr!User u) => u.name.ne(name))(Query.users(q));
}

/// A mutation field. `effect` runs its callable when the field is evaluated.
Expr!RenamePayload rename(Expr!Mutation m, int userId, string name) {
    return effect(() => RenamePayload(db.rename(userId, name), User(userId)), m);
}

/// The query root, to read the state after the mutation (`mutation { ... query { users { name } } }`).
Expr!Query query(Expr!Mutation m) {
    return effect(() => Query.init, m);
}
```

**Procedures:** a mutation field doing more than one call (several statements, reads of its own writes) is best written as a procedure, run with `perform!fn(lengthSource, sources, args...)` (`dunamis.core.expr.effects`). `fn(EvalContext ctx, args)` runs once per request, when the field is evaluated, in a fiber of its own (`performSized` sets the stack size; the default is 1 MB), so it is written in direct style, awaiting promises (`ae.utils.promise.await.await`). `sources` are the data sources it uses: the executor sets up their sessions for the request, which the procedure gets with `ctx.getSession`. With `evaluateNested(expr, ctx)`, a procedure evaluates a typed expression (optimized as its own tree) on those sessions, so that it sees the procedure's writes. If the procedure throws, the field fails.

```d
Expr!AddPayload addUser(Expr!Mutation m, string name) {
    return perform!addUserProcedure(m, [cast(DataSource) db], name);
}

AddPayload addUserProcedure(EvalContext ctx, string name) @async {
    auto session = cast(PostgresSession) ctx.getSession(db);
    auto id = session.queryLongs("INSERT INTO users (name) VALUES (...) RETURNING id").await[0];
    auto count = evaluateNested(userCount(Query().singleton()), ctx).await;  // sees the new user
    return AddPayload(User(cast(int) id), count);
}
```

**Asynchronous batch functions:** a read-only field computed by code which awaits (for example, which evaluates expressions with `evaluateNested`) is written with `useAsync!fn(sources, input)`: it evaluates `input` (`Expr!A`), then runs `fn(EvalContext ctx, A[] items)`, which returns one result per item, once per batch (for a field, with the values of all the objects of the batch), in a fiber of its own (`useAsyncSized` sets the stack size), on the sessions of `sources`. Unlike a procedure, it runs for each evaluation. If it throws, the field fails for the whole batch; for errors of some items only, return `GqlResult!T` values (see [Per-Element Errors with GqlResult](#per-element-errors-with-gqlresult)).

```d
Expr!string badge(Expr!User u) {
    return useAsync!badgesOf([cast(DataSource) db], fieldAccess!"id"(u));
}

string[] badgesOf(EvalContext ctx, int[] ids) @async {
    auto count = evaluateNested(userCount(Query().singleton()), ctx).await;
    return ids.map!(id => id.to!string ~ "/" ~ count.to!string).array;
}
```

**Scoped sessions:** to evaluate expressions as of other database settings (for example, reading another version of versioned data whose views depend on configuration parameters), a procedure evaluates them in a scope of its context with sessions of its own: `ctx.createScope([db: session])` (`EvalContext.createScope(DataSession[DataSource])`) uses `session` for `db` in the scope and in its scopes, while the request's other evaluations keep the request's. `PostgresSession.withSettings(["app.version": "5"])` derives such a session from the request's: its statements are sent on the request's connection, in its transaction (so they see the request's writes, and the request's atomic sections cover them), each between one setting the parameters (`set_config(name, value, true)`) and one restoring the request's values, which the request sets with `PostgresSession.setSetting(name, value)` (`SET LOCAL`). The connection runs statements in the order they are sent, so the request's statements in flight at the same time are not affected.

```d
auto session = cast(PostgresSession) ctx.getSession(db);
auto asOfVersion = ctx.createScope([cast(DataSource) db: session.withSettings(["app.version": "5"])]);
auto oldCount = evaluateNested(userCount(Query().singleton()), asOfVersion).await;
```

**Atomic mutation fields:** each mutation field is an atomic section of the request's sessions (`DataSession.beginAtomic`/`endAtomic`; for PostgreSQL, a savepoint): if the field fails (it fails, or is null with errors recorded while it was evaluated, such as a failing non-null field of its value), its work is undone, and the request's other fields' work is kept.

Each request has one instance of each root type, from which root fields are evaluated; that is the only difference between root types and other types, and it is handled where the request is compiled (the GraphQL compiler), not by the plugins. Root fields return scalars, entities, nullable entities, lists or PODs (types only mutation fields return, such as `RenamePayload`, are part of the schema like those of any other field), with selection sets as for any field. Mutation fields are evaluated one after the other, in the order of the request; a failing nullable mutation field is null, with the error at its path, and the fields after it still run; a null (or failing) non-null mutation field makes the whole result null, as for query fields, and the fields after it are not evaluated. In GraphQL, the root types are named after their role (`Query`, `Mutation`, `Subscription`), whatever the D names of the user-declared types.

**Using filters, sorting and pagination inside a field:** a field function sees the schema at the plugin's position, beneath `FilterPlugin`, `SortingPlugin` and `PaginationPlugin`: `u.posts` takes no `filter` argument there. To use those facilities, go through the final schema explicitly, as for [cross-collection access](#cross-collection-access):

```d
alias FinalSchema = ApplyPlugins!(Schema!(Query, Mutation),
    ComputedFieldsPlugin!(app.fields), FilterPlugin, SortingPlugin, PaginationPlugin);

// in app.fields: the first two posts' titles, for every user
Expr!(string[]) firstPostTitles(Expr!User u) {
    auto posts = FinalSchema.Query.posts(FinalSchema.Query().singleton(), first: Nullable!int(2));
    return map!(p => p.title)(posts).broadcast(u);
}
```

Give such a function an explicit return type: `FinalSchema` is built from the function's signature, so the signature must not depend on `FinalSchema`.

Code written directly with `filterBy`, `sortBy`, `limit`/`offset` from `dunamis.core` works at any level.

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
- **Unknown input object fields** — a field an input object type (e.g. a filter) does not define, at any depth of an argument's value: in literals (reported at the field) and in variables' values (reported at the variable's use, with the field's path within the value, e.g. `Variable "$f" got invalid value at "author.posts.some"; Field "titel" is not defined by type "PostFilter".`). Variables the operation does not declare are ignored, as the GraphQL spec requires.
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
- **Sequential mutations** — mutation fields also catch errors independently and continue to the next field; a null in a non-null mutation field makes the whole result null (null bubbling, as for query fields), and the fields after it are not evaluated
- **Bugs fail too** — a D `Error` (a failed assertion, a range violation, ...) thrown during evaluation is logged to stderr and fails what it was evaluating like an `Exception` would, as an `EvaluationError` ("Internal error: ..."), rather than leaving the evaluation pending forever (`dunamis.core.errors` sets `ae.utils.promise.errorRejection` for the process)

The selection set of a nullable object is evaluated for the whole batch, with placeholders (`T.init`) for the null objects, whose results are then discarded. A required `BelongsTo` of a placeholder yields a placeholder parent; a missing parent of any other row is an error of the field.

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
The null keeps propagating up to the nearest nullable ancestor: through a list of
non-null objects (`[T!]`, i.e. `T[]`) to the list itself (and so on through nested lists of
non-null items, e.g. `[[T!]!]`), through non-null fields to their
parent objects, and from a non-null root field to the whole response `data`.
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

## Subscriptions

GraphQL subscriptions let clients receive real-time updates when data changes. Dunamis supports subscriptions through change events fired after mutations commit.

### Schema Definition

Add a `Subscription` type to your schema. Use `Schema!(Query, Mutation, Subscription)`:

```d
struct Subscription {}  // Empty — RdbmsSubscriptionPlugin auto-generates fields

alias FinalSchema = ApplyPlugins!(Schema!(Query, Mutation, Subscription),
    FilterPlugin, SortingPlugin, PaginationPlugin,
    RdbmsSubscriptionPlugin,  // Auto-generates subscription fields from entities
);
```

`RdbmsSubscriptionPlugin` generates a subscription field for each entity (e.g., `userCreated`, `postCreated`). The generated field returns the entity type's selection set, so clients can select exactly which fields to receive on each event.

### Detecting Subscription Operations

The operation type is embedded in the result expression, consistent with how queries use `DynamicJsonObjectExpr` (parallel) and mutations use `SequentialJsonObjectExpr` (sequential). Subscriptions wrap the result in `SubscriptionResultExpr`:

```d
import dunamis.core.expr.combinators : SubscriptionResultExpr;

auto query = compileQuery!FinalSchema(`
    subscription {
        userCreated { firstName lastName }
    }
`);

if (cast(SubscriptionResultExpr) query) {
    // This is a subscription — route to SubscriptionExecutor
}
```

### SubscriptionExecutor

`SubscriptionExecutor!T` optimizes the expression tree once, then re-evaluates it for each event:

```d
import dunamis.core.executor : SubscriptionExecutor;

auto query = compileQuery!FinalSchema(`subscription { userCreated { firstName } }`);
auto subExec = new SubscriptionExecutor!User(new Executor(), query);

// For each change event, construct the entity and evaluate:
auto result = subExec.execute(someUser);  // Returns Promise!JSONValue

// Or evaluate in a context of your own (e.g. with request contexts set):
auto ctx = new EvalContext();
ctx.setRequestContext(AuthCtx("user-1"));
auto result2 = subExec.execute(someUser, ctx);
```

Deliveries may be evaluated concurrently.

### SubscriptionManager

`SubscriptionManager` dispatches change events to registered subscriptions by table name:

```d
import dunamis.core.executor : SubscriptionManager;

auto mgr = new SubscriptionManager();

// Register a persistent subscription
auto id = mgr.subscribe("users", handler, onResult, onError);

// Wire event dispatch on each mutation's session
session.setEventListener(mgr.eventListener());

// Remove when done
mgr.unsubscribe(id);
```

For one-shot delivery (e.g., HTTP long-poll), use `subscribeOnce` which auto-removes after the first event.

### createSubscriptionHandler

`createSubscriptionHandler` eliminates the boilerplate of constructing entities from change events:

```d
import dunamis.relational.subscription : createSubscriptionHandler;

auto query = compileQuery!FinalSchema(`subscription { userCreated { firstName } }`);
auto subExec = new SubscriptionExecutor!User(new Executor(), query);
auto reg = createSubscriptionHandler(subExec);
// reg.tableName == "users", reg.handler converts ChangeEvent → entity → Promise!JSONValue

mgr.subscribeOnce(reg, onResult, onError);
```

### Event Flow

1. Client sends a subscription query
2. Server compiles it, creates a `SubscriptionExecutor`, registers with `SubscriptionManager`
3. A mutation executes and commits
4. The data source fires a `ChangeEvent` post-commit
5. `SubscriptionManager.dispatch()` routes the event to matching subscriptions
6. The subscription handler constructs the entity from the event and evaluates the query
7. The result is sent to the client
