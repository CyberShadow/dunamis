/// The keys of rows, as the local ids of their refs (`Type:key`, see
/// `dunamis.core.types.AnyRef`) encode them: the texts of the values of the
/// row's key columns, encoded as a composite key (see
/// `dunamis.core.types.encodeCompositeKey`; a single value containing a
/// comma or a double quote, empty, or with outer spaces, is quoted).
///
/// Every ref of a row, whether made of the row itself, of a child row's
/// foreign key (its parent's ref), of the key a child layer is grouped by, or
/// of an entity's primary key fields (`entityToRef`), encodes its key with
/// these, so that they are equal; and queries select rows by the values the
/// keys encode (`keyValues`), not by their encoding.
module dunamis.relational.keys;

import std.json : JSONType, JSONValue;

import dunamis.core.types : decodeCompositeKey, encodeCompositeKey;

/// The text of the value `value` of a key column (as JSON): an integer's
/// decimal text, a string itself, other values their JSON text (null:
/// empty).
string keyText(const JSONValue value) {
    import std.conv : to;
    switch (value.type) {
        case JSONType.integer: return value.integer.to!string;
        case JSONType.uinteger: return value.uinteger.to!string;
        case JSONType.string: return value.str;
        case JSONType.null_: return "";
        default: return value.toString();
    }
}

/// The key (local id) of a row whose key columns have the values `values`.
string keyOf(const JSONValue[] values) {
    auto texts = new string[values.length];
    foreach (i, value; values)
        texts[i] = keyText(value);
    return encodeCompositeKey(texts);
}

/// ditto, of the texts of the values (as databases return them)
string keyOfTexts(const string[] texts) {
    return encodeCompositeKey(texts.dup);
}

/// The texts of the values of the key columns of the row of the key (local
/// id) `key`.
string[] keyValues(string key) {
    return decodeCompositeKey(key);
}

/// The text of the value of the (single) key column of the row of the key
/// `key`.
string singleKeyValue(string key) {
    auto values = decodeCompositeKey(key);
    return values.length == 1 ? values[0] : key;
}

unittest {
    import std.json : parseJSON;
    assert(keyOf([JSONValue(12)]) == "12");
    assert(keyOf([JSONValue("plain")]) == "plain");
    // (Quoted: as entityToRef encodes a string key)
    assert(keyOf([JSONValue("a,b")]) == `"a,b"` && keyOfTexts(["a,b"]) == `"a,b"`);
    assert(keyOf([JSONValue(`say "hi"`)]) == `"say ""hi"""`);
    assert(keyOf([JSONValue(""), JSONValue(" x ")]) == `""," x "`);
    assert(keyOf(parseJSON(`[1, "a,b"]`).array) == `1,"a,b"`);
    foreach (value; ["a,b", `say "hi"`, "", " x ", "o'k", "12"])
        assert(singleKeyValue(keyOfTexts([value])) == value, value);
    assert(keyValues(keyOf(parseJSON(`["x,y", 2]`).array)) == ["x,y", "2"]);
}
