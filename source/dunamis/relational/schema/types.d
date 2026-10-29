module dunamis.relational.schema.types;

import std.traits;
import std.typecons : Nullable;

import dunamis.core.expr : Expr;

// ============================================================================
// Entity Metadata Extraction
// ============================================================================

public import dunamis.relational.schema.attrs : hasEntityAttr, getEntityDb, getEntityTable, getEntityTypeName;

/// Extract entity metadata from the @Entity UDA.
/// Usage: EntityID!User.db, EntityID!User.table, EntityID!User.typeName
template EntityID(T) {
    import dunamis.relational.schema.attrs : getEntityDb, getEntityTable, getEntityTypeName;
    alias db = getEntityDb!T;
    enum table = getEntityTable!T;
    enum typeName = getEntityTypeName!T;
}

// ============================================================================
// Entity Construction Helpers
// ============================================================================

import dunamis.core.types : AnyRef;
import dunamis.relational.schema.attrs : PrimaryKey, getPrimaryKeyFieldNames;

/// Create an entity with its first @PrimaryKey field set from a local ID value.
/// Convenience for single-key entities (used by GetByIdsExpr and tests).
T makeEntity(T, IdType)(IdType localId) {
    import std.conv : to;
    import dunamis.relational.schema.attrs : getPrimaryKeyFieldNames;
    T e;
    enum pkField = getPrimaryKeyFieldNames!T[0];
    __traits(getMember, e, pkField) = to!(typeof(__traits(getMember, T.init, pkField)))(localId);
    return e;
}

/// Create an entity with ALL @PrimaryKey fields set from string parts.
/// Handles CustomScalar types (e.g., Int64) by converting through the base type.
T makeEntityFromParts(T)(string[] keyParts) {
    import std.conv : to;
    import dunamis.core.types : isCustomScalar;
    import dunamis.relational.schema.attrs : getPrimaryKeyFieldNames;
    enum pkFields = getPrimaryKeyFieldNames!T;
    T e;
    static foreach (i, f; pkFields) {{
        alias PkType = typeof(__traits(getMember, T.init, f));
        static if (isCustomScalar!PkType) {
            __traits(getMember, e, f) = PkType(keyParts[i].to!(PkType.DType));
        } else {
            __traits(getMember, e, f) = keyParts[i].to!PkType;
        }
    }}
    return e;
}

/// Create an entity from an AnyRef (parses localId and converts to PK type).
T makeEntityFromRef(T)(AnyRef ref_) {
    import dunamis.core.types : decodeCompositeKey;
    return makeEntityFromParts!T(decodeCompositeKey(ref_.localId));
}

/// Extract an AnyRef from an entity (reads @PrimaryKey field(s)).
AnyRef entityToRef(T)(T entity) {
    import std.conv : to;
    import dunamis.core.types : encodeCompositeKey;
    import dunamis.relational.schema.attrs : getPrimaryKeyFieldNames;
    import std.traits : isIntegral;
    enum pkFields = getPrimaryKeyFieldNames!T;
    // (The key of an integer is its decimal text, which needs no quoting)
    static if (pkFields.length == 1 && isIntegral!(typeof(__traits(getMember, entity, pkFields[0]))))
        return AnyRef(EntityID!T.typeName ~ ":" ~ __traits(getMember, entity, pkFields[0]).to!string);
    else {
        string[] values;
        static foreach (f; pkFields) {
            values ~= __traits(getMember, entity, f).to!string;
        }
        return AnyRef(EntityID!T.typeName ~ ":" ~ encodeCompositeKey(values));
    }
}

/// Check if an entity has a valid (non-default) primary key.
/// For composite keys, ALL PK fields must be non-default.
/// Works via UFCS: entity.isValid()
bool isValid(T)(T entity) {
    import dunamis.relational.schema.attrs : getPrimaryKeyFieldNames;
    enum pkFields = getPrimaryKeyFieldNames!T;
    static foreach (f; pkFields) {{
        alias PkType = typeof(__traits(getMember, T.init, f));
        auto val = __traits(getMember, entity, f);
        static if (is(PkType == string)) {
            if (val.length == 0) return false;
        } else {
            if (val == PkType.init) return false;
        }
    }}
    return true;
}

/// The parents a required (non-nullable) BelongsTo yields for children with
/// the refs `childRefs`, of which `parentRefs` are those of the parents found
/// (an invalid ref where none was).
///
/// A child which is a placeholder (an invalid ref, or an entity without a
/// valid primary key, such as the `T.init` a null object's selection set is
/// evaluated for in its batch, see `NullableObjectExpr`) has no parent: its
/// parent is a placeholder (`Parent.init`) too, whose fields are then
/// evaluated for placeholders as well. A missing parent of any other child
/// is an error (of the field), as for a null in a non-null field.
Parent[] requiredParents(Child, Parent)(AnyRef[] parentRefs, AnyRef[] childRefs, string relation) {
    auto result = new Parent[](parentRefs.length);
    foreach (i, parentRef; parentRefs) {
        if (parentRef.isValid && parentRef.localId.length) {
            result[i] = makeEntityFromRef!Parent(parentRef);
            continue;
        }
        if (i >= childRefs.length)
            throw new Exception("No " ~ EntityID!Parent.typeName ~ " for the required " ~ relation);
        auto childRef = childRefs[i];
        bool placeholder = !childRef.isValid || !childRef.localId.length ||
            !makeEntityFromRef!Child(childRef).isValid;
        if (!placeholder)
            throw new Exception("No " ~ EntityID!Parent.typeName ~ " for the required " ~ relation ~
                " of " ~ childRef.id);
    }
    return result;
}

// ============================================================================
// Foreign Key Type
// ============================================================================

/// Foreign key reference to another entity.
/// Use with Col to define FK columns that reference another entity's primary key.
struct ForeignKey(Entity) {
    /// The referenced entity type
    alias referencedEntity = Entity;

    /// The underlying storage type — derived from the entity's first @PrimaryKey field.
    alias StorageType = typeof(__traits(getMember, Entity.init, getPrimaryKeyFieldNames!Entity[0]));
}

/// Check if a type is a ForeignKey
template isForeignKey(T) {
    static if (is(T == ForeignKey!E, E)) {
        enum isForeignKey = true;
    } else {
        enum isForeignKey = false;
    }
}

/// Check if a type is a Nullable ForeignKey
template isNullableForeignKey(T) {
    static if (is(T == Nullable!(ForeignKey!E), E)) {
        enum isNullableForeignKey = true;
    } else {
        enum isNullableForeignKey = false;
    }
}

/// Check if a type is any kind of ForeignKey (required or nullable)
template isAnyForeignKey(T) {
    enum isAnyForeignKey = isForeignKey!T || isNullableForeignKey!T;
}

/// Get the referenced entity from a ForeignKey type
template getForeignKeyEntity(T) {
    static if (is(T == ForeignKey!E, E)) {
        alias getForeignKeyEntity = E;
    } else static if (is(T == Nullable!(ForeignKey!E), E)) {
        alias getForeignKeyEntity = E;
    } else {
        static assert(false, "Not a ForeignKey type");
    }
}

/// Get the inner ForeignKey type from a Nullable!(ForeignKey!(...))
template getInnerForeignKey(T) {
    static if (is(T == Nullable!(ForeignKey!E), E)) {
        alias getInnerForeignKey = ForeignKey!E;
    } else {
        static assert(false, "Not a Nullable ForeignKey type");
    }
}

/// Get the storage type for a column type.
/// For ForeignKey types, returns the referenced column's type.
/// For Nullable FKs, preserves the Nullable wrapper.
/// For regular types, returns T itself.
template getColumnStorageType(T) {
    import std.typecons : Nullable;
    static if (isNullableForeignKey!T) {
        alias getColumnStorageType = Nullable!(getInnerForeignKey!T.StorageType);
    } else static if (isForeignKey!T) {
        alias getColumnStorageType = T.StorageType;
    } else {
        alias getColumnStorageType = T;
    }
}
