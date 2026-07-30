module dunamis.graphql.compiler.extensions;

import std.json : JSONValue;
import graphql.ast : Arguments, SelectionSet;
import dunamis.core.expr : ExprBase;
import dunamis.graphql.compiler.values : iterateArguments, iterateSelections,
    getFieldName, valueToJson;

/// Optional runtime bridge for schema fields supplied by an external service.
/// Applications install these hooks before compiling requests.
__gshared bool function(string parentType, string fieldName) extensionFieldExists;
__gshared ExprBase function(string parentType, string fieldName, ExprBase parentId,
    Arguments arguments, SelectionSet selection, JSONValue variables) compileExtensionField;

JSONValue extensionArgumentsToJson(Arguments args, JSONValue variables) {
    import graphql.ast : ValueOrVariableEnum;
    JSONValue result = JSONValue.emptyObject;
    foreach (arg; iterateArguments(args)) {
        if (arg.vv.ruleSelection == ValueOrVariableEnum.Var)
            result[arg.name.value] = variables[arg.vv.var.name.value];
        else
            result[arg.name.value] = valueToJson(arg.vv.val, variables);
    }
    return result;
}

string[] extensionAttributes(SelectionSet selection) {
    import graphql.ast : SelectionEnum;
    string[] result;
    void collect(SelectionSet current) {
      foreach (item; iterateSelections(current)) {
        if (item.ruleSelection == SelectionEnum.Field) {
            result ~= getFieldName(item.field);
        } else if (item.ruleSelection == SelectionEnum.IFrag) {
            collect(item.ifrag.ss);
        }
      }
    }
    collect(selection);
    return result;
}
