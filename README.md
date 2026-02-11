# Dunamis

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
4. **Optimizer-visible relationships** - Object relations as optimizable expression trees
5. **SQL optimization** - Expression pushdown and automatic JOINs for declared relationships

See [ARCHITECTURE.md](ARCHITECTURE.md) for more details.

## Example

```d
import dunamis.core;
import dunamis.relational;
import dunamis.graphql;

static MockDB!() db;  // or PostgresDB, SQLiteDB, MySQLDB

@DemoEntity!(db, "users")
struct User {
    mixin DemoId;
    mixin Col!("firstName", string);
    mixin Col!("lastName", string);
    mixin HasMany!("posts", Post, "author_id");

    // Computed field — pushed down to SQL
    static auto fullName(Expr!User u) => u.firstName ~ " " ~ u.lastName;
}

@DemoEntity!(db, "posts")
struct Post {
    mixin DemoId;
    mixin Col!("title", string);
    @GqlHidden mixin Col!("authorId", ForeignKey!User);
    mixin BelongsTo!("author", "authorId");
}

struct Query {
    mixin Table!(User, "users");
    mixin Table!(Post, "posts");
}

db = new MockDB!();
auto executor = new Executor();

auto query = map!(
    (Expr!Post p) => jsonObject(
        "title", p.title,
        "author", p.author.fullName
    )
)(Query.posts());

auto result = executor.execute(query);
```

Generates a single SQL query with JOINs:

```sql
SELECT posts.id, posts.title, j0.first_name, j0.last_name
FROM posts
LEFT JOIN users AS j0 ON posts.author_id = j0.id
```

To add plugins and run GraphQL queries:

```d
alias FinalSchema = ApplyPlugins!(Schema!(Query, Mutation),
    FilterPlugin, SortingPlugin, PaginationPlugin,
);

auto query = compileQuery!FinalSchema(`{
    users(filter: {firstName: {equalTo: "Alice"}}, orderBy: {firstName: asc}, first: 10) {
        firstName
        posts { title }
    }
}`);
auto result = executor.execute(query);
```

See [USAGE.md](USAGE.md) for a more complete example and detailed feature guide.

## Related Work

- [graphqld](https://github.com/burner/graphqld) — GraphQL library for D using traditional resolver-based approach
- [Grafast](https://grafast.org/) (PostGraphile) — Similar "steps" concept for batched execution
- [Haxl](https://github.com/facebook/Haxl) — Haskell library for implicit batching
- [DataLoader](https://github.com/graphql/dataloader) — Per-request batching and caching

## Development

See [HACKING.md](HACKING.md) for development instructions.
