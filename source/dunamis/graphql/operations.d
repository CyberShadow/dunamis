module dunamis.graphql.operations;

import std.json : JSONValue;
import graphql.ast : SelectionSet;

import dunamis.graphql.compiler.selection : compileRootSelectionSet;

/// Compile an already-parsed query-root selection using the normal Dunamis
/// data-query pipeline.
auto compileQuerySelection(alias SchemaType)(SelectionSet selection,
        JSONValue variables) {
    return compileRootSelectionSet!(SchemaType.Query, SchemaType)(
        selection, variables, null);
}
