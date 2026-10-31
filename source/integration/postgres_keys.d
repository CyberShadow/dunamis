/**
 * Keys of rows which need quoting, on PostgreSQL.
 *
 * The local id of a ref (`Type:key`) encodes the values of the row's key
 * (see `dunamis.core.types.encodeCompositeKey`): a string value containing a
 * comma or a double quote (or empty, or with outer spaces) is quoted. The
 * refs of rows, of their parents (by foreign keys) and of their children (by
 * the keys of their parents) must all encode a key alike, on the optimized
 * and on the naive path, for the rows and relationships of such keys to be
 * found.
 */
module integration.postgres_keys;

import std.algorithm : map, sort;
import std.array : array;
import std.conv : to;
import std.json : JSONValue;
import std.typecons : Nullable;

import ae.utils.promise.await : await;

import dunamis.core.datasource : DataSource, SetupMode;
import dunamis.core.eval : EvalContext;
import dunamis.core.expr : Expr, evaluateNested, fieldAccess, jsonObject, map, use;
import dunamis.core.types : AnyRef, queryRoot;
import dunamis.postgres : PostgresSession;
import dunamis.relational.schema : Entity, PrimaryKey, Col, ForeignKeyCol, BelongsTo, HasMany, getAll, getByIds;

import integration.postgres_test : db, onEventLoop;
import integration.test_framework : assertTrue;

@Entity!(db, "quoted_key_parents", "QuotedKeyParent")
struct QuotedKeyParent {
    @PrimaryKey string code;
    mixin Col!("label", string);
    mixin HasMany!("children", QuotedKeyChild, "parent_code");
}

@Entity!(db, "quoted_key_children", "QuotedKeyChild")
struct QuotedKeyChild {
    @PrimaryKey int id;
    mixin ForeignKeyCol!("parentCode", QuotedKeyParent, string, "parent_code");
    mixin BelongsTo!("parent", "parentCode");
    mixin ForeignKeyCol!("otherCode", QuotedKeyParent, Nullable!string, "other_code");
    mixin BelongsTo!("other", "otherCode");
}

/// The keys (each the parent of the child of its index + 1, and the other
/// parent of the next child), and their labels
private immutable string[] codes = ["a,b", `say "hi"`, " sp ", "", "plain", "o'k"];

private string labelOf(string code) {
    return "<" ~ code ~ ">";
}

/// Rows, parents and children of keys which need quoting, of the optimized
/// and of the naive path.
void testKeysNeedingQuotes() {
    onEventLoop(() {
        auto ctx = new EvalContext();
        auto session = cast(PostgresSession) ctx.getSession(db);
        session.setup().await;
        scope (exit) session.teardown(SetupMode.query, false).await;

        session.execute("CREATE TEMP TABLE quoted_key_parents (code text PRIMARY KEY, label text)").await;
        session.execute("CREATE TEMP TABLE quoted_key_children (id integer PRIMARY KEY, parent_code text, " ~
            "other_code text)").await;
        foreach (i, code; codes) {
            auto literal = "'" ~ code.replace("'", "''") ~ "'";
            auto other = i + 1 < codes.length ? "'" ~ codes[i + 1].replace("'", "''") ~ "'" : "NULL";
            session.execute("INSERT INTO quoted_key_parents VALUES (" ~ literal ~ ", '" ~
                labelOf(code).replace("'", "''") ~ "')").await;
            session.execute("INSERT INTO quoted_key_children VALUES (" ~ (i + 1).to!string ~ ", " ~ literal ~ ", " ~
                other ~ ")").await;
        }

        foreach (optimized; [true, false]) {
            auto mode = optimized ? "optimized: " : "naive: ";
            T run(T)(Expr!T expr) {
                if (optimized)
                    return evaluateNested(expr, ctx).await;
                auto s = ctx.createScope();
                s.setValues!AnyRef(null, [queryRoot]);
                return expr.eval(s).await[0];
            }

            // Rows and their children (by their parents' keys)
            auto parents = run(map!((Expr!QuotedKeyParent p) => jsonObject("code", fieldAccess!"code"(p), "label", p.label,
                "children", map!((Expr!QuotedKeyChild c) => fieldAccess!"id"(c))(p.children)))(getAll!QuotedKeyParent()));
            assertTrue(parents.length == codes.length, mode ~ "parents: " ~ parents.to!string);
            foreach (parent; parents) {
                auto code = parent["code"].str;
                auto i = codes.countUntilOf(code);
                assertTrue(i >= 0 && parent["label"].str == labelOf(code), mode ~ "parent: " ~ parent.toString());
                assertTrue(parent["children"].array.map!(c => c.integer).array == [i + 1],
                    mode ~ "children of " ~ parent.toString());
            }

            // Parents of children (by their foreign keys): required, and nullable
            auto children = run(map!((Expr!QuotedKeyChild c) => jsonObject("id", fieldAccess!"id"(c),
                "parent", c.parent.label,
                "other", use((Nullable!QuotedKeyParent o) => o.isNull ? "-" : o.get.code, c.other)))(
                getAll!QuotedKeyChild()));
            assertTrue(children.length == codes.length, mode ~ "children: " ~ children.to!string);
            foreach (child; children) {
                auto i = cast(size_t) child["id"].integer - 1;
                assertTrue(child["parent"].str == labelOf(codes[i]), mode ~ "parent of " ~ child.toString());
                assertTrue(child["other"].str == (i + 1 < codes.length ? codes[i + 1] : "-"),
                    mode ~ "other of " ~ child.toString());
            }

            // Rows by their keys
            auto byKey = run(map!((Expr!QuotedKeyParent p) => p.label)(getByIds!QuotedKeyParent(codes.dup)));
            assertTrue(byKey == codes.map!labelOf.array, mode ~ "rows by key: " ~ byKey.to!string);
        }
    });
}

private import std.string : replace;

private ptrdiff_t countUntilOf(in string[] values, string value) {
    foreach (i, v; values)
        if (v == value)
            return cast(ptrdiff_t) i;
    return -1;
}
