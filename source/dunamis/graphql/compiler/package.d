module dunamis.graphql.compiler;

public import dunamis.graphql.compiler.values;
public import dunamis.graphql.compiler.fields;
public import dunamis.graphql.compiler.selection;
public import dunamis.graphql.compiler.validation;

import std.json;

import graphql.ast : OperationTypeEnum;
import graphql.lexer;
import graphql.parser;

import dunamis.core.expr : Expr;
import dunamis.graphql.schema;

// ============================================================================
// Query Compiler
// ============================================================================

/// Result type for compiled GraphQL queries.
/// A GraphQL query evaluates to a single JSON object containing all root fields.
alias GraphQLResult = Expr!JSONValue;

/// Compiles a GraphQL query string into an executable Expr tree.
///
/// The compiler operates on normalized schema types where all fields are
/// computed fields (static methods taking Expr!T). This guarantees a uniform
/// field representation — see the Schema Protocol in core/discovery.d.
///
/// Requires a Schema type created with Schema!(Query), Schema!(Query, Mutation),
/// or Schema!(Query, Mutation, Subscription). The Schema template applies
/// NormalizePlugin, which converts plain fields and methods into the canonical
/// computed field form.
///
/// Example:
/// ---
/// alias MySchema = Schema!(Query);
/// auto query = compileQuery!MySchema(`{ users { firstName } }`);
///
/// // With plugins:
/// alias MySchema = ApplyPlugins!(Schema!(Query, Mutation),
///     FilterPlugin, SortingPlugin, PaginationPlugin);
/// auto query = compileQuery!MySchema(`{ users(first: 10) { firstName } }`);
/// ---
GraphQLResult compileQuery(alias SchemaType)(string queryString)
    if (isSchema!SchemaType)
{
    return compileQuery!SchemaType(queryString, JSONValue.emptyObject);
}

/// Compiles a GraphQL query string with variables into an executable Expr tree.
GraphQLResult compileQuery(alias SchemaType)(string queryString, JSONValue variables)
    if (isSchema!SchemaType)
{
    alias QueryType = SchemaType.Query;
    alias MutationType = SchemaType.Mutation;
    alias SubscriptionType = SchemaType.Subscription;

    // Parse the GraphQL query
    auto lexer = Lexer(queryString);
    auto parser = Parser(lexer);
    auto doc = parser.parseDocument();

    // Find the operation
    auto op = findOperation(doc);
    if (op is null || op.ss is null) {
        throw new CompilerException("No operation found in query");
    }

    // Collect fragment definitions
    auto fragments = collectFragments(doc);

    // Validation phase — collect all errors before compilation
    auto validationErrors = validateQuery!SchemaType(doc, op, fragments);
    if (validationErrors.length > 0) {
        throw new ValidationException(validationErrors);
    }

    // Determine operation type (default to Query for shorthand syntax)
    bool isMutation = op.ot !is null && op.ot.ruleSelection == OperationTypeEnum.Mutation;
    bool isSubscription = op.ot !is null && op.ot.ruleSelection == OperationTypeEnum.Sub;

    // Compile based on operation type
    if (isSubscription) {
        static if (getFields!SubscriptionType.length > 0) {
            return compileRootSubscriptionSet!(SubscriptionType, SchemaType)(op.ss, variables, fragments);
        } else {
            throw new CompilerException("Subscription operations require a Schema with Subscription type");
        }
    } else if (isMutation) {
        static if (getFields!MutationType.length > 0) {
            return compileRootMutationSet!MutationType(op.ss, variables, fragments);
        } else {
            throw new CompilerException("Mutation operations require a Schema with Mutation type");
        }
    } else {
        return compileRootSelectionSet!(QueryType, SchemaType)(op.ss, variables, fragments);
    }
}

/// Convenience helper for unit tests: wraps a raw Query type in Schema
/// to satisfy the normalization requirement without extra boilerplate.
package(dunamis.graphql) GraphQLResult compileTestQuery(Query)(string queryString) {
    return compileQuery!(Schema!(Query))(queryString);
}

/// ditto
package(dunamis.graphql) GraphQLResult compileTestQuery(Query)(string queryString, JSONValue variables) {
    return compileQuery!(Schema!(Query))(queryString, variables);
}

// ============================================================================
// Tests
// ============================================================================

unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dunamis.core;
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import dunamis.relational.eval_context;

    // Static data source instance - bound by alias in Entity mixin
    static MockDB!() db;

    // Define test entities
    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("firstName", string);
        mixin Col!("lastName", string);

        static auto fullName(Expr!User u) {
            return firstName(u) ~ " " ~ lastName(u);
        }
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    // Set up mock data
    db = new MockDB!();
    db.setTableData("users", `[
        {"id": 1, "first_name": "Alice", "last_name": "Smith"},
        {"id": 2, "first_name": "Bob", "last_name": "Jones"}
    ]`);

    // Compile a simple query - no db parameter needed
    auto query = compileTestQuery!Query(`{ users { firstName, lastName } }`);

    // Execute
    auto executor = new Executor();
    auto result = awaitSync(executor.execute(query));

    // Verify results (executor returns JSONValue with root fields)
    auto users = result["users"].array;
    assert(users.length == 2);
    assert(users[0]["firstName"].str == "Alice");
    assert(users[0]["lastName"].str == "Smith");
    assert(users[1]["firstName"].str == "Bob");
    assert(users[1]["lastName"].str == "Jones");
}

unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dunamis.core;
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import dunamis.relational.eval_context;

    static MockDB!() db;

    // Test computed fields
    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("firstName", string);
        mixin Col!("lastName", string);

        static auto fullName(Expr!User u) {
            return firstName(u) ~ " " ~ lastName(u);
        }
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    db = new MockDB!();
    db.setTableData("users", `[
        {"id": 1, "first_name": "Alice", "last_name": "Smith"}
    ]`);

    auto query = compileTestQuery!Query(`{ users { fullName } }`);

    auto executor = new Executor();
    auto result = awaitSync(executor.execute(query));

    auto users = result["users"].array;
    assert(users.length == 1);
    assert(users[0]["fullName"].str == "Alice Smith");
}

unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dunamis.core;
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import dunamis.relational.eval_context;

    // Test nested hasMany relationships
    static MockDB!() db;

    @DemoEntity!(db, "posts")
    static struct Post {
        mixin DemoId;
        mixin Col!("title", string);
    }

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("firstName", string);
        mixin HasMany!("posts", Post, "author_id");
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    db = new MockDB!();
    db.setTableData("users", `[
        {"id": 1, "first_name": "Alice"},
        {"id": 2, "first_name": "Bob"}
    ]`);
    db.setTableData("posts", `[
        {"id": 1, "author_id": 1, "title": "Hello"},
        {"id": 2, "author_id": 1, "title": "World"},
        {"id": 3, "author_id": 2, "title": "Test"}
    ]`);

    auto query = compileTestQuery!Query(`{ users { firstName, posts { title } } }`);

    auto executor = new Executor();
    auto result = awaitSync(executor.execute(query));

    auto users = result["users"].array;
    assert(users.length == 2);

    // Alice has 2 posts
    assert(users[0]["firstName"].str == "Alice");
    assert(users[0]["posts"].array.length == 2);
    assert(users[0]["posts"][0]["title"].str == "Hello");
    assert(users[0]["posts"][1]["title"].str == "World");

    // Bob has 1 post
    assert(users[1]["firstName"].str == "Bob");
    assert(users[1]["posts"].array.length == 1);
    assert(users[1]["posts"][0]["title"].str == "Test");
}

unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dunamis.core;
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import dunamis.relational.eval_context;

    // Test computed fields with arguments
    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("firstName", string);

        // Computed field with required argument
        static auto greeting(Expr!User u, string prefix) {
            return prefix ~ " " ~ firstName(u);
        }

        // Computed field with optional argument (has default)
        static auto greetingWithSuffix(Expr!User u, string prefix, string suffix = "!") {
            return prefix ~ " " ~ firstName(u) ~ suffix;
        }
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    db = new MockDB!();
    db.setTableData("users", `[
        {"id": 1, "first_name": "Alice"},
        {"id": 2, "first_name": "Bob"}
    ]`);

    // Test with required argument
    auto query1 = compileTestQuery!Query(`{ users { greeting(prefix: "Hello") } }`);
    auto executor = new Executor();
    auto result1 = awaitSync(executor.execute(query1));

    auto users1 = result1["users"].array;
    assert(users1.length == 2);
    assert(users1[0]["greeting"].str == "Hello Alice");
    assert(users1[1]["greeting"].str == "Hello Bob");

    // Test with optional argument using default
    auto query2 = compileTestQuery!Query(`{ users { greetingWithSuffix(prefix: "Hi") } }`);
    auto result2 = awaitSync(executor.execute(query2));

    auto users2 = result2["users"].array;
    assert(users2.length == 2);
    assert(users2[0]["greetingWithSuffix"].str == "Hi Alice!");
    assert(users2[1]["greetingWithSuffix"].str == "Hi Bob!");

    // Test with optional argument overridden
    auto query3 = compileTestQuery!Query(`{ users { greetingWithSuffix(prefix: "Hey", suffix: "?") } }`);
    auto result3 = awaitSync(executor.execute(query3));

    auto users3 = result3["users"].array;
    assert(users3.length == 2);
    assert(users3[0]["greetingWithSuffix"].str == "Hey Alice?");
    assert(users3[1]["greetingWithSuffix"].str == "Hey Bob?");
}

unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dunamis.core;
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import dunamis.relational.eval_context;

    // Test multiple root fields
    static MockDB!() db;

    @DemoEntity!(db, "posts")
    static struct Post {
        mixin DemoId;
        mixin Col!("title", string);
    }

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("firstName", string);
    }

    static struct Query {
        mixin Table!(User, "users");
        mixin Table!(Post, "posts");
    }

    db = new MockDB!();
    db.setTableData("users", `[
        {"id": 1, "first_name": "Alice"},
        {"id": 2, "first_name": "Bob"}
    ]`);
    db.setTableData("posts", `[
        {"id": 1, "title": "Hello"},
        {"id": 2, "title": "World"},
        {"id": 3, "title": "Test"}
    ]`);

    // Query with multiple root fields
    auto query = compileTestQuery!Query(`{
        users { firstName }
        posts { title }
    }`);

    auto executor = new Executor();
    auto result = awaitSync(executor.execute(query));

    // Result should have both users and posts
    auto users = result["users"].array;
    auto posts = result["posts"].array;

    assert(users.length == 2);
    assert(users[0]["firstName"].str == "Alice");
    assert(users[1]["firstName"].str == "Bob");

    assert(posts.length == 3);
    assert(posts[0]["title"].str == "Hello");
    assert(posts[1]["title"].str == "World");
    assert(posts[2]["title"].str == "Test");
}

unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dunamis.core;
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import dunamis.relational.eval_context;

    // Test input objects as computed field arguments

    // Define an input type (plain struct)
    static struct NameFormat {
        string prefix;
        string suffix;
    }

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("firstName", string);
        mixin Col!("lastName", string);

        // Computed field that takes an input object
        static auto formattedName(Expr!User u, NameFormat format) {
            return format.prefix ~ firstName(u) ~ " " ~ lastName(u) ~ format.suffix;
        }
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    db = new MockDB!();
    db.setTableData("users", `[
        {"id": 1, "first_name": "Alice", "last_name": "Smith"},
        {"id": 2, "first_name": "Bob", "last_name": "Jones"}
    ]`);

    // Query with input object argument
    auto query = compileTestQuery!Query(`{
        users {
            formattedName(format: {prefix: "Mr. ", suffix: "!"})
        }
    }`);

    auto executor = new Executor();
    auto result = awaitSync(executor.execute(query));

    auto users = result["users"].array;
    assert(users.length == 2);
    assert(users[0]["formattedName"].str == "Mr. Alice Smith!");
    assert(users[1]["formattedName"].str == "Mr. Bob Jones!");
}

unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dunamis.core;
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import dunamis.relational.eval_context;

    // Test nested input objects

    // Inner input type
    static struct Decoration {
        string left;
        string right;
    }

    // Outer input type containing inner
    static struct NameStyle {
        string separator;
        Decoration decoration;
    }

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("firstName", string);
        mixin Col!("lastName", string);

        // Computed field with nested input object
        static auto styledName(Expr!User u, NameStyle style) {
            return style.decoration.left ~ firstName(u) ~ style.separator ~ lastName(u) ~ style.decoration.right;
        }
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    db = new MockDB!();
    db.setTableData("users", `[
        {"id": 1, "first_name": "Alice", "last_name": "Smith"}
    ]`);

    // Query with nested input object
    auto query = compileTestQuery!Query(`{
        users {
            styledName(style: {
                separator: " - ",
                decoration: {left: "[", right: "]"}
            })
        }
    }`);

    auto executor = new Executor();
    auto result = awaitSync(executor.execute(query));

    auto users = result["users"].array;
    assert(users.length == 1);
    assert(users[0]["styledName"].str == "[Alice - Smith]");
}

unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dunamis.core;
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import dunamis.relational.eval_context;

    // Test GraphQL variables
    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("firstName", string);

        // Computed field with arguments
        static auto greeting(Expr!User u, string prefix, string suffix = "!") {
            return prefix ~ " " ~ firstName(u) ~ suffix;
        }
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    db = new MockDB!();
    db.setTableData("users", `[
        {"id": 1, "first_name": "Alice"},
        {"id": 2, "first_name": "Bob"}
    ]`);

    // Query with variable for scalar argument
    auto variables = JSONValue([
        "greetPrefix": JSONValue("Hello"),
        "greetSuffix": JSONValue("?")
    ]);

    auto query = compileTestQuery!Query(`
        query GetUsers($greetPrefix: String!, $greetSuffix: String) {
            users {
                greeting(prefix: $greetPrefix, suffix: $greetSuffix)
            }
        }
    `, variables);

    auto executor = new Executor();
    auto result = awaitSync(executor.execute(query));

    auto users = result["users"].array;
    assert(users.length == 2);
    assert(users[0]["greeting"].str == "Hello Alice?");
    assert(users[1]["greeting"].str == "Hello Bob?");
}

unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dunamis.core;
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import dunamis.relational.eval_context;

    // Test variables with input objects

    static struct NameFormat {
        string prefix;
        string suffix;
    }

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("firstName", string);
        mixin Col!("lastName", string);

        static auto formattedName(Expr!User u, NameFormat format) {
            return format.prefix ~ firstName(u) ~ " " ~ lastName(u) ~ format.suffix;
        }
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    db = new MockDB!();
    db.setTableData("users", `[
        {"id": 1, "first_name": "Alice", "last_name": "Smith"}
    ]`);

    // Variable containing an input object
    auto variables = JSONValue([
        "fmt": JSONValue([
            "prefix": JSONValue("Dr. "),
            "suffix": JSONValue(", PhD")
        ])
    ]);

    auto query = compileTestQuery!Query(`
        query GetUsers($fmt: NameFormat!) {
            users {
                formattedName(format: $fmt)
            }
        }
    `, variables);

    auto executor = new Executor();
    auto result = awaitSync(executor.execute(query));

    auto users = result["users"].array;
    assert(users.length == 1);
    assert(users[0]["formattedName"].str == "Dr. Alice Smith, PhD");
}

unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dunamis.core;
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import dunamis.relational.eval_context;

    // Test compileQuery with Schema type (rather than raw Query type)
    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("firstName", string);
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    // Create Schema from Query
    alias MySchema = dunamis.graphql.schema.Schema!(Query);

    db = new MockDB!();
    db.setTableData("users", `[
        {"id": 1, "first_name": "Alice"}
    ]`);

    // Compile using Schema type instead of raw Query
    auto query = compileQuery!MySchema(`{ users { firstName } }`);

    auto executor = new Executor();
    auto result = awaitSync(executor.execute(query));

    auto users = result["users"].array;
    assert(users.length == 1);
    assert(users[0]["firstName"].str == "Alice");
}

unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dunamis.core;
    import dunamis.core.expr : effect;
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import dunamis.relational.eval_context;
    import dunamis.graphql.schema : Schema;

    // Test mutation execution

    // Track mutation calls for testing
    __gshared static string lastGreeting;
    __gshared static int deleteCount;

    static struct Mutation {
        // Simple mutation returning scalar
        static Expr!string sayHello(Expr!Mutation parent, string name) {
            return effect(() {
                lastGreeting = "Hello, " ~ name ~ "!";
                return lastGreeting;
            }, parent);
        }

        // Mutation with multiple arguments
        static Expr!bool deleteItems(Expr!Mutation parent, int count) {
            return effect(() {
                deleteCount = count;
                return true;
            }, parent);
        }

        // Mutation with optional argument
        static Expr!string greet(Expr!Mutation parent, string name, string greeting = "Hi") {
            return effect(() => greeting ~ " " ~ name, parent);
        }
    }

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("name", string);
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    // Create Schema with mutations
    alias MySchema = Schema!(Query, Mutation);

    db = new MockDB!();
    db.setTableData("users", `[{"id": 1, "name": "Alice"}]`);

    // Reset tracking variables
    lastGreeting = "";
    deleteCount = 0;

    // Execute mutation
    auto mutation = compileQuery!MySchema(`
        mutation {
            sayHello(name: "World")
            deleteItems(count: 5)
            greet(name: "Bob")
        }
    `);

    auto executor = new Executor();
    auto result = awaitSync(executor.execute(mutation));

    // Verify mutation results
    assert(result["sayHello"].str == "Hello, World!", "sayHello should return greeting");
    assert(result["deleteItems"].boolean == true, "deleteItems should return true");
    assert(result["greet"].str == "Hi Bob", "greet should use default greeting");

    // Verify side effects occurred
    assert(lastGreeting == "Hello, World!", "sayHello should have been called");
    assert(deleteCount == 5, "deleteItems should have been called with count=5");
}

unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dunamis.core;
    import dunamis.core.expr : effect;
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import dunamis.relational.eval_context;
    import dunamis.graphql.schema : Schema;

    // Test mutation with input object

    static struct CreateUserInput {
        string name;
        string email;
    }

    __gshared static CreateUserInput lastInput;

    static struct Mutation {
        static Expr!string createUser(Expr!Mutation parent, CreateUserInput input) {
            return effect(() {
                lastInput = input;
                return "Created user: " ~ input.name;
            }, parent);
        }
    }

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("name", string);
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    alias MySchema = Schema!(Query, Mutation);

    db = new MockDB!();
    db.setTableData("users", `[{"id": 1, "name": "Alice"}]`);

    // Execute mutation with input object
    auto mutation = compileQuery!MySchema(`
        mutation {
            createUser(input: {name: "Bob", email: "bob@example.com"})
        }
    `);

    auto executor = new Executor();
    auto result = awaitSync(executor.execute(mutation));

    assert(result["createUser"].str == "Created user: Bob");
    assert(lastInput.name == "Bob");
    assert(lastInput.email == "bob@example.com");
}

unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dunamis.core;
    import dunamis.core.expr : effect;
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import dunamis.relational.eval_context;
    import dunamis.graphql.schema : Schema;

    // Test mutation with variables

    __gshared static string lastMessage;

    static struct Mutation {
        static Expr!string echo(Expr!Mutation parent, string message) {
            return effect(() {
                lastMessage = message;
                return message;
            }, parent);
        }
    }

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("name", string);
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    alias MySchema = Schema!(Query, Mutation);

    db = new MockDB!();
    db.setTableData("users", `[{"id": 1, "name": "Alice"}]`);

    // Execute mutation with variable
    auto variables = JSONValue([
        "msg": JSONValue("Hello from variable!")
    ]);

    auto mutation = compileQuery!MySchema(`
        mutation Echo($msg: String!) {
            echo(message: $msg)
        }
    `, variables);

    auto executor = new Executor();
    auto result = awaitSync(executor.execute(mutation));

    assert(result["echo"].str == "Hello from variable!");
    assert(lastMessage == "Hello from variable!");
}

// Test mutation returning a single entity with selection set
unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dunamis.core;
    import dunamis.core.expr : effect;
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import dunamis.relational.eval_context;
    import dunamis.graphql.schema : Schema;

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("name", string);
        mixin Col!("email", string);
    }

    static struct Mutation {
        // Mutation that creates a user and returns the entity
        static Expr!User createUser(Expr!Mutation parent, string name, string email) {
            return effect(() {
                // In a real implementation, this would INSERT and return the new ID
                // For testing, we'll just return an existing user
                return makeEntity!User(1);
            }, parent);
        }
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    alias MySchema = Schema!(Query, Mutation);

    db = new MockDB!();
    db.setTableData("users", `[
        {"id": 1, "name": "Alice", "email": "alice@example.com"},
        {"id": 2, "name": "Bob", "email": "bob@example.com"}
    ]`);

    // Execute mutation with selection set on returned entity
    auto mutation = compileQuery!MySchema(`
        mutation {
            createUser(name: "Charlie", email: "charlie@example.com") {
                name
                email
            }
        }
    `);

    auto executor = new Executor();
    auto result = awaitSync(executor.execute(mutation));

    // Verify the returned entity has the selected fields
    assert(result["createUser"]["name"].str == "Alice");
    assert(result["createUser"]["email"].str == "alice@example.com");
}

// Test mutation returning an array of entities with selection set
unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dunamis.core;
    import dunamis.core.expr : effect;
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import dunamis.relational.eval_context;
    import dunamis.graphql.schema : Schema;

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("name", string);
    }

    static struct Mutation {
        // Mutation that returns multiple entities
        static Expr!(User[]) getActiveUsers(Expr!Mutation parent) {
            return effect(() {
                // Return array of user refs
                return [makeEntity!User(1), makeEntity!User(2)];
            }, parent);
        }
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    alias MySchema = Schema!(Query, Mutation);

    db = new MockDB!();
    db.setTableData("users", `[
        {"id": 1, "name": "Alice"},
        {"id": 2, "name": "Bob"}
    ]`);

    // Execute mutation with selection set on returned entities
    auto mutation = compileQuery!MySchema(`
        mutation {
            getActiveUsers {
                name
            }
        }
    `);

    auto executor = new Executor();
    auto result = awaitSync(executor.execute(mutation));

    // Verify the returned entities have the selected fields
    auto users = result["getActiveUsers"].array;
    assert(users.length == 2);
    assert(users[0]["name"].str == "Alice");
    assert(users[1]["name"].str == "Bob");
}

// Test getFieldName/getFieldAlias with aliased fields (verifies graphql-d AST handling)
unittest {
    import graphql.parser : Parser;
    import graphql.lexer : Lexer;

    // Test aliased field: "myAlias: actualField"
    {
        auto lexer = Lexer(`{ myAlias: actualField }`);
        auto parser = Parser(lexer);
        auto doc = parser.parseDocument();
        auto field = doc.defs.def.op.ss.sel.sel.field;

        assert(getFieldName(field) == "actualField", "Should extract actual field name");
        assert(getFieldAlias(field) == "myAlias", "Should extract alias");
        assert(getOutputName(field) == "myAlias", "Output name should be the alias");
    }

    // Test non-aliased field: "justAField"
    {
        auto lexer = Lexer(`{ justAField }`);
        auto parser = Parser(lexer);
        auto doc = parser.parseDocument();
        auto field = doc.defs.def.op.ss.sel.sel.field;

        assert(getFieldName(field) == "justAField", "Should extract field name");
        assert(getFieldAlias(field) is null, "Should have no alias");
        assert(getOutputName(field) == "justAField", "Output name should be the field name");
    }
}

// Test scalar methods on Query root (not just Table fields)
unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dunamis.core;
    import dunamis.core.expr : constant;
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import dunamis.relational.eval_context;
    import dunamis.graphql.schema : Schema;

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("name", string);
    }

    static struct Query {
        // Table field - returns [User!]!
        mixin Table!(User, "users");

        // Scalar field - returns Int!
        static auto userCount(Expr!Query parent) {
            // In a real implementation, this would be COUNT(*) from users
            return constant(42, parent);
        }

        // Scalar field with int argument - returns Int!
        static auto userCountWithLimit(Expr!Query parent, int limit) {
            // In a real implementation, this would be COUNT(*) LIMIT $1
            return constant(limit < 42 ? limit : 42, parent);
        }

        // Scalar field returning string
        static auto serverVersion(Expr!Query parent) {
            return constant("1.0.0", parent);
        }

        // Scalar field with default argument
        static auto greeting(Expr!Query parent, string name = "World") {
            return constant("Hello, " ~ name ~ "!", parent);
        }
    }

    alias MySchema = Schema!(Query);

    db = new MockDB!();
    db.setTableData("users", `[
        {"id": 1, "name": "Alice"},
        {"id": 2, "name": "Bob"}
    ]`);

    // Test scalar field without arguments
    {
        auto query = compileQuery!MySchema(`{
            userCount
            serverVersion
        }`);

        auto executor = new Executor();
        auto result = awaitSync(executor.execute(query));

        assert(result["userCount"].integer == 42);
        assert(result["serverVersion"].str == "1.0.0");
    }

    // Test scalar field with arguments
    {
        auto query = compileQuery!MySchema(`{
            limitedCount: userCountWithLimit(limit: 10)
            fullCount: userCountWithLimit(limit: 100)
        }`);

        auto executor = new Executor();
        auto result = awaitSync(executor.execute(query));

        assert(result["limitedCount"].integer == 10);
        assert(result["fullCount"].integer == 42);
    }

    // Test scalar field with default argument
    {
        auto query = compileQuery!MySchema(`{
            defaultGreeting: greeting
            customGreeting: greeting(name: "Alice")
        }`);

        auto executor = new Executor();
        auto result = awaitSync(executor.execute(query));

        assert(result["defaultGreeting"].str == "Hello, World!");
        assert(result["customGreeting"].str == "Hello, Alice!");
    }

    // Test mixing scalar and table fields
    {
        auto query = compileQuery!MySchema(`{
            userCount
            users { name }
        }`);

        auto executor = new Executor();
        auto result = awaitSync(executor.execute(query));

        assert(result["userCount"].integer == 42);
        assert(result["users"].array.length == 2);
        assert(result["users"].array[0]["name"].str == "Alice");
    }
}

// Test mutation returning custom payload type (Postgraphile pattern)
unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dunamis.core;
    import dunamis.core.expr : effect, constant, singleton;
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import dunamis.relational.eval_context;
    import dunamis.graphql.schema : Schema;

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("name", string);
    }

    // Custom payload type with multiple fields
    static struct CreateUserPayload {
        // Return the created user
        static auto user(Expr!CreateUserPayload p) {
            // In reality, this would return the newly created user
            // For testing, return a reference to user 1
            return effect(() => makeEntity!User(1), p);
        }

        // Return a success message
        static auto message(Expr!CreateUserPayload p) {
            return constant("User created successfully", p);
        }

        // Return the client mutation ID (GraphQL Relay pattern)
        static auto clientMutationId(Expr!CreateUserPayload p) {
            return constant("mutation-123", p);
        }
    }

    static struct Mutation {
        // Mutation returning a custom payload type
        static Expr!CreateUserPayload createUser(Expr!Mutation parent, string name) {
            return effect(() => CreateUserPayload.init, parent);
        }
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    alias MySchema = Schema!(Query, Mutation);

    db = new MockDB!();
    db.setTableData("users", `[
        {"id": 1, "name": "Alice"},
        {"id": 2, "name": "Bob"}
    ]`);

    // Execute mutation with selection set on custom payload
    auto mutation = compileQuery!MySchema(`
        mutation {
            createUser(name: "Charlie") {
                message
                clientMutationId
                user {
                    name
                }
            }
        }
    `);

    auto executor = new Executor();
    auto result = awaitSync(executor.execute(mutation));

    // Verify payload fields
    auto payload = result["createUser"];
    assert(payload["message"].str == "User created successfully");
    assert(payload["clientMutationId"].str == "mutation-123");
    assert(payload["user"]["name"].str == "Alice");
}

// Test mutation payload returning Query type (full Postgraphile pattern)
unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dunamis.core;
    import dunamis.core.expr : effect, constant, singleton;
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import dunamis.relational.eval_context;
    import dunamis.graphql.schema : Schema;

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("name", string);
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    // Payload that includes access to the Query root
    static struct CreateUserPayload {
        static auto user(Expr!CreateUserPayload p) {
            return effect(() => makeEntity!User(1), p);
        }

        // Return the Query root - allows refetching any data after mutation
        static auto query(Expr!CreateUserPayload p) {
            return singleton(Query.init);
        }
    }

    static struct Mutation {
        static Expr!CreateUserPayload createUser(Expr!Mutation parent, string name) {
            return effect(() => CreateUserPayload.init, parent);
        }
    }

    alias MySchema = Schema!(Query, Mutation);

    db = new MockDB!();
    db.setTableData("users", `[
        {"id": 1, "name": "Alice"},
        {"id": 2, "name": "Bob"}
    ]`);

    // Execute mutation that refetches data via query field
    auto mutation = compileQuery!MySchema(`
        mutation {
            createUser(name: "Charlie") {
                user { name }
                query {
                    users { name }
                }
            }
        }
    `);

    auto executor = new Executor();
    auto result = awaitSync(executor.execute(mutation));

    // Verify payload fields
    auto payload = result["createUser"];
    assert(payload["user"]["name"].str == "Alice");

    // Verify we can query the full graph via the query field
    auto users = payload["query"]["users"].array;
    assert(users.length == 2);
    assert(users[0]["name"].str == "Alice");
    assert(users[1]["name"].str == "Bob");
}

// Test enum support in queries
unittest {
    import ae.utils.promise.await : awaitSync;
    import dunamis.core.executor : Executor;
    import dunamis.relational.demo : DemoEntity, DemoId, MockDB;
    import dunamis.relational.schema : Col, Table, getAll;

    enum Status { pending, inProgress, completed }

    static MockDB!() db;

    @DemoEntity!(db, "tasks")
    static struct Task {
        mixin DemoId;
        mixin Col!("title", string);
        mixin Col!("status", Status);
    }

    static struct Query {
        mixin Table!(Task, "tasks");
    }

    db = new MockDB!();
    db.setTableData("tasks", `[
        {"id": 1, "title": "Task 1", "status": "pending"},
        {"id": 2, "title": "Task 2", "status": "inProgress"},
        {"id": 3, "title": "Task 3", "status": "completed"}
    ]`);

    // Query tasks with enum field
    auto query = compileTestQuery!Query(`{
        tasks {
            title
            status
        }
    }`);

    auto executor = new Executor();
    auto result = awaitSync(executor.execute(query));

    // Verify enum values are returned correctly
    auto tasks = result["tasks"].array;
    assert(tasks.length == 3, "Should have 3 tasks");
    assert(tasks[0]["status"].str == "pending", "First task status should be pending");
    assert(tasks[1]["status"].str == "inProgress", "Second task status should be inProgress");
    assert(tasks[2]["status"].str == "completed", "Third task status should be completed");
}

// Test pointer input type extraction (self-referential via pointer)
unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dunamis.core;
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import dunamis.relational.eval_context;

    // Self-referential input type via pointer
    static struct NodeInput {
        string value;
        NodeInput* next;
    }

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("name", string);

        // Computed field taking recursive pointer input
        static auto traverseList(Expr!User u, NodeInput* head) {
            // For testing, just return the user's name
            // Real impl would use the input
            return u.name;
        }
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    db = new MockDB!();
    db.setTableData("users", `[{"id": 1, "name": "Alice"}]`);

    // Test null pointer input
    auto query1 = compileTestQuery!Query(`{
        users {
            traverseList(head: null)
        }
    }`);
    auto executor = new Executor();
    auto result1 = awaitSync(executor.execute(query1));
    auto users1 = result1["users"].array;
    assert(users1.length == 1);
    assert(users1[0]["traverseList"].str == "Alice");

    // Test pointer with value (single node)
    auto query2 = compileTestQuery!Query(`{
        users {
            traverseList(head: {value: "first", next: null})
        }
    }`);
    auto result2 = awaitSync(executor.execute(query2));
    auto users2 = result2["users"].array;
    assert(users2.length == 1);
    assert(users2[0]["traverseList"].str == "Alice");

    // Test pointer with nested value (linked list)
    auto query3 = compileTestQuery!Query(`{
        users {
            traverseList(head: {value: "first", next: {value: "second", next: null}})
        }
    }`);
    auto result3 = awaitSync(executor.execute(query3));
    auto users3 = result3["users"].array;
    assert(users3.length == 1);
    assert(users3[0]["traverseList"].str == "Alice");
}

// Test pointer input type via JSON variable
unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dunamis.core;
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import dunamis.relational.eval_context;

    static struct NodeInput {
        string value;
        NodeInput* next;
    }

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("name", string);

        static auto traverseList(Expr!User u, NodeInput* head) {
            return u.name;
        }
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    db = new MockDB!();
    db.setTableData("users", `[{"id": 1, "name": "Alice"}]`);

    // Test with variable containing nested pointer structure
    auto variables = JSONValue([
        "node": JSONValue([
            "value": JSONValue("first"),
            "next": JSONValue([
                "value": JSONValue("second"),
                "next": JSONValue(null)
            ])
        ])
    ]);

    auto query = compileTestQuery!Query(`
        query TestPointer($node: NodeInput) {
            users {
                traverseList(head: $node)
            }
        }
    `, variables);

    auto executor = new Executor();
    auto result = awaitSync(executor.execute(query));
    auto users = result["users"].array;
    assert(users.length == 1);
    assert(users[0]["traverseList"].str == "Alice");
}

// Test array self-reference input type
unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dunamis.core;
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import dunamis.relational.eval_context;

    // Self-referential via array
    static struct FilterInput {
        string field;
        FilterInput[] and;
    }

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("name", string);

        static auto matchFilter(Expr!User u, FilterInput filter) {
            return u.name;
        }
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    db = new MockDB!();
    db.setTableData("users", `[{"id": 1, "name": "Alice"}]`);

    // Test with nested array recursion
    auto query = compileTestQuery!Query(`{
        users {
            matchFilter(filter: {
                field: "name",
                and: [
                    {field: "age", and: []},
                    {field: "email", and: [{field: "domain", and: []}]}
                ]
            })
        }
    }`);

    auto executor = new Executor();
    auto result = awaitSync(executor.execute(query));
    auto users = result["users"].array;
    assert(users.length == 1);
    assert(users[0]["matchFilter"].str == "Alice");
}

// __typename introspection test
unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dunamis.core;
    import dunamis.relational.schema;
    import dunamis.relational.demo;

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("firstName", string);
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    db = new MockDB!();
    db.setTableData("users", `[
        {"id": 1, "first_name": "Alice"}
    ]`);

    auto executor = new Executor();

    // __typename on root Query
    {
        auto query = compileTestQuery!Query(`{ __typename }`);
        auto result = awaitSync(executor.execute(query));
        assert(result["__typename"].str == "Query");
    }

    // __typename on entity
    {
        auto query = compileTestQuery!Query(`{ users { __typename firstName } }`);
        auto result = awaitSync(executor.execute(query));
        auto users = result["users"].array;
        assert(users.length == 1);
        assert(users[0]["__typename"].str == "User");
        assert(users[0]["firstName"].str == "Alice");
    }
}

// __schema introspection test
unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dunamis.core;
    import dunamis.relational.schema;
    import dunamis.relational.demo;

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("firstName", string);
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    db = new MockDB!();

    auto executor = new Executor();

    // Basic __schema query
    {
        auto query = compileTestQuery!Query(`{ __schema { queryType { name } } }`);
        auto result = awaitSync(executor.execute(query));
        assert(result["__schema"]["queryType"]["name"].str == "Query");
    }

    // __schema with types
    {
        auto query = compileTestQuery!Query(`{ __schema { types { name kind } } }`);
        auto result = awaitSync(executor.execute(query));
        auto types = result["__schema"]["types"].array;
        bool foundUser = false;
        bool foundQuery = false;
        foreach (t; types) {
            if (t["name"].str == "User") {
                foundUser = true;
                assert(t["kind"].str == "OBJECT");
            }
            if (t["name"].str == "Query") {
                foundQuery = true;
                assert(t["kind"].str == "OBJECT");
            }
        }
        assert(foundUser, "Should find User type");
        assert(foundQuery, "Should find Query type");
    }
}

// __type introspection test
unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dunamis.core;
    import dunamis.relational.schema;
    import dunamis.relational.demo;

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("firstName", string);
        mixin Col!("lastName", string);
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    db = new MockDB!();

    auto executor = new Executor();

    // __type lookup for existing type
    {
        auto query = compileTestQuery!Query(`{ __type(name: "User") { name kind } }`);
        auto result = awaitSync(executor.execute(query));
        assert(result["__type"]["name"].str == "User");
        assert(result["__type"]["kind"].str == "OBJECT");
    }

    // __type lookup for non-existent type
    {
        auto query = compileTestQuery!Query(`{ __type(name: "NonExistent") { name } }`);
        auto result = awaitSync(executor.execute(query));
        assert(result["__type"].isNull);
    }

    // __type with fields
    {
        auto query = compileTestQuery!Query(`{ __type(name: "User") { name fields { name type { kind name } } } }`);
        auto result = awaitSync(executor.execute(query));
        assert(result["__type"]["name"].str == "User");
        auto fields = result["__type"]["fields"].array;
        bool foundFirstName = false;
        foreach (f; fields) {
            if (f["name"].str == "firstName") {
                foundFirstName = true;
                // String! → NON_NULL wrapping SCALAR String
                assert(f["type"]["kind"].str == "NON_NULL");
                assert(f["type"]["name"].isNull);
            }
        }
        assert(foundFirstName, "Should find firstName field");
    }
}

// Col field + plain method in the same selection set
// Regression test: evalAs cache stored Promise!(AnyRef[]) from column access,
// then MethodCallExpr tried to retrieve as Promise!(Entity[]) — cast returned
// null → SIGSEGV on .then(). Fixed by runtime type-checking the cache.
unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dunamis.core;
    import dunamis.relational.schema;
    import dunamis.relational.demo;

    static MockDB!() db;

    @DemoEntity!(db, "items")
    static struct Item {
        mixin DemoId;
        mixin Col!("title", string);

        string label() => "item-label";
    }

    static struct Query {
        mixin Table!(Item, "items");
    }

    db = new MockDB!();
    db.setTableData("items", `[{"id": 1, "title": "Thing"}]`);

    auto query = compileQuery!(Schema!(Query))(`{ items { title label } }`);
    auto executor = new Executor();
    auto result = awaitSync(executor.execute(query));

    auto items = result["items"].array;
    assert(items.length == 1);
    assert(items[0]["title"].str == "Thing");
    assert(items[0]["label"].str == "item-label");
}

// @skip directive tests
unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dunamis.core;
    import dunamis.relational.schema;
    import dunamis.relational.demo;

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("firstName", string);
        mixin Col!("lastName", string);
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    db = new MockDB!();
    db.setTableData("users", `[
        {"id": 1, "first_name": "Alice", "last_name": "Smith"},
        {"id": 2, "first_name": "Bob", "last_name": "Jones"}
    ]`);

    auto executor = new Executor();

    // @skip(if: true) — field excluded
    {
        auto query = compileTestQuery!Query(`{ users { firstName @skip(if: true) lastName } }`);
        auto result = awaitSync(executor.execute(query));
        auto users = result["users"].array;
        assert(users.length == 2);
        assert("firstName" !in users[0], "@skip(if: true) should exclude field");
        assert(users[0]["lastName"].str == "Smith");
    }

    // @skip(if: false) — field included
    {
        auto query = compileTestQuery!Query(`{ users { firstName @skip(if: false) lastName } }`);
        auto result = awaitSync(executor.execute(query));
        auto users = result["users"].array;
        assert(users[0]["firstName"].str == "Alice");
        assert(users[0]["lastName"].str == "Smith");
    }
}

// @include directive tests
unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dunamis.core;
    import dunamis.relational.schema;
    import dunamis.relational.demo;

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("firstName", string);
        mixin Col!("lastName", string);
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    db = new MockDB!();
    db.setTableData("users", `[
        {"id": 1, "first_name": "Alice", "last_name": "Smith"}
    ]`);

    auto executor = new Executor();

    // @include(if: true) — field included
    {
        auto query = compileTestQuery!Query(`{ users { firstName @include(if: true) lastName } }`);
        auto result = awaitSync(executor.execute(query));
        auto users = result["users"].array;
        assert(users[0]["firstName"].str == "Alice");
        assert(users[0]["lastName"].str == "Smith");
    }

    // @include(if: false) — field excluded
    {
        auto query = compileTestQuery!Query(`{ users { firstName @include(if: false) lastName } }`);
        auto result = awaitSync(executor.execute(query));
        auto users = result["users"].array;
        assert("firstName" !in users[0], "@include(if: false) should exclude field");
        assert(users[0]["lastName"].str == "Smith");
    }
}

// Directive with variable reference
unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dunamis.core;
    import dunamis.relational.schema;
    import dunamis.relational.demo;

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("firstName", string);
        mixin Col!("lastName", string);
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    db = new MockDB!();
    db.setTableData("users", `[
        {"id": 1, "first_name": "Alice", "last_name": "Smith"}
    ]`);

    auto executor = new Executor();

    // @include(if: $show) with $show = false
    {
        auto variables = JSONValue(["show": JSONValue(false)]);
        auto query = compileTestQuery!Query(`
            query Q($show: Boolean!) {
                users { firstName @include(if: $show) lastName }
            }
        `, variables);
        auto result = awaitSync(executor.execute(query));
        auto users = result["users"].array;
        assert("firstName" !in users[0], "Variable false should exclude field");
        assert(users[0]["lastName"].str == "Smith");
    }

    // @skip(if: $s) with $s = true
    {
        auto variables = JSONValue(["s": JSONValue(true)]);
        auto query = compileTestQuery!Query(`
            query Q($s: Boolean!) {
                users { firstName @skip(if: $s) lastName }
            }
        `, variables);
        auto result = awaitSync(executor.execute(query));
        auto users = result["users"].array;
        assert("firstName" !in users[0], "Variable true should skip field");
        assert(users[0]["lastName"].str == "Smith");
    }
}

// Both @skip and @include on the same field
unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dunamis.core;
    import dunamis.relational.schema;
    import dunamis.relational.demo;

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("firstName", string);
        mixin Col!("lastName", string);
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    db = new MockDB!();
    db.setTableData("users", `[
        {"id": 1, "first_name": "Alice", "last_name": "Smith"}
    ]`);

    auto executor = new Executor();

    // @skip(if: true) @include(if: true) — skip wins, field excluded
    {
        auto query = compileTestQuery!Query(`{ users { firstName @skip(if: true) @include(if: true) lastName } }`);
        auto result = awaitSync(executor.execute(query));
        auto users = result["users"].array;
        assert("firstName" !in users[0], "@skip(if:true) should override @include(if:true)");
        assert(users[0]["lastName"].str == "Smith");
    }

    // @skip(if: false) @include(if: true) — both say include
    {
        auto query = compileTestQuery!Query(`{ users { firstName @skip(if: false) @include(if: true) lastName } }`);
        auto result = awaitSync(executor.execute(query));
        auto users = result["users"].array;
        assert(users[0]["firstName"].str == "Alice");
    }

    // @skip(if: false) @include(if: false) — include=false wins
    {
        auto query = compileTestQuery!Query(`{ users { firstName @skip(if: false) @include(if: false) lastName } }`);
        auto result = awaitSync(executor.execute(query));
        auto users = result["users"].array;
        assert("firstName" !in users[0], "@include(if:false) should exclude field");
    }
}

// Root-level directive — skip an entire root field
unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dunamis.core;
    import dunamis.relational.schema;
    import dunamis.relational.demo;

    static MockDB!() db;

    @DemoEntity!(db, "posts")
    static struct Post {
        mixin DemoId;
        mixin Col!("title", string);
    }

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("firstName", string);
    }

    static struct Query {
        mixin Table!(User, "users");
        mixin Table!(Post, "posts");
    }

    db = new MockDB!();
    db.setTableData("users", `[{"id": 1, "first_name": "Alice"}]`);
    db.setTableData("posts", `[{"id": 1, "title": "Hello"}]`);

    auto executor = new Executor();

    // Skip the users root field entirely
    {
        auto query = compileTestQuery!Query(`{
            users @skip(if: true) { firstName }
            posts { title }
        }`);
        auto result = awaitSync(executor.execute(query));
        assert("users" !in result, "Root field with @skip(if: true) should be excluded");
        assert(result["posts"].array[0]["title"].str == "Hello");
    }
}

// Directive on nested hasMany subfield
unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dunamis.core;
    import dunamis.relational.schema;
    import dunamis.relational.demo;

    static MockDB!() db;

    @DemoEntity!(db, "posts")
    static struct Post {
        mixin DemoId;
        mixin Col!("title", string);
        mixin Col!("body_", string, "body");
    }

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("firstName", string);
        mixin HasMany!("posts", Post, "author_id");
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    db = new MockDB!();
    db.setTableData("users", `[{"id": 1, "first_name": "Alice"}]`);
    db.setTableData("posts", `[{"id": 1, "author_id": 1, "title": "Hello", "body": "World"}]`);

    auto executor = new Executor();

    // Skip title within posts
    {
        auto query = compileTestQuery!Query(`{
            users {
                firstName
                posts { title @skip(if: true) body_ }
            }
        }`);
        auto result = awaitSync(executor.execute(query));
        auto users = result["users"].array;
        assert(users[0]["firstName"].str == "Alice");
        auto posts = users[0]["posts"].array;
        assert(posts.length == 1);
        assert("title" !in posts[0], "Nested field with @skip should be excluded");
        assert(posts[0]["body_"].str == "World");
    }
}

// ============================================================================
// Fragment Tests
// ============================================================================

// Named fragment on entity type
unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dunamis.core;
    import dunamis.relational.schema;
    import dunamis.relational.demo;

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("firstName", string);
        mixin Col!("lastName", string);
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    db = new MockDB!();
    db.setTableData("users", `[
        {"id": 1, "first_name": "Alice", "last_name": "Smith"},
        {"id": 2, "first_name": "Bob", "last_name": "Jones"}
    ]`);

    auto query = compileTestQuery!Query(`
        query {
            users { ...UserFields }
        }
        fragment UserFields on User {
            firstName
            lastName
        }
    `);

    auto executor = new Executor();
    auto result = awaitSync(executor.execute(query));

    auto users = result["users"].array;
    assert(users.length == 2);
    assert(users[0]["firstName"].str == "Alice");
    assert(users[0]["lastName"].str == "Smith");
    assert(users[1]["firstName"].str == "Bob");
    assert(users[1]["lastName"].str == "Jones");
}

// Inline fragment without type condition
unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dunamis.core;
    import dunamis.relational.schema;
    import dunamis.relational.demo;

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("firstName", string);
        mixin Col!("lastName", string);
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    db = new MockDB!();
    db.setTableData("users", `[
        {"id": 1, "first_name": "Alice", "last_name": "Smith"}
    ]`);

    auto query = compileTestQuery!Query(`{
        users {
            firstName
            ... {
                lastName
            }
        }
    }`);

    auto executor = new Executor();
    auto result = awaitSync(executor.execute(query));

    auto users = result["users"].array;
    assert(users.length == 1);
    assert(users[0]["firstName"].str == "Alice");
    assert(users[0]["lastName"].str == "Smith");
}

// Inline fragment with matching type condition
unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dunamis.core;
    import dunamis.relational.schema;
    import dunamis.relational.demo;

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("firstName", string);
        mixin Col!("lastName", string);
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    db = new MockDB!();
    db.setTableData("users", `[
        {"id": 1, "first_name": "Alice", "last_name": "Smith"}
    ]`);

    auto query = compileTestQuery!Query(`{
        users {
            firstName
            ... on User {
                lastName
            }
        }
    }`);

    auto executor = new Executor();
    auto result = awaitSync(executor.execute(query));

    auto users = result["users"].array;
    assert(users.length == 1);
    assert(users[0]["firstName"].str == "Alice");
    assert(users[0]["lastName"].str == "Smith");
}

// Inline fragment with non-matching type condition (skipped)
unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dunamis.core;
    import dunamis.relational.schema;
    import dunamis.relational.demo;

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("firstName", string);
        mixin Col!("lastName", string);
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    db = new MockDB!();
    db.setTableData("users", `[
        {"id": 1, "first_name": "Alice", "last_name": "Smith"}
    ]`);

    auto query = compileTestQuery!Query(`{
        users {
            firstName
            ... on Post {
                lastName
            }
        }
    }`);

    auto executor = new Executor();
    auto result = awaitSync(executor.execute(query));

    auto users = result["users"].array;
    assert(users.length == 1);
    assert(users[0]["firstName"].str == "Alice");
    assert("lastName" !in users[0], "Non-matching type condition should skip fields");
}

// Nested fragments (fragment referencing another fragment)
unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dunamis.core;
    import dunamis.relational.schema;
    import dunamis.relational.demo;

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("firstName", string);
        mixin Col!("lastName", string);

        static auto fullName(Expr!User u) {
            return firstName(u) ~ " " ~ lastName(u);
        }
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    db = new MockDB!();
    db.setTableData("users", `[
        {"id": 1, "first_name": "Alice", "last_name": "Smith"}
    ]`);

    auto query = compileTestQuery!Query(`
        query {
            users { ...NameFields }
        }
        fragment NameFields on User {
            ...BasicFields
            fullName
        }
        fragment BasicFields on User {
            firstName
            lastName
        }
    `);

    auto executor = new Executor();
    auto result = awaitSync(executor.execute(query));

    auto users = result["users"].array;
    assert(users.length == 1);
    assert(users[0]["firstName"].str == "Alice");
    assert(users[0]["lastName"].str == "Smith");
    assert(users[0]["fullName"].str == "Alice Smith");
}

// Fragment spread with @skip(if: true) — skipped
unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dunamis.core;
    import dunamis.relational.schema;
    import dunamis.relational.demo;

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("firstName", string);
        mixin Col!("lastName", string);
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    db = new MockDB!();
    db.setTableData("users", `[
        {"id": 1, "first_name": "Alice", "last_name": "Smith"}
    ]`);

    auto query = compileTestQuery!Query(`
        query {
            users {
                firstName
                ...SkippedFields @skip(if: true)
            }
        }
        fragment SkippedFields on User {
            lastName
        }
    `);

    auto executor = new Executor();
    auto result = awaitSync(executor.execute(query));

    auto users = result["users"].array;
    assert(users.length == 1);
    assert(users[0]["firstName"].str == "Alice");
    assert("lastName" !in users[0], "@skip(if: true) on fragment spread should exclude fields");
}

// Inline fragment with @include(if: false) — skipped
unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dunamis.core;
    import dunamis.relational.schema;
    import dunamis.relational.demo;

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("firstName", string);
        mixin Col!("lastName", string);
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    db = new MockDB!();
    db.setTableData("users", `[
        {"id": 1, "first_name": "Alice", "last_name": "Smith"}
    ]`);

    auto query = compileTestQuery!Query(`{
        users {
            firstName
            ... @include(if: false) {
                lastName
            }
        }
    }`);

    auto executor = new Executor();
    auto result = awaitSync(executor.execute(query));

    auto users = result["users"].array;
    assert(users.length == 1);
    assert(users[0]["firstName"].str == "Alice");
    assert("lastName" !in users[0], "@include(if: false) on inline fragment should exclude fields");
}

// Fragment in nested HasMany selection
unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dunamis.core;
    import dunamis.relational.schema;
    import dunamis.relational.demo;

    static MockDB!() db;

    @DemoEntity!(db, "posts")
    static struct Post {
        mixin DemoId;
        mixin Col!("title", string);
    }

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("firstName", string);
        mixin HasMany!("posts", Post, "author_id");
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    db = new MockDB!();
    db.setTableData("users", `[
        {"id": 1, "first_name": "Alice"}
    ]`);
    db.setTableData("posts", `[
        {"id": 1, "author_id": 1, "title": "Hello"},
        {"id": 2, "author_id": 1, "title": "World"}
    ]`);

    auto query = compileTestQuery!Query(`
        query {
            users {
                firstName
                posts { ...PostFields }
            }
        }
        fragment PostFields on Post {
            title
        }
    `);

    auto executor = new Executor();
    auto result = awaitSync(executor.execute(query));

    auto users = result["users"].array;
    assert(users.length == 1);
    assert(users[0]["firstName"].str == "Alice");
    auto posts = users[0]["posts"].array;
    assert(posts.length == 2);
    assert(posts[0]["title"].str == "Hello");
    assert(posts[1]["title"].str == "World");
}

// Mixed regular fields and fragments
unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dunamis.core;
    import dunamis.relational.schema;
    import dunamis.relational.demo;

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("firstName", string);
        mixin Col!("lastName", string);

        static auto fullName(Expr!User u) {
            return firstName(u) ~ " " ~ lastName(u);
        }
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    db = new MockDB!();
    db.setTableData("users", `[
        {"id": 1, "first_name": "Alice", "last_name": "Smith"}
    ]`);

    auto query = compileTestQuery!Query(`
        query {
            users {
                firstName
                ...Extra
                ... on User { fullName }
            }
        }
        fragment Extra on User {
            lastName
        }
    `);

    auto executor = new Executor();
    auto result = awaitSync(executor.execute(query));

    auto users = result["users"].array;
    assert(users.length == 1);
    assert(users[0]["firstName"].str == "Alice");
    assert(users[0]["lastName"].str == "Smith");
    assert(users[0]["fullName"].str == "Alice Smith");
}

// Circular fragment detection (throws)
unittest {
    import dunamis.core;
    import dunamis.relational.schema;
    import dunamis.relational.demo;

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("firstName", string);
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    db = new MockDB!();
    db.setTableData("users", `[{"id": 1, "first_name": "Alice"}]`);

    bool caught = false;
    try {
        auto query = compileTestQuery!Query(`
            query {
                users { ...A }
            }
            fragment A on User { ...B }
            fragment B on User { ...A }
        `);
        auto executor = new Executor();
        import ae.utils.promise.await : awaitSync;
        awaitSync(executor.execute(query));
    } catch (CompilerException e) {
        caught = true;
        assert(e.msg == "Circular fragment reference: A",
            "Expected circular fragment error, got: " ~ e.msg);
    }
    assert(caught, "Should throw CompilerException for circular fragments");
}

// Fragment on root Query type
unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dunamis.core;
    import dunamis.core.expr : constant;
    import dunamis.relational.schema;
    import dunamis.relational.demo;

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("firstName", string);
    }

    static struct Query {
        mixin Table!(User, "users");

        static auto serverVersion(Expr!Query parent) {
            return constant("1.0.0", parent);
        }
    }

    db = new MockDB!();
    db.setTableData("users", `[
        {"id": 1, "first_name": "Alice"}
    ]`);

    auto query = compileTestQuery!Query(`
        query {
            ...RootFields
        }
        fragment RootFields on Query {
            users { firstName }
            serverVersion
        }
    `);

    auto executor = new Executor();
    auto result = awaitSync(executor.execute(query));

    assert(result["serverVersion"].str == "1.0.0");
    auto users = result["users"].array;
    assert(users.length == 1);
    assert(users[0]["firstName"].str == "Alice");
}

// ============================================================================
// Abstract Type Tests (Unions / Interfaces)
// ============================================================================

// Union type: query with typed fragments
unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dunamis.core;
    import dunamis.core.expr.combinators : unionOf;
    import dunamis.core.types : ImplementedBy;
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import dunamis.graphql.schema : Schema;

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("firstName", string);
    }

    @DemoEntity!(db, "posts")
    static struct Post {
        mixin DemoId;
        mixin Col!("title", string);
    }

    // Union: SearchResult = User | Post
    @ImplementedBy!(User, Post)
    static struct SearchResult {}

    static struct Query {
        mixin Table!(User, "users");
        mixin Table!(Post, "posts");

        // search returns all users and posts as a union
        static auto search(Expr!Query q) {
            return unionOf!SearchResult(users(q), posts(q));
        }
    }

    db = new MockDB!();
    db.setTableData("users", `[
        {"id": 1, "first_name": "Alice"},
        {"id": 2, "first_name": "Bob"}
    ]`);
    db.setTableData("posts", `[
        {"id": 1, "title": "Hello World"},
        {"id": 2, "title": "GraphQL Unions"}
    ]`);

    alias MySchema = Schema!(Query);

    auto query = compileQuery!MySchema(`{
        search {
            ... on User { firstName }
            ... on Post { title }
        }
    }`);

    auto executor = new Executor();
    auto result = awaitSync(executor.execute(query));

    auto items = result["search"].array;
    assert(items.length == 4, "Should have 2 users + 2 posts = 4 results");

    // Collect results by type (order is implementation-defined for unions)
    JSONValue[] userItems, postItems;
    foreach (item; items) {
        if ("firstName" in item) userItems ~= item;
        else if ("title" in item) postItems ~= item;
    }
    assert(userItems.length == 2, "Should have 2 user results");
    assert(postItems.length == 2, "Should have 2 post results");
    assert(userItems[0]["firstName"].str == "Alice");
    assert(userItems[1]["firstName"].str == "Bob");
    assert(postItems[0]["title"].str == "Hello World");
    assert(postItems[1]["title"].str == "GraphQL Unions");
}

// Union type: __typename returns concrete type name
unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dunamis.core;
    import dunamis.core.expr.combinators : unionOf;
    import dunamis.core.types : ImplementedBy;
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import dunamis.graphql.schema : Schema;

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("firstName", string);
    }

    @DemoEntity!(db, "posts")
    static struct Post {
        mixin DemoId;
        mixin Col!("title", string);
    }

    @ImplementedBy!(User, Post)
    static struct SearchResult {}

    static struct Query {
        mixin Table!(User, "users");
        mixin Table!(Post, "posts");

        static auto search(Expr!Query q) {
            return unionOf!SearchResult(users(q), posts(q));
        }
    }

    db = new MockDB!();
    db.setTableData("users", `[{"id": 1, "first_name": "Alice"}]`);
    db.setTableData("posts", `[{"id": 1, "title": "Hello"}]`);

    alias MySchema = Schema!(Query);

    auto query = compileQuery!MySchema(`{
        search {
            __typename
            ... on User { firstName }
            ... on Post { title }
        }
    }`);

    auto executor = new Executor();
    auto result = awaitSync(executor.execute(query));

    import std.conv : to;
    auto items = result["search"].array;
    assert(items.length == 2, "Expected 2 items, got " ~ items.length.to!string ~
        ": " ~ result["search"].toString());

    // Collect by type (order is implementation-defined for unions)
    JSONValue[] userItems, postItems;
    foreach (item; items) {
        if (item["__typename"].str == "User") userItems ~= item;
        else if (item["__typename"].str == "Post") postItems ~= item;
    }
    assert(userItems.length == 1, "Expected 1 user, got " ~ userItems.length.to!string);
    assert(postItems.length == 1, "Expected 1 post, got " ~ postItems.length.to!string);
    assert(userItems[0]["firstName"].str == "Alice");
    assert(postItems[0]["title"].str == "Hello");
}

// Union type: SDL generation
unittest {
    import std.algorithm : canFind;
    import dunamis.core;
    import dunamis.core.types : ImplementedBy;
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import dunamis.graphql.schema : Schema;
    import dunamis.graphql.schema.generation : generateSchemaSDL;

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("firstName", string);
    }

    @DemoEntity!(db, "posts")
    static struct Post {
        mixin DemoId;
        mixin Col!("title", string);
    }

    @ImplementedBy!(User, Post)
    static struct SearchResult {}

    static struct Query {
        mixin Table!(User, "users");
        mixin Table!(Post, "posts");

        static auto search(Expr!Query q) {
            return unionOf!SearchResult(users(q), posts(q));
        }
    }

    alias MySchema = Schema!(Query);
    enum sdl = generateSchemaSDL!MySchema;

    // Should contain union declaration
    assert(sdl.canFind("union SearchResult ="), "SDL should contain union declaration: " ~ sdl);
    // Should contain both member types
    assert(sdl.canFind("User") && sdl.canFind("Post"),
        "SDL should contain both union members: " ~ sdl);
    // Should contain the search field on Query returning the union type
    assert(sdl.canFind("search: [SearchResult!]!"),
        "Query should have search field returning union array: " ~ sdl);
}

// Union type: introspection
unittest {
    import std.json;
    import dunamis.core;
    import dunamis.core.types : ImplementedBy;
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import dunamis.graphql.schema : Schema;
    import dunamis.graphql.introspection : buildIntrospectionJson;

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("firstName", string);
    }

    @DemoEntity!(db, "posts")
    static struct Post {
        mixin DemoId;
        mixin Col!("title", string);
    }

    @ImplementedBy!(User, Post)
    static struct SearchResult {}

    static struct Query {
        mixin Table!(User, "users");
        mixin Table!(Post, "posts");

        static auto search(Expr!Query q) {
            return unionOf!SearchResult(users(q), posts(q));
        }
    }

    alias MySchema = Schema!(Query);
    auto schemaJson = buildIntrospectionJson!(MySchema.Query)();

    // Find the SearchResult type
    bool foundUnion = false;
    foreach (t; schemaJson["types"].array) {
        if (t["name"].str == "SearchResult") {
            foundUnion = true;
            assert(t["kind"].str == "UNION",
                "SearchResult should be UNION, got: " ~ t["kind"].str);
            // Should have possibleTypes listing the member types
            auto possible = t["possibleTypes"].array;
            assert(possible.length == 2,
                "Should have 2 possible types");
            // Collect names (order may vary)
            string[] names;
            foreach (p; possible) names ~= p["name"].str;
            import std.algorithm : canFind;
            assert(names.canFind("User"), "possibleTypes should include User");
            assert(names.canFind("Post"), "possibleTypes should include Post");
            // Union should have no fields
            assert(t["fields"].isNull, "Union should have no fields");
        }
    }
    assert(foundUnion, "Should have SearchResult union type in introspection");
}

// Union type: validation — missing selection set on union field
unittest {
    import dunamis.core;
    import dunamis.core.types : ImplementedBy;
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import dunamis.graphql.schema : Schema;

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("firstName", string);
    }

    @DemoEntity!(db, "posts")
    static struct Post {
        mixin DemoId;
        mixin Col!("title", string);
    }

    @ImplementedBy!(User, Post)
    static struct SearchResult {}

    static struct Query {
        mixin Table!(User, "users");
        mixin Table!(Post, "posts");

        static auto search(Expr!Query q) {
            return unionOf!SearchResult(users(q), posts(q));
        }
    }

    alias MySchema = Schema!(Query);

    // Querying a union field without a selection set should fail validation
    bool caught = false;
    try {
        auto query = compileQuery!MySchema(`{ search }`);
    } catch (CompilerException e) {
        caught = true;
        import std.algorithm : canFind;
        assert(e.msg.canFind("selection set"),
            "Error should mention selection set, got: " ~ e.msg);
    }
    assert(caught, "Should throw CompilerException for union field without selection set");
}

// Interface type: query with shared fields + typed fragments
unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dunamis.core;
    import dunamis.core.expr.combinators : unionOf;
    import dunamis.core.types : ImplementedBy, AbstractField;
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import dunamis.graphql.schema : Schema;

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("firstName", string);
    }

    @DemoEntity!(db, "posts")
    static struct Post {
        mixin DemoId;
        mixin Col!("title", string);
    }

    // Interface: Node has a shared "id" field
    @ImplementedBy!(User, Post)
    static struct Node {
        mixin AbstractField!("id", string);
    }

    static struct Query {
        mixin Table!(User, "users");
        mixin Table!(Post, "posts");

        static auto nodes(Expr!Query q) {
            return unionOf!Node(users(q), posts(q));
        }
    }

    db = new MockDB!();
    db.setTableData("users", `[
        {"id": 1, "first_name": "Alice"},
        {"id": 2, "first_name": "Bob"}
    ]`);
    db.setTableData("posts", `[
        {"id": 10, "title": "Hello World"},
        {"id": 20, "title": "GraphQL Interfaces"}
    ]`);

    alias MySchema = Schema!(Query);

    // Query interface with shared field (id) + typed fragments for member-specific fields
    auto query = compileQuery!MySchema(`{
        nodes {
            __typename
            ... on User { firstName }
            ... on Post { title }
        }
    }`);

    auto executor = new Executor();
    auto result = awaitSync(executor.execute(query));

    auto items = result["nodes"].array;
    assert(items.length == 4, "Should have 2 users + 2 posts = 4 results");

    JSONValue[] userItems, postItems;
    foreach (item; items) {
        if (item["__typename"].str == "User") userItems ~= item;
        else if (item["__typename"].str == "Post") postItems ~= item;
    }
    assert(userItems.length == 2, "Should have 2 user results");
    assert(postItems.length == 2, "Should have 2 post results");
    assert(userItems[0]["firstName"].str == "Alice");
    assert(postItems[0]["title"].str == "Hello World");
}

// Interface type: SDL generation
unittest {
    import std.algorithm : canFind;
    import dunamis.core;
    import dunamis.core.types : ImplementedBy, AbstractField;
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import dunamis.graphql.schema : Schema;
    import dunamis.graphql.schema.generation : generateSchemaSDL;

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("firstName", string);
    }

    @DemoEntity!(db, "posts")
    static struct Post {
        mixin DemoId;
        mixin Col!("title", string);
    }

    @ImplementedBy!(User, Post)
    static struct Node {
        mixin AbstractField!("id", string);
    }

    static struct Query {
        mixin Table!(User, "users");
        mixin Table!(Post, "posts");

        static auto nodes(Expr!Query q) {
            return unionOf!Node(users(q), posts(q));
        }
    }

    alias MySchema = Schema!(Query);
    enum sdl = generateSchemaSDL!MySchema;

    // Should contain interface declaration with the shared field
    assert(sdl.canFind("interface Node"), "SDL should contain interface declaration: " ~ sdl);
    assert(sdl.canFind("id: String!"),
        "Interface should have id field: " ~ sdl);

    // Object types should declare implements clause
    assert(sdl.canFind("type User implements Node"),
        "User should implement Node: " ~ sdl);
    assert(sdl.canFind("type Post implements Node"),
        "Post should implement Node: " ~ sdl);
}

// Interface type: introspection
unittest {
    import std.json;
    import std.algorithm : canFind;
    import dunamis.core;
    import dunamis.core.types : ImplementedBy, AbstractField;
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import dunamis.graphql.schema : Schema;
    import dunamis.graphql.introspection : buildIntrospectionJson;

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("firstName", string);
    }

    @DemoEntity!(db, "posts")
    static struct Post {
        mixin DemoId;
        mixin Col!("title", string);
    }

    @ImplementedBy!(User, Post)
    static struct Node {
        mixin AbstractField!("id", string);
    }

    static struct Query {
        mixin Table!(User, "users");
        mixin Table!(Post, "posts");

        static auto nodes(Expr!Query q) {
            return unionOf!Node(users(q), posts(q));
        }
    }

    alias MySchema = Schema!(Query);
    auto schemaJson = buildIntrospectionJson!(MySchema.Query)();

    // Find the Node type — should be INTERFACE
    bool foundInterface = false;
    foreach (t; schemaJson["types"].array) {
        if (t["name"].str == "Node") {
            foundInterface = true;
            assert(t["kind"].str == "INTERFACE",
                "Node should be INTERFACE, got: " ~ t["kind"].str);

            // Should have possibleTypes listing the member types
            auto possible = t["possibleTypes"].array;
            assert(possible.length == 2, "Should have 2 possible types");
            string[] names;
            foreach (p; possible) names ~= p["name"].str;
            assert(names.canFind("User"), "possibleTypes should include User");
            assert(names.canFind("Post"), "possibleTypes should include Post");

            // Interface should have fields (the shared id field)
            assert(!t["fields"].isNull, "Interface should have fields");
            auto fields = t["fields"].array;
            assert(fields.length >= 1, "Interface should have at least 1 field");
            string[] fieldNames;
            foreach (f; fields) fieldNames ~= f["name"].str;
            assert(fieldNames.canFind("id"), "Interface should have 'id' field");
        }
    }
    assert(foundInterface, "Should have Node interface type in introspection");

    // Verify User declares "implements Node" in its interfaces list
    foreach (t; schemaJson["types"].array) {
        if (t["name"].str == "User") {
            assert(!t["interfaces"].isNull, "User should have interfaces list");
            auto ifaces = t["interfaces"].array;
            assert(ifaces.length >= 1, "User should implement at least 1 interface");
            string[] ifaceNames;
            foreach (iface; ifaces) ifaceNames ~= iface["name"].str;
            assert(ifaceNames.canFind("Node"), "User should implement Node");
        }
    }
}

// Union validation: invalid type condition
unittest {
    import dunamis.core;
    import dunamis.core.types : ImplementedBy;
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import dunamis.graphql.schema : Schema;

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("firstName", string);
    }

    @DemoEntity!(db, "posts")
    static struct Post {
        mixin DemoId;
        mixin Col!("title", string);
    }

    @ImplementedBy!(User, Post)
    static struct SearchResult {}

    static struct Query {
        mixin Table!(User, "users");
        mixin Table!(Post, "posts");

        static auto search(Expr!Query q) {
            return unionOf!SearchResult(users(q), posts(q));
        }
    }

    alias MySchema = Schema!(Query);

    // Type condition "Comment" is not a member of SearchResult
    bool caught = false;
    try {
        auto query = compileQuery!MySchema(`{
            search {
                ... on Comment { text }
            }
        }`);
    } catch (CompilerException e) {
        caught = true;
        import std.algorithm : canFind;
        assert(e.msg.canFind("Comment") && e.msg.canFind("not a member"),
            "Error should mention invalid type condition: " ~ e.msg);
    }
    assert(caught, "Should throw for invalid type condition on union");
}

// Union validation: bare field on union (not allowed)
unittest {
    import dunamis.core;
    import dunamis.core.types : ImplementedBy;
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import dunamis.graphql.schema : Schema;

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("firstName", string);
    }

    @DemoEntity!(db, "posts")
    static struct Post {
        mixin DemoId;
        mixin Col!("title", string);
    }

    @ImplementedBy!(User, Post)
    static struct SearchResult {}

    static struct Query {
        mixin Table!(User, "users");
        mixin Table!(Post, "posts");

        static auto search(Expr!Query q) {
            return unionOf!SearchResult(users(q), posts(q));
        }
    }

    alias MySchema = Schema!(Query);

    // Bare field on union — only __typename is allowed
    bool caught = false;
    try {
        auto query = compileQuery!MySchema(`{
            search {
                firstName
            }
        }`);
    } catch (CompilerException e) {
        caught = true;
        import std.algorithm : canFind;
        assert(e.msg.canFind("Cannot query field") && e.msg.canFind("union"),
            "Error should mention cannot query on union: " ~ e.msg);
    }
    assert(caught, "Should throw for bare field on union type");
}

// Interface validation: unknown field on member via fragment
unittest {
    import dunamis.core;
    import dunamis.core.types : ImplementedBy, AbstractField;
    import dunamis.core.expr.combinators : unionOf;
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import dunamis.graphql.schema : Schema;

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("firstName", string);
    }

    @DemoEntity!(db, "posts")
    static struct Post {
        mixin DemoId;
        mixin Col!("title", string);
    }

    @ImplementedBy!(User, Post)
    static struct Node {
        mixin AbstractField!("id", string);
    }

    static struct Query {
        mixin Table!(User, "users");
        mixin Table!(Post, "posts");

        static auto nodes(Expr!Query q) {
            return unionOf!Node(users(q), posts(q));
        }
    }

    alias MySchema = Schema!(Query);

    // "nonExistent" doesn't exist on User
    bool caught = false;
    try {
        auto query = compileQuery!MySchema(`{
            nodes {
                ... on User { nonExistent }
            }
        }`);
    } catch (CompilerException e) {
        caught = true;
        import std.algorithm : canFind;
        assert(e.msg.canFind("Unknown field") && e.msg.canFind("nonExistent"),
            "Error should mention unknown field: " ~ e.msg);
    }
    assert(caught, "Should throw for unknown field in typed fragment");
}

// Union type: with plugins applied (tests AbstractTypeCastExpr + RemapTypeAttributes)
unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dunamis.core;
    import dunamis.core.expr.combinators : unionOf;
    import dunamis.core.types : ImplementedBy;
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import dunamis.graphql.schema : Schema;
    import dunamis.graphql : ApplyPlugins, FilterPlugin, SortingPlugin;

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("firstName", string);
    }

    @DemoEntity!(db, "posts")
    static struct Post {
        mixin DemoId;
        mixin Col!("title", string);
    }

    @ImplementedBy!(User, Post)
    static struct SearchResult {}

    static struct Query {
        mixin Table!(User, "users");
        mixin Table!(Post, "posts");

        static auto search(Expr!Query q) {
            return unionOf!SearchResult(users(q), posts(q));
        }
    }

    db = new MockDB!();
    db.setTableData("users", `[
        {"id": 1, "first_name": "Alice"},
        {"id": 2, "first_name": "Bob"}
    ]`);
    db.setTableData("posts", `[
        {"id": 1, "title": "Hello World"},
        {"id": 2, "title": "GraphQL Unions"}
    ]`);

    // Full plugin chain — tests AbstractTypeCastExpr wrapping
    alias FullSchema = ApplyPlugins!(Schema!(Query), FilterPlugin, SortingPlugin);

    auto query = compileQuery!FullSchema(`{
        search {
            __typename
            ... on User { firstName }
            ... on Post { title }
        }
    }`);

    auto executor = new Executor();
    auto result = awaitSync(executor.execute(query));

    auto items = result["search"].array;
    assert(items.length == 4, "Should have 2 users + 2 posts = 4 results");

    JSONValue[] userItems, postItems;
    foreach (item; items) {
        if (item["__typename"].str == "User") userItems ~= item;
        else if (item["__typename"].str == "Post") postItems ~= item;
    }
    assert(userItems.length == 2, "Should have 2 user results");
    assert(postItems.length == 2, "Should have 2 post results");
    assert(userItems[0]["firstName"].str == "Alice");
    assert(postItems[0]["title"].str == "Hello World");
}

// Union type: named fragments (spread) with type conditions
unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dunamis.core;
    import dunamis.core.expr.combinators : unionOf;
    import dunamis.core.types : ImplementedBy;
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import dunamis.graphql.schema : Schema;

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("firstName", string);
    }

    @DemoEntity!(db, "posts")
    static struct Post {
        mixin DemoId;
        mixin Col!("title", string);
    }

    @ImplementedBy!(User, Post)
    static struct SearchResult {}

    static struct Query {
        mixin Table!(User, "users");
        mixin Table!(Post, "posts");

        static auto search(Expr!Query q) {
            return unionOf!SearchResult(users(q), posts(q));
        }
    }

    db = new MockDB!();
    db.setTableData("users", `[
        {"id": 1, "first_name": "Alice"},
        {"id": 2, "first_name": "Bob"}
    ]`);
    db.setTableData("posts", `[
        {"id": 1, "title": "Hello World"},
        {"id": 2, "title": "GraphQL Unions"}
    ]`);

    alias MySchema = Schema!(Query);

    auto query = compileQuery!MySchema(`
        query {
            search {
                ...UserFields
                ...PostFields
            }
        }
        fragment UserFields on User { firstName }
        fragment PostFields on Post { title }
    `);

    auto executor = new Executor();
    auto result = awaitSync(executor.execute(query));

    auto items = result["search"].array;
    assert(items.length == 4, "Should have 2 users + 2 posts = 4 results");

    JSONValue[] userItems, postItems;
    foreach (item; items) {
        if ("firstName" in item) userItems ~= item;
        else if ("title" in item) postItems ~= item;
    }
    assert(userItems.length == 2, "Should have 2 user results");
    assert(postItems.length == 2, "Should have 2 post results");
    assert(userItems[0]["firstName"].str == "Alice");
    assert(postItems[0]["title"].str == "Hello World");
}

// Test: subscription compilation and execution via SubscriptionExecutor
unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dunamis.core;
    import dunamis.core.expr.combinators : EventSourceExpr;
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import dunamis.relational.eval_context;

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("firstName", string);
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    static struct Subscription {
        static Expr!User userCreated(Expr!Subscription s) {
            return eventSource!User();
        }
    }

    alias TestSchema = Schema!(Query, void, Subscription);

    db = new MockDB!();
    db.setTableData("users", `[{"id": 1, "first_name": "Alice"}]`);

    // Compile a subscription query
    auto query = compileQuery!TestSchema(`subscription { userCreated { firstName } }`);
    assert(query !is null);

    // Use SubscriptionExecutor to deliver events
    auto executor = new Executor();
    auto sub = new SubscriptionExecutor!User(executor, query);

    // Deliver an event with a User entity (id=1 → Alice)
    import dunamis.relational.demo : Int64;
    auto result = awaitSync(sub.execute(User(Int64(1))));
    assert("userCreated" in result, "Result should have userCreated field");

    // Verify the field value was actually fetched from the database
    auto userCreated = result["userCreated"];
    assert("firstName" in userCreated, "userCreated should have firstName field: " ~ userCreated.toString());
    assert(userCreated["firstName"].str == "Alice",
        "firstName should be 'Alice', got: " ~ userCreated["firstName"].toString());
}

// Test: subscription rejects multiple root fields
unittest {
    import std.json;
    import dunamis.core;
    import dunamis.core.expr.combinators : EventSourceExpr;
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import dunamis.relational.eval_context;

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("firstName", string);
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    static struct Subscription {
        static Expr!User userCreated(Expr!Subscription s) {
            return eventSource!User();
        }
        static Expr!User userUpdated(Expr!Subscription s) {
            return eventSource!User();
        }
    }

    alias TestSchema = Schema!(Query, void, Subscription);

    db = new MockDB!();

    // Multiple root fields should fail validation
    try {
        compileQuery!TestSchema(`subscription { userCreated { firstName } userUpdated { firstName } }`);
        assert(false, "Should have thrown");
    } catch (ValidationException e) {
        assert(e.errors.length > 0);
        bool foundSingleFieldError = false;
        foreach (err; e.errors) {
            if (err.message == "Subscription operations must have exactly one root field") {
                foundSingleFieldError = true;
                break;
            }
        }
        assert(foundSingleFieldError, "Expected single root field error");
    }
}

// Test: subscription without Subscription type throws
unittest {
    import std.json;
    import dunamis.core;
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import dunamis.relational.eval_context;

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("firstName", string);
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    alias TestSchema = Schema!(Query);

    db = new MockDB!();

    // Subscription on schema without subscription type should fail validation
    try {
        compileQuery!TestSchema(`subscription { userCreated { firstName } }`);
        assert(false, "Should have thrown");
    } catch (CompilerException e) {
        // Validation error about no subscription type
    }
}
