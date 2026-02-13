# Architecture

## Package Dependencies

```
    ┌──────────┐  ┌──────────┐  ┌──────────┐
    │ postgres │  │  sqlite  │  │  mysql   │
    └────┬─────┘  └────┬─────┘  └────┬─────┘
         │             │             │
         └─────────────┼─────────────┘
                       │
                       ▼
  ┌─────────┐   ┌──────────────┐  ┌──────────┐
  │ graphql │   │  relational  │  │  schema  │
  └────┬────┘   └──────┬───────┘  └─────┬────┘
       │               │                │
       └───────────────┼────────────────┘
                       │
                       ▼
                  ┌──────────┐
                  │   core   │
                  └──────────┘
```

The three middle-tier packages (graphql, schema, relational) depend only on core and are completely isolated from each other. DB-specific packages (postgres, sqlite, mysql) depend on relational for shared SQL generation and query planning.

The Executor is data-source agnostic. Data sources travel with expressions — root expressions (like `getByIds!User`) carry their DataFetcher. The executor walks the expression tree to collect optimizers needed for each data source.

The schema layer defines a typed API that can be consumed by any presentation format. GraphQL is one such format; business logic within the application can also query the schema directly using D's type system.

## Data Flow

```
                       REQUEST            RESPONSE
                       ───────            ────────

                     HTTP request      HTTP response
                          │                  ▲
                  server  │                  │  server
                          ▼                  │
                    GraphQL query +    JSON response
                    JSON variables        string
                          │                  ▲
              lex, parse  │                  │  serialize
                          ▼                  │
                   AST + JSONValue       JSONValue
                        trees               tree
                          │                  ▲
    compile, deserialize  │                  │  assemble
    inputs                ▼                  │  result tree
                      Expr tree          evaluated
                       (naive)            values
                          │                  ▲
                optimize  │                  │  evaluate
                          ▼                  │
                     Expr tree           row data
                 (optimized) + SQL      from fetcher
                          │                  ▲
         execute queries  │    ┌──────────┐  │  parse rows
                          └───▶│ Database │──┘
                               └──────────┘
```

## Approach

The core library is built around expression trees (`Expr!T`) that are data-source agnostic. Different data sources can implement their own optimization strategies.

### Two-Phase Execution

For relational databases, the library uses a two-phase approach:

**Phase 1: Optimization** — Walk the expression tree and:
- Collect QueryNodes (one per MapExpr scope)
- Track columns needed from each table
- Build JOINs for belongsTo relationships
- Create child QueryNodes for hasMany relationships

**Phase 2: Evaluation** — Execute prefetch queries (CTE-based SQL for all layers), evaluate expressions against fetched data, and assemble the response.

### Optimizer-Visible vs Dynamic Relationships

For **optimal performance**, relationships should be expressed using the built-in mixins (`BelongsTo`, `HasMany`, `Col` with `ForeignKey`) so the optimizer can recognize them:
- Recognized relationships → JOINs and CTEs
- Prefetch all possible dependencies, discard unused ones
- O(fields) database round-trips, not O(objects)

However, **dynamic fetching is always possible**. Custom `Expr` implementations can perform arbitrary async operations (the API uses Promises). This is useful for:
- ML-based recommendations returning computed IDs
- External service lookups
- Complex business logic that can't be expressed as optimizer-visible patterns

The trade-off: dynamic fetches don't benefit from the batch optimization and may reintroduce N+1 patterns for that specific field.

## Design Principles

### 1. Entities as Lightweight Proxies

Entity structs hold only the minimal state needed to identify an object — typically just an ID:

```d
@Entity!(db, "users")
struct User {
    @PrimaryKey long id;             // Just an ID — no column data stored

    mixin Col!("firstName", string);  // No data stored here — just generates accessor
    mixin Col!("lastName", string);
}
```

The struct itself stores no column data. Instead, it acts as a **proxy** for the database row:

- `user.firstName` doesn't read from memory — it returns an `Expr!string` that represents "the firstName column for this user"
- The actual data lives in the database until explicitly fetched

**Why this design?**

1. **Efficiency** — Only requested columns are fetched. If a query doesn't select `email`, that column is never read from the database. This matters when some columns are large (BLOBs, long text) or expensive to compute (view-backed tables with complex aggregations).

2. **Vectorization** — Operations happen on all objects at once, not one at a time. Traditional resolver-based systems call `fullName(user)` for each user sequentially. Here, `u.firstName ~ " " ~ u.lastName` becomes a single SQL expression evaluated for all users in one query.

3. **Compile-time safety** — Field access returns `Expr!T`, not `T`. This means typos like `user.fristName` fail at compile time, and the type system ensures expressions compose correctly.

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

Users can also define plain fields and plain methods as a convenience for data that doesn't need SQL optimization (see [USAGE.md](USAGE.md)). These are normalized into the canonical static Expr method form before plugin processing, so the plugin system only ever sees one kind of field.

**Why this design?**

1. **Uniform representation** — The optimizer and plugins can analyze and transform field access patterns regardless of whether the data comes from a database column, a JOIN, or in-memory computation. All fields look the same to the expression tree, and plugins only need to handle one field kind.

2. **SQL pushdown** — Because fields return expressions (not values), the optimizer can compose them into SQL. `u.firstName ~ " " ~ u.lastName` isn't computed in D — it becomes `first_name || ' ' || last_name` in the SQL query itself.

3. **Compile-time validation** — Return types are checked at compile time. If `fullName` returns `Expr!int` but you try to concatenate it with a string, the compiler catches it immediately. Traditional resolver-based systems return `Json` and defer type errors to runtime.

### 3. Schema Protocol

After normalization (`Schema!()` or `NormalizePlugin`), all fields are computed fields — static methods taking `Expr!T` as first parameter and returning an `Expr` type. The **Schema Protocol** is the compile-time interface that all post-normalization consumers use to discover and interact with schema types.

Instead of ad-hoc `__traits(allMembers)` loops, consumers use two templates from `core/discovery.d`:

```d
// Enumerate all public computed field names on a normalized type
getSchemaFields!T        // → enum string[] (e.g., ["id", "firstName", "posts"])

// Get the D result type of a field (unwraps Expr!U → U)
fieldResultType!(T, "firstName")  // → string
```

All code that needs to iterate over a type's fields uses this protocol:

- **GraphQL compiler** (`selection.d`) — `compileFieldAccess`, `compileRootField`, `resolveNonNullFlags`
- **Query validator** (`validation.d`) — `validateFieldAccess`, `validateRootField`
- **SDL generator** (`fields.d`) — `getFields!T`
- **Introspection** (`introspection.d`) — `getRuntimeFields!T`

**Precondition**: Types must have been through normalization. `compileQuery` enforces this via `static assert(isSchema!SchemaType)`. Raw entity types (pre-normalization) may have plain fields and plain methods that the protocol does not see — use `isPlainField`/`isPlainMethod` for pre-normalization code like `NormalizePlugin`.

### 4. Data Source Binding via Static Alias

Entity types bind to their data source through a compile-time alias to a static/module-level variable:

```d
static PostgresDB db;  // or MockDB, SQLiteDB, MySQLDB

@Entity!(db, "users")  // Binds User to db at compile time
struct User {
    @PrimaryKey long id;
    // ...
}
```

**Why this design?**

1. **Multiple data sources** — A single schema can span multiple databases or backends. Users from PostgreSQL, analytics from ClickHouse, cache from Redis — each entity declares its source, and the executor coordinates them:
   ```d
   static PostgresDB mainDb;
   static ClickHouseDB analyticsDb;

   @Entity!(mainDb, "users") struct User { @PrimaryKey long id; }
   @Entity!(analyticsDb, "page_views") struct PageView { @PrimaryKey long id; }
   ```

2. **Compile-time dialect selection** — The optimizer knows at compile time which SQL dialect to use. PostgreSQL gets `||` for concatenation, MySQL gets `CONCAT()`. No runtime dialect switching needed.

3. **Type-safe query generation** — The binding is checked at compile time. If you reference a non-existent data source or mismatched types, compilation fails.

### 5. Extensible Optimizer via Pattern Matching

The optimizer uses interface-based pattern matching to recognize and transform expression types:

- `ColumnAccessInfo` — Column reads that can be batched into SELECT
- `BelongsToInfo` — Many-to-one relationships that become JOINs
- `HasManyInfo` — One-to-many relationships that become child CTEs
- `BinaryOpInfo` — Operations that can be pushed down to SQL

Different data sources register their own optimizers. The relational package contributes `RelationalOptimizer` and `SqlOptimizer`; future packages (e.g., REST APIs, in-memory stores) can add their own without modifying core.

To list all pattern-matching interfaces in the codebase:

```bash
grep -rn 'interface.*Info' source/dunamis/ --include='*.d' | grep -v unittest
```

### 6. Plugins as Composable Type Transformers

A plugin is a compile-time function from Schema to Schema. Each plugin takes the output of the previous one, transforms its types, and produces a new schema. Plugins compose by chaining:

```d
alias MySchema = ApplyPlugins!(Schema!(Query, Mutation), FilterPlugin, SortingPlugin, PaginationPlugin);
```

**Key invariant: each plugin only sees the output of the previous plugin.** SortingPlugin never sees `User` — it sees `FilteredUser`. There is no mechanism to "look back" at original types. Entity types are discovered from the Query's field return types, and each plugin wraps the types it finds.

All types are treated uniformly — Query, Mutation, User, Post are all types with fields. The only distinction for Query/Mutation is that they are singletons (one instance per request), and this difference is encapsulated at the boundary rather than threaded through the plugin system.

Plugins are part of the schema layer, not the presentation layer. They operate on D types and standard visibility — they have no knowledge of GraphQL or any other presentation format (see [Principle 7](#7-schema-independence-from-presentation)).

**Why this design?**

1. **Composability** — Plugins are independent. Adding or removing a plugin doesn't require changes to other plugins. The order of composition determines the order of transformation.

2. **Simplicity** — Each plugin only needs to understand one input (the previous schema's output) and produce one output (the transformed schema). No coordination between plugins.

3. **Extensibility** — New plugins can add arbitrary capabilities (filtering, sorting, pagination, normalization, access control) without modifying existing code. The plugin interface is just: expose `Query`, `Mutation`, and `Config`.

### 7. Schema Independence from Presentation

The schema and plugin system define a **typed API** that is independent of any presentation format. `Schema!(Query, Mutation)` normalizes entity types and applies plugins using only D type structure and visibility — no knowledge of GraphQL or any other protocol.

```d
// Schema + plugins = typed API (presentation-agnostic)
alias MySchema = ApplyPlugins!(Schema!(Query, Mutation), FilterPlugin, SortingPlugin, PaginationPlugin);

// GraphQL is ONE way to consume the API
auto gqlQuery = compileQuery!MySchema(`{ users { firstName } }`);

// Direct D calls are ANOTHER way — no parsing, same optimization
auto directQuery = map!((Expr!User u) => u.firstName)(MySchema.Query.users());

// Both produce the same expression tree, same SQL, same results
auto result = executor.execute(directQuery);
```

Presentation-specific concerns live exclusively in their respective layers:

- `@GqlHidden` hides a field from the GraphQL schema but not from programmatic access
- `@GqlName` renames a field in GraphQL but the D name is canonical everywhere else
- `@GqlDescription`, `@GqlDeprecated` add metadata consumed only by GraphQL SDL generation and introspection

**Why this design?**

1. **Multiple consumers** — Business logic within the application can query the graph directly using D's type system, without constructing GraphQL strings. The same schema serves both external API clients (via GraphQL) and internal application code (via direct D calls).

2. **Clean plugin boundaries** — Plugins decide which fields to process based on D visibility (`public`, `package`, etc.), not presentation-layer annotations. A `package`-scoped field is invisible to plugins; a `@GqlHidden` field is visible to plugins but hidden from GraphQL output. These are different concerns with different semantics.

3. **Extensibility** — New presentation layers (REST, gRPC, CLI tools) can be added by writing a new consumer of the schema types, without modifying the schema or any plugins.

### 8. Namespace Isolation

User-defined types (`struct User`, `struct Post`) should contain only declarations meaningful to the user. Library internals must not pollute the user's namespace with auto-generated symbols that could clash with user-declared fields.

**Mechanisms** (in order of preference):

1. **UDAs for metadata** — Carry metadata on existing declarations without adding new names. UDAs from `dunamis.core` or `dunamis.relational` are fully qualified and cannot clash with user-defined UDAs.

   ```d
   @Entity!(db, "users")           // UDA on the struct — no members added
   struct User {
       @PrimaryKey long id;        // UDA on the field — no extra members
       mixin Col!("email", string); // Generates one method `email` + @SqlColumn UDA
   }
   ```

2. **Package visibility for internal state** — When library infrastructure must store runtime state in a struct field (data that can't be expressed as a UDA), use `package` visibility to hide it from all external consumers:

   ```d
   package(dunamis.schema) SourceType _normalizedSource;
   ```

   This field is invisible to `isPlainField`, `getSchemaFields`, and all schema discovery, but accessible to the plugin infrastructure within the `dunamis.schema` package.

3. **Code templates over mixin templates** — Generate method bodies as strings (code templates) rather than using mixin templates. String-based code generation produces only the intended symbols; mixin templates leak their local aliases, enums, and helper functions into the host struct's `__traits(allMembers)`.

   ```d
   // Preferred: code template (zero leak)
   template SortedArrayFieldCode(...) {
       enum SortedArrayFieldCode = "static auto fieldName(...) { ... }";
   }
   mixin template SortedArrayField(...) {
       mixin(SortedArrayFieldCode!(...));  // Only fieldName appears in allMembers
   }

   // Avoid: direct mixin template (leaks helpers)
   mixin template BadField(...) {
       alias _Internal = ...;                // Leaks into __traits(allMembers)
       private static auto _helper() { ... } // Also leaks
       static auto fieldName(...) { ... }
   }
   ```

4. **Visibility checks over naming conventions** — Use `__traits(getVisibility)` to filter internal members, not name-based heuristics like `member[0] != '_'`. Visibility is a language-level guarantee; naming conventions can be violated by user code that legitimately uses `_`-prefixed field names.

**What user-facing mixins inject:**

Each mixin produces exactly one user-visible symbol (the field name the user chose) with all metadata expressed as UDAs:

| Mixin | Injected symbol | UDAs |
|---|---|---|
| `Col!("name", T)` | `name` (static method) | `@SqlColumn`, `@ForeignKeyRef` |
| `HasMany!("posts", Post, "fk")` | `posts` (static method) | `@HasManyFK`, `@HasManyChild` |
| `BelongsTo!("author", "fkField")` | `author` (static method) | `@BelongsToFK`, `@BelongsToParent` |
| `Table!(Entity, "users")` | `users` (static method) | `@TableEntity` |
| `DemoId` | `id` (field) | `@PrimaryKey`, `@AutoIncrement`, `@SqlColumn` |

**What the plugin chain adds internally:**

Plugin wrappers add `_normalizedSource` (package-scoped, invisible to schema discovery) and may generate private helper methods or types prefixed with `_`. These are filtered out by the Schema Protocol (`getSchemaFields`) and by `isPlainField`/`isPlainMethod`, so they never appear in the GraphQL schema or affect user-visible type structure.

**Known limitation:** `FilteredArrayField` in the filtering plugin uses a mixin template (not a code template) due to an LDC compiler limitation with eager alias resolution of `alias TypeMap`. The filter type generation (`_FilterTypesFor`, `_ShallowFilterFor`) has been moved to module-level templates to eliminate most leakage, but the mixin template still leaks a few type aliases (`_SrcParams`, `_SrcDefaults`, `_SrcEntity`, `_ElementType`, `_FilterType`) and a private `_applyFilter` method into `__traits(allMembers)`. These are benign — they are not schema fields — but they are visible to compile-time introspection. If LDC resolves the eager evaluation issue in the future, this can be fully converted to a code template.
