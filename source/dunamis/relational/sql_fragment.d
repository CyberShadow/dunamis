/// Typed SQL fragments: SQL built from interpolated expression sequences
/// (`i"..."`), whose text comes from source code only, and whose values are
/// kept apart from it until the fragment is rendered for a dialect.
///
/// ---
/// Sql cond = sql(i"$(Ident(column)) = $(value)");
/// Sql q = sql(i"SELECT id FROM $(SqlName(table)) WHERE $(cond)");
/// q.render(dialect);  // e.g. `SELECT id FROM app."Users" WHERE "name" = 'it''s'`
/// ---
///
/// In `sql(i"...")`, the literal text of the sequence is SQL; of the
/// expressions interpolated, a `Sql` is spliced in, an `Ident` is an
/// identifier (which the dialect quotes), a `SqlName` is a name which is SQL
/// already (written as it is), and any other value (see `SqlValue`) is a
/// value, which the dialect renders as a literal. As the literal text is a
/// compile-time constant, SQL text computed at run time can only enter a
/// fragment as a `SqlName`.
///
/// (Values are kept apart from the text so that a fragment can also be
/// rendered with its values as parameters of the statement; `render` writes
/// them as literals.)
module dunamis.relational.sql_fragment;

import core.interpolation : InterpolatedExpression, InterpolatedLiteral, InterpolationFooter, InterpolationHeader;
import std.json : JSONValue;
import std.typecons : Nullable;

import dunamis.relational.sql_dialect : SqlDialect, isSqlNumericType;

/// An identifier (e.g. of a column) in a `Sql` fragment: a bare name, which
/// the dialect quotes (see `SqlDialect.quoteIdentifier`).
struct Ident {
    string name;
}

/// A name in a `Sql` fragment which is SQL already, written as it is: the
/// name of a table or column as the schema declares it (see
/// `dunamis.relational.schema`; e.g. a schema-qualified or quoted name), an
/// alias the generator makes up, or a function's. Such a name must not be
/// made of untrusted input (it is the one way into fragments for SQL text
/// computed at run time); for a bare name, use
/// `Ident`.
struct SqlName {
    string name;
}

/// A value in a `Sql` fragment: NULL, a boolean, a number, a string, or a
/// JSON value (e.g. an input value of a mutation).
struct SqlValue {
    enum Kind : ubyte { null_, boolean, number, text, json }

    Kind kind;  /// (The default value is NULL.)
    /// The value's text: of a number, as SQL writes it; of a boolean,
    /// "true" or "false".
    string text;
    /// The JSON value (of a `json` value), which the dialect writes as it
    /// writes JSON values (see `SqlDialect.jsonToSqlLiteral`).
    JSONValue json;

    /// The value of the D value `value`: of a boolean, a number, a string,
    /// a `JSONValue`, a `Nullable` of these, or `null` (NULL).
    static SqlValue of(T)(T value) {
        import std.conv : to;
        import std.traits : Unqual;
        static if (is(T == typeof(null)))
            return SqlValue.init;
        else static if (is(Unqual!T == Nullable!U, U))
            return value.isNull ? SqlValue.init : of(value.get);
        else static if (is(Unqual!T == bool))
            return SqlValue(Kind.boolean, value ? "true" : "false");
        else static if (__traits(isIntegral, T) || __traits(isFloating, T))
            return SqlValue(Kind.number, value.to!string);
        else static if (is(T : const(char)[]))
            return SqlValue(Kind.text, value.idup);
        else static if (is(T : const JSONValue))
            return SqlValue(Kind.json, null, value);
        else
            static assert(false, "Not a value of SQL: " ~ T.stringof);
    }

    /// The value of a constant of the type `type`, given as
    /// `ConstantInfo.valueAsString` represents it: a boolean, a number
    /// (see `isSqlNumericType`), or else (also of types other than
    /// strings) a string.
    static SqlValue ofConstant(TypeInfo type, string valueAsString) {
        if (type == typeid(bool))
            return SqlValue(Kind.boolean, valueAsString == "true" ? "true" : "false");
        if (isSqlNumericType(type))
            return SqlValue(Kind.number, valueAsString);
        return SqlValue(Kind.text, valueAsString);
    }

    /// The value as a literal of `dialect`.
    string literal(SqlDialect dialect) const {
        final switch (kind) {
            case Kind.null_: return "NULL";
            case Kind.boolean: return text == "true" ? "TRUE" : "FALSE";
            case Kind.number: return text;
            case Kind.text: return dialect.escapeSqlString(text);
            case Kind.json: return dialect.jsonToSqlLiteral(json);
        }
    }
}

/// A fragment of SQL (see the module's documentation): built by `sql`
/// or `Sql.join`; rendered by `render`.
struct Sql {
    private static struct Part {
        enum Kind : ubyte { text, name, ident, value }
        Kind kind;
        string text;     // The SQL text, the SQL name, or the identifier
        SqlValue value;
    }
    private Part[] parts;

    /// The fragments `fragments`, with the SQL text `separator` between
    /// them (e.g. `Sql.join!", "(columns)`).
    static Sql join(string separator)(const(Sql)[] fragments) {
        Sql result;
        foreach (i, fragment; fragments) {
            if (i)
                result.appendText(separator);
            result.append(fragment);
        }
        return result;
    }

    /// Whether the fragment is empty.
    @property bool empty() const {
        return parts.length == 0;
    }

    /// The SQL text of the fragment, in `dialect`, its values written as
    /// literals.
    string render(SqlDialect dialect) const {
        import std.array : appender;
        auto result = appender!string;
        foreach (ref part; parts)
            final switch (part.kind) {
                case Part.Kind.text: result.put(part.text); break;
                case Part.Kind.name: result.put(part.text); break;
                case Part.Kind.ident:
                    assert(dialect !is null, "Rendering the identifiers of SQL without a dialect");
                    result.put(dialect.quoteIdentifier(part.text));
                    break;
                case Part.Kind.value:
                    assert(dialect !is null, "Rendering the values of SQL without a dialect");
                    result.put(part.value.literal(dialect));
                    break;
            }
        return result[];
    }

    private void appendText(string text) {
        if (text.length == 0)
            return;
        if (parts.length && parts[$ - 1].kind == Part.Kind.text)
            parts[$ - 1].text ~= text;
        else
            parts ~= Part(Part.Kind.text, text);
    }

    private void append(const Sql fragment) {
        foreach (part; fragment.parts)
            if (part.kind == Part.Kind.text)
                appendText(part.text);
            else
                parts ~= part;
    }
}

/// The fragment of SQL the interpolated expression sequence `i"..."`
/// writes (see the module's documentation).
Sql sql(Args...)(InterpolationHeader, Args args, InterpolationFooter) {
    Sql result;
    foreach (i, arg; args) {
        alias A = Args[i];
        static if (is(A == InterpolatedLiteral!text, string text))
            result.appendText(text);
        else static if (is(A == InterpolatedExpression!code, string code))
            {}  // (The source of the following value)
        else static if (is(A : const Sql))
            result.append(arg);
        else static if (is(A : const Ident))
            result.parts ~= Sql.Part(Sql.Part.Kind.ident, arg.name);
        else static if (is(A : const SqlName))
            result.parts ~= Sql.Part(Sql.Part.Kind.name, arg.name);
        else static if (is(A : const SqlValue))
            result.parts ~= Sql.Part(Sql.Part.Kind.value, null, arg);
        else
            result.parts ~= Sql.Part(Sql.Part.Kind.value, null, SqlValue.of(arg));
    }
    return result;
}

version (unittest) {
    import std.typecons : BlackHole;

    /// A dialect writing string literals and identifiers as PostgreSQL
    /// does.
    private class TestDialect : BlackHole!SqlDialect {
        override string escapeSqlString(string s) {
            import std.array : replace;
            return "'" ~ s.replace("'", "''") ~ "'";
        }
        override string quoteIdentifier(string name) {
            import std.array : replace;
            return `"` ~ name.replace(`"`, `""`) ~ `"`;
        }
        override string jsonToSqlLiteral(JSONValue value) {
            return value.isNull ? "NULL" : escapeSqlString(value.toString());
        }
    }
}

// The text of the sequence is SQL; identifiers are quoted, SQL names are
// SQL; other values are values, written as literals
unittest {
    auto d = new TestDialect;
    string table = `app."Users"`, column = `it's "x"`, name = "it's";
    long id = -3;
    assert(sql(i"SELECT $(Ident(column)) FROM $(SqlName(table)) WHERE name = $(name) AND id <> $(id)").render(d) ==
        `SELECT "it's ""x""" FROM app."Users" WHERE name = 'it''s' AND id <> -3`);
    assert(sql(i"$(true), $(false), $(null), $(1.5), $(Nullable!int()), $(Nullable!int(7))").render(d) ==
        "TRUE, FALSE, NULL, 1.5, NULL, 7");
    const Nullable!int none, some = 3;
    const yes = true;
    assert(sql(i"$(none), $(some), $(yes)").render(d) == "NULL, 3, TRUE");
    // A string value is never SQL, whatever its text
    string evil = "x'; DROP TABLE users; --";
    assert(sql(i"name = $(evil)").render(d) == "name = 'x''; DROP TABLE users; --'");
    // Constants, by their type
    auto n = SqlValue.ofConstant(typeid(int), "42"), b = SqlValue.ofConstant(typeid(bool), "true");
    auto s = SqlValue.ofConstant(typeid(string), "42");
    assert(sql(i"$(n), $(b), $(s)").render(d) == "42, TRUE, '42'");
    // JSON values, as the dialect writes them
    auto j = JSONValue(["a": 1]);
    assert(sql(i"$(j), $(JSONValue(null))").render(d) == `'{"a":1}', NULL`);
}

// Fragments compose: interpolated fragments are spliced in (with their
// values), and joined
unittest {
    auto d = new TestDialect;
    auto cond = sql(i"(name = $("a") OR name = $("b"))");
    auto query = sql(i"SELECT 1 FROM t WHERE $(cond) AND $(sql(i"NOT $(cond)"))");
    assert(query.render(d) == "SELECT 1 FROM t WHERE (name = 'a' OR name = 'b') AND NOT (name = 'a' OR name = 'b')");
    assert(Sql.join!", "([sql(i"a"), sql(i"$(1)"), sql(i"$("c")")]).render(d) == "a, 1, 'c'");
    assert(Sql.join!" AND "([]).empty && Sql.join!" AND "([cond]) == cond);
    assert(sql(i"").empty && !sql(i"x").empty);
    // Adjacent text is merged
    assert(sql(i"a$(sql(i"b"))c").parts.length == 1);
    // Backslashes in wysiwyg sequences
    auto pattern = `a\%`;
    assert(sql(i`LIKE $(pattern) ESCAPE '\'`).render(d) == `LIKE 'a\%' ESCAPE '\'`);
}

// The text of fragments is that of the source code: it is no string
// computed at run time (but through `SqlName`)
unittest {
    string text = "SELECT 1";
    static assert(!__traits(compiles, sql(text)));
    static assert(!__traits(compiles, Sql(text)));
    static assert(!__traits(compiles, Sql.join!", "(text)));
    // (Even a run-time string spliced as text by the sequence's text
    // positions only ever is a value)
    assert(sql(i"$(text)").render(new TestDialect) == "'SELECT 1'");
    assert(sql(i"$(SqlName(text))").render(new TestDialect) == "SELECT 1");
}
