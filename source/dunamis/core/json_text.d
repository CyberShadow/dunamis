/// Fast parsing of JSON text (such as the results of the SQL queries of the
/// relational data sources, which return their rows as JSON) into
/// `std.json.JSONValue`s.
module dunamis.core.json_text;

import std.json : JSONValue;

/// The value of the JSON text `text`: the same as `std.json.parseJSON(text)`
/// (with the default options), faster.
///
/// It parses standard JSON itself, without copying the strings without
/// escape sequences (the values are slices of `text`, so they keep it
/// alive); any other text (which std.json's lenient parsing may accept,
/// e.g. trailing commas, or reject) it parses with std.json.
JSONValue parseJsonText(string text) @safe {
    import std.json : parseJSON;

    JSONValue value;
    if (JsonTextParser(text).parse(value))
        return value;
    return parseJSON(text);
}

private:

/// A parser of standard JSON, which gives up (returns false) on anything
/// else, and on the few things std.json handles in its own way.
struct JsonTextParser {
@safe:
    string text;
    size_t i;

    bool parse(out JSONValue value) {
        skipWhitespace();
        if (!parseValue(value))
            return false;
        skipWhitespace();
        return i == text.length;
    }

    void skipWhitespace() {
        // (std.json also skips NUL, \v and \f: such text is not parsed here)
        while (i < text.length) {
            auto c = text[i];
            if (c != ' ' && c != '\n' && c != '\r' && c != '\t')
                break;
            i++;
        }
    }

    bool parseValue(out JSONValue value) {
        if (i >= text.length)
            return false;
        switch (text[i]) {
            case '{':
                return parseObject(value);
            case '[':
                return parseArray(value);
            case '"': {
                string s;
                if (!parseString(s))
                    return false;
                value = JSONValue(s);
                return true;
            }
            case '-':
            case '0': .. case '9':
                return parseNumber(value);
            case 't':
                return literal("true", JSONValue(true), value);
            case 'f':
                return literal("false", JSONValue(false), value);
            case 'n':
                return literal("null", JSONValue(null), value);
            default:
                return false;
        }
    }

    bool literal(string word, JSONValue literalValue, out JSONValue value) {
        if (text.length - i < word.length || text[i .. i + word.length] != word)
            return false;
        i += word.length;
        // (std.json then reads the next value, if the word is followed by
        // letters: such text is not parsed here)
        if (i < text.length && isLetter(text[i]))
            return false;
        value = literalValue;
        return true;
    }

    static bool isLetter(char c) {
        return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
    }

    bool parseObject(out JSONValue value) {
        i++;  // {
        skipWhitespace();
        JSONValue[string] members;
        if (i < text.length && text[i] == '}') {
            i++;
            value = JSONValue(members);
            return true;
        }
        while (true) {
            skipWhitespace();
            if (i >= text.length || text[i] != '"')
                return false;
            string name;
            if (!parseString(name))
                return false;
            skipWhitespace();
            if (i >= text.length || text[i] != ':')
                return false;
            i++;
            skipWhitespace();
            JSONValue member;
            if (!parseValue(member))
                return false;
            members[name] = member;
            skipWhitespace();
            if (i >= text.length)
                return false;
            if (text[i] == ',') {
                i++;
                continue;
            }
            if (text[i] != '}')
                return false;
            i++;
            value = JSONValue(members);
            return true;
        }
    }

    bool parseArray(out JSONValue value) {
        i++;  // [
        skipWhitespace();
        JSONValue[] elements;
        if (i < text.length && text[i] == ']') {
            i++;
            value = JSONValue(elements);
            return true;
        }
        while (true) {
            skipWhitespace();
            JSONValue element;
            if (!parseValue(element))
                return false;
            elements ~= element;
            skipWhitespace();
            if (i >= text.length)
                return false;
            if (text[i] == ',') {
                i++;
                continue;
            }
            if (text[i] != ']')
                return false;
            i++;
            value = JSONValue(elements);
            return true;
        }
    }

    /// A string (at its opening quote): a slice of the text if it has no
    /// escape sequences.
    bool parseString(out string value) {
        i++;  // "
        auto start = i;
        while (i < text.length) {
            auto c = text[i];
            if (c == '"') {
                value = text[start .. i];
                i++;
                return true;
            }
            if (c == '\\')
                return parseEscapedString(start, value);
            if (c < 0x20)
                return false;  // (std.json accepts NUL)
            i++;
        }
        return false;
    }

    /// The rest of a string with escape sequences (at the first one; the
    /// string started at `start`).
    bool parseEscapedString(size_t start, out string value) {
        import std.typecons : Yes;
        import std.uni : isSurrogateHi, isSurrogateLo;
        import std.utf : decode, encode;

        auto buffer = text[start .. i].dup;
        while (i < text.length) {
            auto c = text[i];
            if (c == '"') {
                i++;
                value = (() @trusted => cast(string) buffer)();
                return true;
            }
            if (c < 0x20)
                return false;
            if (c != '\\') {
                buffer ~= c;
                i++;
                continue;
            }
            if (i + 1 >= text.length)
                return false;
            auto escaped = text[i + 1];
            i += 2;
            switch (escaped) {
                case '"': buffer ~= '"'; break;
                case '\\': buffer ~= '\\'; break;
                case '/': buffer ~= '/'; break;
                case 'b': buffer ~= '\b'; break;
                case 'f': buffer ~= '\f'; break;
                case 'n': buffer ~= '\n'; break;
                case 'r': buffer ~= '\r'; break;
                case 't': buffer ~= '\t'; break;
                case 'u': {
                    wchar unit;
                    if (!hex4(unit))
                        return false;
                    dchar character;
                    if (isSurrogateHi(unit)) {
                        // (A pair of UTF-16 surrogates, as std.json decodes them)
                        if (text.length - i < 2 || text[i] != '\\' || text[i + 1] != 'u')
                            return false;
                        i += 2;
                        wchar[2] pair;
                        pair[0] = unit;
                        if (!hex4(pair[1]))
                            return false;
                        size_t index = 0;
                        try
                            character = decode(pair[], index);
                        catch (Exception)
                            return false;
                        if (index != 2)
                            return false;
                    } else if (isSurrogateLo(unit))
                        return false;
                    else
                        character = unit;
                    char[4] encoded;
                    auto length = encode!(Yes.useReplacementDchar)(encoded, character);
                    buffer ~= encoded[0 .. length];
                    break;
                }
                default:
                    return false;
            }
        }
        return false;
    }

    bool hex4(out wchar unit) {
        if (text.length - i < 4)
            return false;
        uint result;
        foreach (c; text[i .. i + 4]) {
            uint digit;
            if (c >= '0' && c <= '9')
                digit = c - '0';
            else if (c >= 'a' && c <= 'f')
                digit = c - 'a' + 10;
            else if (c >= 'A' && c <= 'F')
                digit = c - 'A' + 10;
            else
                return false;
            result = result * 16 + digit;
        }
        i += 4;
        unit = cast(wchar) result;
        return true;
    }

    /// A number: an integer (long, or ulong if it is that large, as
    /// std.json reads them) or a float.
    bool parseNumber(out JSONValue value) {
        import std.conv : ConvException, to;

        auto start = i;
        bool negative, isFloat;
        if (text[i] == '-') {
            negative = true;
            i++;
        }
        if (!digits())
            return false;
        if (i < text.length && text[i] == '.') {
            isFloat = true;
            i++;
            if (!digits())
                return false;
        }
        if (i < text.length && (text[i] == 'e' || text[i] == 'E')) {
            isFloat = true;
            i++;
            if (i < text.length && (text[i] == '+' || text[i] == '-'))
                i++;
            if (!digits())
                return false;
        }
        auto number = text[start .. i];
        try {
            if (isFloat)
                value = JSONValue(number.to!double);
            else if (negative)
                value = JSONValue(number.to!long);
            else {
                auto u = number.to!ulong;
                value = u & (1UL << 63) ? JSONValue(u) : JSONValue(cast(long) u);
            }
        } catch (ConvException)
            return false;  // (out of range: std.json reports it)
        return true;
    }

    bool digits() {
        auto start = i;
        while (i < text.length && text[i] >= '0' && text[i] <= '9')
            i++;
        return i > start;
    }
}

unittest {
    import std.conv : text;
    import std.json : JSONType, parseJSON;

    // The same values, of the same types (opEquals compares numbers across
    // their types)
    static bool same(JSONValue a, JSONValue b) {
        if (a.type != b.type)
            return false;
        switch (a.type) {
            case JSONType.object:
                if (a.object.length != b.object.length)
                    return false;
                foreach (key, value; a.object)
                    if (key !in b.object || !same(value, b.object[key]))
                        return false;
                return true;
            case JSONType.array:
                if (a.array.length != b.array.length)
                    return false;
                foreach (index, value; a.array)
                    if (!same(value, b.array[index]))
                        return false;
                return true;
            case JSONType.float_:
                return a.floating is b.floating || a.floating == b.floating;
            default:
                return a == b;
        }
    }

    static bool parsedHere(string json) {
        JSONValue value;
        return JsonTextParser(json).parse(value);
    }

    // Standard JSON: parsed here, as std.json does
    foreach (json; [
        `{}`, `[]`, `[[]]`, `{"a":{}}`, `""`, `"a"`, `0`, `-0`, `7`, `-12`, `007`, `1.5`, `-0.25`, `1e3`, `1E+3`,
        `2.5e-3`, `9223372036854775807`, `9223372036854775808`, `18446744073709551615`, `-9223372036854775808`,
        `true`, `false`, `null`, ` { "a" : [ 1 , 2.0 , "x" , null , true , false ] , "b" : { } } `,
        `{"a":1,"a":2}`, `"\"\\\/\b\f\n\r\t"`, `"xéy€"`, `"😀"`, `"😀"`, `"é€😀"`,
        `[{"layer0":[{"id":1,"name":"a,b","validity":{"start":"2020-01-01","end":null}}]}]`,
        `{"id": 1, "first_name": "Alice", "tags": ["x", "y"], "nested": {"deep": [[1], [2, [3]]]}}`,
        "[1,\n\t2\r\n]",
    ]) {
        assert(parsedHere(json), json);
        assert(same(parseJsonText(json), parseJSON(json)), json);
        assert(parseJsonText(json).toString() == parseJSON(json).toString(), json);
    }
    assert(parseJsonText(`18446744073709551615`).type == JSONType.uinteger);
    assert(parseJsonText(`9223372036854775807`).type == JSONType.integer);
    assert(parseJsonText(`[]`).array.length == 0);

    // Strings without escapes are slices of the text
    auto source = `{"name":"Alice"}`;
    auto name = parseJsonText(source)["name"].str;
    assert(name == "Alice" && name.ptr >= source.ptr && name.ptr < source.ptr + source.length);

    // Anything else is left to std.json: what it accepts, as it parses it
    foreach (json; [`[1,]`, `{"a":1,}`, `TRUE`, `tRue`, `nul`, "\"a\0b\"", "[1,\v2]", "\x00[1]", `1 .5`]) {
        assert(!parsedHere(json), json);
        bool ok;
        JSONValue expected;
        try {
            expected = parseJSON(json);
            ok = true;
        } catch (Exception) {}
        if (ok)
            assert(same(parseJsonText(json), expected), json);
    }
    // ... and what it rejects, it rejects
    foreach (json; [`[1`, `{"a"}`, `"\x"`, `"\ude00"`, `"\ud83d"`, `-`, `1.`, `1e`, `[1 2]`, `99999999999999999999`,
        `-9223372036854775809`, `"unterminated`, "\"a\nb\""]) {
        assert(!parsedHere(json), json);
        bool threw;
        try
            parseJsonText(json);
        catch (Exception)
            threw = true;
        assert(threw, text(json, " was accepted"));
    }
}
