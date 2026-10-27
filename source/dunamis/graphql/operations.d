module dunamis.graphql.operations;

import std.json : JSONValue;
import graphql.ast : SelectionSet;
import graphql.lexer : Lexer;
import graphql.parser : Parser;

import dunamis.core.expr : Expr, ExprBase;
import dunamis.graphql.compiler.values : findOperation, iterateSelections,
    getFieldName, getOutputName, findArgumentValue, valueToJson, collectFragments;
import dunamis.graphql.compiler.selection : compileRootSelectionSet, compileRootField;

struct OperationField {
    string name;
    string outputName;
    JSONValue input;
    SelectionSet selection;
}

struct OperationSelection {
    string name;
    string outputName;
    SelectionSet selection;
}

/// Return the concrete fields in a selection set for application adapters.
OperationSelection[] parseSelectionFields(SelectionSet selection) {
    OperationSelection[] result;
    foreach (item; iterateSelections(selection)) {
        if (item.field is null) continue;
        result ~= OperationSelection(getFieldName(item.field),
            getOutputName(item.field), item.field.ss);
    }
    return result;
}

/// Whether a selection contains fragment-derived fields which the lightweight
/// adapter parser cannot enumerate without the complete document.
bool selectionHasFragments(SelectionSet selection) {
    foreach (item; iterateSelections(selection))
        if (item.field is null) return true;
    return false;
}

/// Compile an already-parsed query-root selection using the normal Dunamis
/// data-query pipeline.
auto compileQuerySelection(alias SchemaType)(SelectionSet selection,
        JSONValue variables) {
    return compileRootSelectionSet!(SchemaType.Query, SchemaType)(
        selection, variables, null);
}

/// Compile one top-level field of the operation of `document` (the
/// `index`th of `parseOperationFields`), a field of the root type of the
/// operation (Query or Mutation) of the schema S, into an expression of its
/// JSON value (which fails if the field does, e.g. evaluated with
/// `evaluateNested`). This lets application adapters which run an
/// operation's fields themselves evaluate those of the schema. The document
/// is not validated.
Expr!JSONValue compileOperationField(alias S)(string document, JSONValue variables, size_t index) {
    import graphql.ast : OperationTypeEnum;
    import dunamis.graphql.compiler.values : CompilerException;

    auto parsed = Parser(Lexer(document)).parseDocument();
    auto operation = findOperation(parsed);
    if (operation is null || operation.ss is null)
        throw new CompilerException("No operation found in query");
    auto fragments = collectFragments(parsed);
    size_t i;
    foreach (selection; iterateSelections(operation.ss)) {
        if (selection.field is null) continue;
        if (i++ != index) continue;
        ExprBase field;
        if (operation.ot !is null && operation.ot.ruleSelection == OperationTypeEnum.Mutation)
            field = compileRootField!(S.Mutation, S)(selection.field, variables, fragments);
        else
            field = compileRootField!(S.Query, S)(selection.field, variables, fragments);
        if (auto json = cast(Expr!JSONValue) field)
            return json;
        return new JsonOfExpr(field);
    }
    throw new CompilerException("The operation has no field #" ~ (){ import std.conv : to; return index.to!string; }());
}

/// The JSON value of an expression (as `evalToJson`).
private final class JsonOfExpr : Expr!JSONValue {
    import ae.utils.promise : Promise;
    import dunamis.core.eval : EvalContext;
    import dunamis.core.optimize : OptimizeContext;

    private ExprBase _inner;

    this(ExprBase inner) { _inner = inner; }

    override ExprBase[] dependencies() { return [_inner]; }

    override void replaceDependency(size_t index, ExprBase newDep) {
        if (index == 0) _inner = newDep;
    }

    override Expr!JSONValue optimize(OptimizeContext ctx) {
        import dunamis.core.expr : optimizeExpr;
        _inner = optimizeExpr(_inner, ctx);
        return this;
    }

    override Promise!(JSONValue[]) eval(EvalContext ctx) {
        import dunamis.core.expr : evalToJson;
        return evalToJson(_inner, ctx);
    }
}

/// Parse top-level operation fields and resolve their `input` argument.  This
/// is useful to application adapters which intentionally live below the
/// compile-time schema (such as generated database mutation shims).
OperationField[] parseOperationFields(string document, JSONValue variables) {
    auto parser = Parser(Lexer(document));
    auto operation = findOperation(parser.parseDocument());
    OperationField[] result;
    if (operation is null || operation.ss is null) return result;
    foreach (selection; iterateSelections(operation.ss)) {
        if (selection.field is null) continue;
        auto field = selection.field;
        auto argument = findArgumentValue(field.args, "input");
        JSONValue input = JSONValue(null);
        if (argument.isVariable) {
            if (!(argument.variableName in variables))
                throw new Exception("Missing variable $" ~ argument.variableName);
            input = variables[argument.variableName];
        } else if (argument.value !is null) {
            input = valueToJson(argument.value, variables);
        }
        result ~= OperationField(getFieldName(field), getOutputName(field), input, field.ss);
    }
    return result;
}
