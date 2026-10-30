/// Regression tests of the relational optimizer and evaluation over MockDB:
/// results which must not depend on what other fields of the same request
/// query or write.
module dunamis.regression_tests;

version (unittest):

import std.json : JSONValue, parseJSON;

import ae.utils.promise.await : awaitSync;

import dunamis.core : Executor;
import dunamis.core.expr : Expr, use;
import dunamis.graphql.compiler : compileQuery;
import dunamis.graphql.schema : Schema;
import dunamis.relational.demo : DemoEntity, DemoId, Int64, MockDB;
import dunamis.relational.mutation : insert;
import dunamis.relational.schema : Col, Table, getAll;
import dunamis.schema.filtering : FilterPlugin;
import dunamis.schema.pagination : PaginationPlugin;
import dunamis.schema.plugin : ApplyPlugins;
import dunamis.schema.sorting : SortingPlugin;

private MockDB!() regDb;

@DemoEntity!(regDb, "reg_people")
private struct RegPerson {
    mixin DemoId;
    mixin Col!("name", string);
}

private struct RegQuery {
    mixin Table!(RegPerson, "people");

    /// The number of people: a root collection which is not a list field's
    static Expr!long peopleCount(Expr!RegQuery q) {
        return use((RegPerson[] people) => cast(long) people.length, getAll!RegPerson());
    }
}

private struct RegMutation {
    static auto createPerson(Expr!RegMutation m, string name) {
        return insert!RegPerson(["name": JSONValue(name)]);
    }

    /// An existing person (not one the mutation wrote)
    static auto firstPerson(Expr!RegMutation m) {
        return use((RegMutation _) => RegPerson(Int64(1)), m);
    }
}

private alias RegSchema = ApplyPlugins!(Schema!(RegQuery, RegMutation), FilterPlugin, SortingPlugin, PaginationPlugin);

private void seed() {
    regDb = new MockDB!();
    regDb.setTableData("reg_people", `[
        {"id": 1, "name": "Ann"},
        {"id": 2, "name": "Ben"},
        {"id": 3, "name": "Cid"}
    ]`);
}

// A root collection read by a field (here, counted) is all the rows, also
// next to a paginated field of the same table (whose query has a LIMIT)
unittest {
    foreach (optimize; [false, true]) {
        seed();
        auto result = awaitSync(new Executor().execute(compileQuery!RegSchema(
            `{ people(first: 1) { name } peopleCount }`), optimize));
        assert(result == parseJSON(`{"people": [{"name": "Ann"}], "peopleCount": 3}`), result.toString());
    }
}
