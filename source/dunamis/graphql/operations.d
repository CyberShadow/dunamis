module dunamis.graphql.operations;

import std.json : JSONValue;
import graphql.ast : SelectionSet;
import graphql.lexer : Lexer;
import graphql.parser : Parser;

import dunamis.graphql.compiler.values : findOperation, iterateSelections,
    getFieldName, getOutputName, findArgumentValue, valueToJson;
import dunamis.graphql.compiler.selection : compileRootSelectionSet;

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
