module dunamis.relational.subscription;

import ae.utils.promise : Promise;

import std.json : JSONValue;

import dunamis.core.datasource : ChangeEvent;
import dunamis.core.executor : SubscriptionExecutor, SubscriptionRegistration;
import dunamis.core.types : makeAnyRef;
import dunamis.relational.schema.types : EntityID, makeEntityFromRef;

/// Creates a type-erased subscription handler from a SubscriptionExecutor.
///
/// Encapsulates entity construction from ChangeEvent IDs, eliminating
/// the boilerplate of `makeEntityFromRef!T(makeAnyRef(...))` at each
/// dispatch site.
///
/// Usage:
/// ---
/// auto subExec = new SubscriptionExecutor!User(executor, compiled.expr);
/// auto reg = createSubscriptionHandler(subExec);
/// mgr.subscribe(reg, onResult, onError);
/// ---
SubscriptionRegistration createSubscriptionHandler(T)(SubscriptionExecutor!T executor) {
    return SubscriptionRegistration(
        EntityID!T.table,
        (ChangeEvent event) {
            auto entity = makeEntityFromRef!T(
                makeAnyRef(EntityID!T.typeName, event.ids[0]));
            return executor.execute(entity);
        }
    );
}
