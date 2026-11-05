/// Unit tests for the default filter vocabulary: the string operators
/// (PostGraphile's connection filter's: includes, startsWith, endsWith,
/// like, their `Insensitive` and `not` forms, equalToInsensitive), the
/// Boolean `in`/`notIn`, and the array field filters (contains,
/// containedBy, overlaps, anyEqualTo, anyNotEqualTo), in both execution
/// modes. (The Postgres integration suite covers their SQL.)
module dunamis.schema.filter_vocabulary_tests;

version (unittest):

import std.algorithm : canFind;
import std.conv : to;
import std.typecons : Nullable;

import ae.utils.promise.await : awaitSync;

import dunamis.core : Executor;
import dunamis.graphql.compiler : compileQuery;
import dunamis.graphql.schema : Schema, generateSchemaSDL;
import dunamis.relational.demo : MockDB;
import dunamis.relational.schema : Col, Entity, PrimaryKey, Table;
import dunamis.schema.filtering : DefaultFilterSurface, FilterPlugin, FilterPluginWith;
import dunamis.core.expr : Expr;
import dunamis.schema.pagination : PaginationPlugin;
import dunamis.schema.plugin : ApplyPlugins;
import dunamis.schema.sorting : SortingPlugin;

enum FvColor { red, green, blue }

private MockDB!() fvDb;

@Entity!(fvDb, "fv_items")
private struct FvItem {
    @PrimaryKey int id;
    mixin Col!("name", string);
    mixin Col!("note", Nullable!string);
    mixin Col!("active", bool);
    mixin Col!("tagIds", Nullable!int[], "tag_ids");
    mixin Col!("colors", Nullable!FvColor[]);
}

private struct FvQuery {
    mixin Table!(FvItem, "items", ["id"]);
}

private alias FvSchema = ApplyPlugins!(Schema!FvQuery, FilterPlugin, SortingPlugin, PaginationPlugin);

/// Items: 1 "Alpha_1" (note "x%y"), 2 "alpha 2" (no note), 3 "Beta" (note
/// "ALPHA"), 4 "a\b" (note "b").
private void seed() {
    fvDb = new MockDB!();
    fvDb.setTableData("fv_items", `[
        {"id": 1, "name": "Alpha_1", "note": "x%y", "active": true, "tag_ids": [1, 2], "colors": ["red"]},
        {"id": 2, "name": "alpha 2", "note": null, "active": false, "tag_ids": [2, null], "colors": ["green", "blue"]},
        {"id": 3, "name": "Beta", "note": "ALPHA", "active": true, "tag_ids": [], "colors": []},
        {"id": 4, "name": "a\\b", "note": "b", "active": false, "tag_ids": [3], "colors": ["blue", null]}
    ]`);
}

private void check(string filter, long[] expected) {
    foreach (optimize; [false, true]) {
        seed();
        auto result = awaitSync(new Executor().execute(compileQuery!FvSchema(
            `{ items(filter: ` ~ filter ~ `) { id } }`), optimize));
        long[] found;
        foreach (row; result["items"].array)
            found ~= row["id"].integer;
        assert(found == expected, (optimize ? "(optimized) " : "(naive) ") ~ filter ~ ": expected " ~
            expected.to!string ~ ", got " ~ found.to!string);
    }
}

// The types and their operators
unittest {
    enum sdl = generateSchemaSDL!FvSchema;
    foreach (op; ["includes", "notIncludes", "includesInsensitive", "notIncludesInsensitive", "startsWith",
            "notStartsWith", "startsWithInsensitive", "notStartsWithInsensitive", "endsWith", "notEndsWith",
            "endsWithInsensitive", "notEndsWithInsensitive", "like", "notLike", "likeInsensitive",
            "notLikeInsensitive", "equalToInsensitive", "notEqualToInsensitive"])
        assert(sdl.canFind("\n  " ~ op ~ ": String\n"), op);
    // (Not the former synonyms of includes / includesInsensitive)
    static assert(!sdl.canFind("  contains: String\n") && !sdl.canFind("containsInsensitive"), sdl);
    static assert(sdl.canFind("input BooleanFilter {\n  equalTo: Boolean\n  notEqualTo: Boolean\n  in: [Boolean!]\n  notIn: [Boolean!]\n"), sdl);
    static assert(sdl.canFind("  tagIds: IntListFilter\n") && sdl.canFind("  colors: FvColorListFilter\n"), sdl);
    static assert(sdl.canFind("input IntListFilter {\n  isNull: Boolean\n  equalTo: [Int]\n  notEqualTo: [Int]\n" ~
        "  contains: [Int]\n  containedBy: [Int]\n" ~
        "  overlaps: [Int]\n  anyEqualTo: Int\n  anyNotEqualTo: Int\n}"), sdl);
    static assert(sdl.canFind("input FvColorListFilter {"), sdl);
}

// String operators: literal operands (wildcards escaped), patterns, case
// and negation; on a nullable column, only non-null values match
unittest {
    check(`{name: {includes: "lpha"}}`, [1, 2]);
    check(`{name: {includes: "_"}}`, [1]);              // (not a wildcard)
    check(`{name: {notIncludes: "lpha"}}`, [3, 4]);
    check(`{name: {includesInsensitive: "ALPHA"}}`, [1, 2]);
    check(`{name: {notIncludesInsensitive: "ALPHA"}}`, [3, 4]);
    check(`{name: {startsWith: "Al"}}`, [1]);
    check(`{name: {notStartsWith: "Al"}}`, [2, 3, 4]);
    check(`{name: {startsWithInsensitive: "AL"}}`, [1, 2]);
    check(`{name: {notStartsWithInsensitive: "AL"}}`, [3, 4]);
    check(`{name: {endsWith: "a"}}`, [3]);
    check(`{name: {notEndsWith: "a"}}`, [1, 2, 4]);
    check(`{name: {endsWithInsensitive: "TA"}}`, [3]);
    check(`{name: {notEndsWithInsensitive: "TA"}}`, [1, 2, 4]);
    check(`{name: {like: "%lpha_%"}}`, [1, 2]);         // (`_`: any one character)
    check(`{name: {notLike: "%lpha%"}}`, [3, 4]);
    check(`{name: {likeInsensitive: "%ALPHA%"}}`, [1, 2]);
    check(`{name: {notLikeInsensitive: "a%"}}`, [3]);
    check(`{name: {equalToInsensitive: "BETA"}}`, [3]);
    check(`{name: {equalToInsensitive: "bet_"}}`, []);   // (literal)
    check(`{name: {notEqualToInsensitive: "BETA"}}`, [1, 2, 4]);
    check(`{note: {includes: "%"}}`, [1]);
    check(`{note: {notIncludes: "%"}}`, [3, 4]);        // (not the null note)
    check(`{note: {likeInsensitive: "alpha"}}`, [3]);
    check(`{note: {notEqualToInsensitive: "b"}}`, [1, 3]);
}

// Boolean in / notIn
unittest {
    check(`{active: {in: [true]}}`, [1, 3]);
    check(`{active: {in: [true, false]}}`, [1, 2, 3, 4]);
    check(`{active: {notIn: [true]}}`, [2, 4]);
}

// Array fields (null elements match nothing, as in PostgreSQL)
unittest {
    check(`{tagIds: {equalTo: [2, null]}}`, [2]);
    check(`{tagIds: {equalTo: []}}`, [3]);
    check(`{tagIds: {notEqualTo: [3]}}`, [1, 2, 3]);
    check(`{colors: {equalTo: [green, blue]}}`, [2]);
    check(`{tagIds: {contains: [2]}}`, [1, 2]);
    check(`{tagIds: {contains: [1, 2]}}`, [1]);
    check(`{tagIds: {contains: []}}`, [1, 2, 3, 4]);
    check(`{tagIds: {contains: [null]}}`, []);
    check(`{tagIds: {containedBy: [1, 2, 3]}}`, [1, 3, 4]);
    check(`{tagIds: {overlaps: [3, 1]}}`, [1, 4]);
    check(`{tagIds: {anyEqualTo: 2}}`, [1, 2]);
    check(`{tagIds: {anyNotEqualTo: 2}}`, [1, 4]);
    check(`{tagIds: {isNull: false}}`, [1, 2, 3, 4]);
    check(`{colors: {contains: [blue]}}`, [2, 4]);
    check(`{colors: {containedBy: [red, green, blue]}}`, [1, 2, 3]);
    check(`{colors: {anyEqualTo: green}, tagIds: {anyEqualTo: 2}}`, [2]);
    check(`{or: [{colors: {overlaps: [red]}}, {tagIds: {contains: [3]}}]}`, [1, 4]);
}

// Escapes in operands: a backslash, and escaped wildcards, given as variables
// and as (escaped) string literals
unittest {
    import std.array : replace;
    import std.json : JSONValue;
    void checkOperand(string op, string operand, long[] expected) {
        const literal = `"` ~ operand.replace(`\`, `\\`).replace(`"`, `\"`) ~ `"`;
        foreach (optimize; [false, true]) {
            foreach (query; [
                compileQuery!FvSchema(`query($v: String!) { items(filter: {name: {` ~ op ~ `: $v}}) { id } }`,
                    JSONValue(["v": operand])),
                compileQuery!FvSchema(`{ items(filter: {name: {` ~ op ~ `: ` ~ literal ~ `}}) { id } }`),
            ]) {
                seed();
                auto result = awaitSync(new Executor().execute(query, optimize));
                long[] found;
                foreach (row; result["items"].array)
                    found ~= row["id"].integer;
                assert(found == expected, op ~ " " ~ operand ~ ": expected " ~ expected.to!string ~ ", got " ~ found.to!string);
            }
        }
    }
    checkOperand("includes", `\`, [4]);
    checkOperand("includes", `a\b`, [4]);
    checkOperand("like", `%\_%`, [1]);
    checkOperand("like", `a\\b`, [4]);
    checkOperand("likeInsensitive", `A\%`, []);
}

/// A second argument surface: `named: <name>`, on lists of items, besides
/// the default `filter`.
template FvNamedSurface(Scope, string fieldName, Element) {
    import dunamis.schema.plugin : getOriginalTypeName;
    static if (getOriginalTypeName!Element == "FvItem") {
        alias Argument = FvItemName;
        enum string argumentName = "named";
        static Expr!bool predicate(Expr!Element item, const ref Argument argument) {
            return Element.name(item).eq(argument.name);
        }
    }
}

struct FvItemName { string name; }

private alias FvNamedSchema = ApplyPlugins!(Schema!FvQuery,
    FilterPluginWith!(FvNamedSurface, DefaultFilterSurface), SortingPlugin, PaginationPlugin);

// Several surfaces: each an argument (in the surfaces' order), whose
// conditions the elements must all satisfy
unittest {
    enum sdl = generateSchemaSDL!FvNamedSchema;
    static assert(sdl.canFind("items(named: FvItemName = null, filter: FvItemFilter, orderBy: "), sdl);
    foreach (optimize; [false, true]) {
        long[] ids(string arguments) {
            seed();
            auto result = awaitSync(new Executor().execute(compileQuery!FvNamedSchema(
                `{ items(` ~ arguments ~ `) { id } }`), optimize));
            long[] found;
            foreach (row; result["items"].array)
                found ~= row["id"].integer;
            return found;
        }
        assert(ids(`named: {name: "Beta"}`) == [3]);
        assert(ids(`named: {name: "Beta"}, filter: {active: {equalTo: false}}`) == []);
        assert(ids(`filter: {active: {equalTo: false}}`) == [2, 4]);
        assert(ids(``) == [1, 2, 3, 4]);
    }
}
