/// Stored entities: the protocol by which a data source declares the root
/// fields listing the entities it stores, and how they are written, so that
/// plugins can generate fields for them (e.g. CRUD mutations, change
/// subscriptions) knowing nothing of the data source.
module dunamis.core.stored;

/// UDA of a root field listing the stored entities of the type `E` (as
/// declared, before normalization), e.g. a table's rows (see the relational
/// `Table` mixin).
///
/// `W` is the data source's mixin template generating the fields writing
/// such entities, as static members of a mutation type:
/// ---
/// mixin W!(E, NormalizedEntity, MutationType, cast_);
/// ---
/// generates the write fields the data source supports for `E` (e.g.
/// `create<Entity>`, `update<Entity>`, `delete<Entity>`), omitting those
/// `MutationType` has a member of the name of; their parent is the type they
/// are mixed into, and they return the entities they write as
/// `NormalizedEntity`s (the entity type at the position of the plugin
/// generating them), converted with `cast_!NormalizedEntity(expr)`.
struct StoredEntities(E, alias W) {
    alias entityType = E;
    alias Writes = W;
}

/// Whether the field `field` lists stored entities (has a `StoredEntities`
/// UDA).
template hasStoredEntities(alias field) {
    enum hasStoredEntities = () {
        bool found;
        static foreach (attr; __traits(getAttributes, field))
            static if (is(attr == StoredEntities!Args, Args...))
                found = true;
        return found;
    }();
}

/// The `StoredEntities` UDA of the field `field`.
template StoredEntitiesOf(alias field) if (hasStoredEntities!field) {
    alias StoredEntitiesOf = StoredEntitiesImpl!(__traits(getAttributes, field));
}

private template StoredEntitiesImpl(Attrs...) {
    static if (is(Attrs[0] == StoredEntities!Args, Args...))
        alias StoredEntitiesImpl = Attrs[0];
    else
        alias StoredEntitiesImpl = StoredEntitiesImpl!(Attrs[1 .. $]);
}

unittest {
    mixin template NoWrites(E, NE, M, alias cast_) {}
    static struct Item {}
    static struct Root {
        @StoredEntities!(Item, NoWrites) static int items() { return 0; }
        @("other") static int other() { return 0; }
    }
    static assert(hasStoredEntities!(Root.items) && !hasStoredEntities!(Root.other));
    static assert(is(StoredEntitiesOf!(Root.items).entityType == Item));
    static assert(__traits(isSame, StoredEntitiesOf!(Root.items).Writes, NoWrites));
}
