/// Tests that input object values (literals and variables) with fields their
/// type does not define are rejected as validation errors.
module dunamis.graphql.compiler.input_validation_tests;

version (unittest):

import std.algorithm : canFind;
import std.conv : to;
import std.json : JSONValue, parseJSON;

import dunamis.graphql.compiler : compileQuery;
import dunamis.graphql.compiler.validation : ValidationError, ValidationException;
import dunamis.graphql.schema : Schema;
import dunamis.relational.demo : MockDB;
import dunamis.relational.schema : BelongsTo, Col, Entity, ForeignKeyCol, HasMany, PrimaryKey, Table;
import dunamis.schema.filtering : FilterPlugin;
import dunamis.schema.plugin : ApplyPlugins;
import dunamis.schema.sorting : SortingPlugin;

private MockDB!() ivDb;

@Entity!(ivDb, "iv_authors")
private struct IvAuthor {
    @PrimaryKey int id;
    mixin Col!("name", string);
    mixin HasMany!("books", IvBook, "author_id");
}

@Entity!(ivDb, "iv_books")
private struct IvBook {
    @PrimaryKey int id;
    mixin Col!("title", string);
    mixin ForeignKeyCol!("authorId", IvAuthor);
    mixin BelongsTo!("author", "authorId");
}

private struct IvQuery {
    mixin Table!(IvAuthor, "authors");
    mixin Table!(IvBook, "books");
}

private alias IvSchema = ApplyPlugins!(Schema!IvQuery, FilterPlugin, SortingPlugin);

/// The validation errors compiling `query` gives.
private ValidationError[] errorsOf(string query, string variables = "{}") {
    ivDb = new MockDB!();
    try {
        compileQuery!IvSchema(query, parseJSON(variables));
    } catch (ValidationException e) {
        return e.errors;
    }
    return null;
}

private void expectError(string query, string variables, string message, uint line, ushort column) {
    auto errors = errorsOf(query, variables);
    assert(errors.length == 1, query ~ ": expected one error, got " ~ errors.to!string);
    assert(errors[0].message == message, query ~ ": " ~ errors[0].message);
    assert(errors[0].line == line && errors[0].column == column,
        query ~ ": error at " ~ errors[0].line.to!string ~ ":" ~ errors[0].column.to!string);
}

// Unknown fields in literals, at any depth, are reported where they are.
unittest {
    expectError(`{ books(filter: {titel: {equalTo: "x"}}) { id } }`, "{}",
        `Field "titel" is not defined by type "IvBookFilter".`, 1, 18);
    expectError(`{ books(filter: {title: {equalsTo: "x"}}) { id } }`, "{}",
        `Field "equalsTo" is not defined by type "StringFilter".`, 1, 26);
    expectError("{\n  authors(filter: {books: {some: {author: {nam: {equalTo: \"x\"}}}}}) { id }\n}", "{}",
        `Field "nam" is not defined by type "IvAuthorFilter".`, 2, 44);
    expectError(`{ authors(filter: {books: {any: {title: {equalTo: "x"}}}}) { id } }`, "{}",
        `Field "any" is not defined by type "IvBookFilterListFilter".`, 1, 28);
    // In lists and combinators
    expectError(`{ books(filter: {or: [{title: {equalTo: "a"}}, {name: {equalTo: "b"}}]}) { id } }`, "{}",
        `Field "name" is not defined by type "IvBookFilter".`, 1, 49);
    expectError(`{ books(filter: {not: {author: {books: {every: {x: {equalTo: 1}}}}}}) { id } }`, "{}",
        `Field "x" is not defined by type "IvBookFilter".`, 1, 49);
    // Nested fields of the sort order input
    expectError(`{ books(orderBy: [{field: id, direction: ASC, nulls: FIRST}]) { id } }`, "{}",
        `Field "nulls" is not defined by type "_OrderByStruct_Query_books".`, 1, 47);

    // Every unknown field is reported.
    auto errors = errorsOf(`{ books(filter: {a: {b: 1}, title: {b: "x"}}) { id } a: authors(filter: {c: {d: 1}}) { id } }`);
    assert(errors.length == 3, errors.to!string);

    // Known fields are fine.
    assert(errorsOf(`{ authors(filter: {books: {some: {author: {name: {equalTo: "x"}}}}, ` ~
        `or: [{name: {in: ["a"]}}], not: {id: {equalTo: 1}}}) { id } }`).length == 0);
}

// Unknown fields in variables' values are reported at the variable's use.
unittest {
    enum query = "query($f: IvBookFilter) {\n  books(filter: $f) { id }\n}";
    expectError(query, `{"f": {"titel": {"equalTo": "x"}}}`,
        `Variable "$f" got invalid value; Field "titel" is not defined by type "IvBookFilter".`, 2, 17);
    expectError(query, `{"f": {"author": {"books": {"some": {"title": {"eq": "x"}}}}}}`,
        `Variable "$f" got invalid value at "author.books.some.title"; ` ~
        `Field "eq" is not defined by type "StringFilter".`, 2, 17);
    expectError(query, `{"f": {"or": [{"title": {"equalTo": "x"}}, {"x": null}]}}`,
        `Variable "$f" got invalid value at "or[1]"; Field "x" is not defined by type "IvBookFilter".`, 2, 17);
    assert(errorsOf(query, `{"f": {"author": {"name": {"equalTo": "x"}}, "or": []}}`).length == 0);
    assert(errorsOf(query, `{"f": null}`).length == 0);

    // A variable within a literal
    expectError("query($t: StringFilter) {\n  books(filter: {title: $t}) { id }\n}",
        `{"t": {"equalTo": "x", "unknown": 1}}`,
        `Variable "$t" got invalid value; Field "unknown" is not defined by type "StringFilter".`, 2, 25);

    // Variables not declared by the operation are ignored (as the spec says).
    assert(errorsOf(query, `{"f": {}, "other": {"titel": 1}}`).length == 0);
}

// Variables in list literals are resolved and validated like the list's
// other items, and empty input objects are input objects without fields.
unittest {
    import std.algorithm : map, sort;
    import std.array : array;
    import ae.utils.promise.await : awaitSync;
    import dunamis.core : Executor;

    long[] bookIds(string query, string variables) {
        ivDb = new MockDB!();
        ivDb.setTableData("iv_books", `[{"id":1,"title":"a"},{"id":2,"title":"b"},{"id":3,"title":"c"}]`);
        auto expression = compileQuery!IvSchema(query, parseJSON(variables));
        auto result = awaitSync(new Executor().execute(expression));
        return result["books"].array.map!(book => book["id"].integer).array.sort.release;
    }

    assert(bookIds(`query($a: String!) { books(filter: {title: {in: [$a, "c"]}}) { id } }`,
        `{"a": "a"}`) == [1, 3]);
    assert(bookIds(`query($a: String!, $b: String!) { books(filter: {title: {in: [$a, $b]}}) { id } }`,
        `{"a": "b", "b": "c"}`) == [2, 3]);
    assert(bookIds(`query($f: IvBookFilter!) { books(filter: {or: [$f, {title: {equalTo: "c"}}]}) { id } }`,
        `{"f": {"title": {"equalTo": "a"}}}`) == [1, 3]);
    assert(bookIds(`{ books(filter: {}) { id } }`, `{}`) == [1, 2, 3]);

    expectError("query($f: IvBookFilter) {\n  books(filter: {or: [$f]}) { id }\n}",
        `{"f": {"titel": {"equalTo": "x"}}}`,
        `Variable "$f" got invalid value; Field "titel" is not defined by type "IvBookFilter".`, 2, 23);
    assert(errorsOf(`{ books(filter: {or: [{}], title: {}}) { id } }`).length == 0);
}
