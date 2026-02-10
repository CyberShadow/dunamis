module dunamis.graphql.schema;

public import dunamis.graphql.schema.udas;
public import dunamis.graphql.schema.fields;
public import dunamis.graphql.schema.input_types;
public import dunamis.graphql.schema.discovery;
public import dunamis.graphql.schema.generation;

// Re-export Schema and isSchema from the schema layer for backward compatibility
public import dunamis.schema : Schema, isSchema;

// ============================================================================
// Tests
// ============================================================================

unittest {
    import dunamis.core.types : CustomScalar, isCustomScalar;
    import std.conv : to;
    import std.json : JSONValue, JSONType;
    import std.typecons : Nullable;

    // Test built-in GraphQL scalars
    static assert(graphqlTypeName!string == "String!");
    static assert(graphqlTypeName!int == "Int!");
    static assert(graphqlTypeName!bool == "Boolean!");
    static assert(graphqlTypeName!float == "Float!");
    static assert(graphqlTypeName!double == "Float!");
    static assert(graphqlTypeName!(string[]) == "[String!]!");

    // Test Nullable types (no "!" suffix)
    static assert(graphqlTypeName!(Nullable!string) == "String");
    static assert(graphqlTypeName!(Nullable!int) == "Int");

    // Test base type names (without "!")
    static assert(graphqlBaseTypeName!string == "String");
    static assert(graphqlBaseTypeName!int == "Int");
    static assert(graphqlBaseTypeName!(Nullable!string) == "String");

    // Test custom scalars
    alias Int64 = CustomScalar!(
        long, "Int64",
        (long v) => JSONValue(v),
        (JSONValue j) => j.type == JSONType.integer ? j.integer : j.str.to!long
    );
    static assert(isCustomScalar!Int64);
    static assert(graphqlTypeName!Int64 == "Int64!");
    static assert(graphqlBaseTypeName!Int64 == "Int64");
    static assert(graphqlTypeName!(Nullable!Int64) == "Int64");

    // Verify unsupported types would error (can't test static assert failure directly)
    // graphqlTypeName!long would fail: "No GraphQL type mapping for `long`..."
}

// Test that UDAs on mixin templates propagate to generated members
unittest {
    import std.meta : staticIndexOf;

    // Simple mixin template that generates a marker
    mixin template TestCol(string name) {
        mixin("enum _marker_" ~ name ~ " = true;");
    }

    static struct TestEntity {
        @GqlHidden
        mixin TestCol!"hidden";

        mixin TestCol!"visible";
    }

    // Check if UDA propagates to generated member
    static if (__traits(hasMember, TestEntity, "_marker_hidden")) {
        alias attrs = __traits(getAttributes, __traits(getMember, TestEntity, "_marker_hidden"));
        static assert(attrs.length == 1, "Expected 1 attribute on hidden marker, got " ~ attrs.length.stringof);
        // GqlHidden is an enum, so check if it's in the attributes
        static assert(staticIndexOf!(GqlHidden, attrs) >= 0, "Expected GqlHidden attribute");
    }

    static if (__traits(hasMember, TestEntity, "_marker_visible")) {
        alias attrs2 = __traits(getAttributes, __traits(getMember, TestEntity, "_marker_visible"));
        static assert(attrs2.length == 0, "Expected no attributes on visible marker");
    }
}

// Test @GqlHidden with actual Col mixin
unittest {
    import std.algorithm : canFind;
    import dunamis.relational.demo : DemoEntity, DemoId, MockDB;
    import dunamis.relational.schema : Col;

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("name", string);

        @GqlHidden
        mixin Col!("passwordHash", string);
    }

    // Check that getFields detects hidden field
    enum fields = getFields!User;
    static assert(fields.length == 3);

    // Find the passwordHash field and verify it's hidden
    bool foundPasswordHash = false;
    foreach (f; fields) {
        if (f.name == "passwordHash") {
            foundPasswordHash = true;
            assert(f.hidden, "passwordHash should be hidden");
        }
        if (f.name == "name") {
            assert(!f.hidden, "name should not be hidden");
        }
    }
    assert(foundPasswordHash, "passwordHash field should exist");

    // Verify SDL doesn't include hidden field
    enum sdl = generateObjectTypeSDL!User(getGraphQLTypeName!User);
    assert(sdl.canFind("name:"), "SDL should include name field");
    assert(!sdl.canFind("passwordHash"), "SDL should NOT include passwordHash field");
}

// Test that plain fields (struct instance fields) are detected by getFields
unittest {
    import std.algorithm : canFind;
    import std.typecons : Nullable;
    import dunamis.relational.demo : DemoEntity, DemoId, MockDB;
    import dunamis.relational.schema : Col;

    static MockDB!() db;

    @DemoEntity!(db, "persons")
    static struct Person {
        mixin DemoId;
        mixin Col!("name", string);  // Column field

        // Plain fields (struct instance fields)
        string nickname;
        Nullable!string bio;
    }

    enum fields = getFields!Person;

    // Should have: id (from DemoEntity), name (Col), nickname, bio
    static assert(fields.length == 4, "Expected 4 fields (id, name, nickname, bio)");

    // Check each field
    bool foundNickname = false;
    bool foundBio = false;
    foreach (f; fields) {
        if (f.name == "nickname") {
            foundNickname = true;
            assert(f.graphqlType == "String!", "nickname should be String! type");
        }
        if (f.name == "bio") {
            foundBio = true;
            assert(f.graphqlType == "String", "bio should be nullable String type");
        }
    }
    assert(foundNickname, "nickname plain field should be detected");
    assert(foundBio, "bio plain field should be detected");

    // Verify SDL includes plain fields
    enum sdl = generateObjectTypeSDL!Person(getGraphQLTypeName!Person);
    assert(sdl.canFind("nickname:"), "SDL should include nickname field");
    assert(sdl.canFind("bio:"), "SDL should include bio field");
}

// Test @GqlDescription and @GqlDeprecated UDAs
unittest {
    import std.algorithm : canFind;
    import dunamis.relational.demo : DemoEntity, DemoId, MockDB;
    import dunamis.relational.schema : Col;

    static MockDB!() db;

    @DemoEntity!(db, "articles")
    static struct Article {
        mixin DemoId;

        @GqlDescription("The article title")
        mixin Col!("title", string);

        @GqlDescription("Main content")
        @GqlDeprecated("Use content instead")
        mixin Col!("body", string);

        mixin Col!("plain", string);  // No annotations
    }

    // Check that getFields extracts description and deprecation
    enum fields = getFields!Article;

    bool foundTitle = false;
    bool foundBody = false;
    bool foundPlain = false;

    foreach (f; fields) {
        if (f.name == "title") {
            foundTitle = true;
            assert(f.description == "The article title", "title should have description");
            assert(f.deprecation == "", "title should not be deprecated");
        }
        if (f.name == "body") {
            foundBody = true;
            assert(f.description == "Main content", "body should have description");
            assert(f.deprecation == "Use content instead", "body should be deprecated");
        }
        if (f.name == "plain") {
            foundPlain = true;
            assert(f.description == "", "plain should have no description");
            assert(f.deprecation == "", "plain should not be deprecated");
        }
    }
    assert(foundTitle && foundBody && foundPlain, "All fields should exist");

    // Verify SDL output
    enum sdl = generateObjectTypeSDL!Article(getGraphQLTypeName!Article);

    // Should have description as doc string
    assert(sdl.canFind(`"""The article title"""`), "SDL should include title description");
    assert(sdl.canFind(`"""Main content"""`), "SDL should include body description");

    // Should have @deprecated directive
    assert(sdl.canFind(`@deprecated(reason: "Use content instead")`), "SDL should include deprecation");

    // Plain field should exist without annotations
    assert(sdl.canFind("plain: String!"), "plain field should exist in SDL");
}

// Test Schema template
unittest {
    import dunamis.relational.demo : DemoEntity, DemoId, MockDB;
    import dunamis.relational.schema : Col, Table, getAll;

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("name", string);
    }

    static struct MyQuery {
        mixin Table!(User, "users");
    }

    // Schema without mutations
    alias MySchema = Schema!(MyQuery);

    // Verify Schema properties
    static assert(isSchema!MySchema);
    static assert(getFields!(MySchema.Mutation).length == 0);  // No mutation fields

    // generateSchemaSDL should work with Schema
    enum sdlFromSchema = generateSchemaSDL!MySchema;

    // Verify SDL contains expected content
    import std.algorithm : canFind;
    static assert(sdlFromSchema.canFind("type Query"));
    static assert(sdlFromSchema.canFind("users: [User!]!"));
    static assert(sdlFromSchema.canFind("type User"));
}

// Test isSchema with non-schema types
unittest {
    static struct NotASchema {
        int x;
    }

    static struct AlsoNotASchema {
        alias Query = int;  // Has Query but not Mutation
    }

    static assert(!isSchema!NotASchema);
    static assert(!isSchema!int);
}

// Test mutation SDL generation
unittest {
    import std.algorithm : canFind;
    import dunamis.core.expr : Expr;
    import dunamis.relational.demo : DemoEntity, DemoId, MockDB;
    import dunamis.relational.schema : Col, Table, getAll;

    static MockDB!() db;

    // Define an entity for mutation results
    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("name", string);
    }

    // Input type for mutations
    static struct CreateUserInput {
        string name;
        string email;
    }

    // Mutation type with various mutation patterns
    // Mutations take Expr!Mutation as first param (ignored) and return Expr!T
    static struct MyMutation {
        import dunamis.core.expr : effect;

        // Simple mutation returning entity
        static Expr!User createUser(Expr!MyMutation parent, CreateUserInput input) {
            return effect(() => User.init, parent);
        }

        // Mutation returning scalar
        static Expr!bool deleteUser(Expr!MyMutation parent, int id) {
            return effect(() => true, parent);
        }

        // Mutation with optional parameter
        static Expr!string greet(Expr!MyMutation parent, string name, string greeting = "Hello") {
            return effect(() => greeting ~ " " ~ name, parent);
        }

        @GqlDescription("Updates a user's profile")
        @GqlDeprecated("Use updateUserV2 instead")
        static Expr!User updateUser(Expr!MyMutation parent, int id, CreateUserInput input) {
            return effect(() => User.init, parent);
        }
    }

    static struct MyQuery {
        mixin Table!(User, "users");
    }

    // Schema with mutations
    alias MySchema = Schema!(MyQuery, MyMutation);

    // Verify Schema properties
    static assert(isSchema!MySchema);
    static assert(getFields!(MySchema.Mutation).length > 0);  // Has mutation fields

    // Check getFields extracts fields correctly
    enum mutationFields = getFields!MyMutation;
    static assert(mutationFields.length == 4, "Should have 4 mutation fields");

    // Verify SDL generation
    enum sdl = generateSchemaSDL!MySchema;

    // Should include Query type
    static assert(sdl.canFind("type Query"));
    static assert(sdl.canFind("users: [User!]!"));

    // Should include Mutation type
    static assert(sdl.canFind("type Mutation"));

    // Check mutation signatures
    static assert(sdl.canFind("createUser(input: CreateUserInput!): User!"),
        "createUser mutation should have correct signature");
    static assert(sdl.canFind("deleteUser(id: Int!): Boolean!"),
        "deleteUser mutation should have correct signature");
    static assert(sdl.canFind("greet(name: String!, greeting: String = "),
        "greet mutation should have optional parameter");

    // Check UDAs on mutations
    static assert(sdl.canFind(`"""Updates a user's profile"""`),
        "Should have description comment");
    static assert(sdl.canFind(`@deprecated(reason: "Use updateUserV2 instead")`),
        "Should have deprecation directive");

    // Should include User entity type
    static assert(sdl.canFind("type User"));

    // Should include input type
    static assert(sdl.canFind("input CreateUserInput"));
}

// Test Schema without mutations generates no Mutation type
unittest {
    import std.algorithm : canFind;
    import dunamis.relational.demo : DemoEntity, DemoId, MockDB;
    import dunamis.relational.schema : Col, Table, getAll;

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("name", string);
    }

    static struct MyQuery {
        mixin Table!(User, "users");
    }

    // Schema without mutations
    alias MySchema = Schema!(MyQuery);

    enum sdl = generateSchemaSDL!MySchema;

    // Should have Query but not Mutation
    static assert(sdl.canFind("type Query"));
    static assert(!sdl.canFind("type Mutation"),
        "Schema without mutations should not have type Mutation");
}

// Test enum support in GraphQL schema
unittest {
    import std.algorithm : canFind;
    import std.typecons : Nullable;
    import dunamis.relational.demo : DemoEntity, DemoId, MockDB;
    import dunamis.relational.schema : Col, Table, getAll;

    // Define a D enum
    enum Status { pending, inProgress, completed }

    static MockDB!() db;

    @DemoEntity!(db, "tasks")
    static struct Task {
        mixin DemoId;
        mixin Col!("title", string);
        mixin Col!("status", Status);
    }

    static struct MyQuery {
        mixin Table!(Task, "tasks");
    }

    // Test type name mapping
    static assert(graphqlTypeName!Status == "Status!");
    static assert(graphqlBaseTypeName!Status == "Status");
    static assert(graphqlTypeName!(Nullable!Status) == "Status");

    // Test enum detection
    static assert(isGraphQLEnum!Status);
    static assert(!isGraphQLEnum!string);
    static assert(!isGraphQLEnum!int);

    // Test SDL generation
    enum sdl = generateSchemaSDL!MyQuery;

    // Should contain enum definition
    static assert(sdl.canFind("enum Status"), "SDL should contain enum Status: " ~ sdl);
    static assert(sdl.canFind("pending"), "SDL should contain pending: " ~ sdl);
    static assert(sdl.canFind("inProgress"), "SDL should contain inProgress: " ~ sdl);
    static assert(sdl.canFind("completed"), "SDL should contain completed: " ~ sdl);

    // Task type should have status field
    static assert(sdl.canFind("status: Status!"), "Task should have status: Status! field: " ~ sdl);
}

// Test nested input type discovery
unittest {
    import std.algorithm : canFind;
    import dunamis.relational.demo : DemoEntity, DemoId, MockDB;
    import dunamis.relational.schema : Col, Table;

    // Nested input types
    static struct Inner {
        string x;
    }

    static struct Outer {
        string y;
        Inner inner;
    }

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("name", string);

        // Computed field with nested input type
        static auto format(Expr!User u, Outer options) {
            return u.name;
        }
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    enum sdl = generateSchemaSDL!Query;

    // Both input types should be discovered
    static assert(sdl.canFind("input Outer"), "SDL should contain input Outer: " ~ sdl);
    static assert(sdl.canFind("input Inner"), "SDL should contain input Inner: " ~ sdl);

    static assert(sdl.canFind("inner: Inner!"), "Outer should have inner: Inner! field: " ~ sdl);
}

// Test self-referential input type via array
unittest {
    import std.algorithm : canFind;
    import dunamis.relational.demo : DemoEntity, DemoId, MockDB;
    import dunamis.relational.schema : Col, Table;

    // Self-referential via array
    static struct FilterInput {
        string field;
        FilterInput[] and;  // Self-reference via array
    }

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("name", string);

        static auto filter(Expr!User u, FilterInput f) {
            return u.name;
        }
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    enum sdl = generateSchemaSDL!Query;

    // FilterInput should appear in SDL
    static assert(sdl.canFind("input FilterInput"), "SDL should contain input FilterInput: " ~ sdl);
    static assert(sdl.canFind("and: [FilterInput!]!"), "FilterInput should have and field: " ~ sdl);
}

// Test self-referential input type via pointer
unittest {
    import std.algorithm : canFind;
    import dunamis.relational.demo : DemoEntity, DemoId, MockDB;
    import dunamis.relational.schema : Col, Table;

    // Self-referential via pointer (nullable reference)
    static struct NodeInput {
        string value;
        NodeInput* next;  // Self-reference via pointer
    }

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("name", string);

        static auto traverse(Expr!User u, NodeInput* head) {
            return u.name;
        }
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    enum sdl = generateSchemaSDL!Query;

    // NodeInput should appear in SDL
    static assert(sdl.canFind("input NodeInput"), "SDL should contain input NodeInput: " ~ sdl);
    // next should be nullable (pointer = nullable reference)
    static assert(sdl.canFind("next: NodeInput") && !sdl.canFind("next: NodeInput!"),
        "NodeInput.next should be nullable: " ~ sdl);
}

// Test deeply nested input types via pointer
unittest {
    import std.algorithm : canFind;
    import dunamis.relational.demo : DemoEntity, DemoId, MockDB;
    import dunamis.relational.schema : Col, Table;

    // Deeply nested via pointer (A -> B -> C via pointers)
    static struct TypeC {
        string z;
    }

    static struct TypeB {
        string y;
        TypeC* c;
    }

    static struct TypeA {
        string x;
        TypeB* b;
    }

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("name", string);

        static auto process(Expr!User u, TypeA input) {
            return u.name;
        }
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    enum sdl = generateSchemaSDL!Query;

    // All three types should be discovered
    static assert(sdl.canFind("input TypeA"), "SDL should contain input TypeA: " ~ sdl);
    static assert(sdl.canFind("input TypeB"), "SDL should contain input TypeB: " ~ sdl);
    static assert(sdl.canFind("input TypeC"), "SDL should contain input TypeC: " ~ sdl);
    // Pointer references should be nullable
    static assert(sdl.canFind("b: TypeB") && !sdl.canFind("b: TypeB!"),
        "TypeA.b should be nullable: " ~ sdl);
    static assert(sdl.canFind("c: TypeC") && !sdl.canFind("c: TypeC!"),
        "TypeB.c should be nullable: " ~ sdl);
}

// Test POD type with only plain fields is recognized as object type
unittest {
    import std.algorithm : canFind;

    // POD struct with only plain fields (no computed fields)
    static struct Range {
        int start;
        int end;
    }

    // Range should be recognized as an object type (has plain fields)
    static assert(isObjectType!Range, "Range should be an object type (has plain fields)");

    // Range fields should be discoverable
    enum rangeFields = getFields!Range;
    static assert(rangeFields.length == 2, "Range should have 2 fields (start, end)");

    // Verify field names using CTFE
    enum foundStartEnd = () {
        bool foundStart = false;
        bool foundEnd = false;
        foreach (f; rangeFields) {
            if (f.name == "start") foundStart = true;
            if (f.name == "end") foundEnd = true;
        }
        return foundStart && foundEnd;
    }();
    static assert(foundStartEnd, "Range should have start and end fields");
}

// Test POD type with plain methods is recognized as object type
unittest {
    import std.algorithm : canFind;

    // POD struct with plain fields and plain methods
    static struct Stats {
        int count;
        int total;

        int average() => total / count;
    }

    // Stats should be recognized as an object type (has plain fields and methods)
    static assert(isObjectType!Stats, "Stats should be an object type (has plain fields and methods)");

    // Stats fields should include plain method
    enum statsFields = getFields!Stats;
    static assert(statsFields.length == 3, "Stats should have 3 fields (count, total, average)");
}

// Test POD type discovery through plain method return type
unittest {
    import std.algorithm : canFind;
    import dunamis.relational.demo : DemoEntity, DemoId, MockDB;
    import dunamis.relational.schema : Col, Table;

    // POD struct to be returned by plain method
    static struct UserStats {
        int postCount;
        int commentCount;

        int totalActivity() => postCount + commentCount;
    }

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("name", string);

        // Plain method returning POD struct
        UserStats stats() => UserStats(1, 2);
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    // UserStats should be recognized as an object type
    static assert(isObjectType!UserStats, "UserStats should be an object type");

    // UserStats should be discovered from User
    alias relatedTypes = getRelatedTypes!User;
    static assert(staticContains!(UserStats, relatedTypes),
        "UserStats should be discovered from User via plain method return type");

    // SDL should include UserStats type
    enum sdl = generateSchemaSDL!Query;
    static assert(sdl.canFind("type UserStats"), "SDL should contain type UserStats: " ~ sdl);
    static assert(sdl.canFind("postCount: Int!"), "UserStats should have postCount field: " ~ sdl);
    static assert(sdl.canFind("totalActivity: Int!"), "UserStats should have totalActivity method: " ~ sdl);
}

// Test POD type discovery through plain field type (schema-only test)
// Note: POD types as plain fields is primarily for schema generation.
// Runtime evaluation of nested POD types from SQL is not supported by the relational layer.
unittest {
    import std.algorithm : canFind;

    // POD struct used as plain field type
    static struct Coordinates {
        int x;
        int y;
    }

    // Container struct with POD field (no Entity mixin - just testing schema layer)
    static struct Location {
        string name;
        Coordinates coords;  // Plain field with POD type
    }

    // Coordinates should be recognized as an object type
    static assert(isObjectType!Coordinates, "Coordinates should be an object type");

    // Location should also be an object type (has plain fields)
    static assert(isObjectType!Location, "Location should be an object type");

    // Coordinates should be discovered from Location
    alias relatedTypes = getRelatedTypes!Location;
    static assert(staticContains!(Coordinates, relatedTypes),
        "Coordinates should be discovered from Location via plain field type");

    // Verify Location fields are discovered
    enum locationFields = getFields!Location;
    static assert(locationFields.length == 2, "Location should have 2 fields (name, coords)");
}

// Test nested POD type discovery (schema-only test)
unittest {
    import std.algorithm : canFind;

    // Nested POD structs
    static struct Inner {
        int value;
    }

    static struct Outer {
        string label;
        Inner inner;  // Nested POD
    }

    // Both should be object types
    static assert(isObjectType!Inner, "Inner should be an object type");
    static assert(isObjectType!Outer, "Outer should be an object type");

    // Inner should be discovered from Outer
    alias relatedTypes = getRelatedTypes!Outer;
    static assert(staticContains!(Inner, relatedTypes),
        "Inner should be discovered from Outer via plain field type");
}

// Test Nullable POD type discovery (schema-only test)
unittest {
    import std.algorithm : canFind;
    import std.typecons : Nullable;

    // POD struct
    static struct Badge {
        string name;
        int level;
    }

    // Container with nullable POD field (no Entity mixin - just testing schema layer)
    static struct Profile {
        string username;
        Nullable!Badge badge;  // Nullable POD field
    }

    // Badge should be recognized as object type
    static assert(isObjectType!Badge, "Badge should be an object type");

    // Badge should be discovered from Profile (through Nullable wrapper)
    alias relatedTypes = getRelatedTypes!Profile;
    static assert(staticContains!(Badge, relatedTypes),
        "Badge should be discovered from Profile via Nullable plain field type");

    // Verify fields
    enum profileFields = getFields!Profile;
    static assert(profileFields.length == 2, "Profile should have 2 fields (username, badge)");
}

// Test array of POD type discovery (schema-only test)
unittest {
    import std.algorithm : canFind;

    // POD struct
    static struct Tag {
        string name;
        string color;
    }

    // Container with array of POD (no Entity mixin - just testing schema layer)
    static struct Article {
        string title;
        Tag[] tags;  // Array of POD
    }

    // Tag should be recognized as object type
    static assert(isObjectType!Tag, "Tag should be an object type");

    // Tag should be discovered from Article (through array)
    alias relatedTypes = getRelatedTypes!Article;
    static assert(staticContains!(Tag, relatedTypes),
        "Tag should be discovered from Article via array plain field type");
}

// Test fixpoint entity type discovery with deep POD chain (depth > 4)
unittest {
    import dunamis.core.expr : Expr;

    // Chain of 7 POD types linked via plain fields:
    // Query -> L0 -> L1 -> L2 -> L3 -> L4 -> L5
    // Old 4-level expansion would miss L4 and L5.

    static struct L5 { string value; }
    static struct L4 { string name; L5 child; }
    static struct L3 { string name; L4 child; }
    static struct L2 { string name; L3 child; }
    static struct L1 { string name; L2 child; }
    static struct L0 { string name; L1 child; }

    static struct DeepQuery {
        static Expr!(L0[]) items(Expr!DeepQuery self) { assert(false); }
    }

    alias AllTypes = getAllObjectTypes!DeepQuery;
    static assert(staticContains!(L0, AllTypes), "L0 should be discovered");
    static assert(staticContains!(L1, AllTypes), "L1 should be discovered");
    static assert(staticContains!(L2, AllTypes), "L2 should be discovered");
    static assert(staticContains!(L3, AllTypes), "L3 should be discovered");
    static assert(staticContains!(L4, AllTypes), "L4 should be discovered");
    static assert(staticContains!(L5, AllTypes), "L5 should be discovered");
}
