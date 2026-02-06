module dynamo.graphql.type_mapping;

import std.meta : AliasSeq;
import dynamo.core.types : SchemaConfig;
import dynamo.graphql.schema : isSchema;

/// Plugin that adds external type mappings to a schema.
///
/// Allows mapping D types to GraphQL-visible types without modifying
/// the original type. Maps are applied at every type unwrapping level
/// (Nullable, arrays), so `Nullable!Date` with a `Date → string` mapping
/// becomes `Nullable!string` in the GraphQL schema.
///
/// Example:
/// ---
/// import dynamo.core.types : TypeMapping;
///
/// alias MySchema = ExternalTypesPlugin!(
///     Schema!(Query, Mutation),
///     TypeMapping!(Date, string,
///         (Date d) => d.toISOExtString,
///         (string s) => Date.fromISOExtString(s)),
/// );
/// ---
template ExternalTypesPlugin(alias S, NewMappings...) if (isSchema!S) {
    alias Query = S.Query;
    alias Mutation = S.Mutation;

    // Merge new mappings with any existing ones from the inner schema
    alias Config = SchemaConfig!(AliasSeq!(S.Config.typeMappings, NewMappings));

    // Forward AllEntityTypes if inner schema has it (from other plugins)
    static if (__traits(hasMember, S, "AllEntityTypes")) {
        alias AllEntityTypes = S.AllEntityTypes;
    }

    // Forward EntityTypeMap if inner schema has it (from other plugins)
    static if (__traits(hasMember, S, "EntityTypeMap")) {
        template EntityTypeMap(T) {
            alias EntityTypeMap = S.EntityTypeMap!T;
        }
    }
}

// SDL generation: mapped types in plain methods and computed field args
unittest {
    import std.algorithm : canFind;
    import std.typecons : Nullable;
    import dynamo.core.types : TypeMapping;
    import dynamo.graphql.schema : Schema, generateSchemaSDL;
    import dynamo.relational.demo : DemoEntity, MockDB;
    import dynamo.relational.schema : Col, Table;
    import dynamo.core.expr : Expr;

    static struct Date {
        int year, month, day;
    }

    alias DateMapping = TypeMapping!(Date, string,
        function string(Date d) {
            import std.conv : to;
            return d.year.to!string ~ "-" ~ d.month.to!string ~ "-" ~ d.day.to!string;
        },
        function Date(string s) {
            import std.conv : to;
            import std.array : split;
            auto parts = s.split("-");
            return Date(parts[0].to!int, parts[1].to!int, parts[2].to!int);
        });

    static MockDB!() db;

    static struct Event {
        mixin DemoEntity!(db, "events");
        mixin Col!("title", string);

        // Plain method returning mapped type
        Date startDate() => Date(2024, 1, 15);

        // Plain method returning Nullable mapped type
        Nullable!Date endDate() => Nullable!Date.init;

        // Computed field taking mapped type as argument
        static auto eventsAfter(Expr!Event e, Date since) {
            return e.title;
        }
    }

    static struct Query {
        mixin Table!(Event, "events");
    }

    // Without mapping: Date appears as an object/input type
    enum sdlWithout = generateSchemaSDL!Query;
    static assert(sdlWithout.canFind("type Date"), "Date is a POD object type without mapping");
    static assert(sdlWithout.canFind("startDate: Date!"));

    // With mapping: Date → String
    alias MappedSchema = ExternalTypesPlugin!(Schema!(Query), DateMapping);
    enum sdlWith = generateSchemaSDL!MappedSchema;
    static assert(sdlWith.canFind("startDate: String!"), "Plain method returning mapped type → String!");
    static assert(sdlWith.canFind("endDate: String"), "Plain method returning Nullable mapped type → nullable String");
    static assert(sdlWith.canFind("since: String!"), "Computed field arg with mapped type → String!");
    static assert(!sdlWith.canFind("type Date"), "Date type should not appear with mapping");
}

// SDL generation: mapped types in POD struct fields
unittest {
    import std.algorithm : canFind;
    import std.typecons : Nullable;
    import dynamo.core.types : TypeMapping;
    import dynamo.graphql.schema : Schema, generateSchemaSDL;
    import dynamo.relational.demo : DemoEntity, MockDB;
    import dynamo.relational.schema : Col, Table;
    import dynamo.core.expr : Expr;

    static struct Timestamp {
        long epochMs;
    }

    alias TsMapping = TypeMapping!(Timestamp, string,
        (Timestamp t) => "2024-01-15T00:00:00Z",
        (string s) => Timestamp(0));

    // POD type with mapped fields
    static struct DateRange {
        Timestamp start;
        Nullable!Timestamp end;
    }

    static MockDB!() db;

    static struct User {
        mixin DemoEntity!(db, "users");
        mixin Col!("name", string);

        // Plain method returning POD with mapped-type fields
        DateRange activePeriod() => DateRange(Timestamp(0), Nullable!Timestamp.init);
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    alias MappedSchema = ExternalTypesPlugin!(Schema!(Query), TsMapping);
    enum sdl = generateSchemaSDL!MappedSchema;
    static assert(sdl.canFind("activePeriod: DateRange!"), "Plain method returning POD type");
    static assert(sdl.canFind("type DateRange"), "POD type discovered");
    static assert(sdl.canFind("start: String!"), "POD field with mapped type → String!");
    static assert(sdl.canFind("end: String"), "Nullable POD field with mapped type → nullable String");
    static assert(!sdl.canFind("scalar Timestamp"), "Timestamp scalar should not appear");
}

// Introspection reflects mapped types
unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dynamo.core;
    import dynamo.core.types : TypeMapping;
    import dynamo.relational.schema;
    import dynamo.relational.demo;
    import dynamo.graphql.schema : Schema;
    import dynamo.graphql.compiler : compileQuery;

    static struct Date {
        int year, month, day;
    }

    alias DateMapping = TypeMapping!(Date, string,
        (Date d) => "2024-01-15",
        (string s) => Date(2024, 1, 15));

    static MockDB!() db;

    static struct Event {
        mixin DemoEntity!(db, "events");
        mixin Col!("title", string);

        Date startDate() => Date(2024, 1, 15);
    }

    static struct Query {
        mixin Table!(Event, "events");
    }

    alias MappedSchema = ExternalTypesPlugin!(Schema!(Query), DateMapping);

    db = new MockDB!();

    auto executor = new Executor();

    auto query = compileQuery!MappedSchema(`{
        __type(name: "Event") {
            fields {
                name
                type { name kind ofType { name } }
            }
        }
    }`);

    auto result = awaitSync(executor.execute(query));
    auto fields = result["__type"]["fields"].array;

    bool foundStartDate = false;
    foreach (f; fields) {
        if (f["name"].str == "startDate") {
            foundStartDate = true;
            // Should be NON_NULL wrapping String (mapped from Date)
            assert(f["type"]["kind"].str == "NON_NULL");
            assert(f["type"]["ofType"]["name"].str == "String");
        }
    }
    assert(foundStartDate, "startDate field should be in introspection");
}

// Input deserialization through mapping
unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dynamo.core;
    import dynamo.core.expr : Expr, effect;
    import dynamo.core.types : TypeMapping;
    import dynamo.relational.schema;
    import dynamo.relational.demo;
    import dynamo.relational.eval_context;
    import dynamo.graphql.schema : Schema;
    import dynamo.graphql.compiler : compileQuery;

    static struct Date {
        int year, month, day;
    }

    alias DateMapping = TypeMapping!(Date, string,
        function string(Date d) {
            import std.conv : to;
            return d.year.to!string ~ "-" ~ d.month.to!string ~ "-" ~ d.day.to!string;
        },
        function Date(string s) {
            import std.conv : to;
            import std.array : split;
            auto parts = s.split("-");
            return Date(parts[0].to!int, parts[1].to!int, parts[2].to!int);
        });

    __gshared static Date capturedDate;

    static MockDB!() db;

    static struct User {
        mixin DemoEntity!(db, "users");
        mixin Col!("name", string);

        static auto eventsAfter(Expr!User u, Date since) {
            return effect(() {
                capturedDate = since;
                return "ok";
            }, u);
        }
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    alias MappedSchema = ExternalTypesPlugin!(Schema!(Query), DateMapping);

    db = new MockDB!();
    db.setTableData("users", `[{"id": 1, "name": "Alice"}]`);

    // Pass a string argument that should be deserialized to Date via mapping
    auto query = compileQuery!MappedSchema(`{
        users {
            eventsAfter(since: "2024-6-15")
        }
    }`);

    auto executor = new Executor();
    auto result = awaitSync(executor.execute(query));

    auto users = result["users"].array;
    assert(users.length == 1);
    assert(users[0]["eventsAfter"].str == "ok");
    // Verify the Date was properly deserialized from the string
    assert(capturedDate.year == 2024);
    assert(capturedDate.month == 6);
    assert(capturedDate.day == 15);
}
