/// Unit tests for the interaction of FilterPlugin with PaginationPlugin and
/// SortingPlugin: the plugin order determines the order in which a field's
/// `filter`, `orderBy` and `first`/`offset` arguments apply, in both execution
/// modes. With FilterPlugin before PaginationPlugin, the filter selects the
/// rows the window is taken from; with FilterPlugin after it, the filter is
/// applied to the window.
module dunamis.schema.filter_pagination_tests;

version (unittest):

import std.conv : to;
import std.json : JSONValue;

import ae.utils.promise.await : awaitSync;

import dunamis.core : Executor;
import dunamis.graphql.compiler : compileQuery;
import dunamis.graphql.schema : Schema;
import dunamis.relational.demo : MockDB;
import dunamis.relational.schema : BelongsTo, Col, Entity, ForeignKey, HasMany, PrimaryKey, Table;
import dunamis.schema.crud : CrudMutationPlugin;
import dunamis.schema.filtering : FilterPlugin;
import dunamis.schema.pagination : PaginationPlugin;
import dunamis.schema.plugin : ApplyPlugins;
import dunamis.schema.sorting : SortingPlugin;

private MockDB!() fpDb;

@Entity!(fpDb, "fp_accounts")
private struct FpAccount {
    @PrimaryKey int id;
    mixin Col!("category", string);
    mixin Col!("customerId", ForeignKey!FpCustomer);
    mixin BelongsTo!("customer", "customerId");
}

@Entity!(fpDb, "fp_customers")
private struct FpCustomer {
    @PrimaryKey int id;
    mixin Col!("name", string);
    mixin HasMany!("accounts", FpAccount, "customer_id");
}

@Entity!(fpDb, "fp_products")
private struct FpProduct {
    @PrimaryKey int id;
    mixin Col!("name", string);
    mixin Col!("accountId", ForeignKey!FpAccount);
    mixin BelongsTo!("account", "accountId");
}

private struct FpQuery {
    mixin Table!(FpCustomer, "customers");
    mixin Table!(FpAccount, "accounts");
    mixin Table!(FpProduct, "products");
}

/// Customers 1..11 each have one "R" account (id = customer id) with one product
/// (id = customer id); customer 12 has one "M" account and product (id 12);
/// customer 13 has no accounts.  Every customer/product name is "v<id>"/"p<id>".
private void seed() {
    fpDb = new MockDB!();
    JSONValue[] customers, accounts, products;
    foreach (i; 1 .. 14) {
        customers ~= JSONValue(["id": JSONValue(i), "name": JSONValue("v" ~ i.to!string)]);
        if (i == 13) continue;
        accounts ~= JSONValue(["id": JSONValue(i), "category": JSONValue(i == 12 ? "M" : "R"),
            "customer_id": JSONValue(i)]);
        products ~= JSONValue(["id": JSONValue(i), "name": JSONValue("p" ~ i.to!string),
            "account_id": JSONValue(i)]);
    }
    fpDb.setTableData("fp_customers", customers);
    fpDb.setTableData("fp_accounts", accounts);
    fpDb.setTableData("fp_products", products);
}

private long[] ids(alias S)(string field, string args, bool optimize) {
    auto result = awaitSync(new Executor().execute(
        compileQuery!S(`{ ` ~ field ~ `(` ~ args ~ `) { id } }`), optimize));
    long[] found;
    foreach (row; result[field].array)
        found ~= row["id"].integer;
    return found;
}

private void check(alias S)(string field, string args, long[] expected, bool optimize) {
    auto found = ids!S(field, args, optimize);
    assert(found == expected, S.stringof ~ (optimize ? " (optimized) " : " (naive) ") ~
        field ~ "(" ~ args ~ "): expected " ~ expected.to!string ~ ", got " ~ found.to!string);
}

/// The documented order (filter, then sort, then window), the same with
/// SortingPlugin first, and with FilterPlugin last (window, then filter).
private alias FilterFirst = ApplyPlugins!(Schema!FpQuery, CrudMutationPlugin, FilterPlugin, SortingPlugin, PaginationPlugin);
private alias FilterMiddle = ApplyPlugins!(Schema!FpQuery, SortingPlugin, FilterPlugin, PaginationPlugin);
private alias FilterLast = ApplyPlugins!(Schema!FpQuery, SortingPlugin, PaginationPlugin, FilterPlugin);

/// Check a query against each plugin order: `filtered` is the expected
/// result where the filter applies before the window, `windowed` where it
/// applies to the window.
/// (MockDB, not a SQL data source, evaluates no WHERE clauses: optimized,
/// filters are evaluated in memory too; the Postgres integration suite
/// covers their SQL.)
private void checkOrders(string field, string args, long[] filtered, long[] windowed, bool optimize) {
    check!FilterFirst(field, args, filtered, optimize);
    check!FilterMiddle(field, args, filtered, optimize);
    check!FilterLast(field, args, windowed, optimize);
}

/// Relationship filters.
unittest {
    foreach (optimize; [false, true]) {
        seed();
        enum m = `{some: {category: {equalTo: "M"}}}`;
        enum r = `{category: {equalTo: "R"}}`;

        // BelongsTo
        checkOrders("products", `first: 2, filter: {account: {category: {equalTo: "M"}}}`, [12], [], optimize);
        checkOrders("products", `first: 2, offset: 1, filter: {account: ` ~ r ~ `}`, [2, 3], [2, 3], optimize);
        checkOrders("products", `first: 2, filter: {account: ` ~ r ~ `}, orderBy: [{field: id, direction: DESC}]`,
            [11, 10], [11], optimize);

        // HasMany some/every/none
        checkOrders("customers", `first: 10, filter: {accounts: ` ~ m ~ `}`, [12], [], optimize);
        checkOrders("customers", `first: 1, filter: {accounts: {none: ` ~ r ~ `}}`, [12], [], optimize);
        checkOrders("customers", `first: 5, offset: 1, filter: {accounts: {none: ` ~ r ~ `}}`, [13], [], optimize);
        checkOrders("customers", `first: 3, offset: 10, filter: {accounts: {every: ` ~ r ~ `}}`, [11, 13], [11, 13], optimize);
        checkOrders("customers", `first: 2, filter: {accounts: {some: ` ~ r ~ `}}, orderBy: [{field: id, direction: DESC}]`,
            [11, 10], [], optimize);
        checkOrders("customers", `first: 2, offset: 1, filter: {accounts: {every: ` ~ r ~ `}}, orderBy: [{field: id, direction: DESC}]`,
            [11, 10], [11], optimize);

        // Combined with a scalar condition (as a search typically does)
        checkOrders("customers", `first: 10, filter: {name: {equalTo: "v12"}, accounts: ` ~ m ~ `}`, [12], [], optimize);
        checkOrders("customers", `first: 13, filter: {name: {equalTo: "v12"}, accounts: ` ~ m ~ `}`, [12], [12], optimize);
        checkOrders("customers", `first: 10, filter: {name: {equalTo: "v11"}, accounts: ` ~ m ~ `}`, [], [], optimize);
    }
}

/// Scalar root filters.
unittest {
    foreach (optimize; [false, true]) {
        seed();
        checkOrders("accounts", `first: 2, filter: {category: {equalTo: "M"}}`, [12], [], optimize);
        checkOrders("accounts", `first: 2, offset: 10, filter: {category: {equalTo: "R"}}`, [11], [11], optimize);
        checkOrders("accounts", `first: 2, filter: {category: {equalTo: "R"}}, orderBy: [{field: id, direction: DESC}]`,
            [11, 10], [11], optimize);
        checkOrders("customers", `first: 1, filter: {name: {equalTo: "v13"}}`, [13], [], optimize);
    }
}

/// Nested (HasMany) fields follow the plugin order too.
unittest {
    foreach (optimize; [false, true]) {
        seed();
        // Customer 12's only account is its "M" one, customer 1's is "R".
        enum query = `{
            customers(filter: {id: {in: [1, 12]}}) {
                id
                accounts(first: 1, filter: {category: {equalTo: "M"}}) { id }
            }
        }`;
        static foreach (S; AliasSeq!(FilterFirst, FilterMiddle, FilterLast)) {{
            auto result = awaitSync(new Executor().execute(compileQuery!S(query), optimize));
            auto customers = result["customers"].array;
            assert(customers.length == 2 && customers[0]["id"].integer == 1 && customers[1]["id"].integer == 12,
                S.stringof ~ ": " ~ result.toString());
            assert(customers[0]["accounts"].array.length == 0, S.stringof ~ ": " ~ result.toString());
            auto cs = customers[1]["accounts"].array;
            assert(cs.length == 1 && cs[0]["id"].integer == 12, S.stringof ~ ": " ~ result.toString());
        }}
    }
}

/// Names derived from the root type (the sort order input types of its
/// fields) do not depend on which plugins wrapped it before SortingPlugin.
unittest {
    import std.algorithm : canFind;
    import dunamis.graphql.schema : generateSchemaSDL;

    static foreach (S; AliasSeq!(FilterFirst, FilterMiddle, FilterLast)) {{
        enum sdl = generateSchemaSDL!S;
        static assert(sdl.canFind("input _OrderByStruct_Query_customers {"), sdl);
        static assert(!sdl.canFind("FilteredQuery"), sdl);
    }}
}

private alias AliasSeq(T...) = T;

/// A conditional collection (onlyIf) of a root collection: the collection,
/// or nothing (without evaluating it) (the Postgres integration suite
/// covers a filter over it being pushed into the root collection's query).
unittest {
    import dunamis.core.expr : Expr, constant, fieldAccess, map, onlyIf, singleton, use;
    import dunamis.core.filtering : filterBy;

    seed();
    foreach (optimize; [false, true])
        foreach (condition; [false, true]) {
            auto q = singleton(FpQuery.init);
            auto tree = map!((Expr!FpAccount c) => FpAccount.category(c))(
                filterBy!((Expr!FpAccount c) => FpAccount.category(c).eq("M"))(
                    onlyIf(constant(condition, q), FpQuery.accounts(q))));
            auto executor = new Executor();
            if (optimize) {
                auto found = awaitSync(executor.execute(tree));
                string[] expected = condition ? ["M"] : null;
                assert(found == expected, found.to!string);
            } else {
                auto found = awaitSync(executor.execute(tree, false));
                string[] expected = condition ? ["M"] : null;
                assert(found == expected, found.to!string);
            }
        }

    // The source is not evaluated where the condition does not hold
    auto q = singleton(FpQuery.init);
    auto failing = use((bool _) { if (_) throw new Exception("evaluated"); return cast(FpAccount[]) null; },
        constant(true, q));
    FpAccount[] none = awaitSync(new Executor().execute(onlyIf(constant(false, q), failing), false));
    assert(none.length == 0);
}
