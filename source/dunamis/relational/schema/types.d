module dunamis.relational.schema.types;

import std.traits;
import std.typecons : Nullable;

import dunamis.core.expr : Expr, ExprResultType, isExpr;

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

import dunamis.core.types : AnyRef, PrimaryKeyAttr, isPlainField;

// Helper: resolve PK field name without iterating allMembers (avoids forward references
// during mixin expansion). Prefers _pkField enum if available (set by DemoEntity mixin),
// falls back to getPrimaryKeyFieldName for structs with @PrimaryKey on Col or plain fields.
private template pkFieldOf(T) {
    static if (__traits(hasMember, T, "_pkField")) {
        enum pkFieldOf = __traits(getMember, T, "_pkField");
    } else {
        import dunamis.core.types : getPrimaryKeyFieldName;
        enum pkFieldOf = getPrimaryKeyFieldName!T;
    }
}

// Helper: resolve ALL PK field names (for composite key support).
private template pkFieldsOf(T) {
    static if (__traits(hasMember, T, "_pkField")) {
        enum pkFieldsOf = [__traits(getMember, T, "_pkField")];
    } else {
        import dunamis.core.types : getPrimaryKeyFieldNames;
        enum pkFieldsOf = getPrimaryKeyFieldNames!T;
    }
}

/// Create an entity with its @PrimaryKey field set from a local ID value.
T makeEntity(T, IdType)(IdType localId) {
    import std.conv : to;
    T e;
    enum pkField = pkFieldOf!T;
    __traits(getMember, e, pkField) = to!(typeof(__traits(getMember, T.init, pkField)))(localId);
    return e;
}

/// Create an entity from an AnyRef (parses localId and converts to PK type).
T makeEntityFromRef(T)(AnyRef ref_) {
    import std.conv : to;
    import dunamis.core.types : isCustomScalar, decodeCompositeKey;
    enum pkFields = pkFieldsOf!T;
    static if (pkFields.length == 1) {
        enum pkField = pkFields[0];
        alias PkType = typeof(__traits(getMember, T.init, pkField));
        // For CustomScalar (e.g., Int64), convert through the base type
        static if (isCustomScalar!PkType) {
            return makeEntity!T(PkType(ref_.localId.to!(PkType.DType)));
        } else {
            return makeEntity!T(ref_.localId.to!PkType);
        }
    } else {
        // Composite key: decode "val1,val2" into parts and set each PK field
        auto parts = decodeCompositeKey(ref_.localId);
        T e;
        static foreach (i, f; pkFields) {
            __traits(getMember, e, f) = parts[i].to!(typeof(__traits(getMember, T.init, f)));
        }
        return e;
    }
}

/// Extract an AnyRef from an entity (reads @PrimaryKey field(s)).
AnyRef entityToRef(T)(T entity) {
    import std.conv : to;
    import dunamis.core.types : encodeCompositeKey;
    enum pkFields = pkFieldsOf!T;
    static if (pkFields.length == 1) {
        return AnyRef(EntityID!T.typeName ~ ":" ~ __traits(getMember, entity, pkFields[0]).to!string);
    } else {
        // Composite key: encode all PK fields
        string[] values;
        static foreach (f; pkFields) {
            values ~= __traits(getMember, entity, f).to!string;
        }
        return AnyRef(EntityID!T.typeName ~ ":" ~ encodeCompositeKey(values));
    }
}

/// Check if an entity has a valid (non-default) primary key.
/// Works via UFCS: entity.isValid()
bool isValid(T)(T entity) {
    import std.conv : to;
    enum pkField = pkFieldOf!T;
    alias PkType = typeof(__traits(getMember, T.init, pkField));
    auto val = __traits(getMember, entity, pkField);
    // For numeric types, 0 is invalid (default); for strings, empty is invalid
    static if (is(PkType == string))
        return val.length > 0;
    else
        return val != PkType.init;
}

// ============================================================================
// Foreign Key Type
// ============================================================================

/// Foreign key reference to another entity.
/// Use with Col to define FK columns that reference another entity's primary key.
struct ForeignKey(Entity, string idField = "id") {
    /// The referenced entity type
    alias referencedEntity = Entity;

    /// The referenced column name
    enum referencedColumn = idField;

    /// The underlying storage type.
    /// For plain fields (@PrimaryKey long id): uses the field type directly.
    /// For Col-generated methods: extracts T from the Expr!T return type.
    static if (isPlainField!(Entity, idField)) {
        alias StorageType = typeof(__traits(getMember, Entity.init, idField));
    } else {
        private alias _FieldMethod = __traits(getMember, Entity, idField);
        private alias _ReturnType = getMethodReturnType!(_FieldMethod, Expr!Entity);
        static assert(isExpr!_ReturnType,
            "Field '" ~ idField ~ "' in " ~ Entity.stringof ~ " must return an Expr type");
        alias StorageType = ExprResultType!_ReturnType;
    }
}

/// Helper to get return type of a method, handling both regular and template functions.
private template getMethodReturnType(alias method, ArgType) {
    static if (__traits(compiles, ReturnType!method)) {
        alias getMethodReturnType = ReturnType!method;
    } else static if (__traits(compiles, ReturnType!(method!()))) {
        alias getMethodReturnType = ReturnType!(method!());
    } else {
        alias getMethodReturnType = typeof(method(ArgType.init));
    }
}

/// Check if a type is a ForeignKey
template isForeignKey(T) {
    static if (is(T == ForeignKey!(E, col), E, string col)) {
        enum isForeignKey = true;
    } else {
        enum isForeignKey = false;
    }
}

/// Check if a type is a Nullable ForeignKey
template isNullableForeignKey(T) {
    static if (is(T == Nullable!(ForeignKey!(E, col)), E, string col)) {
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
    static if (is(T == ForeignKey!(E, col), E, string col)) {
        alias getForeignKeyEntity = E;
    } else static if (is(T == Nullable!(ForeignKey!(E, col)), E, string col)) {
        alias getForeignKeyEntity = E;
    } else {
        static assert(false, "Not a ForeignKey type");
    }
}

/// Get the inner ForeignKey type from a Nullable!(ForeignKey!(...))
template getInnerForeignKey(T) {
    static if (is(T == Nullable!(ForeignKey!(E, col)), E, string col)) {
        alias getInnerForeignKey = ForeignKey!(E, col);
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
