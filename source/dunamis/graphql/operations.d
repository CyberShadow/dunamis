module dunamis.graphql.operations;

import std.json : JSONValue;
import graphql.ast : SelectionSet;
import graphql.lexer : Lexer;
import graphql.parser : Parser;

import dunamis.graphql.compiler.values : findOperation, iterateSelections,
    getFieldName, getOutputName;
import dunamis.graphql.compiler.selection : compileRootSelectionSet;

struct OperationField {
    string name;
    string outputName;
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

/// Parse top-level operation fields, for application adapters which
/// intentionally live below the compile-time schema.
OperationField[] parseOperationFields(string document) {
    auto parser = Parser(Lexer(document));
    auto operation = findOperation(parser.parseDocument());
    OperationField[] result;
    if (operation is null || operation.ss is null) return result;
    foreach (selection; iterateSelections(operation.ss)) {
        if (selection.field is null) continue;
        auto field = selection.field;
        result ~= OperationField(getFieldName(field), getOutputName(field), field.ss);
    }
    return result;
}
