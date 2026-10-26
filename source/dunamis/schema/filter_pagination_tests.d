/// Unit tests for the interaction of FilterPlugin with PaginationPlugin and
/// SortingPlugin: a field's `filter` argument selects the rows that its
/// `first`/`offset` window is then taken from, whatever the plugin order.
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

/// Plugin orders in use: filter outermost, and the documented one.
private alias FilterLast = ApplyPlugins!(Schema!FpQuery, SortingPlugin, PaginationPlugin, FilterPlugin);
private alias FilterFirst = ApplyPlugins!(Schema!FpQuery, CrudMutationPlugin, FilterPlugin, SortingPlugin, PaginationPlugin);
private alias FilterMiddle = ApplyPlugins!(Schema!FpQuery, SortingPlugin, FilterPlugin, PaginationPlugin);

/// Relationship filters are evaluated in memory, which MockDB supports in
/// both execution modes.
unittest {
    static foreach (S; AliasSeq!(FilterLast, FilterFirst, FilterMiddle)) {
        foreach (optimize; [false, true]) {
            seed();
            enum m = `{some: {category: {equalTo: "M"}}}`;
            enum r = `{category: {equalTo: "R"}}`;

            // BelongsTo
            check!S("products", `first: 2, filter: {account: {category: {equalTo: "M"}}}`, [12], optimize);
            check!S("products", `first: 2, offset: 1, filter: {account: ` ~ r ~ `}`, [2, 3], optimize);
            check!S("products", `first: 2, filter: {account: ` ~ r ~ `}, orderBy: [{field: id, direction: DESC}]`,
                [11, 10], optimize);

            // HasMany some/every/none
            check!S("customers", `first: 10, filter: {accounts: ` ~ m ~ `}`, [12], optimize);
            check!S("customers", `first: 1, filter: {accounts: {none: ` ~ r ~ `}}`, [12], optimize);
            check!S("customers", `first: 5, offset: 1, filter: {accounts: {none: ` ~ r ~ `}}`, [13], optimize);
            check!S("customers", `first: 3, offset: 10, filter: {accounts: {every: ` ~ r ~ `}}`, [11, 13], optimize);
            check!S("customers", `first: 2, filter: {accounts: {some: ` ~ r ~ `}}, orderBy: [{field: id, direction: DESC}]`,
                [11, 10], optimize);
            check!S("customers", `first: 2, offset: 1, filter: {accounts: {every: ` ~ r ~ `}}, orderBy: [{field: id, direction: DESC}]`,
                [11, 10], optimize);

            // Combined with a scalar condition (as a search typically does)
            check!S("customers", `first: 10, filter: {name: {equalTo: "v12"}, accounts: ` ~ m ~ `}`, [12], optimize);
            check!S("customers", `first: 10, filter: {name: {equalTo: "v11"}, accounts: ` ~ m ~ `}`, [], optimize);
        }
    }
}

/// Scalar root filters.  MockDB ignores SQL WHERE clauses, so these only run
/// naively here; the optimized path is covered by the Postgres integration suite.
unittest {
    static foreach (S; AliasSeq!(FilterLast, FilterFirst, FilterMiddle)) {
        seed();
        check!S("accounts", `first: 2, filter: {category: {equalTo: "M"}}`, [12], false);
        check!S("accounts", `first: 2, offset: 10, filter: {category: {equalTo: "R"}}`, [11], false);
        check!S("accounts", `first: 2, filter: {category: {equalTo: "R"}}, orderBy: [{field: id, direction: DESC}]`,
            [11, 10], false);
        check!S("customers", `first: 1, filter: {name: {equalTo: "v13"}}`, [13], false);
    }
}

/// Nested (HasMany) fields: the filter applies before the per-parent window.
unittest {
    static foreach (S; AliasSeq!(FilterLast, FilterFirst, FilterMiddle)) {
        foreach (optimize; [false, true]) {
            seed();
            auto result = awaitSync(new Executor().execute(compileQuery!S(`{
                customers(filter: {id: {equalTo: 12}}) {
                    id
                    accounts(first: 1, filter: {category: {equalTo: "M"}}) { id }
                }
            }`), optimize));
            // MockDB ignores the root WHERE when optimizing; look up customer 12.
            bool seen;
            foreach (v; result["customers"].array) {
                if (v["id"].integer != 12) continue;
                seen = true;
                auto cs = v["accounts"].array;
                assert(cs.length == 1 && cs[0]["id"].integer == 12, S.stringof ~ ": " ~ result.toString());
            }
            assert(seen, result.toString());
        }
    }
}

private alias AliasSeq(T...) = T;
