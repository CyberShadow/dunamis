module dynamo.graphql.compiler;

import std.algorithm;
import std.array;
import std.conv;
import std.json;
import std.meta : staticMap;
import std.traits;
import std.typecons : Nullable;

import graphql.ast;
import graphql.lexer;
import graphql.parser;

import ae.utils.promise : Promise;
import dynamo.core;
import dynamo.core.expr : SequentialJsonObjectExpr, SingletonExpr, isExpr, ExprResultType, Expr, singleton, FieldAccessExpr, MethodCallExpr;
import dynamo.core.optimize : OptimizeContext;
import dynamo.core.types : isPlainField, isPlainMethod, NoSchemaConfig, ResolveType, findMapping, hasMappingFor, applySerialize, applyDeserialize;
import dynamo.graphql.introspection;
import dynamo.graphql.schema;

// ============================================================================
// Query Compiler
// ============================================================================

/// Result type for compiled GraphQL queries.
/// A GraphQL query evaluates to a single JSON object containing all root fields.
alias GraphQLResult = Expr!JSONValue;

/// Compiles a GraphQL query string into an executable Expr tree.
///
/// The compiler uses compile-time reflection on the Query type to look up
/// fields and generate the appropriate expressions. The result is an Expr
/// tree that can be executed by the Executor.
///
/// Accepts either a Schema type (created with Schema!(Query, Mutation)) or a raw Query type.
/// The Query type should have Table mixins that reference entities bound to a data source.
///
/// Example:
/// ---
/// static MyDB myDB;
///
/// struct User {
///     mixin Entity!(myDB, "users");
///     mixin Col!("firstName", string);
/// }
///
/// struct Query {
///     mixin Table!(User, "users");  // db derived from User._db
/// }
///
/// // Using raw Query type
/// auto query = compileQuery!Query(`{ users { firstName } }`);
///
/// // Using Schema type
/// alias MySchema = Schema!(Query);
/// auto query = compileQuery!MySchema(`{ users { firstName } }`);
/// ---
GraphQLResult compileQuery(alias SchemaOrQuery)(string queryString) {
    return compileQuery!SchemaOrQuery(queryString, JSONValue.emptyObject);
}

/// Compiles a GraphQL query string with variables into an executable Expr tree.
///
/// Example:
/// ---
/// auto variables = JSONValue(["format": JSONValue(["prefix": "Mr. "])]);
/// auto query = compileQuery!Query(`
///     query GetUsers($format: NameFormat!) {
///         users { formattedName(format: $format) }
///     }
/// `, variables);
/// ---
GraphQLResult compileQuery(alias SchemaOrQuery)(string queryString, JSONValue variables) {
    import graphql.ast : OperationTypeEnum;

    // Parse the GraphQL query
    auto lexer = Lexer(queryString);
    auto parser = Parser(lexer);
    auto doc = parser.parseDocument();

    // Find the operation
    auto op = findOperation(doc);
    if (op is null || op.ss is null) {
        throw new CompilerException("No operation found in query");
    }

    // Determine operation type (default to Query for shorthand syntax)
    bool isMutation = op.ot !is null && op.ot.ruleSelection == OperationTypeEnum.Mutation;
    bool isSubscription = op.ot !is null && op.ot.ruleSelection == OperationTypeEnum.Sub;

    if (isSubscription) {
        throw new CompilerException("Subscriptions are not supported");
    }

    // Extract types from Schema if needed
    static if (isSchema!SchemaOrQuery) {
        alias QueryType = SchemaOrQuery.Query;
        alias MutationType = SchemaOrQuery.Mutation;
    } else {
        alias QueryType = SchemaOrQuery;
        struct MutationType {}
    }

    // Extract config from Schema if available (bare Query types have no Config)
    static if (isSchema!SchemaOrQuery) {
        alias cfg = SchemaOrQuery.Config;
    } else {
        alias cfg = NoSchemaConfig;
    }

    // Compile based on operation type
    if (isMutation) {
        static if (getFields!(MutationType, cfg).length > 0) {
            return compileRootMutationSet!(MutationType, cfg)(op.ss, variables);
        } else {
            throw new CompilerException("Mutation operations require a Schema with Mutation type");
        }
    } else {
        // Query operation - compile using QueryType directly
        // Entity return types are already wrapped by ForwardFieldWithTypeMap
        return compileRootSelectionSet!(QueryType, cfg, SchemaOrQuery)(op.ss, variables);
    }
}

/// Exception thrown during query compilation
class CompilerException : Exception {
    this(string msg, string file = __FILE__, size_t line = __LINE__) {
        super(msg, file, line);
    }
}

// ============================================================================
// Internal: AST Navigation
// ============================================================================

package:

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
JSONValue valueToJson(Value val) {
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
                        obj[name] = valueToJson(vov.val);
                    }
                    vals = vals.follow;
                }
            }
            return JSONValue(obj);
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
T extractValueFromJson(T, alias cfg = NoSchemaConfig)(JSONValue json) {
    import std.json : JSONType;

    // Check for type mapping first
    static if (hasMappingFor!(T, cfg)) {
        alias mapping = findMapping!(T, cfg);
        auto targetVal = extractValueFromJson!(mapping.TargetType, cfg)(json);
        return mapping.fromTarget(targetVal);
    } else {

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

    } // end static else (no mapping)
}

/// Extract an input object from a JSONValue
T extractInputObjectFromJson(T, alias cfg = NoSchemaConfig)(JSONValue json) if (isInputType!T) {
    import std.json : JSONType;

    if (json.type != JSONType.object) {
        throw new CompilerException(
            "Expected object for input type " ~ T.stringof ~ ", got " ~ json.type.to!string
        );
    }

    T result;

    // Set each field from the JSON object
    // We need to check if we can get the type of the member first (skips type aliases)
    static foreach (member; __traits(allMembers, T)) {{
        static if (!isInternalMember!member) {
            // Check if this member is a valid field (not a type alias or other non-field member)
            static if (__traits(compiles, typeof(__traits(getMember, T.init, member)))) {
                alias MemberType = typeof(__traits(getMember, T, member));
                static if (!is(MemberType == function) && !is(MemberType == void)) {
                    if (member in json.object) {
                        __traits(getMember, result, member) = extractValueFromJson!(MemberType, cfg)(json.object[member]);
                    }
                }
            }
        }
    }}

    return result;
}

/// Extract a typed value from a GraphQL Value node
T extractValue(T, alias cfg = NoSchemaConfig)(Value val) {
    import graphql.ast : ValueEnum;

    // Check for type mapping first
    static if (hasMappingFor!(T, cfg)) {
        alias mapping = findMapping!(T, cfg);
        auto targetVal = extractValue!(mapping.TargetType, cfg)(val);
        return mapping.fromTarget(targetVal);
    } else {

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

    } // end static else (no mapping)
}

/// Extract an input object from a GraphQL object Value node
T extractInputObject(T, alias cfg = NoSchemaConfig)(Value val) if (isInputType!T) {
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
            setInputField!(T, cfg)(result, fieldName, fieldVal);
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
void setInputField(T, alias cfg = NoSchemaConfig)(ref T obj, string fieldName, Value val) if (isInputType!T) {
    // Use compile-time introspection to find and set the matching field
    static foreach (member; __traits(allMembers, T)) {{
        static if (!isInternalMember!member) {
            // Check if this member is a valid field (not a type alias or other non-field member)
            static if (__traits(compiles, typeof(__traits(getMember, T.init, member)))) {
                alias MemberType = typeof(__traits(getMember, T, member));
                static if (!is(MemberType == function) && !is(MemberType == void)) {
                    if (fieldName == member) {
                        // Special cases for self-referential types - handle inline to break
                        // template instantiation cycle that would otherwise occur with extractValue
                        static if (is(MemberType == T*)) {
                            // Self-referential pointer (e.g., not: T*)
                            if (isNullValue(val)) {
                                __traits(getMember, obj, member) = null;
                            } else {
                                auto ptr = new T;
                                *ptr = extractInputObject!(T, cfg)(val);
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
                                        result ~= extractInputObject!(T, cfg)(v.val);
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
                            __traits(getMember, obj, member) = extractValue!(MemberType, cfg)(val);
                        }
                        return;
                    }
                }
            }
        }
    }}
    // Unknown field - ignore (GraphQL validation should catch this)
}

// ============================================================================
// Computed Field Invocation
// ============================================================================

/// Check if a type is a supported argument type (scalars or input objects)
template isSupportedArgType(T) {
    static if (is(T == string) || is(T == long) || is(T == int) ||
               is(T == double) || is(T == float) || is(T == bool)) {
        enum isSupportedArgType = true;
    } else static if (is(T == Nullable!U, U)) {
        enum isSupportedArgType = isSupportedArgType!U;
    } else static if (is(T == U*, U)) {
        // Pointer to input type - accept without recursive check (enables self-referential types)
        enum isSupportedArgType = isInputType!U || isSupportedArgType!U;
    } else static if (isInputType!T) {
        // Input object - check all fields are supported
        enum isSupportedArgType = allInputFieldsSupported!T;
    } else {
        enum isSupportedArgType = false;
    }
}

/// Check if all fields of an input type are supported
template allInputFieldsSupported(T) if (isInputType!T) {
    enum allInputFieldsSupported = () {
        static foreach (member; __traits(allMembers, T)) {{
            static if (!isInternalMember!member) {
                // Check if this member is a valid field (not a type alias or other non-field member)
                static if (__traits(compiles, typeof(__traits(getMember, T.init, member)))) {
                    alias MemberType = typeof(__traits(getMember, T, member));
                    static if (!is(MemberType == function) && !is(MemberType == void)) {
                        // Check member type directly - isSupportedArgType handles Nullable/pointer unwrapping
                        // and avoids infinite recursion for self-referential types
                        if (!isSupportedArgType!MemberType) {
                            return false;
                        }
                    }
                }
            }
        }}
        return true;
    }();
}

/// Check if all argument types of a function are supported
template allArgTypesSupported(alias fn) {
    import std.traits : Parameters;
    alias Params = Parameters!fn;

    enum allArgTypesSupported = () {
        static foreach (i; 1 .. Params.length) {
            if (!isSupportedArgType!(Params[i])) {
                return false;
            }
        }
        return true;
    }();
}

/// Call a computed field with arguments extracted from GraphQL.
/// Uses compile-time introspection to determine parameter types and names,
/// then extracts values from the GraphQL Arguments at runtime.
/// Variables are resolved from the provided JSONValue map.
auto callComputedField(alias fn, Entity, alias cfg = NoSchemaConfig)(Expr!Entity entityRef, Arguments args, JSONValue variables) {
    import std.traits : Parameters, ParameterDefaults, ParameterIdentifierTuple;
    import std.typecons : tuple;

    alias Params = Parameters!fn;
    alias Defaults = ParameterDefaults!fn;
    enum paramNames = [ParameterIdentifierTuple!fn];

    // Number of extra parameters (excluding first Expr!Entity parameter)
    enum numArgs = Params.length - 1;

    // Extract arguments (starting from index 1, skipping entityRef)
    static if (numArgs == 0) {
        return fn(entityRef);
    } else {
        auto argTuple = mixin(() {
            string code = "tuple(";
            static foreach (i; 1 .. Params.length) {
                code ~= (i > 1 ? ", " : "") ~
                    "extractArg!(Params[" ~ i.stringof ~ "], Defaults[" ~ i.stringof ~ "], cfg)" ~
                    "(args, paramNames[" ~ i.stringof ~ "], variables)";
            }
            code ~= ")";
            return code;
        }());
        return fn(entityRef, argTuple.expand);
    }
}

/// Extract an argument value, using default if not provided.
/// Handles both literal values and variable references.
T extractArg(T, alias Default, alias cfg = NoSchemaConfig)(Arguments args, string name, JSONValue variables) {
    import std.json : JSONType;
    import std.typecons : Nullable;

    // Determine if argument is optional:
    // - Has an explicit default value (Default != void), OR
    // - Is a Nullable type (implicitly optional with T.init as default)
    enum hasExplicitDefault = !is(Default == void);
    enum isNullableType = is(T == Nullable!U, U);
    enum isOptional = hasExplicitDefault || isNullableType;

    auto lookup = findArgumentValue(args, name);

    if (lookup.isNull) {
        // Argument not provided
        static if (hasExplicitDefault) {
            return Default;
        } else static if (isNullableType) {
            // Nullable types default to null (T.init)
            return T.init;
        } else {
            throw new CompilerException("Missing required argument: " ~ name);
        }
    }

    if (lookup.isVariable) {
        // Variable reference - look up in variables map
        if (variables.type != JSONType.object || lookup.variableName !in variables.object) {
            static if (hasExplicitDefault) {
                return Default;
            } else static if (isNullableType) {
                return T.init;
            } else {
                throw new CompilerException("Missing variable: $" ~ lookup.variableName);
            }
        }
        return extractValueFromJson!(T, cfg)(variables.object[lookup.variableName]);
    } else {
        // Literal value
        static if (hasExplicitDefault) {
            if (isNullValue(lookup.value)) {
                return Default;
            }
        } else static if (isNullableType) {
            if (isNullValue(lookup.value)) {
                return T.init;
            }
        }
        return extractValue!(T, cfg)(lookup.value);
    }
}

// ============================================================================
// Root Mutation Compilation
// ============================================================================

/// Compile the root selection set for mutations (sequential execution)
SequentialJsonObjectExpr compileRootMutationSet(Mutation, alias cfg = NoSchemaConfig)(SelectionSet ss, JSONValue variables) {
    auto selections = iterateSelections(ss);

    if (selections.length == 0) {
        throw new CompilerException("Empty mutation selection set");
    }

    string[] fieldNames;
    ExprBase[] fieldExprs;

    foreach (sel; selections) {
        if (sel.ruleSelection != SelectionEnum.Field) continue;
        auto field = sel.field;
        fieldNames ~= getOutputName(field);
        fieldExprs ~= compileRootField!(Mutation, cfg)(field, variables);
    }

    if (fieldNames.length == 0) {
        throw new CompilerException("No fields in mutation selection set");
    }

    return new SequentialJsonObjectExpr(fieldNames, fieldExprs);
}

/// Compile a single root field (works for both Query and Mutation).
/// Scans for function members with matching GraphQL name.
ExprBase compileRootField(Parent, alias cfg = NoSchemaConfig, alias IntrospectionSource = Parent)(Field field, JSONValue variables) {
    auto fieldName = getFieldName(field);
    auto parentExpr = singleton(Parent.init);

    // Introspection fields
    if (fieldName == "__typename") {
        return wrapAsJsonExpr(singleton(getGraphQLTypeName!Parent));
    }
    if (fieldName == "__schema") {
        auto schemaJson = buildIntrospectionJson!IntrospectionSource();
        auto result = applySelectionSet(schemaJson, field.ss, variables);
        return wrapAsJsonExpr(singleton(result));
    }
    if (fieldName == "__type") {
        auto typeName = extractTypeNameArg(field.args, variables);
        auto lookup = buildTypeLookup!IntrospectionSource();
        if (auto typeJson = typeName in lookup) {
            return wrapAsJsonExpr(singleton(applySelectionSet(*typeJson, field.ss, variables)));
        }
        return wrapAsJsonExpr(singleton(JSONValue(null)));
    }

    static foreach (member; __traits(allMembers, Parent)) {{
        static if (!isInternalMember!member) {
            alias memberSym = __traits(getMember, Parent, member);
            static if (is(typeof(memberSym) == function)) {
                enum gqlName = getGqlName!(memberSym, member);
                if (fieldName == gqlName) {
                    return callRootField!(memberSym, Parent, cfg)(parentExpr, field.args, field.ss, variables);
                }
            }
        }
    }}

    throw new CompilerException("Unknown field: " ~ fieldName);
}

/// Call a root field function and handle the return type.
/// Root fields return Expr!T which we may need to descend into with a selection set.
/// Works for both Query and Mutation fields.
ExprBase callRootField(alias fn, Parent, alias cfg = NoSchemaConfig)(Expr!Parent parent, Arguments args, SelectionSet ss, JSONValue variables) {
    import std.traits : Parameters, ReturnType, ParameterDefaults, ParameterIdentifierTuple;
    import std.typecons : tuple;
    import dynamo.core.expr : toJsonValue, Expr, ExprResultType, isExpr;

    alias Params = Parameters!fn;
    alias Return = ReturnType!fn;

    // Verify return type is an Expr
    static assert(isExpr!Return,
        "Root field " ~ __traits(identifier, fn) ~ " must return an Expr type, got " ~ Return.stringof);

    // Extract arguments (skip first param which is parent)
    static if (Params.length == 1) {
        // Only parent, no additional args
        auto resultExpr = fn(parent);
    } else {
        auto argTuple = mixin(() {
            string code = "tuple(";
            static foreach (i; 1 .. Params.length) {
                code ~= (i > 1 ? ", " : "") ~
                    "extractArg!(Params[" ~ i.stringof ~ "], ParameterDefaults!fn[" ~ i.stringof ~ "], cfg)" ~
                    "(args, [ParameterIdentifierTuple!fn][" ~ i.stringof ~ "], variables)";
            }
            code ~= ")";
            return code;
        }());
        auto resultExpr = fn(parent, argTuple.expand);
    }

    // Handle return type generically
    return compileFieldResult!(typeof(resultExpr), cfg)(resultExpr, ss, variables);
}

/// Wrap an expression to convert its result to JSONValue
ExprBase wrapAsJsonExpr(E)(E expr) if (isExpr!E) {
    import dynamo.core.expr : use, toJsonValue, ExprResultType;
    alias T = ExprResultType!E;
    return use((T val) => toJsonValue(val), expr);
}

/// Helper to extract all arguments for a function and return as a tuple
auto extractAllArgs(alias fn)(Arguments args, JSONValue variables) {
    import std.traits : Parameters, ParameterDefaults, ParameterIdentifierTuple;
    import std.meta : staticMap, aliasSeqOf;
    import std.range : iota;
    import std.typecons : tuple;

    alias Params = Parameters!fn;
    alias Defaults = ParameterDefaults!fn;
    enum paramNames = [ParameterIdentifierTuple!fn];

    // Build a tuple of extracted arguments
    template ExtractArg(size_t i) {
        alias ExtractArg = extractArg!(Params[i], Defaults[i])(args, paramNames[i], variables);
    }

    // Use static foreach to build the tuple
    static if (Params.length == 0) {
        return tuple();
    } else {
        return mixin(() {
            string code = "tuple(";
            static foreach (i; 0 .. Params.length) {
                code ~= (i > 0 ? ", " : "") ~
                    "extractArg!(Params[" ~ i.stringof ~ "], Defaults[" ~ i.stringof ~ "])" ~
                    "(args, paramNames[" ~ i.stringof ~ "], variables)";
            }
            code ~= ")";
            return code;
        }());
    }
}

// ============================================================================
// Root Selection Set Compilation
// ============================================================================

/// Compile the root selection set (fields from Query type)
DynamicJsonObjectExpr compileRootSelectionSet(Query, alias cfg = NoSchemaConfig, alias IntrospectionSource = Query)(SelectionSet ss, JSONValue variables) {
    auto selections = iterateSelections(ss);

    if (selections.length == 0) {
        throw new CompilerException("Empty selection set");
    }

    string[] fieldNames;
    ExprBase[] fieldExprs;

    foreach (sel; selections) {
        if (sel.ruleSelection != SelectionEnum.Field) continue;
        auto field = sel.field;
        fieldNames ~= getOutputName(field);
        fieldExprs ~= compileRootField!(Query, cfg, IntrospectionSource)(field, variables);
    }

    if (fieldNames.length == 0) {
        throw new CompilerException("No fields in root selection set");
    }

    return buildDynamicJsonObject(fieldNames, fieldExprs);
}

// ============================================================================
// Selection Set Compilation (for entity types)
// ============================================================================

/// Compile a selection set into a MapExpr with DynamicJsonObjectExpr body.
/// Returns Expr!(JSONValue[]) which is the result of mapping over the collection.
/// Note: Explicit return type breaks circular template instantiation.
MapExpr!(Entity, DynamicJsonObjectExpr) compileMapExpr(Entity, alias cfg = NoSchemaConfig, Coll)(Coll collection, SelectionSet ss, JSONValue variables) {
    import dynamo.core.expr : Expr, map;

    return map!(
        (Expr!Entity entity) => compileSelectionSetBody!(Entity, cfg)(entity, ss, variables)
    )(collection);
}

/// Compile the body of a selection set (the fields to extract).
/// Works with any struct type that has field methods.
DynamicJsonObjectExpr compileSelectionSetBody(T, alias cfg = NoSchemaConfig)(Expr!T ref_, SelectionSet ss, JSONValue variables) {
    auto selections = iterateSelections(ss);
    if (selections.length == 0) {
        throw new CompilerException("Empty selection set for " ~ T.stringof);
    }

    // Build field name/value pairs for jsonObject
    return compileFieldsToJsonObject!(T, cfg)(ref_, selections, variables);
}

/// Compile selected fields into a jsonObject call.
/// Works with any struct type that has field methods.
DynamicJsonObjectExpr compileFieldsToJsonObject(T, alias cfg = NoSchemaConfig)(Expr!T ref_, Selection[] selections, JSONValue variables) {
    // Collect field expressions
    ExprBase[] fieldExprs;
    string[] fieldNames;

    foreach (sel; selections) {
        if (sel.ruleSelection != SelectionEnum.Field) continue;
        auto field = sel.field;
        auto name = getFieldName(field);
        auto outputName = getOutputName(field);

        fieldNames ~= outputName;
        fieldExprs ~= compileFieldAccess!(T, cfg)(ref_, field, variables);
    }

    // Build a dynamic JSON object using runtime construction
    return buildDynamicJsonObject(fieldNames, fieldExprs);
}

/// Build a JSON object from runtime field names and expressions
DynamicJsonObjectExpr buildDynamicJsonObject(string[] names, ExprBase[] exprs) {
    import dynamo.core.expr : DynamicJsonObjectExpr;
    return new DynamicJsonObjectExpr(names, exprs);
}

/// Check if a member is a field method for type T.
/// A field method takes Expr!T as first parameter and returns an Expr.
template isFieldMethod(T, alias member) {
    import std.traits : Parameters, ReturnType;
    static if (is(typeof(member) == function)) {
        alias Params = Parameters!member;
        alias Return = ReturnType!member;
        static if (Params.length >= 1 && is(Params[0] == Expr!T) && isExpr!Return) {
            enum isFieldMethod = true;
        } else {
            enum isFieldMethod = false;
        }
    } else {
        enum isFieldMethod = false;
    }
}

/// Compile the result of a field method based on its return type.
/// Handles scalars, structs (with selection sets), and arrays.
/// Scalars are wrapped to convert to JSONValue.
/// Structs/arrays of structs compile selection sets.
ExprBase compileFieldResult(ResultExpr, alias cfg = NoSchemaConfig)(ResultExpr resultExpr, SelectionSet ss, JSONValue variables) {
    import dynamo.core.expr : ExprResultType, UnwrapNullableExpr, finalizeNullableObjectExpr;

    alias ResultType = ExprResultType!ResultExpr;

    // Arrays need element type inspection
    static if (is(ResultType == E[], E)) {
        static if (isCustomScalar!E || !is(E == struct)) {
            // Array of scalars (custom or primitive) - wrap to JSON
            return wrapAsJsonExpr(resultExpr);
        } else {
            // Array of structs - requires selection set
            if (ss is null) {
                throw new CompilerException(
                    "Field returning [" ~ E.stringof ~ "] requires a selection set");
            }
            return compileMapExpr!(E, cfg)(resultExpr, ss, variables);
        }
    }
    // Nullable structs (entities) - handle null case specially
    else static if (is(ResultType == Nullable!T, T) && is(T == struct) && !isCustomScalar!T) {
        if (ss is null) {
            throw new CompilerException(
                "Field returning " ~ T.stringof ~ " requires a selection set");
        }
        // Create unwrapper expression that forwards to the nullable input
        // This preserves the chain for optimization (findMapExprFromChain)
        auto unwrapper = new UnwrapNullableExpr!T(resultExpr);
        // Compile selection set using the unwrapper as input
        auto innerExpr = compileSelectionSetBody!(T, cfg)(unwrapper, ss, variables);
        // Wrap in nullable handler
        return finalizeNullableObjectExpr!T(resultExpr, unwrapper, innerExpr);
    }
    // Nullable scalars (e.g., Nullable!string) - wrap to JSON
    else static if (is(ResultType == Nullable!U, U)) {
        return wrapAsJsonExpr(resultExpr);
    }
    // Structs (non-CustomScalar, non-Nullable) require selection sets
    else static if (is(ResultType == struct) && !isCustomScalar!ResultType) {
        if (ss is null) {
            throw new CompilerException(
                "Field returning " ~ ResultType.stringof ~ " requires a selection set");
        }
        return compileSelectionSetBody!(ResultType, cfg)(resultExpr, ss, variables);
    }
    // Scalars (primitives and CustomScalar) - wrap to JSON
    else {
        return wrapAsJsonExpr(resultExpr);
    }
}

/// Expression that calls an instance method and applies a type mapping serialization.
/// Combines MethodCallExpr + serialization in one eval step to avoid nested UseExpr
/// chains that can trigger LDC optimizer issues.
private class MappedMethodCallExpr(Entity, string methodName, alias serialize, TargetType) : Expr!TargetType {
    import dynamo.core.expr : Expr, ExprBase, evalAs;
    import dynamo.core.optimize : OptimizeContext;
    import dynamo.core.eval : EvalContext;
    import ae.utils.promise : Promise;

    alias RawType = ReturnType!(__traits(getMember, Entity, methodName));
    private ExprBase _input;

    this(Expr!Entity input) {
        _input = input;
    }

    override ExprBase[] dependencies() {
        return [_input];
    }

    override void replaceDependency(size_t index, ExprBase newDep) {
        if (index == 0)
            _input = newDep;
    }

    override Expr!TargetType optimize(OptimizeContext ctx) {
        _input = (cast(Expr!Entity) _input).optimize(ctx);
        return this;
    }

    override Promise!(TargetType[]) eval(EvalContext ctx) {
        return evalAs!Entity(_input, ctx).then((Entity[] entities) {
            TargetType[] result = new TargetType[entities.length];
            foreach (i, ref e; entities) {
                result[i] = serialize(__traits(getMember, e, methodName)());
            }
            return result;
        });
    }
}

/// Compile access to a single field.
/// Finds a method with signature (Expr!T, args...) -> Expr!U and calls it.
/// Also handles plain fields (struct instance fields marked with plain fields).
ExprBase compileFieldAccess(T, alias cfg = NoSchemaConfig)(Expr!T ref_, Field field, JSONValue variables) {
    import dynamo.core.expr : use;

    auto fieldName = getFieldName(field);

    // First, find a field method matching the GraphQL field name
    static foreach (member; __traits(allMembers, T)) {{
        static if (!isInternalMember!member) {
            alias memberSym = __traits(getMember, T, member);
            static if (isFieldMethod!(T, memberSym)) {
                // Check for @GqlHidden
                static if (!hasGqlHidden!memberSym) {
                    enum gqlName = getGqlName!(memberSym, member);

                    if (fieldName == gqlName) {
                        // Call the field method with arguments
                        auto resultExpr = callComputedField!(memberSym, T, cfg)(ref_, field.args, variables);
                        // Apply type mapping if needed
                        alias RawType = ExprResultType!(typeof(resultExpr));
                        alias Resolved = ResolveType!(RawType, cfg);
                        static if (!is(Resolved == RawType)) {
                            auto converted = use(&applySerialize!(RawType, Resolved, findMapping!(RawType, cfg).toTarget), resultExpr);
                            return compileFieldResult!(typeof(converted), cfg)(converted, field.ss, variables);
                        } else {
                            return compileFieldResult!(typeof(resultExpr), cfg)(resultExpr, field.ss, variables);
                        }
                    }
                }
            }
        }
    }}

    // Second, check for plain fields (struct instance fields)
    static foreach (member; __traits(allMembers, T)) {{
        static if (!isInternalMember!member) {
            static if (isPlainField!(T, member)) {
                // Eager field - use D field name directly (GraphQL uses camelCase like D)
                if (fieldName == member) {
                    // Create FieldAccessExpr to read the struct field
                    auto resultExpr = new FieldAccessExpr!(T, member)(ref_);
                    // Apply type mapping if needed
                    alias RawType = ExprResultType!(typeof(resultExpr));
                    alias Resolved = ResolveType!(RawType, cfg);
                    static if (!is(Resolved == RawType)) {
                        auto converted = use(&applySerialize!(RawType, Resolved, findMapping!(RawType, cfg).toTarget), resultExpr);
                        return compileFieldResult!(typeof(converted), cfg)(converted, field.ss, variables);
                    } else {
                        return compileFieldResult!(typeof(resultExpr), cfg)(resultExpr, field.ss, variables);
                    }
                }
            }
        }
    }}

    // Third, check for plain methods (instance methods returning non-Expr types)
    static foreach (member; __traits(allMembers, T)) {{
        static if (!isInternalMember!member) {
            static if (isPlainMethod!(T, member)) {
                alias methodSym = __traits(getMember, T, member);
                static if (!hasGqlHidden!methodSym) {
                    enum gqlName = getGqlName!(methodSym, member);
                    if (fieldName == gqlName) {
                        // Apply type mapping if needed
                        alias MethodRetType = ReturnType!(__traits(getMember, T, member));
                        alias Resolved = ResolveType!(MethodRetType, cfg);
                        static if (!is(Resolved == MethodRetType)) {
                            alias mapping = findMapping!(MethodRetType, cfg);
                            auto resultExpr = new MappedMethodCallExpr!(T, member, applySerialize!(MethodRetType, Resolved, mapping.toTarget), Resolved)(ref_);
                            return compileFieldResult!(typeof(resultExpr), cfg)(resultExpr, field.ss, variables);
                        } else {
                            auto resultExpr = new MethodCallExpr!(T, member)(ref_);
                            return compileFieldResult!(typeof(resultExpr), cfg)(resultExpr, field.ss, variables);
                        }
                    }
                }
            }
        }
    }}

    // __typename: returns the GraphQL type name as a constant
    if (fieldName == "__typename") {
        return wrapAsJsonExpr(constant(getGraphQLTypeName!T, ref_));
    }

    throw new CompilerException("Unknown field '" ~ fieldName ~ "' on type " ~ T.stringof);
}

// ============================================================================
// Tests
// ============================================================================

unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dynamo.core;
    import dynamo.relational.schema;
    import dynamo.relational.demo;
    import dynamo.relational.eval_context;

    // Static data source instance - bound by alias in Entity mixin
    static MockDB!() db;

    // Define test entities
    static struct User {
        mixin DemoEntity!(db, "users");
        mixin Col!("firstName", string);
        mixin Col!("lastName", string);

        static auto fullName(Expr!User u) {
            return firstName(u) ~ " " ~ lastName(u);
        }
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    // Set up mock data
    db = new MockDB!();
    db.setTableData("users", `[
        {"id": 1, "first_name": "Alice", "last_name": "Smith"},
        {"id": 2, "first_name": "Bob", "last_name": "Jones"}
    ]`);

    // Compile a simple query - no db parameter needed
    auto query = compileQuery!Query(`{ users { firstName, lastName } }`);

    // Execute
    auto executor = new Executor();
    auto result = awaitSync(executor.execute(query));

    // Verify results (executor returns JSONValue with root fields)
    auto users = result["users"].array;
    assert(users.length == 2);
    assert(users[0]["firstName"].str == "Alice");
    assert(users[0]["lastName"].str == "Smith");
    assert(users[1]["firstName"].str == "Bob");
    assert(users[1]["lastName"].str == "Jones");
}

unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dynamo.core;
    import dynamo.relational.schema;
    import dynamo.relational.demo;
    import dynamo.relational.eval_context;

    static MockDB!() db;

    // Test computed fields
    static struct User {
        mixin DemoEntity!(db, "users");
        mixin Col!("firstName", string);
        mixin Col!("lastName", string);

        static auto fullName(Expr!User u) {
            return firstName(u) ~ " " ~ lastName(u);
        }
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    db = new MockDB!();
    db.setTableData("users", `[
        {"id": 1, "first_name": "Alice", "last_name": "Smith"}
    ]`);

    auto query = compileQuery!Query(`{ users { fullName } }`);

    auto executor = new Executor();
    auto result = awaitSync(executor.execute(query));

    auto users = result["users"].array;
    assert(users.length == 1);
    assert(users[0]["fullName"].str == "Alice Smith");
}

unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dynamo.core;
    import dynamo.relational.schema;
    import dynamo.relational.demo;
    import dynamo.relational.eval_context;

    // Test nested hasMany relationships
    static MockDB!() db;

    static struct Post {
        mixin DemoEntity!(db, "posts");
        mixin Col!("title", string);
    }

    static struct User {
        mixin DemoEntity!(db, "users");
        mixin Col!("firstName", string);
        mixin HasMany!("posts", Post, "author_id");
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    db = new MockDB!();
    db.setTableData("users", `[
        {"id": 1, "first_name": "Alice"},
        {"id": 2, "first_name": "Bob"}
    ]`);
    db.setTableData("posts", `[
        {"id": 1, "author_id": 1, "title": "Hello"},
        {"id": 2, "author_id": 1, "title": "World"},
        {"id": 3, "author_id": 2, "title": "Test"}
    ]`);

    auto query = compileQuery!Query(`{ users { firstName, posts { title } } }`);

    auto executor = new Executor();
    auto result = awaitSync(executor.execute(query));

    auto users = result["users"].array;
    assert(users.length == 2);

    // Alice has 2 posts
    assert(users[0]["firstName"].str == "Alice");
    assert(users[0]["posts"].array.length == 2);
    assert(users[0]["posts"][0]["title"].str == "Hello");
    assert(users[0]["posts"][1]["title"].str == "World");

    // Bob has 1 post
    assert(users[1]["firstName"].str == "Bob");
    assert(users[1]["posts"].array.length == 1);
    assert(users[1]["posts"][0]["title"].str == "Test");
}

unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dynamo.core;
    import dynamo.relational.schema;
    import dynamo.relational.demo;
    import dynamo.relational.eval_context;

    // Test computed fields with arguments
    static MockDB!() db;

    static struct User {
        mixin DemoEntity!(db, "users");
        mixin Col!("firstName", string);

        // Computed field with required argument
        static auto greeting(Expr!User u, string prefix) {
            return prefix ~ " " ~ firstName(u);
        }

        // Computed field with optional argument (has default)
        static auto greetingWithSuffix(Expr!User u, string prefix, string suffix = "!") {
            return prefix ~ " " ~ firstName(u) ~ suffix;
        }
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    db = new MockDB!();
    db.setTableData("users", `[
        {"id": 1, "first_name": "Alice"},
        {"id": 2, "first_name": "Bob"}
    ]`);

    // Test with required argument
    auto query1 = compileQuery!Query(`{ users { greeting(prefix: "Hello") } }`);
    auto executor = new Executor();
    auto result1 = awaitSync(executor.execute(query1));

    auto users1 = result1["users"].array;
    assert(users1.length == 2);
    assert(users1[0]["greeting"].str == "Hello Alice");
    assert(users1[1]["greeting"].str == "Hello Bob");

    // Test with optional argument using default
    auto query2 = compileQuery!Query(`{ users { greetingWithSuffix(prefix: "Hi") } }`);
    auto result2 = awaitSync(executor.execute(query2));

    auto users2 = result2["users"].array;
    assert(users2.length == 2);
    assert(users2[0]["greetingWithSuffix"].str == "Hi Alice!");
    assert(users2[1]["greetingWithSuffix"].str == "Hi Bob!");

    // Test with optional argument overridden
    auto query3 = compileQuery!Query(`{ users { greetingWithSuffix(prefix: "Hey", suffix: "?") } }`);
    auto result3 = awaitSync(executor.execute(query3));

    auto users3 = result3["users"].array;
    assert(users3.length == 2);
    assert(users3[0]["greetingWithSuffix"].str == "Hey Alice?");
    assert(users3[1]["greetingWithSuffix"].str == "Hey Bob?");
}

unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dynamo.core;
    import dynamo.relational.schema;
    import dynamo.relational.demo;
    import dynamo.relational.eval_context;

    // Test multiple root fields
    static MockDB!() db;

    static struct Post {
        mixin DemoEntity!(db, "posts");
        mixin Col!("title", string);
    }

    static struct User {
        mixin DemoEntity!(db, "users");
        mixin Col!("firstName", string);
    }

    static struct Query {
        mixin Table!(User, "users");
        mixin Table!(Post, "posts");
    }

    db = new MockDB!();
    db.setTableData("users", `[
        {"id": 1, "first_name": "Alice"},
        {"id": 2, "first_name": "Bob"}
    ]`);
    db.setTableData("posts", `[
        {"id": 1, "title": "Hello"},
        {"id": 2, "title": "World"},
        {"id": 3, "title": "Test"}
    ]`);

    // Query with multiple root fields
    auto query = compileQuery!Query(`{
        users { firstName }
        posts { title }
    }`);

    auto executor = new Executor();
    auto result = awaitSync(executor.execute(query));

    // Result should have both users and posts
    auto users = result["users"].array;
    auto posts = result["posts"].array;

    assert(users.length == 2);
    assert(users[0]["firstName"].str == "Alice");
    assert(users[1]["firstName"].str == "Bob");

    assert(posts.length == 3);
    assert(posts[0]["title"].str == "Hello");
    assert(posts[1]["title"].str == "World");
    assert(posts[2]["title"].str == "Test");
}

unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dynamo.core;
    import dynamo.relational.schema;
    import dynamo.relational.demo;
    import dynamo.relational.eval_context;

    // Test input objects as computed field arguments

    // Define an input type (plain struct)
    static struct NameFormat {
        string prefix;
        string suffix;
    }

    static MockDB!() db;

    static struct User {
        mixin DemoEntity!(db, "users");
        mixin Col!("firstName", string);
        mixin Col!("lastName", string);

        // Computed field that takes an input object
        static auto formattedName(Expr!User u, NameFormat format) {
            return format.prefix ~ firstName(u) ~ " " ~ lastName(u) ~ format.suffix;
        }
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    db = new MockDB!();
    db.setTableData("users", `[
        {"id": 1, "first_name": "Alice", "last_name": "Smith"},
        {"id": 2, "first_name": "Bob", "last_name": "Jones"}
    ]`);

    // Query with input object argument
    auto query = compileQuery!Query(`{
        users {
            formattedName(format: {prefix: "Mr. ", suffix: "!"})
        }
    }`);

    auto executor = new Executor();
    auto result = awaitSync(executor.execute(query));

    auto users = result["users"].array;
    assert(users.length == 2);
    assert(users[0]["formattedName"].str == "Mr. Alice Smith!");
    assert(users[1]["formattedName"].str == "Mr. Bob Jones!");
}

unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dynamo.core;
    import dynamo.relational.schema;
    import dynamo.relational.demo;
    import dynamo.relational.eval_context;

    // Test nested input objects

    // Inner input type
    static struct Decoration {
        string left;
        string right;
    }

    // Outer input type containing inner
    static struct NameStyle {
        string separator;
        Decoration decoration;
    }

    static MockDB!() db;

    static struct User {
        mixin DemoEntity!(db, "users");
        mixin Col!("firstName", string);
        mixin Col!("lastName", string);

        // Computed field with nested input object
        static auto styledName(Expr!User u, NameStyle style) {
            return style.decoration.left ~ firstName(u) ~ style.separator ~ lastName(u) ~ style.decoration.right;
        }
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    db = new MockDB!();
    db.setTableData("users", `[
        {"id": 1, "first_name": "Alice", "last_name": "Smith"}
    ]`);

    // Query with nested input object
    auto query = compileQuery!Query(`{
        users {
            styledName(style: {
                separator: " - ",
                decoration: {left: "[", right: "]"}
            })
        }
    }`);

    auto executor = new Executor();
    auto result = awaitSync(executor.execute(query));

    auto users = result["users"].array;
    assert(users.length == 1);
    assert(users[0]["styledName"].str == "[Alice - Smith]");
}

unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dynamo.core;
    import dynamo.relational.schema;
    import dynamo.relational.demo;
    import dynamo.relational.eval_context;

    // Test GraphQL variables
    static MockDB!() db;

    static struct User {
        mixin DemoEntity!(db, "users");
        mixin Col!("firstName", string);

        // Computed field with arguments
        static auto greeting(Expr!User u, string prefix, string suffix = "!") {
            return prefix ~ " " ~ firstName(u) ~ suffix;
        }
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    db = new MockDB!();
    db.setTableData("users", `[
        {"id": 1, "first_name": "Alice"},
        {"id": 2, "first_name": "Bob"}
    ]`);

    // Query with variable for scalar argument
    auto variables = JSONValue([
        "greetPrefix": JSONValue("Hello"),
        "greetSuffix": JSONValue("?")
    ]);

    auto query = compileQuery!Query(`
        query GetUsers($greetPrefix: String!, $greetSuffix: String) {
            users {
                greeting(prefix: $greetPrefix, suffix: $greetSuffix)
            }
        }
    `, variables);

    auto executor = new Executor();
    auto result = awaitSync(executor.execute(query));

    auto users = result["users"].array;
    assert(users.length == 2);
    assert(users[0]["greeting"].str == "Hello Alice?");
    assert(users[1]["greeting"].str == "Hello Bob?");
}

unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dynamo.core;
    import dynamo.relational.schema;
    import dynamo.relational.demo;
    import dynamo.relational.eval_context;

    // Test variables with input objects

    static struct NameFormat {
        string prefix;
        string suffix;
    }

    static MockDB!() db;

    static struct User {
        mixin DemoEntity!(db, "users");
        mixin Col!("firstName", string);
        mixin Col!("lastName", string);

        static auto formattedName(Expr!User u, NameFormat format) {
            return format.prefix ~ firstName(u) ~ " " ~ lastName(u) ~ format.suffix;
        }
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    db = new MockDB!();
    db.setTableData("users", `[
        {"id": 1, "first_name": "Alice", "last_name": "Smith"}
    ]`);

    // Variable containing an input object
    auto variables = JSONValue([
        "fmt": JSONValue([
            "prefix": JSONValue("Dr. "),
            "suffix": JSONValue(", PhD")
        ])
    ]);

    auto query = compileQuery!Query(`
        query GetUsers($fmt: NameFormat!) {
            users {
                formattedName(format: $fmt)
            }
        }
    `, variables);

    auto executor = new Executor();
    auto result = awaitSync(executor.execute(query));

    auto users = result["users"].array;
    assert(users.length == 1);
    assert(users[0]["formattedName"].str == "Dr. Alice Smith, PhD");
}

unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dynamo.core;
    import dynamo.relational.schema;
    import dynamo.relational.demo;
    import dynamo.relational.eval_context;

    // Test compileQuery with Schema type (rather than raw Query type)
    static MockDB!() db;

    static struct User {
        mixin DemoEntity!(db, "users");
        mixin Col!("firstName", string);
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    // Create Schema from Query
    alias MySchema = dynamo.graphql.schema.Schema!(Query);

    db = new MockDB!();
    db.setTableData("users", `[
        {"id": 1, "first_name": "Alice"}
    ]`);

    // Compile using Schema type instead of raw Query
    auto query = compileQuery!MySchema(`{ users { firstName } }`);

    auto executor = new Executor();
    auto result = awaitSync(executor.execute(query));

    auto users = result["users"].array;
    assert(users.length == 1);
    assert(users[0]["firstName"].str == "Alice");
}

unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dynamo.core;
    import dynamo.core.expr : effect;
    import dynamo.relational.schema;
    import dynamo.relational.demo;
    import dynamo.relational.eval_context;
    import dynamo.graphql.schema : Schema;

    // Test mutation execution

    // Track mutation calls for testing
    __gshared static string lastGreeting;
    __gshared static int deleteCount;

    static struct Mutation {
        // Simple mutation returning scalar
        static Expr!string sayHello(Expr!Mutation parent, string name) {
            return effect(() {
                lastGreeting = "Hello, " ~ name ~ "!";
                return lastGreeting;
            }, parent);
        }

        // Mutation with multiple arguments
        static Expr!bool deleteItems(Expr!Mutation parent, int count) {
            return effect(() {
                deleteCount = count;
                return true;
            }, parent);
        }

        // Mutation with optional argument
        static Expr!string greet(Expr!Mutation parent, string name, string greeting = "Hi") {
            return effect(() => greeting ~ " " ~ name, parent);
        }
    }

    static MockDB!() db;

    static struct User {
        mixin DemoEntity!(db, "users");
        mixin Col!("name", string);
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    // Create Schema with mutations
    alias MySchema = Schema!(Query, Mutation);

    db = new MockDB!();
    db.setTableData("users", `[{"id": 1, "name": "Alice"}]`);

    // Reset tracking variables
    lastGreeting = "";
    deleteCount = 0;

    // Execute mutation
    auto mutation = compileQuery!MySchema(`
        mutation {
            sayHello(name: "World")
            deleteItems(count: 5)
            greet(name: "Bob")
        }
    `);

    auto executor = new Executor();
    auto result = awaitSync(executor.execute(mutation));

    // Verify mutation results
    assert(result["sayHello"].str == "Hello, World!", "sayHello should return greeting");
    assert(result["deleteItems"].boolean == true, "deleteItems should return true");
    assert(result["greet"].str == "Hi Bob", "greet should use default greeting");

    // Verify side effects occurred
    assert(lastGreeting == "Hello, World!", "sayHello should have been called");
    assert(deleteCount == 5, "deleteItems should have been called with count=5");
}

unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dynamo.core;
    import dynamo.core.expr : effect;
    import dynamo.relational.schema;
    import dynamo.relational.demo;
    import dynamo.relational.eval_context;
    import dynamo.graphql.schema : Schema;

    // Test mutation with input object

    static struct CreateUserInput {
        string name;
        string email;
    }

    __gshared static CreateUserInput lastInput;

    static struct Mutation {
        static Expr!string createUser(Expr!Mutation parent, CreateUserInput input) {
            return effect(() {
                lastInput = input;
                return "Created user: " ~ input.name;
            }, parent);
        }
    }

    static MockDB!() db;

    static struct User {
        mixin DemoEntity!(db, "users");
        mixin Col!("name", string);
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    alias MySchema = Schema!(Query, Mutation);

    db = new MockDB!();
    db.setTableData("users", `[{"id": 1, "name": "Alice"}]`);

    // Execute mutation with input object
    auto mutation = compileQuery!MySchema(`
        mutation {
            createUser(input: {name: "Bob", email: "bob@example.com"})
        }
    `);

    auto executor = new Executor();
    auto result = awaitSync(executor.execute(mutation));

    assert(result["createUser"].str == "Created user: Bob");
    assert(lastInput.name == "Bob");
    assert(lastInput.email == "bob@example.com");
}

unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dynamo.core;
    import dynamo.core.expr : effect;
    import dynamo.relational.schema;
    import dynamo.relational.demo;
    import dynamo.relational.eval_context;
    import dynamo.graphql.schema : Schema;

    // Test mutation with variables

    __gshared static string lastMessage;

    static struct Mutation {
        static Expr!string echo(Expr!Mutation parent, string message) {
            return effect(() {
                lastMessage = message;
                return message;
            }, parent);
        }
    }

    static MockDB!() db;

    static struct User {
        mixin DemoEntity!(db, "users");
        mixin Col!("name", string);
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    alias MySchema = Schema!(Query, Mutation);

    db = new MockDB!();
    db.setTableData("users", `[{"id": 1, "name": "Alice"}]`);

    // Execute mutation with variable
    auto variables = JSONValue([
        "msg": JSONValue("Hello from variable!")
    ]);

    auto mutation = compileQuery!MySchema(`
        mutation Echo($msg: String!) {
            echo(message: $msg)
        }
    `, variables);

    auto executor = new Executor();
    auto result = awaitSync(executor.execute(mutation));

    assert(result["echo"].str == "Hello from variable!");
    assert(lastMessage == "Hello from variable!");
}

// Test mutation returning a single entity with selection set
unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dynamo.core;
    import dynamo.core.expr : effect;
    import dynamo.relational.schema;
    import dynamo.relational.demo;
    import dynamo.relational.eval_context;
    import dynamo.graphql.schema : Schema;

    static MockDB!() db;

    static struct User {
        mixin DemoEntity!(db, "users");
        mixin Col!("name", string);
        mixin Col!("email", string);
    }

    static struct Mutation {
        // Mutation that creates a user and returns the entity
        static Expr!User createUser(Expr!Mutation parent, string name, string email) {
            return effect(() {
                // In a real implementation, this would INSERT and return the new ID
                // For testing, we'll just return an existing user
                return User("User:1");
            }, parent);
        }
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    alias MySchema = Schema!(Query, Mutation);

    db = new MockDB!();
    db.setTableData("users", `[
        {"id": 1, "name": "Alice", "email": "alice@example.com"},
        {"id": 2, "name": "Bob", "email": "bob@example.com"}
    ]`);

    // Execute mutation with selection set on returned entity
    auto mutation = compileQuery!MySchema(`
        mutation {
            createUser(name: "Charlie", email: "charlie@example.com") {
                name
                email
            }
        }
    `);

    auto executor = new Executor();
    auto result = awaitSync(executor.execute(mutation));

    // Verify the returned entity has the selected fields
    assert(result["createUser"]["name"].str == "Alice");
    assert(result["createUser"]["email"].str == "alice@example.com");
}

// Test mutation returning an array of entities with selection set
unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dynamo.core;
    import dynamo.core.expr : effect;
    import dynamo.relational.schema;
    import dynamo.relational.demo;
    import dynamo.relational.eval_context;
    import dynamo.graphql.schema : Schema;

    static MockDB!() db;

    static struct User {
        mixin DemoEntity!(db, "users");
        mixin Col!("name", string);
    }

    static struct Mutation {
        // Mutation that returns multiple entities
        static Expr!(User[]) getActiveUsers(Expr!Mutation parent) {
            return effect(() {
                // Return array of user refs
                return [User("User:1"), User("User:2")];
            }, parent);
        }
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    alias MySchema = Schema!(Query, Mutation);

    db = new MockDB!();
    db.setTableData("users", `[
        {"id": 1, "name": "Alice"},
        {"id": 2, "name": "Bob"}
    ]`);

    // Execute mutation with selection set on returned entities
    auto mutation = compileQuery!MySchema(`
        mutation {
            getActiveUsers {
                name
            }
        }
    `);

    auto executor = new Executor();
    auto result = awaitSync(executor.execute(mutation));

    // Verify the returned entities have the selected fields
    auto users = result["getActiveUsers"].array;
    assert(users.length == 2);
    assert(users[0]["name"].str == "Alice");
    assert(users[1]["name"].str == "Bob");
}

// Test getFieldName/getFieldAlias with aliased fields (verifies graphql-d AST handling)
unittest {
    import graphql.parser : Parser;
    import graphql.lexer : Lexer;

    // Test aliased field: "myAlias: actualField"
    {
        auto lexer = Lexer(`{ myAlias: actualField }`);
        auto parser = Parser(lexer);
        auto doc = parser.parseDocument();
        auto field = doc.defs.def.op.ss.sel.sel.field;

        assert(getFieldName(field) == "actualField", "Should extract actual field name");
        assert(getFieldAlias(field) == "myAlias", "Should extract alias");
        assert(getOutputName(field) == "myAlias", "Output name should be the alias");
    }

    // Test non-aliased field: "justAField"
    {
        auto lexer = Lexer(`{ justAField }`);
        auto parser = Parser(lexer);
        auto doc = parser.parseDocument();
        auto field = doc.defs.def.op.ss.sel.sel.field;

        assert(getFieldName(field) == "justAField", "Should extract field name");
        assert(getFieldAlias(field) is null, "Should have no alias");
        assert(getOutputName(field) == "justAField", "Output name should be the field name");
    }
}

// Test scalar methods on Query root (not just Table fields)
unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dynamo.core;
    import dynamo.core.expr : constant;
    import dynamo.relational.schema;
    import dynamo.relational.demo;
    import dynamo.relational.eval_context;
    import dynamo.graphql.schema : Schema;

    static MockDB!() db;

    static struct User {
        mixin DemoEntity!(db, "users");
        mixin Col!("name", string);
    }

    static struct Query {
        // Table field - returns [User!]!
        mixin Table!(User, "users");

        // Scalar field - returns Int!
        static auto userCount(Expr!Query parent) {
            // In a real implementation, this would be COUNT(*) from users
            return constant(42, parent);
        }

        // Scalar field with int argument - returns Int!
        static auto userCountWithLimit(Expr!Query parent, int limit) {
            // In a real implementation, this would be COUNT(*) LIMIT $1
            return constant(limit < 42 ? limit : 42, parent);
        }

        // Scalar field returning string
        static auto serverVersion(Expr!Query parent) {
            return constant("1.0.0", parent);
        }

        // Scalar field with default argument
        static auto greeting(Expr!Query parent, string name = "World") {
            return constant("Hello, " ~ name ~ "!", parent);
        }
    }

    alias MySchema = Schema!(Query);

    db = new MockDB!();
    db.setTableData("users", `[
        {"id": 1, "name": "Alice"},
        {"id": 2, "name": "Bob"}
    ]`);

    // Test scalar field without arguments
    {
        auto query = compileQuery!MySchema(`{
            userCount
            serverVersion
        }`);

        auto executor = new Executor();
        auto result = awaitSync(executor.execute(query));

        assert(result["userCount"].integer == 42);
        assert(result["serverVersion"].str == "1.0.0");
    }

    // Test scalar field with arguments
    {
        auto query = compileQuery!MySchema(`{
            limitedCount: userCountWithLimit(limit: 10)
            fullCount: userCountWithLimit(limit: 100)
        }`);

        auto executor = new Executor();
        auto result = awaitSync(executor.execute(query));

        assert(result["limitedCount"].integer == 10);
        assert(result["fullCount"].integer == 42);
    }

    // Test scalar field with default argument
    {
        auto query = compileQuery!MySchema(`{
            defaultGreeting: greeting
            customGreeting: greeting(name: "Alice")
        }`);

        auto executor = new Executor();
        auto result = awaitSync(executor.execute(query));

        assert(result["defaultGreeting"].str == "Hello, World!");
        assert(result["customGreeting"].str == "Hello, Alice!");
    }

    // Test mixing scalar and table fields
    {
        auto query = compileQuery!MySchema(`{
            userCount
            users { name }
        }`);

        auto executor = new Executor();
        auto result = awaitSync(executor.execute(query));

        assert(result["userCount"].integer == 42);
        assert(result["users"].array.length == 2);
        assert(result["users"].array[0]["name"].str == "Alice");
    }
}

// Test mutation returning custom payload type (Postgraphile pattern)
unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dynamo.core;
    import dynamo.core.expr : effect, constant, singleton;
    import dynamo.relational.schema;
    import dynamo.relational.demo;
    import dynamo.relational.eval_context;
    import dynamo.graphql.schema : Schema;

    static MockDB!() db;

    static struct User {
        mixin DemoEntity!(db, "users");
        mixin Col!("name", string);
    }

    // Custom payload type with multiple fields
    static struct CreateUserPayload {
        // Return the created user
        static auto user(Expr!CreateUserPayload p) {
            // In reality, this would return the newly created user
            // For testing, return a reference to user 1
            return effect(() => User("User:1"), p);
        }

        // Return a success message
        static auto message(Expr!CreateUserPayload p) {
            return constant("User created successfully", p);
        }

        // Return the client mutation ID (GraphQL Relay pattern)
        static auto clientMutationId(Expr!CreateUserPayload p) {
            return constant("mutation-123", p);
        }
    }

    static struct Mutation {
        // Mutation returning a custom payload type
        static Expr!CreateUserPayload createUser(Expr!Mutation parent, string name) {
            return effect(() => CreateUserPayload.init, parent);
        }
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    alias MySchema = Schema!(Query, Mutation);

    db = new MockDB!();
    db.setTableData("users", `[
        {"id": 1, "name": "Alice"},
        {"id": 2, "name": "Bob"}
    ]`);

    // Execute mutation with selection set on custom payload
    auto mutation = compileQuery!MySchema(`
        mutation {
            createUser(name: "Charlie") {
                message
                clientMutationId
                user {
                    name
                }
            }
        }
    `);

    auto executor = new Executor();
    auto result = awaitSync(executor.execute(mutation));

    // Verify payload fields
    auto payload = result["createUser"];
    assert(payload["message"].str == "User created successfully");
    assert(payload["clientMutationId"].str == "mutation-123");
    assert(payload["user"]["name"].str == "Alice");
}

// Test mutation payload returning Query type (full Postgraphile pattern)
unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dynamo.core;
    import dynamo.core.expr : effect, constant, singleton;
    import dynamo.relational.schema;
    import dynamo.relational.demo;
    import dynamo.relational.eval_context;
    import dynamo.graphql.schema : Schema;

    static MockDB!() db;

    static struct User {
        mixin DemoEntity!(db, "users");
        mixin Col!("name", string);
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    // Payload that includes access to the Query root
    static struct CreateUserPayload {
        static auto user(Expr!CreateUserPayload p) {
            return effect(() => User("User:1"), p);
        }

        // Return the Query root - allows refetching any data after mutation
        static auto query(Expr!CreateUserPayload p) {
            return singleton(Query.init);
        }
    }

    static struct Mutation {
        static Expr!CreateUserPayload createUser(Expr!Mutation parent, string name) {
            return effect(() => CreateUserPayload.init, parent);
        }
    }

    alias MySchema = Schema!(Query, Mutation);

    db = new MockDB!();
    db.setTableData("users", `[
        {"id": 1, "name": "Alice"},
        {"id": 2, "name": "Bob"}
    ]`);

    // Execute mutation that refetches data via query field
    auto mutation = compileQuery!MySchema(`
        mutation {
            createUser(name: "Charlie") {
                user { name }
                query {
                    users { name }
                }
            }
        }
    `);

    auto executor = new Executor();
    auto result = awaitSync(executor.execute(mutation));

    // Verify payload fields
    auto payload = result["createUser"];
    assert(payload["user"]["name"].str == "Alice");

    // Verify we can query the full graph via the query field
    auto users = payload["query"]["users"].array;
    assert(users.length == 2);
    assert(users[0]["name"].str == "Alice");
    assert(users[1]["name"].str == "Bob");
}

// Test enum support in queries
unittest {
    import ae.utils.promise.await : awaitSync;
    import dynamo.core.executor : Executor;
    import dynamo.relational.demo : DemoEntity, MockDB;
    import dynamo.relational.schema : Col, Table, getAll;

    enum Status { pending, inProgress, completed }

    static MockDB!() db;

    static struct Task {
        mixin DemoEntity!(db, "tasks");
        mixin Col!("title", string);
        mixin Col!("status", Status);
    }

    static struct Query {
        mixin Table!(Task, "tasks");
    }

    db = new MockDB!();
    db.setTableData("tasks", `[
        {"id": 1, "title": "Task 1", "status": "pending"},
        {"id": 2, "title": "Task 2", "status": "inProgress"},
        {"id": 3, "title": "Task 3", "status": "completed"}
    ]`);

    // Query tasks with enum field
    auto query = compileQuery!Query(`{
        tasks {
            title
            status
        }
    }`);

    auto executor = new Executor();
    auto result = awaitSync(executor.execute(query));

    // Verify enum values are returned correctly
    auto tasks = result["tasks"].array;
    assert(tasks.length == 3, "Should have 3 tasks");
    assert(tasks[0]["status"].str == "pending", "First task status should be pending");
    assert(tasks[1]["status"].str == "inProgress", "Second task status should be inProgress");
    assert(tasks[2]["status"].str == "completed", "Third task status should be completed");
}

// Test pointer input type extraction (self-referential via pointer)
unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dynamo.core;
    import dynamo.relational.schema;
    import dynamo.relational.demo;
    import dynamo.relational.eval_context;

    // Self-referential input type via pointer
    static struct NodeInput {
        string value;
        NodeInput* next;
    }

    static MockDB!() db;

    static struct User {
        mixin DemoEntity!(db, "users");
        mixin Col!("name", string);

        // Computed field taking recursive pointer input
        static auto traverseList(Expr!User u, NodeInput* head) {
            // For testing, just return the user's name
            // Real impl would use the input
            return u.name;
        }
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    db = new MockDB!();
    db.setTableData("users", `[{"id": 1, "name": "Alice"}]`);

    // Test null pointer input
    auto query1 = compileQuery!Query(`{
        users {
            traverseList(head: null)
        }
    }`);
    auto executor = new Executor();
    auto result1 = awaitSync(executor.execute(query1));
    auto users1 = result1["users"].array;
    assert(users1.length == 1);
    assert(users1[0]["traverseList"].str == "Alice");

    // Test pointer with value (single node)
    auto query2 = compileQuery!Query(`{
        users {
            traverseList(head: {value: "first", next: null})
        }
    }`);
    auto result2 = awaitSync(executor.execute(query2));
    auto users2 = result2["users"].array;
    assert(users2.length == 1);
    assert(users2[0]["traverseList"].str == "Alice");

    // Test pointer with nested value (linked list)
    auto query3 = compileQuery!Query(`{
        users {
            traverseList(head: {value: "first", next: {value: "second", next: null}})
        }
    }`);
    auto result3 = awaitSync(executor.execute(query3));
    auto users3 = result3["users"].array;
    assert(users3.length == 1);
    assert(users3[0]["traverseList"].str == "Alice");
}

// Test pointer input type via JSON variable
unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dynamo.core;
    import dynamo.relational.schema;
    import dynamo.relational.demo;
    import dynamo.relational.eval_context;

    static struct NodeInput {
        string value;
        NodeInput* next;
    }

    static MockDB!() db;

    static struct User {
        mixin DemoEntity!(db, "users");
        mixin Col!("name", string);

        static auto traverseList(Expr!User u, NodeInput* head) {
            return u.name;
        }
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    db = new MockDB!();
    db.setTableData("users", `[{"id": 1, "name": "Alice"}]`);

    // Test with variable containing nested pointer structure
    auto variables = JSONValue([
        "node": JSONValue([
            "value": JSONValue("first"),
            "next": JSONValue([
                "value": JSONValue("second"),
                "next": JSONValue(null)
            ])
        ])
    ]);

    auto query = compileQuery!Query(`
        query TestPointer($node: NodeInput) {
            users {
                traverseList(head: $node)
            }
        }
    `, variables);

    auto executor = new Executor();
    auto result = awaitSync(executor.execute(query));
    auto users = result["users"].array;
    assert(users.length == 1);
    assert(users[0]["traverseList"].str == "Alice");
}

// Test array self-reference input type
unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dynamo.core;
    import dynamo.relational.schema;
    import dynamo.relational.demo;
    import dynamo.relational.eval_context;

    // Self-referential via array
    static struct FilterInput {
        string field;
        FilterInput[] and;
    }

    static MockDB!() db;

    static struct User {
        mixin DemoEntity!(db, "users");
        mixin Col!("name", string);

        static auto matchFilter(Expr!User u, FilterInput filter) {
            return u.name;
        }
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    db = new MockDB!();
    db.setTableData("users", `[{"id": 1, "name": "Alice"}]`);

    // Test with nested array recursion
    auto query = compileQuery!Query(`{
        users {
            matchFilter(filter: {
                field: "name",
                and: [
                    {field: "age", and: []},
                    {field: "email", and: [{field: "domain", and: []}]}
                ]
            })
        }
    }`);

    auto executor = new Executor();
    auto result = awaitSync(executor.execute(query));
    auto users = result["users"].array;
    assert(users.length == 1);
    assert(users[0]["matchFilter"].str == "Alice");
}

// __typename introspection test
unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dynamo.core;
    import dynamo.relational.schema;
    import dynamo.relational.demo;

    static MockDB!() db;

    static struct User {
        mixin DemoEntity!(db, "users");
        mixin Col!("firstName", string);
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    db = new MockDB!();
    db.setTableData("users", `[
        {"id": 1, "first_name": "Alice"}
    ]`);

    auto executor = new Executor();

    // __typename on root Query
    {
        auto query = compileQuery!Query(`{ __typename }`);
        auto result = awaitSync(executor.execute(query));
        assert(result["__typename"].str == "Query");
    }

    // __typename on entity
    {
        auto query = compileQuery!Query(`{ users { __typename firstName } }`);
        auto result = awaitSync(executor.execute(query));
        auto users = result["users"].array;
        assert(users.length == 1);
        assert(users[0]["__typename"].str == "User");
        assert(users[0]["firstName"].str == "Alice");
    }
}

// __schema introspection test
unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dynamo.core;
    import dynamo.relational.schema;
    import dynamo.relational.demo;

    static MockDB!() db;

    static struct User {
        mixin DemoEntity!(db, "users");
        mixin Col!("firstName", string);
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    db = new MockDB!();

    auto executor = new Executor();

    // Basic __schema query
    {
        auto query = compileQuery!Query(`{ __schema { queryType { name } } }`);
        auto result = awaitSync(executor.execute(query));
        assert(result["__schema"]["queryType"]["name"].str == "Query");
    }

    // __schema with types
    {
        auto query = compileQuery!Query(`{ __schema { types { name kind } } }`);
        auto result = awaitSync(executor.execute(query));
        auto types = result["__schema"]["types"].array;
        bool foundUser = false;
        bool foundQuery = false;
        foreach (t; types) {
            if (t["name"].str == "User") {
                foundUser = true;
                assert(t["kind"].str == "OBJECT");
            }
            if (t["name"].str == "Query") {
                foundQuery = true;
                assert(t["kind"].str == "OBJECT");
            }
        }
        assert(foundUser, "Should find User type");
        assert(foundQuery, "Should find Query type");
    }
}

// __type introspection test
unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dynamo.core;
    import dynamo.relational.schema;
    import dynamo.relational.demo;

    static MockDB!() db;

    static struct User {
        mixin DemoEntity!(db, "users");
        mixin Col!("firstName", string);
        mixin Col!("lastName", string);
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    db = new MockDB!();

    auto executor = new Executor();

    // __type lookup for existing type
    {
        auto query = compileQuery!Query(`{ __type(name: "User") { name kind } }`);
        auto result = awaitSync(executor.execute(query));
        assert(result["__type"]["name"].str == "User");
        assert(result["__type"]["kind"].str == "OBJECT");
    }

    // __type lookup for non-existent type
    {
        auto query = compileQuery!Query(`{ __type(name: "NonExistent") { name } }`);
        auto result = awaitSync(executor.execute(query));
        assert(result["__type"].isNull);
    }

    // __type with fields
    {
        auto query = compileQuery!Query(`{ __type(name: "User") { name fields { name type { kind name } } } }`);
        auto result = awaitSync(executor.execute(query));
        assert(result["__type"]["name"].str == "User");
        auto fields = result["__type"]["fields"].array;
        bool foundFirstName = false;
        foreach (f; fields) {
            if (f["name"].str == "firstName") {
                foundFirstName = true;
                // String! → NON_NULL wrapping SCALAR String
                assert(f["type"]["kind"].str == "NON_NULL");
                assert(f["type"]["name"].isNull);
            }
        }
        assert(foundFirstName, "Should find firstName field");
    }
}

// Col field + plain method in the same selection set
// Regression test: evalAs cache stored Promise!(AnyRef[]) from column access,
// then MethodCallExpr tried to retrieve as Promise!(Entity[]) — cast returned
// null → SIGSEGV on .then(). Fixed by runtime type-checking the cache.
unittest {
    import std.json;
    import ae.utils.promise.await : awaitSync;
    import dynamo.core;
    import dynamo.relational.schema;
    import dynamo.relational.demo;

    static MockDB!() db;

    static struct Item {
        mixin DemoEntity!(db, "items");
        mixin Col!("title", string);

        string label() => "item-label";
    }

    static struct Query {
        mixin Table!(Item, "items");
    }

    db = new MockDB!();
    db.setTableData("items", `[{"id": 1, "title": "Thing"}]`);

    auto query = compileQuery!(Schema!(Query))(`{ items { title label } }`);
    auto executor = new Executor();
    auto result = awaitSync(executor.execute(query));

    auto items = result["items"].array;
    assert(items.length == 1);
    assert(items[0]["title"].str == "Thing");
    assert(items[0]["label"].str == "item-label");
}
