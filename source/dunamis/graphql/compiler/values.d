module dunamis.graphql.compiler.values;

import std.algorithm;
import std.array;
import std.conv;
import std.json;
import std.meta : staticMap;
import std.traits;
import std.typecons : Nullable;

import graphql.ast;

import dunamis.core.types : isCustomScalar;
import dunamis.graphql.schema : isInputType, isInternalMember;
import dunamis.graphql.schema.udas : getGqlName, getGraphQLTypeName;

// ============================================================================
// Internal: AST Navigation
// ============================================================================

package(dunamis.graphql):

/// Map from fragment name to its definition
alias FragmentMap = FragmentDefinition[string];

/// Collect all fragment definitions from a document
FragmentMap collectFragments(Document doc) @safe {
    FragmentMap fragments;
    if (doc is null || doc.defs is null) return fragments;
    collectFragmentsFromDefs(fragments, doc.defs);
    return fragments;
}

private void collectFragmentsFromDefs(ref FragmentMap fragments, Definitions defs) @safe {
    if (defs is null) return;

    if (defs.def !is null && defs.def.ruleSelection == DefinitionEnum.F) {
        auto frag = defs.def.frag;
        if (frag !is null && frag.name.value !is null) {
            fragments[frag.name.value] = frag;
        }
    }

    if (defs.follow !is null) {
        collectFragmentsFromDefs(fragments, defs.follow);
    }
}

/// Find the first operation in the document
OperationDefinition findOperation(Document doc) @safe {
    if (doc is null || doc.defs is null) return null;
    return findOperationInDefs(doc.defs);
}

OperationDefinition findOperationInDefs(Definitions defs) @safe {
    if (defs is null) return null;

    if (defs.def !is null) {
        if (defs.def.ruleSelection == DefinitionEnum.O) {
            return defs.def.op;
        }
    }

    // Check following definitions
    if (defs.follow !is null) {
        return findOperationInDefs(defs.follow);
    }

    return null;
}

/// Get field name from a Field AST node.
/// Note: graphql-d stores the alias in `name` and actual field name in `aka` when an alias is present.
string getFieldName(Field field) @safe {
    if (field is null || field.name is null) {
        return null;
    }
    // When there's an alias, aka contains the actual field name
    if (field.name.aka !is null) {
        return field.name.aka.tok.value;
    }
    // No alias, name contains the field name
    if (field.name.name !is null) {
        return field.name.name.tok.value;
    }
    return null;
}

/// Get alias (if any) from a Field AST node.
/// Note: graphql-d stores the alias in `name` when present.
string getFieldAlias(Field field) @safe {
    if (field is null || field.name is null) {
        return null;
    }
    // When there's an alias, name contains the alias and aka contains the field name
    if (field.name.aka !is null) {
        return field.name.name !is null ? field.name.name.tok.value : null;
    }
    return null;
}

/// Get the output name (alias if present, otherwise field name)
string getOutputName(Field field) @safe {
    auto alias_ = getFieldAlias(field);
    return alias_ !is null ? alias_ : getFieldName(field);
}

/// Iterate over selections in a SelectionSet
auto iterateSelections(SelectionSet ss) @safe {
    Selection[] result;
    if (ss is null || ss.sel is null) return result;

    void collect(Selections sels) {
        if (sels is null) return;
        if (sels.sel !is null) {
            result ~= sels.sel;
        }
        if (sels.follow !is null) {
            collect(sels.follow);
        }
    }

    collect(ss.sel);
    return result;
}

/// Iterate over arguments in an Arguments node
auto iterateArguments(Arguments args) @safe {
    Argument[] result;
    if (args is null || args.arg is null) return result;

    void collect(ArgumentList list) {
        if (list is null) return;
        if (list.arg !is null) {
            result ~= list.arg;
        }
        if (list.follow !is null) {
            collect(list.follow);
        }
    }

    collect(args.arg);
    return result;
}

// ============================================================================
// Argument Value Extraction
// ============================================================================

/// Result of looking up an argument - either a literal Value or a variable reference
struct ArgumentLookup {
    Value value;           // Literal value (if not a variable)
    string variableName;   // Variable name (if a variable reference)
    bool isVariable;       // True if this is a variable reference

    bool isNull() const {
        return value is null && variableName is null;
    }
}

/// Find an argument by name and return either its Value or variable name
ArgumentLookup findArgumentValue(Arguments args, string name) {
    import graphql.ast : ValueOrVariableEnum;

    foreach (arg; iterateArguments(args)) {
        if (arg.name.value == name) {
            if (arg.vv !is null) {
                if (arg.vv.ruleSelection == ValueOrVariableEnum.Var && arg.vv.var !is null) {
                    // Variable reference
                    return ArgumentLookup(null, arg.vv.var.name.value, true);
                } else if (arg.vv.val !is null) {
                    // Literal value
                    return ArgumentLookup(arg.vv.val, null, false);
                }
            }
        }
    }
    return ArgumentLookup(null, null, false);
}

/// Extract a string value from a GraphQL Value node
string extractString(Value val) {
    import graphql.ast : ValueEnum;
    if (val is null) return null;
    if (val.ruleSelection == ValueEnum.STR) {
        return val.tok.value;
    }
    throw new CompilerException("Expected string argument, got " ~ val.ruleSelection.to!string);
}

/// Extract a long value from a GraphQL Value node
long extractLong(Value val) {
    import graphql.ast : ValueEnum;
    if (val is null) throw new CompilerException("Missing required integer argument");
    if (val.ruleSelection == ValueEnum.INT) {
        return val.tok.value.to!long;
    }
    throw new CompilerException("Expected integer argument, got " ~ val.ruleSelection.to!string);
}

/// Extract a double value from a GraphQL Value node
double extractDouble(Value val) {
    import graphql.ast : ValueEnum;
    if (val is null) throw new CompilerException("Missing required float argument");
    if (val.ruleSelection == ValueEnum.FLOAT) {
        return val.tok.value.to!double;
    }
    if (val.ruleSelection == ValueEnum.INT) {
        return val.tok.value.to!double;  // Allow int where float expected
    }
    throw new CompilerException("Expected float argument, got " ~ val.ruleSelection.to!string);
}

/// Extract a bool value from a GraphQL Value node
bool extractBool(Value val) {
    import graphql.ast : ValueEnum;
    if (val is null) throw new CompilerException("Missing required boolean argument");
    if (val.ruleSelection == ValueEnum.T) return true;
    if (val.ruleSelection == ValueEnum.F) return false;
    throw new CompilerException("Expected boolean argument, got " ~ val.ruleSelection.to!string);
}

/// Check if a Value node is null
bool isNullValue(Value val) {
    import graphql.ast : ValueEnum;
    return val is null || val.ruleSelection == ValueEnum.N;
}

/// Extract the "name" argument for __type introspection query
string extractTypeNameArg(Arguments args, JSONValue variables) {
    auto lookup = findArgumentValue(args, "name");
    if (lookup.isNull) {
        throw new CompilerException("__type requires a 'name' argument");
    }
    if (lookup.isVariable) {
        if (lookup.variableName in variables) {
            return variables[lookup.variableName].str;
        }
        throw new CompilerException("Variable $" ~ lookup.variableName ~ " not found");
    }
    return extractString(lookup.value);
}

/// Convert a GraphQL AST Value to JSONValue
JSONValue valueToJson(Value val, JSONValue variables = JSONValue.emptyObject) {
    import graphql.ast : ValueEnum;

    if (val is null || val.ruleSelection == ValueEnum.N) {
        return JSONValue(null);
    }

    switch (val.ruleSelection) {
        case ValueEnum.T: return JSONValue(true);
        case ValueEnum.F: return JSONValue(false);
        case ValueEnum.N: return JSONValue(null);
        case ValueEnum.INT: return JSONValue(val.tok.value.to!long);
        case ValueEnum.FLOAT: return JSONValue(val.tok.value.to!double);
        case ValueEnum.STR: return JSONValue(val.tok.value);
        case ValueEnum.E: return JSONValue(val.tok.value);  // Enum as string
        case ValueEnum.O: {
            // Object value - parse ObjectType.vals (linked list of name:value pairs)
            JSONValue[string] obj;
            auto objType = val.obj;
            if (objType !is null) {
                auto vals = objType.vals;
                while (vals !is null) {
                    auto name = vals.name.value;
                    auto vov = vals.val;
                    if (vov !is null && vov.ruleSelection == ValueOrVariableEnum.Val && vov.val !is null) {
                        obj[name] = valueToJson(vov.val, variables);
                    } else if (vov !is null && vov.ruleSelection == ValueOrVariableEnum.Var && vov.var !is null) {
                        auto variableName = vov.var.name.value;
                        if (!(variableName in variables))
                            throw new CompilerException("Missing variable $" ~ variableName);
                        obj[name] = variables[variableName];
                    }
                    vals = vals.follow;
                }
            }
            return JSONValue(obj);
        }
        case ValueEnum.ARR: {
            JSONValue[] values;
            auto current = val.arr is null ? null : val.arr.vals;
            while (current !is null) {
                if (current.val !is null)
                    values ~= valueToJson(current.val, variables);
                current = current.follow;
            }
            return JSONValue(values);
        }
        default:
            throw new CompilerException("Unsupported value type: " ~ val.ruleSelection.to!string);
    }
}

// ============================================================================
// Enum Value Extraction
// ============================================================================

/// Convert a string to a D enum value.
/// Matches the string against enum member names.
T enumFromString(T)(string s) if (is(T == enum)) {
    import std.traits : EnumMembers;

    static foreach (member; EnumMembers!T) {
        if (__traits(identifier, member) == s) {
            return member;
        }
    }

    throw new CompilerException(
        "Invalid enum value '" ~ s ~ "' for type " ~ T.stringof ~
        ". Valid values: " ~ [staticMap!(getMemberName, EnumMembers!T)].join(", ")
    );
}

private template getMemberName(alias member) {
    enum getMemberName = __traits(identifier, member);
}

// ============================================================================
// JSON Value Extraction (for variables)
// ============================================================================

/// Extract a typed value from a JSONValue (used for variable resolution)
T extractValueFromJson(T)(JSONValue json) {
    import std.json : JSONType;

    if (json.type == JSONType.null_) {
        static if (is(T == Nullable!U, U)) {
            return T.init;
        } else static if (is(T == U*, U)) {
            return null;  // Pointer is nullable
        } else {
            throw new CompilerException("Null value for non-nullable type " ~ T.stringof);
        }
    }

    static if (is(T == string)) {
        if (json.type != JSONType.string) {
            throw new CompilerException("Expected string variable, got " ~ json.type.to!string);
        }
        return json.str;
    } else static if (is(T == long)) {
        if (json.type != JSONType.integer) {
            throw new CompilerException("Expected integer variable, got " ~ json.type.to!string);
        }
        return json.integer;
    } else static if (is(T == int)) {
        if (json.type != JSONType.integer) {
            throw new CompilerException("Expected integer variable, got " ~ json.type.to!string);
        }
        return cast(int) json.integer;
    } else static if (is(T == double)) {
        if (json.type == JSONType.float_) {
            return json.floating;
        } else if (json.type == JSONType.integer) {
            return cast(double) json.integer;
        }
        throw new CompilerException("Expected float variable, got " ~ json.type.to!string);
    } else static if (is(T == float)) {
        if (json.type == JSONType.float_) {
            return cast(float) json.floating;
        } else if (json.type == JSONType.integer) {
            return cast(float) json.integer;
        }
        throw new CompilerException("Expected float variable, got " ~ json.type.to!string);
    } else static if (is(T == bool)) {
        if (json.type == JSONType.true_) return true;
        if (json.type == JSONType.false_) return false;
        throw new CompilerException("Expected boolean variable, got " ~ json.type.to!string);
    } else static if (is(T == Nullable!U, U)) {
        if (json.type == JSONType.null_) {
            return T.init;
        }
        return T(extractValueFromJson!U(json));
    } else static if (is(T == U*, U)) {
        // Pointer - allocate and extract if not null (enables recursive types)
        if (json.type == JSONType.null_) {
            return null;
        }
        T result = new U;
        *result = extractValueFromJson!U(json);
        return result;
    } else static if (isCustomScalar!T) {
        // CustomScalar handles its own JSON deserialization
        return T.fromJsonValue(json);
    } else static if (is(T == enum)) {
        // D enum - convert from string
        if (json.type != JSONType.string) {
            throw new CompilerException("Expected string for enum " ~ T.stringof ~ ", got " ~ json.type.to!string);
        }
        return enumFromString!T(json.str);
    } else static if (isInputType!T) {
        return extractInputObjectFromJson!T(json);
    } else static if (is(T : U[], U) && !is(T == string)) {
        // Array type - extract each element
        if (json.type != JSONType.array) {
            throw new CompilerException("Expected array for " ~ T.stringof ~ ", got " ~ json.type.to!string);
        }
        U[] result;
        foreach (item; json.array) {
            result ~= extractValueFromJson!U(item);
        }
        return result;
    } else static if (is(T == JSONValue[string])) {
        // Raw JSON object - pass through directly
        if (json.type != JSONType.object) {
            throw new CompilerException("Expected object, got " ~ json.type.to!string);
        }
        return json.object;
    } else static if (is(T == JSONValue)) {
        // Raw JSONValue - pass through as-is
        return json;
    } else {
        static assert(false, "Unsupported variable type: " ~ T.stringof);
    }
}

/// Extract an input object from a JSONValue
T extractInputObjectFromJson(T)(JSONValue json) if (isInputType!T) {
    import std.json : JSONType;

    if (json.type != JSONType.object) {
        throw new CompilerException(
            "Expected object for input type " ~ T.stringof ~ ", got " ~ json.type.to!string
        );
    }

    T result;
    size_t knownFields;

    // Set each field from the JSON object
    // We need to check if we can get the type of the member first (skips type aliases)
    static foreach (member; __traits(allMembers, T)) {{
        static if (!isInternalMember!member) {
            // Check if this member is a valid field (not a type alias or other non-field member)
            static if (__traits(compiles, typeof(__traits(getMember, T.init, member)))) {
                alias MemberType = typeof(__traits(getMember, T, member));
                static if (!is(MemberType == function) && !is(MemberType == void)) {
                    enum gqlName = getGqlName!(__traits(getMember, T, member), member);
                    if (gqlName in json.object) {
                        knownFields++;
                        __traits(getMember, result, member) = extractValueFromJson!MemberType(json.object[gqlName]);
                    }
                }
            }
        }
    }}

    // Input objects must not have fields their type does not define (they
    // are reported with their location by validation; this is a safeguard).
    if (knownFields != json.object.length)
        foreach (name, _; json.object)
            if (!inputTypeDefinesField!T(name))
                throw new CompilerException("Field \"" ~ name ~ "\" is not defined by type \"" ~
                    getGraphQLTypeName!T ~ "\".");

    return result;
}

/// Extract a typed value from a GraphQL Value node
T extractValue(T)(Value val) {
    import graphql.ast : ValueEnum;

    if (val is null || val.ruleSelection == ValueEnum.N) {
        return T.init;
    }

    static if (is(T == string)) {
        return extractString(val);
    } else static if (is(T == long) || is(T == int)) {
        return cast(T) extractLong(val);
    } else static if (is(T == double) || is(T == float)) {
        return cast(T) extractDouble(val);
    } else static if (is(T == bool)) {
        return extractBool(val);
    } else static if (is(T == Nullable!U, U)) {
        if (isNullValue(val)) {
            return T.init;  // null
        }
        return T(extractValue!U(val));
    } else static if (is(T == U*, U)) {
        // Pointer - allocate and extract if not null (enables recursive types)
        if (isNullValue(val)) {
            return null;
        }
        T result = new U;
        *result = extractValue!U(val);
        return result;
    } else static if (isCustomScalar!T) {
        // CustomScalar handles its own JSON deserialization
        return T.fromJsonValue(valueToJson(val));
    } else static if (is(T == enum)) {
        // D enum - extract from enum value or string
        import graphql.ast : ValueEnum;
        if (val.ruleSelection == ValueEnum.E) {
            return enumFromString!T(val.tok.value);
        } else if (val.ruleSelection == ValueEnum.STR) {
            return enumFromString!T(val.tok.value);
        }
        throw new CompilerException(
            "Expected enum value for " ~ T.stringof ~ ", got " ~ val.ruleSelection.to!string
        );
    } else static if (isInputType!T) {
        return extractInputObject!T(val);
    } else static if (is(T : U[], U) && !is(T == string)) {
        // Array type - extract each element from GraphQL list literal
        import graphql.ast : ValueEnum, Values;
        if (val is null || val.ruleSelection != ValueEnum.ARR) {
            throw new CompilerException("Expected array for " ~ T.stringof);
        }
        U[] result;
        // Traverse the linked list of array values
        void processValues(Values v) {
            if (v is null) return;
            if (v.val !is null) {
                result ~= extractValue!U(v.val);
            }
            if (v.follow !is null) {
                processValues(v.follow);
            }
        }
        if (val.arr !is null && val.arr.vals !is null) {
            processValues(val.arr.vals);
        }
        return result;
    } else static if (is(T == JSONValue[string])) {
        // Raw JSON object - convert Value to JSONValue.object
        auto json = valueToJson(val);
        if (json.type != JSONType.object) {
            throw new CompilerException("Expected object, got " ~ json.type.to!string);
        }
        return json.object;
    } else static if (is(T == JSONValue)) {
        // Raw JSON value - convert Value to JSONValue
        return valueToJson(val);
    } else {
        static assert(false, "Unsupported argument type: " ~ T.stringof);
    }
}

/// Extract an input object from a GraphQL object Value node
T extractInputObject(T)(Value val) if (isInputType!T) {
    import graphql.ast : ValueEnum;

    if (val is null) {
        throw new CompilerException("Missing required input object of type " ~ T.stringof);
    }

    if (val.ruleSelection != ValueEnum.O) {
        throw new CompilerException(
            "Expected object for input type " ~ T.stringof ~ ", got " ~ val.ruleSelection.to!string
        );
    }

    T result;

    // Iterate over GraphQL object fields and set corresponding struct fields
    void processObjectValues(ObjectValues vals) {
        if (vals is null) return;

        string fieldName = vals.name.value;
        if (fieldName !is null && vals.val !is null) {
            // Get the Value from ValueOrVariable
            Value fieldVal = vals.val.val;

            // Set the corresponding struct field
            setInputField!T(result, fieldName, fieldVal);
        }

        // Process remaining fields (linked list)
        if (vals.follow !is null) {
            processObjectValues(vals.follow);
        }
    }

    if (val.obj !is null && val.obj.vals !is null) {
        processObjectValues(val.obj.vals);
    }

    return result;
}

/// Set a field in an input object struct from a GraphQL Value
void setInputField(T)(ref T obj, string fieldName, Value val) if (isInputType!T) {
    // Use compile-time introspection to find and set the matching field
    static foreach (member; __traits(allMembers, T)) {{
        static if (!isInternalMember!member) {
            // Check if this member is a valid field (not a type alias or other non-field member)
            static if (__traits(compiles, typeof(__traits(getMember, T.init, member)))) {
                alias MemberType = typeof(__traits(getMember, T, member));
                static if (!is(MemberType == function) && !is(MemberType == void)) {
                    enum gqlName = getGqlName!(__traits(getMember, T, member), member);
                    if (fieldName == gqlName) {
                        // Special cases for self-referential types - handle inline to break
                        // template instantiation cycle that would otherwise occur with extractValue
                        static if (is(MemberType == T*)) {
                            // Self-referential pointer (e.g., not: T*)
                            if (isNullValue(val)) {
                                __traits(getMember, obj, member) = null;
                            } else {
                                auto ptr = new T;
                                *ptr = extractInputObject!T(val);
                                __traits(getMember, obj, member) = ptr;
                            }
                        } else static if (is(MemberType == T[])) {
                            // Self-referential array (e.g., and: T[], or: T[])
                            import graphql.ast : ValueEnum, Values;
                            if (val is null || val.ruleSelection != ValueEnum.ARR) {
                                __traits(getMember, obj, member) = null;
                            } else {
                                T[] result;
                                void processValues(Values v) {
                                    if (v is null) return;
                                    if (v.val !is null) {
                                        result ~= extractInputObject!T(v.val);
                                    }
                                    if (v.follow !is null) {
                                        processValues(v.follow);
                                    }
                                }
                                if (val.arr !is null && val.arr.vals !is null) {
                                    processValues(val.arr.vals);
                                }
                                __traits(getMember, obj, member) = result;
                            }
                        } else {
                            __traits(getMember, obj, member) = extractValue!MemberType(val);
                        }
                        return;
                    }
                }
            }
        }
    }}
    throw new CompilerException("Field \"" ~ fieldName ~ "\" is not defined by type \"" ~
        getGraphQLTypeName!T ~ "\".");
}

/// Whether the input object type T has a field with the GraphQL name `name`.
bool inputTypeDefinesField(T)(string name) if (isInputType!T) {
    static foreach (member; __traits(allMembers, T)) {{
        static if (!isInternalMember!member) {
            static if (__traits(compiles, typeof(__traits(getMember, T.init, member)))) {
                alias MemberType = typeof(__traits(getMember, T, member));
                static if (!is(MemberType == function) && !is(MemberType == void)) {
                    if (name == getGqlName!(__traits(getMember, T, member), member))
                        return true;
                }
            }
        }
    }}
    return false;
}

// ============================================================================
// Directive Evaluation (@skip / @include)
// ============================================================================

/// Check @skip/@include directives to determine if a field should be included.
/// Returns true if the field should be included, false if it should be skipped.
///
/// Follows the GraphQL June 2018 spec:
///   @skip(if: true)  → exclude
///   @include(if: false) → exclude
///   Both present: include only if NOT skipped AND included
///   Unknown directives are ignored.
bool shouldIncludeField(Directives dirs, JSONValue variables) {
    import graphql.ast : ValueOrVariableEnum;

    bool dominated;  // true when at least one @skip/@include was seen
    bool skip;
    bool include = true;

    auto d = dirs;
    while (d !is null) {
        auto dir = d.dir;
        d = d.follow;
        if (dir is null) continue;

        auto name = dir.name.value;
        if (name != "skip" && name != "include") continue;

        // Extract the required `if` argument (Boolean!)
        auto lookup = findArgumentValue(dir.arg, "if");
        if (lookup.isNull) {
            throw new CompilerException(
                "Directive @" ~ name ~ " requires an 'if' argument");
        }

        bool ifValue;
        if (lookup.isVariable) {
            if (lookup.variableName !in variables) {
                throw new CompilerException(
                    "Variable $" ~ lookup.variableName ~ " not found");
            }
            ifValue = extractValueFromJson!bool(variables[lookup.variableName]);
        } else {
            ifValue = extractBool(lookup.value);
        }

        if (name == "skip") {
            skip = skip || ifValue;
        } else {
            include = ifValue;
        }
        dominated = true;
    }

    if (!dominated) return true;
    return !skip && include;
}

// ============================================================================
// CompilerException (needed here for the package(dunamis.graphql) scope)
// ============================================================================

public:

/// Exception thrown during query compilation
class CompilerException : Exception {
    this(string msg, string file = __FILE__, size_t line = __LINE__) {
        super(msg, file, line);
    }
}
