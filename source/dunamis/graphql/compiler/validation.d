module dunamis.graphql.compiler.validation;

import std.algorithm;
import std.array;
import std.conv;
import std.json;
import std.traits;
import std.typecons : Nullable;

import graphql.ast;
import graphql.tokenmodule : Token;

import dunamis.core.types : isCustomScalar, isGqlResult, isAbstractType, getImplementedByMembers, isPublicDataField;
import dunamis.core.expr : ExprResultType, Expr, isExpr;
import dunamis.core.discovery : isObjectType, extractObjectFromType, getSchemaFields,
    getAbstractTypeMembers, getSchemaObjectTypes;
import dunamis.graphql.schema;
import dunamis.graphql.compiler.values;
import dunamis.graphql.compiler.extensions : extensionFieldExists;
import dunamis.graphql.compiler.selection : abstractTypeNamesIn, typeConditionApplies;

// ============================================================================
// Types
// ============================================================================

private template isScalarElement(T) {
    import std.traits : isSomeString;
    static if (is(T == Nullable!U, U))
        enum isScalarElement = isScalarElement!U;
    else static if (is(T == E[], E) && !isSomeString!T && !isCustomScalar!T)
        enum isScalarElement = isScalarElement!E;
    else
        enum isScalarElement = isCustomScalar!T || !is(T == struct) || isGqlResult!T;
}

/// A validation error with source location information.
struct ValidationError {
    string message;
    uint line;      // 0 = unknown
    ushort column;  // 0 = unknown

    /// Convert to GraphQL-spec error JSON format.
    JSONValue toJson() const {
        auto result = JSONValue.emptyObject;
        result["message"] = JSONValue(message);
        if (line > 0) {
            result["locations"] = JSONValue([
                JSONValue(["line": JSONValue(cast(long) line), "column": JSONValue(cast(long) column)])
            ]);
        }
        return result;
    }
}

/// Exception thrown when validation finds errors. Carries the full error list.
/// Extends CompilerException so existing catch blocks still work.
class ValidationException : CompilerException {
    ValidationError[] errors;

    this(ValidationError[] errors, string file = __FILE__, size_t line = __LINE__) {
        // Build a combined message from all errors
        string msg = errors.length.to!string ~ " validation error(s):";
        foreach (err; errors) {
            msg ~= "\n  - " ~ err.message;
        }
        super(msg, file, line);
        this.errors = errors;
    }
}

// ============================================================================
// Entry Point
// ============================================================================

package(dunamis.graphql):

/// Validate a parsed GraphQL document against a schema.
/// Returns an empty array if valid, or a list of ValidationErrors.
///
/// Requires a Schema type (guarantees normalization). See Schema Protocol
/// in core/discovery.d.
ValidationError[] validateQuery(alias SchemaType)(
    Document doc,
    OperationDefinition op,
    FragmentMap fragments,
    JSONValue variables = JSONValue.emptyObject
) if (isSchema!SchemaType) {
    alias QueryType = SchemaType.Query;
    alias MutationType = SchemaType.Mutation;
    alias SubscriptionType = SchemaType.Subscription;

    ValidationError[] errors;

    // 1. AST-only checks (pure runtime)
    errors ~= validateDuplicateOperations(doc);
    errors ~= validateDuplicateFragments(doc);
    errors ~= validateVariables(op, fragments);

    // 2. Type-aware checks (templated on schema types)
    bool isMutation = op.ot !is null && op.ot.ruleSelection == OperationTypeEnum.Mutation;
    bool isSubscription = op.ot !is null && op.ot.ruleSelection == OperationTypeEnum.Sub;

    if (op.ss !is null) {
        if (isSubscription) {
            static if (getFields!SubscriptionType.length > 0) {
                errors ~= validateSubscriptionSelectionSet!(SubscriptionType, SchemaType)(op.ss, fragments, variables);
            } else {
                errors ~= ValidationError("Subscription operations require a Schema with Subscription type");
            }
        } else if (isMutation) {
            static if (getFields!MutationType.length > 0) {
                errors ~= validateRootSelectionSet!(MutationType, SchemaType)(op.ss, fragments, null, variables);
            }
        } else {
            errors ~= validateRootSelectionSet!(QueryType, SchemaType)(op.ss, fragments, null, variables);
        }
    }

    return errors;
}

// ============================================================================
// AST-Only Validations
// ============================================================================

/// Check for duplicate operation names in the document.
private ValidationError[] validateDuplicateOperations(Document doc) {
    ValidationError[] errors;
    if (doc is null || doc.defs is null) return errors;

    string[][string] nameLocations; // name -> list of locations
    uint[][string] nameLines;
    ushort[][string] nameCols;

    void walk(Definitions defs) {
        if (defs is null) return;
        if (defs.def !is null && defs.def.ruleSelection == DefinitionEnum.O) {
            auto op = defs.def.op;
            if (op !is null && op.name.value !is null) {
                auto name = op.name.value;
                if (name !in nameLocations) {
                    nameLocations[name] = [];
                    nameLines[name] = [];
                    nameCols[name] = [];
                }
                nameLocations[name] ~= name;
                nameLines[name] ~= op.name.line;
                nameCols[name] ~= op.name.column;
            }
        }
        if (defs.follow !is null) walk(defs.follow);
    }

    walk(doc.defs);

    foreach (name, locs; nameLocations) {
        if (locs.length > 1) {
            // Report error on the second (and subsequent) occurrences
            foreach (i; 1 .. locs.length) {
                errors ~= ValidationError(
                    "Duplicate operation name '" ~ name ~ "'",
                    nameLines[name][i],
                    nameCols[name][i]
                );
            }
        }
    }

    return errors;
}

/// Check for duplicate fragment names in the document.
private ValidationError[] validateDuplicateFragments(Document doc) {
    ValidationError[] errors;
    if (doc is null || doc.defs is null) return errors;

    uint[][string] nameLines;
    ushort[][string] nameCols;

    void walk(Definitions defs) {
        if (defs is null) return;
        if (defs.def !is null && defs.def.ruleSelection == DefinitionEnum.F) {
            auto frag = defs.def.frag;
            if (frag !is null && frag.name.value !is null) {
                auto name = frag.name.value;
                if (name !in nameLines) {
                    nameLines[name] = [];
                    nameCols[name] = [];
                }
                nameLines[name] ~= frag.name.line;
                nameCols[name] ~= frag.name.column;
            }
        }
        if (defs.follow !is null) walk(defs.follow);
    }

    walk(doc.defs);

    foreach (name, lines; nameLines) {
        if (lines.length > 1) {
            foreach (i; 1 .. lines.length) {
                errors ~= ValidationError(
                    "Duplicate fragment name '" ~ name ~ "'",
                    lines[i],
                    nameCols[name][i]
                );
            }
        }
    }

    return errors;
}

/// Validate undefined and unused variables.
private ValidationError[] validateVariables(OperationDefinition op, FragmentMap fragments) {
    ValidationError[] errors;
    if (op is null) return errors;

    // Collect declared variables
    Token[string] declaredVars; // name -> Token (for location)
    if (op.vd !is null) {
        iterateVariableDefinitions(op.vd, (VariableDefinition varDef) {
            if (varDef.var !is null && varDef.var.name.value !is null) {
                declaredVars[varDef.var.name.value] = varDef.var.name;
            }
        });
    }

    // Collect used variable references
    Token[string] usedVars; // name -> Token (for location of first use)
    bool[string] visited; // fragment cycle guard
    collectVariableReferences(op.ss, fragments, usedVars, visited);

    // Check for undefined variables (used but not declared)
    foreach (name, tok; usedVars) {
        if (name !in declaredVars) {
            errors ~= ValidationError(
                "Variable $" ~ name ~ " is not defined",
                tok.line,
                tok.column
            );
        }
    }

    // Check for unused variables (declared but not used)
    foreach (name, tok; declaredVars) {
        if (name !in usedVars) {
            errors ~= ValidationError(
                "Variable $" ~ name ~ " is defined but not used",
                tok.line,
                tok.column
            );
        }
    }

    return errors;
}

/// Iterate over variable definitions in an operation.
private void iterateVariableDefinitions(VariableDefinitions vds, void delegate(VariableDefinition) callback) {
    if (vds is null || vds.vars is null) return;
    iterateVariableDefinitionList(vds.vars, callback);
}

private void iterateVariableDefinitionList(VariableDefinitionList list, void delegate(VariableDefinition) callback) {
    if (list is null) return;
    if (list.var !is null) callback(list.var);
    if (list.follow !is null) iterateVariableDefinitionList(list.follow, callback);
}

/// Collect all variable references from a selection set.
private void collectVariableReferences(
    SelectionSet ss,
    FragmentMap fragments,
    ref Token[string] usedVars,
    ref bool[string] visited
) {
    if (ss is null) return;

    foreach (sel; iterateSelections(ss)) {
        if (sel.ruleSelection == SelectionEnum.Field) {
            auto field = sel.field;
            if (field is null) continue;
            collectVariableRefsFromArgs(field.args, usedVars);
            collectVariableRefsFromDirectives(field.dirs, usedVars);
            // Recurse into nested selection set
            collectVariableReferences(field.ss, fragments, usedVars, visited);
        } else if (sel.ruleSelection == SelectionEnum.Spread) {
            auto spread = sel.frag;
            if (spread is null) continue;
            collectVariableRefsFromDirectives(spread.dirs, usedVars);
            auto fragName = spread.name.value;
            if (fragName !is null && fragName !in visited) {
                auto fragDefPtr = fragName in fragments;
                if (fragDefPtr !is null) {
                    visited[fragName] = true;
                    collectVariableReferences((*fragDefPtr).ss, fragments, usedVars, visited);
                }
            }
        } else if (sel.ruleSelection == SelectionEnum.IFrag) {
            auto ifrag = sel.ifrag;
            if (ifrag is null) continue;
            collectVariableRefsFromDirectives(ifrag.dirs, usedVars);
            collectVariableReferences(ifrag.ss, fragments, usedVars, visited);
        }
    }
}

/// Collect variable references from arguments.
private void collectVariableRefsFromArgs(Arguments args, ref Token[string] usedVars) {
    foreach (arg; iterateArguments(args)) {
        if (arg.vv !is null) {
            collectVariableRefs(arg.vv, usedVars);
        }
    }
}

/// Collect variable references from a ValueOrVariable node.
private void collectVariableRefs(ValueOrVariable vov, ref Token[string] usedVars) {
    if (vov is null) return;
    if (vov.ruleSelection == ValueOrVariableEnum.Var && vov.var !is null) {
        auto name = vov.var.name.value;
        if (name !is null && name !in usedVars) {
            usedVars[name] = vov.var.name;
        }
    } else if (vov.val !is null) {
        // Recurse into literal values to find nested variable references
        collectVariableRefs(vov.val, usedVars);
    }
}

/// Collect variable references from a Value node (recursing into objects and arrays).
private void collectVariableRefs(Value val, ref Token[string] usedVars) {
    if (val is null) return;

    if (val.ruleSelection == ValueEnum.O && val.obj !is null) {
        // Object literal — may contain variable references in field values
        void walkObjectValues(ObjectValues ov) {
            if (ov is null) return;
            if (ov.val !is null) {
                collectVariableRefs(ov.val, usedVars);
            }
            if (ov.follow !is null) walkObjectValues(ov.follow);
        }
        if (val.obj.vals !is null) walkObjectValues(val.obj.vals);
    } else if (val.ruleSelection == ValueEnum.ARR && val.arr !is null) {
        // Array literal — recurse into each element
        void walkValues(Values v) {
            if (v is null) return;
            if (v.val !is null) collectVariableRefs(v.val, usedVars);
            if (v.follow !is null) walkValues(v.follow);
        }
        if (val.arr.vals !is null) walkValues(val.arr.vals);
    }
}

/// Collect variable references from directives.
private void collectVariableRefsFromDirectives(Directives dirs, ref Token[string] usedVars) {
    auto d = dirs;
    while (d !is null) {
        if (d.dir !is null) {
            collectVariableRefsFromArgs(d.dir.arg, usedVars);
        }
        d = d.follow;
    }
}

// ============================================================================
// Type-Aware Validations
// ============================================================================

/// Validate a subscription selection set.
/// Enforces the GraphQL spec requirement of exactly one root field.
private ValidationError[] validateSubscriptionSelectionSet(Subscription, alias SchemaSource)(
    SelectionSet ss, FragmentMap fragments, JSONValue variables
) {
    // First, validate fields the same way as any root selection set
    auto errors = validateRootSelectionSet!(Subscription, SchemaSource)(ss, fragments, null, variables);

    // Count root fields to enforce single-field rule
    auto selections = iterateSelections(ss);
    size_t fieldCount = 0;
    foreach (sel; selections) {
        if (sel.ruleSelection == SelectionEnum.Field) {
            fieldCount++;
        }
    }

    if (fieldCount > 1) {
        // Get location from the second field for the error
        size_t seen = 0;
        foreach (sel; selections) {
            if (sel.ruleSelection == SelectionEnum.Field) {
                seen++;
                if (seen == 2) {
                    errors ~= fieldError(
                        "Subscription operations must have exactly one root field",
                        sel.field
                    );
                    break;
                }
            }
        }
    }

    return errors;
}

/// Validate a root selection set against a Query/Mutation type.
private ValidationError[] validateRootSelectionSet(Query, alias SchemaSource)(
    SelectionSet ss, FragmentMap fragments, bool[string] visited, JSONValue variables
) {
    ValidationError[] errors;
    auto selections = iterateSelections(ss);

    foreach (sel; selections) {
        if (sel.ruleSelection == SelectionEnum.Field) {
            auto field = sel.field;
            if (field is null) continue;
            errors ~= validateRootField!(Query, SchemaSource)(field, fragments, visited, variables);
        } else if (sel.ruleSelection == SelectionEnum.Spread) {
            auto spread = sel.frag;
            if (spread is null) continue;
            auto fragName = spread.name.value;
            if (fragName is null || fragName in visited) continue;
            auto fragDefPtr = fragName in fragments;
            if (fragDefPtr !is null) {
                auto fragDef = *fragDefPtr;
                if (fragDef.tc.value is null || fragDef.tc.value == getGraphQLTypeName!Query) {
                    visited[fragName] = true;
                    errors ~= validateRootSelectionSet!(Query, SchemaSource)(fragDef.ss, fragments, visited, variables);
                }
            }
        } else if (sel.ruleSelection == SelectionEnum.IFrag) {
            auto ifrag = sel.ifrag;
            if (ifrag is null) continue;
            if (ifrag.tc.value is null || ifrag.tc.value == getGraphQLTypeName!Query) {
                errors ~= validateRootSelectionSet!(Query, SchemaSource)(ifrag.ss, fragments, visited, variables);
            }
        }
    }

    return errors;
}

/// Validate a single root field against the Query/Mutation type.
private ValidationError[] validateRootField(Parent, alias SchemaSource)(Field field, FragmentMap fragments, bool[string] visited, JSONValue variables) {
    auto fieldName = getFieldName(field);
    if (fieldName is null) return [];

    // The schema's introspection meta-fields are always valid
    if (fieldName == "__schema" || fieldName == "__type") {
        return [];
    }

    // The root types' own fields are those of any other type
    return validateFieldAccess!(Parent, SchemaSource)(field, fragments, visited, variables);
}

/// Validate a selection set against an entity/object type.
private ValidationError[] validateSelectionSet(T, alias SchemaSource)(SelectionSet ss, FragmentMap fragments, bool[string] visited, JSONValue variables) {
    ValidationError[] errors;
    if (ss is null) return errors;
    auto selections = iterateSelections(ss);

    foreach (sel; selections) {
        if (sel.ruleSelection == SelectionEnum.Field) {
            auto field = sel.field;
            if (field is null) continue;
            errors ~= validateFieldAccess!(T, SchemaSource)(field, fragments, visited, variables);
        } else if (sel.ruleSelection == SelectionEnum.Spread) {
            auto spread = sel.frag;
            if (spread is null) continue;
            auto fragName = spread.name.value;
            if (fragName is null || fragName in visited) continue;
            auto fragDefPtr = fragName in fragments;
            if (fragDefPtr !is null) {
                auto fragDef = *fragDefPtr;
                if (typeConditionApplies(fragDef.tc.value, getGraphQLTypeName!T, abstractTypeNamesIn!(T, SchemaSource))) {
                    visited[fragName] = true;
                    errors ~= validateSelectionSet!(T, SchemaSource)(fragDef.ss, fragments, visited, variables);
                }
            }
        } else if (sel.ruleSelection == SelectionEnum.IFrag) {
            auto ifrag = sel.ifrag;
            if (ifrag is null) continue;
            if (typeConditionApplies(ifrag.tc.value, getGraphQLTypeName!T, abstractTypeNamesIn!(T, SchemaSource))) {
                errors ~= validateSelectionSet!(T, SchemaSource)(ifrag.ss, fragments, visited, variables);
            }
        }
    }

    return errors;
}

/// Validate a single field access against type T.
/// Uses the Schema Protocol to discover computed fields.
private ValidationError[] validateFieldAccess(T, alias SchemaSource)(Field field, FragmentMap fragments, bool[string] visited, JSONValue variables) {
    auto fieldName = getFieldName(field);
    if (fieldName is null) return [];

    // __typename is always valid, no selection set allowed
    if (fieldName == "__typename") return [];

    // Match field against computed fields from the schema protocol
    static foreach (member; getSchemaFields!T) {{
        alias memberSym = __traits(getMember, T, member);
        static if (!hasGqlHidden!memberSym) {
            enum gqlName = getGqlName!(memberSym, member);
            if (fieldName == gqlName) {
                ValidationError[] errors;
                // Fields without arguments share one validation of their
                // (absence of) arguments, rather than an instance each
                static if (Parameters!memberSym.length > 1)
                    errors ~= validateFieldArguments!(memberSym)(field, variables);
                else
                    errors ~= validateNoFieldArguments(field);
                errors ~= validateFieldResult!(ReturnType!(typeof(memberSym)), SchemaSource)(field, fragments, visited, variables);
                return errors;
            }
        }
    }}

    if (extensionFieldExists !is null &&
        extensionFieldExists(getGraphQLTypeName!T, fieldName)) return [];
    return [fieldError("Unknown field '" ~ fieldName ~ "' on type " ~ getGraphQLTypeName!T, field)];
}

/// Validate the arguments of a computed field which takes none.
private ValidationError[] validateNoFieldArguments(Field field) {
    ValidationError[] errors = duplicateArgumentErrors(field);
    errors ~= unexpectedArgumentErrors(field);
    return errors;
}

/// Errors for the arguments given more than once to a field.
private ValidationError[] duplicateArgumentErrors(Field field) {
    ValidationError[] errors;
    string[string] seen;
    foreach (arg; iterateArguments(field.args)) {
        auto name = arg.name.value;
        if (name is null) continue;
        if (name in seen) {
            errors ~= ValidationError(
                "Duplicate argument '" ~ name ~ "' on field '" ~ getFieldName(field) ~ "'",
                arg.name.line,
                arg.name.column
            );
        }
        seen[name] = name;
    }
    return errors;
}

/// Errors for the arguments given to a field which takes none.
private ValidationError[] unexpectedArgumentErrors(Field field) {
    ValidationError[] errors;
    foreach (arg; iterateArguments(field.args)) {
        auto name = arg.name.value;
        if (name is null) continue;
        errors ~= ValidationError(
            "Unknown argument '" ~ name ~ "' on field '" ~ getFieldName(field) ~ "'",
            arg.name.line,
            arg.name.column
        );
    }
    return errors;
}

/// Validate arguments for a computed field.
private ValidationError[] validateFieldArguments(alias fn)(Field field, JSONValue variables) {
    import std.traits : Parameters, ParameterDefaults, ParameterIdentifierTuple;

    auto args = field.args;

    alias Params = Parameters!fn;
    alias Defaults = ParameterDefaults!fn;
    enum paramNames = [ParameterIdentifierTuple!fn];

    // Check for duplicate arguments
    ValidationError[] errors = duplicateArgumentErrors(field);

    // Check for unknown arguments (skip first param which is Expr!Entity or Expr!Parent)
    static if (Params.length > 1) {
        foreach (arg; iterateArguments(args)) {
            auto name = arg.name.value;
            if (name is null) continue;
            bool found = false;
            static foreach (i; 1 .. Params.length) {
                if (name == paramNames[i]) found = true;
            }
            if (!found) {
                errors ~= ValidationError(
                    "Unknown argument '" ~ name ~ "' on field '" ~ getFieldName(field) ~ "'",
                    arg.name.line,
                    arg.name.column
                );
            }
        }

        // Check the values of input object arguments
        foreach (arg; iterateArguments(args)) {
            static foreach (i; 1 .. Params.length) {
                if (arg.name.value == paramNames[i])
                    validateInputValue!(Params[i])(arg.vv, variables, errors);
            }
        }

        // Check for missing required arguments
        static foreach (i; 1 .. Params.length) {{
            enum isNullableType = is(Params[i] == Nullable!U, U);
            enum hasDefault = !is(Defaults[i] == void);
            static if (!hasDefault && !isNullableType) {
                // Required argument — check that it exists
                bool provided = false;
                foreach (arg; iterateArguments(args)) {
                    if (arg.name.value == paramNames[i]) {
                        provided = true;
                        break;
                    }
                }
                if (!provided) {
                    errors ~= fieldError(
                        "Missing required argument '" ~ paramNames[i] ~ "' on field '" ~ getFieldName(field) ~ "'",
                        field
                    );
                }
            }
        }}
    } else {
        // Field takes no arguments — check for unexpected arguments
        errors ~= unexpectedArgumentErrors(field);
    }

    return errors;
}

/// Validate the result of a field that returns an Expr type.
private ValidationError[] validateFieldResult(ResultExpr, alias SchemaSource)(Field field, FragmentMap fragments, bool[string] visited, JSONValue variables) {
    static if (isExpr!ResultExpr) {
        alias ResultType = ExprResultType!ResultExpr;
        return validateFieldResultType!(ResultType, SchemaSource)(field, fragments, visited, variables);
    } else {
        return [];
    }
}

/// Validate selection set requirements based on a field's result type.
private ValidationError[] validateFieldResultType(ResultType, alias SchemaSource)(Field field, FragmentMap fragments, bool[string] visited, JSONValue variables) {
    // Unwrap GqlResult
    static if (isGqlResult!ResultType) {
        alias Inner = typeof(ResultType.init.value);
        return validateFieldResultType!(Inner, SchemaSource)(field, fragments, visited, variables);
    }
    // Unwrap Nullable
    else static if (is(ResultType == Nullable!U, U)) {
        return validateFieldResultType!(U, SchemaSource)(field, fragments, visited, variables);
    }
    // Arrays: check element type
    else static if (is(ResultType == E[], E)) {
        // Abstract type array (union/interface) — requires selection set
        static if (is(E == struct) && isAbstractType!E) {
            if (field.ss is null) {
                return [fieldError(
                    "Field '" ~ getFieldName(field) ~ "' must have a selection set (it returns " ~ getGraphQLTypeName!E ~ ")",
                    field
                )];
            }
            return validateAbstractSelectionSet!(E, SchemaSource)(field.ss, fragments, visited, variables);
        }
        else static if (isScalarElement!E) {
            // Array of scalars — no selection set allowed
            if (field.ss !is null) {
                return [fieldError(
                    "Field '" ~ getFieldName(field) ~ "' must not have a selection set (it returns a scalar type)",
                    field
                )];
            }
            return [];
        } else static if (is(E == Nullable!V, V) || is(E == F[], F)) {
            // Nullable objects or lists of objects — validate as the item type
            return validateFieldResultType!(E, SchemaSource)(field, fragments, visited, variables);
        } else {
            // Array of objects — requires selection set
            if (field.ss is null) {
                return [fieldError(
                    "Field '" ~ getFieldName(field) ~ "' must have a selection set (it returns " ~ getGraphQLTypeName!E ~ ")",
                    field
                )];
            }
            return validateSelectionSet!(E, SchemaSource)(field.ss, fragments, visited, variables);
        }
    }
    // Object types (non-scalar structs) — requires selection set
    else static if (is(ResultType == struct) && !isCustomScalar!ResultType) {
        if (field.ss is null) {
            return [fieldError(
                "Field '" ~ getFieldName(field) ~ "' must have a selection set (it returns " ~ getGraphQLTypeName!ResultType ~ ")",
                field
            )];
        }
        return validateSelectionSet!(ResultType, SchemaSource)(field.ss, fragments, visited, variables);
    }
    // Scalars — no selection set allowed
    else {
        if (field.ss !is null) {
            return [fieldError(
                "Field '" ~ getFieldName(field) ~ "' must not have a selection set (it returns a scalar type)",
                field
            )];
        }
        return [];
    }
}

// ============================================================================
// Abstract Type Validation (Unions / Interfaces)
// ============================================================================

/// Validate a selection set against an abstract type (union or interface).
///
/// For unions (no schema fields): only __typename and type-conditioned fragments are valid.
/// For interfaces (has schema fields): bare fields must exist on the interface type;
/// type-conditioned fragments are validated against the matching member type.
///
/// Type conditions are validated against the abstract type's member types.
private ValidationError[] validateAbstractSelectionSet(AbstractT, alias SchemaSource)(
    SelectionSet ss, FragmentMap fragments, bool[string] visited, JSONValue variables
) {
    ValidationError[] errors;
    if (ss is null) return errors;

    alias AllTypes = getSchemaObjectTypes!SchemaSource;
    alias Members = getAbstractTypeMembers!(AbstractT, AllTypes);
    enum abstractName = getGraphQLTypeName!AbstractT;
    enum bool isInterface = getSchemaFields!AbstractT.length > 0;

    foreach (sel; iterateSelections(ss)) {
        if (sel.ruleSelection == SelectionEnum.Field) {
            auto field = sel.field;
            if (field is null) continue;
            auto fieldName = getFieldName(field);
            if (fieldName is null) continue;

            // __typename is always valid on abstract types
            if (fieldName == "__typename") continue;

            // For interfaces, bare fields must exist on the interface type
            static if (isInterface) {
                errors ~= validateFieldAccess!(AbstractT, SchemaSource)(field, fragments, visited, variables);
            } else {
                // For unions, no bare fields except __typename
                errors ~= fieldError(
                    "Cannot query field '" ~ fieldName ~ "' on union type " ~ abstractName ~
                    " (use typed fragments like ... on ConcreteType { " ~ fieldName ~ " })",
                    field
                );
            }
        } else if (sel.ruleSelection == SelectionEnum.Spread) {
            auto spread = sel.frag;
            if (spread is null) continue;
            auto fragName = spread.name.value;
            if (fragName is null || fragName in visited) continue;
            auto fragDefPtr = fragName in fragments;
            if (fragDefPtr is null) continue;
            auto fragDef = *fragDefPtr;

            // Fragment without type condition on abstract type — same as bare fields
            if (fragDef.tc.value is null) {
                static if (isInterface) {
                    visited[fragName] = true;
                    errors ~= validateAbstractSelectionSet!(AbstractT, SchemaSource)(fragDef.ss, fragments, visited, variables);
                }
                continue;
            }

            // Validate type condition against member types
            errors ~= validateTypeCondition!(AbstractT, SchemaSource, Members)(
                fragDef.tc.value, fragDef.tc.line, fragDef.tc.column, fragDef.ss, fragments, visited, variables);
        } else if (sel.ruleSelection == SelectionEnum.IFrag) {
            auto ifrag = sel.ifrag;
            if (ifrag is null) continue;

            // Inline fragment without type condition — same as bare fields
            if (ifrag.tc.value is null) {
                static if (isInterface) {
                    errors ~= validateAbstractSelectionSet!(AbstractT, SchemaSource)(ifrag.ss, fragments, visited, variables);
                }
                continue;
            }

            // Validate type condition against member types
            errors ~= validateTypeCondition!(AbstractT, SchemaSource, Members)(
                ifrag.tc.value, ifrag.tc.line, ifrag.tc.column, ifrag.ss, fragments, visited, variables);
        }
    }

    return errors;
}

/// Validate a type condition against the members of an abstract type.
/// If the type condition matches a member, validate the fragment's selection set against that member.
private ValidationError[] validateTypeCondition(AbstractT, alias SchemaSource, Members...)(
    string tcValue, uint tcLine, ushort tcCol, SelectionSet ss, FragmentMap fragments, bool[string] visited, JSONValue variables
) {
    enum abstractName = getGraphQLTypeName!AbstractT;

    // Check type condition against each member type
    static foreach (Member; Members) {{
        if (tcValue == getGraphQLTypeName!Member) {
            // Valid type condition — validate the fragment's fields against this member type
            return validateSelectionSet!(Member, SchemaSource)(ss, fragments, visited, variables);
        }
    }}

    // Also allow the abstract type name itself as type condition
    if (tcValue == abstractName) {
        return validateAbstractSelectionSet!(AbstractT, SchemaSource)(ss, fragments, visited, variables);
    }

    // Type condition doesn't match any member
    return [ValidationError(
        "Type condition '" ~ tcValue ~ "' is not a member of " ~
        (getSchemaFields!AbstractT.length > 0 ? "interface" : "union") ~ " '" ~ abstractName ~ "'",
        tcLine, tcCol
    )];
}

// ============================================================================
// Input Values
// ============================================================================

/// Validate an argument or input object field value (a literal or a
/// variable) of D type T: every field of an input object it contains must be
/// a field of that input object's type. (Other errors in input values are
/// reported when they are coerced to T.)
private void validateInputValue(T)(ValueOrVariable vov, JSONValue variables,
        ref ValidationError[] errors) {
    if (vov is null) return;
    if (vov.ruleSelection == ValueOrVariableEnum.Var && vov.var !is null) {
        auto name = vov.var.name.value;
        if (variables.type == JSONType.object)
            if (auto value = name in variables.object)
                validateInputJson!T(*value, "$" ~ name, "", vov.var.name, errors);
        return;
    }
    validateInputValue!T(vov.val, variables, errors);
}

/// ditto
private void validateInputValue(T)(Value val, JSONValue variables, ref ValidationError[] errors) {
    import std.traits : isSomeString;

    if (val is null || val.ruleSelection == ValueEnum.N) return;
    static if (is(T == Nullable!U, U)) {
        validateInputValue!U(val, variables, errors);
    } else static if (is(T == U*, U)) {
        validateInputValue!U(val, variables, errors);
    } else static if (isInputType!T) {
        if (val.ruleSelection != ValueEnum.O || val.obj is null) return;
        for (auto field = val.obj.vals; field !is null; field = field.follow) {
            auto name = field.name.value;
            bool known;
            static foreach (member; inputFieldMembers!T) {
                if (name == getGqlName!(__traits(getMember, T, member), member)) {
                    known = true;
                    validateInputValue!(typeof(__traits(getMember, T, member)))(
                        field.val, variables, errors);
                }
            }
            if (!known)
                errors ~= ValidationError(unknownInputFieldMessage!T(name),
                    field.name.line, startColumn(field.name));
        }
    } else static if (is(T : U[], U) && !isSomeString!T) {
        if (val.ruleSelection == ValueEnum.ARR) {
            for (auto element = val.arr is null ? null : val.arr.vals; element !is null; element = element.follow)
                validateInputValue!U(element.val, variables, errors);
        } else {
            // A single value is coerced to a list of it.
            validateInputValue!U(val, variables, errors);
        }
    }
}

/// Validate the JSON value of a variable (at `path` within it) used where a
/// value of D type T is expected, as validateInputValue does for literals.
/// Errors are reported at the variable's use, `location`.
private void validateInputJson(T)(JSONValue value, string variable, string path, Token location,
        ref ValidationError[] errors) {
    import std.traits : isSomeString;

    if (value.type == JSONType.null_) return;
    static if (is(T == Nullable!U, U)) {
        validateInputJson!U(value, variable, path, location, errors);
    } else static if (is(T == U*, U)) {
        validateInputJson!U(value, variable, path, location, errors);
    } else static if (isInputType!T) {
        if (value.type != JSONType.object) return;
        foreach (name, fieldValue; value.object) {
            bool known;
            static foreach (member; inputFieldMembers!T) {
                if (name == getGqlName!(__traits(getMember, T, member), member)) {
                    known = true;
                    validateInputJson!(typeof(__traits(getMember, T, member)))(
                        fieldValue, variable, path ~ (path.length ? "." : "") ~ name, location, errors);
                }
            }
            if (!known)
                errors ~= ValidationError("Variable \"" ~ variable ~ "\" got invalid value" ~
                    (path.length ? " at \"" ~ path ~ "\"" : "") ~ "; " ~
                    unknownInputFieldMessage!T(name), location.line,
                    cast(ushort)(startColumn(location) - 1));  // at the `$`
        }
    } else static if (is(T : U[], U) && !isSomeString!T) {
        if (value.type == JSONType.array) {
            foreach (i, element; value.array)
                validateInputJson!U(element, variable, path ~ "[" ~ i.to!string ~ "]", location, errors);
        } else {
            validateInputJson!U(value, variable, path, location, errors);
        }
    }
}

/// The column a name token starts at (the lexer records where it ends).
private ushort startColumn(Token name) {
    return cast(ushort)(name.column - name.value.length);
}

private string unknownInputFieldMessage(T)(string name) {
    return "Field \"" ~ name ~ "\" is not defined by type \"" ~ getGraphQLTypeName!T ~ "\".";
}

/// The D names of the fields of an input object type.
private template inputFieldMembers(T) {
    enum string[] inputFieldMembers = () {
        string[] members;
        static foreach (member; __traits(allMembers, T)) {
            static if (isPublicDataField!(T, member) &&
                    __traits(compiles, typeof(__traits(getMember, T.init, member)))) {
                static if (!is(typeof(__traits(getMember, T, member)) == function) &&
                        !is(typeof(__traits(getMember, T, member)) == void))
                    members ~= member;
            }
        }
        return members;
    }();
}

// ============================================================================
// Helpers
// ============================================================================

/// Create a ValidationError with location from a Field's name token.
private ValidationError fieldError(string msg, Field field) {
    if (field !is null && field.name !is null) {
        auto ident = field.name.aka !is null ? field.name.aka : field.name.name;
        if (ident !is null) {
            return ValidationError(msg, ident.tok.line, ident.tok.column);
        }
    }
    return ValidationError(msg, 0, 0);
}

// ============================================================================
// Tests
// ============================================================================

// --- AST-only tests ---

// Test: duplicate operation names
unittest {
    import graphql.lexer : Lexer;
    import graphql.parser : Parser;

    auto lexer = Lexer(`
        query GetUsers { __typename }
        query GetUsers { __typename }
    `);
    auto parser = Parser(lexer);
    auto doc = parser.parseDocument();

    auto errors = validateDuplicateOperations(doc);
    assert(errors.length == 1, "Expected 1 duplicate operation error, got " ~ errors.length.to!string);
    assert(errors[0].message == "Duplicate operation name 'GetUsers'");
}

// Test: no duplicate when names differ
unittest {
    import graphql.lexer : Lexer;
    import graphql.parser : Parser;

    auto lexer = Lexer(`
        query GetUsers { __typename }
        query GetPosts { __typename }
    `);
    auto parser = Parser(lexer);
    auto doc = parser.parseDocument();

    auto errors = validateDuplicateOperations(doc);
    assert(errors.length == 0, "Expected no errors");
}

// Test: duplicate fragment names
unittest {
    import graphql.lexer : Lexer;
    import graphql.parser : Parser;

    auto lexer = Lexer(`
        query { __typename }
        fragment F on Query { __typename }
        fragment F on Query { __typename }
    `);
    auto parser = Parser(lexer);
    auto doc = parser.parseDocument();

    auto errors = validateDuplicateFragments(doc);
    assert(errors.length == 1, "Expected 1 duplicate fragment error, got " ~ errors.length.to!string);
    assert(errors[0].message == "Duplicate fragment name 'F'");
}

// Test: undefined variable
unittest {
    import graphql.lexer : Lexer;
    import graphql.parser : Parser;

    auto lexer = Lexer(`
        query GetUsers($x: String!) {
            users { greeting(prefix: $y) }
        }
    `);
    auto parser = Parser(lexer);
    auto doc = parser.parseDocument();
    auto op = findOperation(doc);
    auto fragments = collectFragments(doc);

    auto errors = validateVariables(op, fragments);
    // Should have: $y undefined, $x unused
    bool foundUndefined = false;
    bool foundUnused = false;
    foreach (err; errors) {
        if (err.message == "Variable $y is not defined") foundUndefined = true;
        if (err.message == "Variable $x is defined but not used") foundUnused = true;
    }
    assert(foundUndefined, "Expected undefined variable error for $y");
    assert(foundUnused, "Expected unused variable error for $x");
}

// Test: valid variable usage — no errors
unittest {
    import graphql.lexer : Lexer;
    import graphql.parser : Parser;

    auto lexer = Lexer(`
        query GetUsers($x: String!) {
            users { greeting(prefix: $x) }
        }
    `);
    auto parser = Parser(lexer);
    auto doc = parser.parseDocument();
    auto op = findOperation(doc);
    auto fragments = collectFragments(doc);

    auto errors = validateVariables(op, fragments);
    assert(errors.length == 0, "Expected no errors for valid variable usage, got " ~ errors.length.to!string);
}

// Test: variable in directive counts as used
unittest {
    import graphql.lexer : Lexer;
    import graphql.parser : Parser;

    auto lexer = Lexer(`
        query Q($show: Boolean!) {
            users { firstName @include(if: $show) }
        }
    `);
    auto parser = Parser(lexer);
    auto doc = parser.parseDocument();
    auto op = findOperation(doc);
    auto fragments = collectFragments(doc);

    auto errors = validateVariables(op, fragments);
    assert(errors.length == 0, "Expected no errors — $show is used in directive");
}

// Test: variable in fragment counts as used
unittest {
    import graphql.lexer : Lexer;
    import graphql.parser : Parser;

    auto lexer = Lexer(`
        query Q($prefix: String!) {
            users { ...UserFields }
        }
        fragment UserFields on User {
            greeting(prefix: $prefix)
        }
    `);
    auto parser = Parser(lexer);
    auto doc = parser.parseDocument();
    auto op = findOperation(doc);
    auto fragments = collectFragments(doc);

    auto errors = validateVariables(op, fragments);
    assert(errors.length == 0, "Expected no errors — $prefix is used in fragment");
}

// Test: variable in input object literal counts as used
unittest {
    import graphql.lexer : Lexer;
    import graphql.parser : Parser;

    auto lexer = Lexer(`
        query Q($pfx: String!) {
            users { formattedName(format: {prefix: $pfx, suffix: "!"}) }
        }
    `);
    auto parser = Parser(lexer);
    auto doc = parser.parseDocument();
    auto op = findOperation(doc);
    auto fragments = collectFragments(doc);

    auto errors = validateVariables(op, fragments);
    assert(errors.length == 0, "Expected no errors — $pfx is used inside input object");
}

// Test: no variables declared, none used — no errors
unittest {
    import graphql.lexer : Lexer;
    import graphql.parser : Parser;

    auto lexer = Lexer(`{ users { firstName } }`);
    auto parser = Parser(lexer);
    auto doc = parser.parseDocument();
    auto op = findOperation(doc);
    auto fragments = collectFragments(doc);

    auto errors = validateVariables(op, fragments);
    assert(errors.length == 0, "Expected no errors for query without variables");
}

// Test: ValidationError toJson
unittest {
    auto err = ValidationError("Test error", 5, 10);
    auto json = err.toJson();
    assert(json["message"].str == "Test error");
    assert(json["locations"].array[0]["line"].integer == 5);
    assert(json["locations"].array[0]["column"].integer == 10);
}

// Test: ValidationError toJson without location
unittest {
    auto err = ValidationError("Test error", 0, 0);
    auto json = err.toJson();
    assert(json["message"].str == "Test error");
    assert("locations" !in json);
}

// --- Type-aware tests ---

// Test: unknown field on entity type
unittest {
    import dunamis.core;
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import graphql.lexer : Lexer;
    import graphql.parser : Parser;

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("firstName", string);
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    auto lexer = Lexer(`{ users { nonExistent } }`);
    auto parser = Parser(lexer);
    auto doc = parser.parseDocument();
    auto op = findOperation(doc);
    auto fragments = collectFragments(doc);

    auto errors = validateQuery!(Schema!(Query))(doc, op, fragments);
    assert(errors.length == 1, "Expected 1 error for unknown field, got " ~ errors.length.to!string);
    assert(errors[0].message.canFind("Unknown field") && errors[0].message.canFind("nonExistent"),
        "Error message should mention unknown field: " ~ errors[0].message);
}

// Test: unknown argument on computed field
unittest {
    import dunamis.core;
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import graphql.lexer : Lexer;
    import graphql.parser : Parser;

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("firstName", string);

        static auto greeting(Expr!User u, string prefix) {
            return prefix ~ " " ~ firstName(u);
        }
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    auto lexer = Lexer(`{ users { greeting(prefix: "Hi", badArg: 1) } }`);
    auto parser = Parser(lexer);
    auto doc = parser.parseDocument();
    auto op = findOperation(doc);
    auto fragments = collectFragments(doc);

    auto errors = validateQuery!(Schema!(Query))(doc, op, fragments);
    assert(errors.length == 1, "Expected 1 error for unknown argument, got " ~ errors.length.to!string);
    assert(errors[0].message.canFind("Unknown argument") && errors[0].message.canFind("badArg"),
        "Error message should mention unknown argument: " ~ errors[0].message);
}

// Test: missing required argument
unittest {
    import dunamis.core;
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import graphql.lexer : Lexer;
    import graphql.parser : Parser;

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("firstName", string);

        static auto greeting(Expr!User u, string prefix) {
            return prefix ~ " " ~ firstName(u);
        }
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    auto lexer = Lexer(`{ users { greeting } }`);
    auto parser = Parser(lexer);
    auto doc = parser.parseDocument();
    auto op = findOperation(doc);
    auto fragments = collectFragments(doc);

    auto errors = validateQuery!(Schema!(Query))(doc, op, fragments);
    assert(errors.length == 1, "Expected 1 error for missing required argument, got " ~ errors.length.to!string);
    assert(errors[0].message.canFind("Missing required argument") && errors[0].message.canFind("prefix"),
        "Error message should mention missing argument: " ~ errors[0].message);
}

// Test: duplicate argument
unittest {
    import dunamis.core;
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import graphql.lexer : Lexer;
    import graphql.parser : Parser;

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("firstName", string);

        static auto greeting(Expr!User u, string prefix) {
            return prefix ~ " " ~ firstName(u);
        }
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    auto lexer = Lexer(`{ users { greeting(prefix: "Hi", prefix: "Hey") } }`);
    auto parser = Parser(lexer);
    auto doc = parser.parseDocument();
    auto op = findOperation(doc);
    auto fragments = collectFragments(doc);

    auto errors = validateQuery!(Schema!(Query))(doc, op, fragments);
    assert(errors.length >= 1, "Expected at least 1 error for duplicate argument");
    bool foundDuplicate = false;
    foreach (err; errors) {
        if (err.message.canFind("Duplicate argument")) foundDuplicate = true;
    }
    assert(foundDuplicate, "Expected duplicate argument error");
}

// Test: selection set on scalar field
unittest {
    import dunamis.core;
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import graphql.lexer : Lexer;
    import graphql.parser : Parser;

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("firstName", string);
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    auto lexer = Lexer(`{ users { firstName { x } } }`);
    auto parser = Parser(lexer);
    auto doc = parser.parseDocument();
    auto op = findOperation(doc);
    auto fragments = collectFragments(doc);

    auto errors = validateQuery!(Schema!(Query))(doc, op, fragments);
    assert(errors.length >= 1, "Expected at least 1 error for selection set on scalar");
    bool foundError = false;
    foreach (err; errors) {
        if (err.message.canFind("must not have a selection set")) foundError = true;
    }
    assert(foundError, "Expected selection set on scalar error");
}

// Test: missing selection set on object field
unittest {
    import dunamis.core;
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import graphql.lexer : Lexer;
    import graphql.parser : Parser;

    static MockDB!() db;

    @DemoEntity!(db, "posts")
    static struct Post {
        mixin DemoId;
        mixin Col!("title", string);
    }

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("firstName", string);
        mixin HasMany!("posts", Post, "author_id");
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    auto lexer = Lexer(`{ users { firstName posts } }`);
    auto parser = Parser(lexer);
    auto doc = parser.parseDocument();
    auto op = findOperation(doc);
    auto fragments = collectFragments(doc);

    auto errors = validateQuery!(Schema!(Query))(doc, op, fragments);
    assert(errors.length >= 1, "Expected at least 1 error for missing selection set");
    bool foundError = false;
    foreach (err; errors) {
        if (err.message.canFind("must have a selection set")) foundError = true;
    }
    assert(foundError, "Expected missing selection set error");
}

// Test: valid query — no errors
unittest {
    import dunamis.core;
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import graphql.lexer : Lexer;
    import graphql.parser : Parser;

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("firstName", string);
        mixin Col!("lastName", string);
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    auto lexer = Lexer(`{ users { firstName lastName } }`);
    auto parser = Parser(lexer);
    auto doc = parser.parseDocument();
    auto op = findOperation(doc);
    auto fragments = collectFragments(doc);

    auto errors = validateQuery!(Schema!(Query))(doc, op, fragments);
    assert(errors.length == 0, "Expected no errors for valid query, got " ~ errors.length.to!string);
}

// Test: multiple errors reported at once
unittest {
    import dunamis.core;
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import graphql.lexer : Lexer;
    import graphql.parser : Parser;

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("firstName", string);
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    // Query with multiple errors: unknown field + unknown root field
    auto lexer = Lexer(`{ users { badField } nonExistent { x } }`);
    auto parser = Parser(lexer);
    auto doc = parser.parseDocument();
    auto op = findOperation(doc);
    auto fragments = collectFragments(doc);

    auto errors = validateQuery!(Schema!(Query))(doc, op, fragments);
    assert(errors.length >= 2, "Expected at least 2 errors, got " ~ errors.length.to!string);
}

// Test: ValidationException carries all errors
unittest {
    auto errors = [
        ValidationError("Error 1", 1, 1),
        ValidationError("Error 2", 2, 5),
    ];
    auto ex = new ValidationException(errors);
    assert(ex.errors.length == 2);
    assert(ex.msg.canFind("Error 1"));
    assert(ex.msg.canFind("2 validation error(s)"));
}

// Test: optional arguments don't trigger missing error
unittest {
    import dunamis.core;
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import graphql.lexer : Lexer;
    import graphql.parser : Parser;

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("firstName", string);

        static auto greeting(Expr!User u, string prefix, string suffix = "!") {
            return prefix ~ " " ~ firstName(u) ~ suffix;
        }
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    // Provide only the required argument, omit the optional one
    auto lexer = Lexer(`{ users { greeting(prefix: "Hi") } }`);
    auto parser = Parser(lexer);
    auto doc = parser.parseDocument();
    auto op = findOperation(doc);
    auto fragments = collectFragments(doc);

    auto errors = validateQuery!(Schema!(Query))(doc, op, fragments);
    assert(errors.length == 0, "Expected no errors when optional args omitted, got " ~ errors.length.to!string);
}

// Test: unknown argument on field with no arguments
unittest {
    import dunamis.core;
    import dunamis.relational.schema;
    import dunamis.relational.demo;
    import graphql.lexer : Lexer;
    import graphql.parser : Parser;

    static MockDB!() db;

    @DemoEntity!(db, "users")
    static struct User {
        mixin DemoId;
        mixin Col!("firstName", string);

        static auto fullName(Expr!User u) {
            return firstName(u);
        }
    }

    static struct Query {
        mixin Table!(User, "users");
    }

    auto lexer = Lexer(`{ users { fullName(extra: "bad") } }`);
    auto parser = Parser(lexer);
    auto doc = parser.parseDocument();
    auto op = findOperation(doc);
    auto fragments = collectFragments(doc);

    auto errors = validateQuery!(Schema!(Query))(doc, op, fragments);
    assert(errors.length == 1, "Expected 1 error for unknown arg on no-arg field, got " ~ errors.length.to!string);
    assert(errors[0].message.canFind("Unknown argument"));
}
