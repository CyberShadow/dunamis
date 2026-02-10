module dunamis.schema;

public import dunamis.schema.plugin;
public import dunamis.schema.filtering;
public import dunamis.schema.sorting;
public import dunamis.schema.pagination;
public import dunamis.schema.crud;
public import dunamis.schema.type_mapping;

// Schema template bundling Query and optional Mutation types.
// Normalizes entity types so all fields use uniform static Expr methods.
template Schema(QueryType, MutationType = void) {
    import dunamis.schema.plugin : NormalizePlugin;

    static if (is(MutationType == void)) {
        struct _EmptyMutation {}
        alias _RawMutation = _EmptyMutation;
    } else {
        alias _RawMutation = MutationType;
    }

    alias _Normalized = NormalizePlugin!(QueryType, _RawMutation);
    alias Query = _Normalized.Query;
    alias Mutation = _Normalized.Mutation;
}
