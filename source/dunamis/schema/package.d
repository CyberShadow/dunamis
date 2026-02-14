module dunamis.schema;

public import dunamis.schema.plugin;
public import dunamis.schema.filtering;
public import dunamis.schema.sorting;
public import dunamis.schema.pagination;
public import dunamis.schema.crud;
public import dunamis.schema.type_mapping;
public import dunamis.schema.overrides;

// Schema template bundling Query, optional Mutation, and optional Subscription types.
// Normalizes entity types so all fields use uniform static Expr methods.
template Schema(QueryType, MutationType = void, SubscriptionType = void) {
    import dunamis.schema.plugin : NormalizePlugin;

    static if (is(MutationType == void)) {
        struct _EmptyMutation {}
        alias _RawMutation = _EmptyMutation;
    } else {
        alias _RawMutation = MutationType;
    }

    static if (is(SubscriptionType == void)) {
        struct _EmptySubscription {}
        alias _RawSubscription = _EmptySubscription;
    } else {
        alias _RawSubscription = SubscriptionType;
    }

    alias _Normalized = NormalizePlugin!(QueryType, _RawMutation, _RawSubscription);
    alias Query = _Normalized.Query;
    alias Mutation = _Normalized.Mutation;
    alias Subscription = _Normalized.Subscription;
}
