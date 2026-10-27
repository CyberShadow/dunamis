#!/usr/bin/env dub
/+ dub.sdl:
    name "schema_bench"
+/
/// Generates a synthetic schema module, for measuring how the compiler's
/// memory and time grow with the size of a schema (see HACKING.md).
///
/// The schema is shaped like a typical application's: entities with columns
/// and relationships, computed fields (free functions, through
/// `ComputedFieldsPlugin`), and the plugin chain
/// `Schema!`, `ComputedFieldsPlugin`, `FilterPlugin`, `SortingPlugin`,
/// `PaginationPlugin`. With `--ops`, the module also instantiates the GraphQL
/// compiler and SDL generation for the schema, as a server does.
module schema_bench;

import std.array : appender, join;
import std.format : format;
import std.getopt : defaultGetoptPrinter, getopt;
import std.stdio : stdout, writeln;

void main(string[] args) {
    size_t entities = 16, columns = 4, relations = 1;
    size_t scalarFields = 1, objectFields = 0, listFields = 0, mutations = 0;
    bool ops, functionSources;
    auto help = getopt(args,
        "entities", "Number of entities", &entities,
        "columns", "Scalar columns per entity", &columns,
        "relations", "To-one relations (with the inverse to-many) per entity", &relations,
        "scalar-fields", "Scalar computed fields per entity", &scalarFields,
        "object-fields", "To-one (nullable) computed fields per even entity, of the next entity's type", &objectFields,
        "list-fields", "To-many computed fields per even entity, of the next entity's type", &listFields,
        "mutations", "Mutation fields, each returning a payload type of its own", &mutations,
        "ops", "Also instantiate compileQuery, compileQuerySelection and generateSchemaSDL", &ops,
        "function-sources", "Pass the computed field functions to ComputedFieldsPlugin themselves, " ~
            "rather than as a field set", &functionSources,
    );
    if (help.helpWanted) {
        defaultGetoptPrinter("Usage: schema_bench [options] > bench.d", help.options);
        return;
    }
    assert(relations > 0 || (objectFields == 0 && listFields == 0), "computed object fields need relations");
    assert(entities % 2 == 0 || (objectFields == 0 && listFields == 0), "computed object fields need an even number of entities");

    static immutable string[] types = ["string", "int", "Nullable!string", "bool", "Nullable!int", "Color"];
    auto o = appender!string;
    o ~= "module bench;\n\n";
    o ~= "import std.typecons : Nullable;\n";
    o ~= "import dunamis.core : Expr, constant, filterBy, use;\n";
    o ~= "import dunamis.core.expr : fieldAccess, map;\n";
    o ~= "import dunamis.graphql : Schema, ApplyPlugins, FilterPlugin, SortingPlugin, PaginationPlugin;\n";
    o ~= "import dunamis.postgres : PostgresDB;\n";
    o ~= "import dunamis.relational.schema : Entity, PrimaryKey, Col, ForeignKeyCol, BelongsTo, HasMany, Table, hasMany;\n";
    o ~= "import dunamis.schema.computed : ComputedFieldsPlugin;\n\n";
    o ~= "__gshared PostgresDB!() db;\n\n";
    o ~= "enum Color { red, green, blue }\n\n";
    o ~= "private Nullable!E firstOf(E)(int[] ids) { E e; if (ids.length) { e.id = ids[0]; return Nullable!E(e); } return Nullable!E.init; }\n";
    o ~= "private Expr!(Nullable!E) selectFirst(E)(Expr!(E[]) records) { return use(&firstOf!E, map!((Expr!E r) => fieldAccess!\"id\"(r))(records)); }\n\n";

    foreach (i; 0 .. entities) {
        o ~= format("@Entity!(db, \"t%s\", \"E%s\")\nstruct E%s {\n  @PrimaryKey int id;\n", i, i, i);
        foreach (j; 0 .. columns)
            o ~= format("  mixin Col!(\"c%s\", %s, \"c%s\");\n", j, types[j % $], j);
        foreach (k; 0 .. relations) {
            o ~= format("  mixin ForeignKeyCol!(\"r%sId\", E%s, int, \"r%s_id\");\n", k, (i + k + 1) % entities, k);
            o ~= format("  mixin BelongsTo!(\"r%s\", \"r%sId\");\n", k, k);
        }
        foreach (k; 0 .. relations)
            o ~= format("  mixin HasMany!(\"back%s\", E%s, \"r%s_id\");\n", k, (i + entities - k - 1) % entities, k);
        o ~= "}\n\n";
    }
    o ~= "struct Query {\n";
    foreach (i; 0 .. entities)
        o ~= format("  mixin Table!(E%s, \"e%ss\");\n", i, i);
    o ~= "}\n\n";
    o ~= "struct Mutation { static auto placeholder(Expr!Mutation m) { return constant(false, m); } }\n\n";

    string[] names;
    void field(string name) {
        foreach (n; names)
            if (n == name)
                return;
        names ~= name;
    }
    foreach (i; 0 .. entities) {
        foreach (k; 0 .. scalarFields) {
            o ~= format("Expr!string cs%s(Expr!E%s e) { return E%s.c0(e); }\n", k, i, i);
            field(format("cs%s", k));
        }
        // Like point-in-time fields of a temporal schema: parents (even entities) get
        // fields returning their records (odd entities)
        if (i % 2)
            continue;
        auto t = (i + 1) % entities;
        foreach (k; 0 .. objectFields) {
            o ~= format("Expr!(Nullable!E%s) ce%s(Expr!E%s e) { return selectFirst(hasMany!(E%s, \"r0_id\", E%s)(e)); }\n",
                t, k, i, t, i);
            field(format("ce%s", k));
        }
        foreach (k; 0 .. listFields) {
            o ~= format("Expr!(E%s[]) cl%s(Expr!E%s e) { return filterBy!((Expr!E%s r) => E%s.c3(r))(hasMany!(E%s, \"r0_id\", E%s)(e)); }\n",
                t, k, i, t, t, t, i);
            field(format("cl%s", k));
        }
    }
    foreach (k; 0 .. mutations) {
        o ~= format("struct Payload%s { int count; string message; Nullable!string note; }\n", k);
        o ~= format("Expr!Payload%s mut%s(Expr!Mutation m, int arg, Nullable!string comment = Nullable!string.init) " ~
            "{ return use((bool b) => Payload%s(1, \"x\"), constant(true, m)); }\n", k, k, k);
        field(format("mut%s", k));
    }
    o ~= "\n";

    string plugins = "FilterPlugin, SortingPlugin, PaginationPlugin";
    if (names.length) {
        string sources;
        if (functionSources)
            sources = names.join(", ");
        else {
            o ~= "struct BenchFields {\n";
            foreach (n; names)
                o ~= format("  alias %s = .%s;\n", n, n);
            o ~= "}\n";
            sources = "BenchFields";
        }
        plugins = "ComputedFieldsPlugin!(" ~ sources ~ "), " ~ plugins;
    }
    o ~= "alias BenchSchema = ApplyPlugins!(Schema!(Query, Mutation), " ~ plugins ~ ");\n";
    o ~= "alias BenchQuery = BenchSchema.Query;\n";
    if (ops) {
        o ~= "\nimport std.json : JSONValue;\n";
        o ~= "import graphql.ast : SelectionSet;\n";
        o ~= "import dunamis.graphql : GraphQLResult, compileQuery, compileQuerySelection, generateSchemaSDL;\n";
        o ~= "GraphQLResult benchCompile(string q, JSONValue v) { return compileQuery!BenchSchema(q, v); }\n";
        o ~= "GraphQLResult benchCompileSelection(SelectionSet s, JSONValue v) { return compileQuerySelection!BenchSchema(s, v); }\n";
        o ~= "string benchSDL() { return generateSchemaSDL!BenchSchema; }\n";
    }
    stdout.write(o.data);
}
