module dunamis.graphql.compiler.fields;

import std.conv;
import std.json;
import std.traits;
import std.typecons : Nullable;

import graphql.ast;

import dunamis.core.expr : Expr, isExpr;
import dunamis.graphql.schema : isInputType, isInternalMember;
import dunamis.graphql.compiler.values;

// ============================================================================
// Computed Field Invocation
// ============================================================================

package(dunamis.graphql):

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
auto callComputedField(alias fn, Entity)(Expr!Entity entityRef, Arguments args, JSONValue variables) {
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
                    "extractArg!(Params[" ~ i.stringof ~ "], Defaults[" ~ i.stringof ~ "])" ~
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
T extractArg(T, alias Default)(Arguments args, string name, JSONValue variables) {
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
        return extractValueFromJson!T(variables.object[lookup.variableName]);
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
        // Go through the JSON representation so variables nested inside input
        // object/list literals are resolved as well (e.g.
        // `filter: {name: {equalTo: $name}}`).
        return extractValueFromJson!T(valueToJson(lookup.value, variables));
    }
}
