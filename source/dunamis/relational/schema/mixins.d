module dunamis.relational.schema.mixins;

import dunamis.relational.schema.types : EntityID;

// ============================================================================
// Field Definition Mixins
// ============================================================================

/// Convert camelCase to snake_case at compile time
string toSnakeCase(string input) {
    if (input.length == 0) return "";

    string result;
    foreach (i, c; input) {
        if (c >= 'A' && c <= 'Z') {
            if (i > 0) result ~= '_';
            result ~= cast(char)(c + 32);  // toLowerCase
        } else {
            result ~= c;
        }
    }
    return result;
}

/// Mixin to define a column accessor.
///
/// Examples:
///   mixin Col!("firstName", string);                      // regular column
///   mixin Col!("authorId", ForeignKey!User);              // required FK
///   mixin Col!("editorId", Nullable!(ForeignKey!User));   // nullable FK
///   mixin Col!("createdAt", string, "created_at");        // explicit column name
mixin template Col(string fieldName, T, string columnName = toSnakeCase(fieldName)) {
    import dunamis.relational.schema.types : isForeignKey, isNullableForeignKey, getForeignKeyEntity;
    import dunamis.relational.schema.types : getColumnStorageType;
    import dunamis.relational.schema.attrs : SqlColumn, ForeignKeyRef;
    import dunamis.relational.schema.expressions : column;
    import dunamis.core.expr : Expr;

    static if (isNullableForeignKey!T) {
        // Nullable FK column - nullability preserved in return type via getColumnStorageType
        @SqlColumn(columnName) @ForeignKeyRef!(getForeignKeyEntity!T)
        mixin("static auto " ~ fieldName ~ "(Expr!(typeof(this)) e) {
            return e.column!(getColumnStorageType!T, typeof(this))(\"" ~ columnName ~ "\");
        }");
    } else static if (isForeignKey!T) {
        // Required FK column
        @SqlColumn(columnName) @ForeignKeyRef!(getForeignKeyEntity!T)
        mixin("static auto " ~ fieldName ~ "(Expr!(typeof(this)) e) {
            return e.column!(getColumnStorageType!T, typeof(this))(\"" ~ columnName ~ "\");
        }");
    } else {
        // Regular column - nullability in T (e.g., Nullable!string) preserved in return type
        @SqlColumn(columnName)
        mixin("static auto " ~ fieldName ~ "(Expr!(typeof(this)) e) {
            return e.column!(T, typeof(this))(\"" ~ columnName ~ "\");
        }");
    }
}

/// Mixin to define a hasMany relationship.
/// Example: mixin HasMany!("posts", Post, "author_id");
mixin template HasMany(string fieldName, Child, string fk) {
    import dunamis.core.expr : Expr;
    import dunamis.relational.schema.attrs : HasManyFK, HasManyChild;
    import dunamis.relational.schema.expressions : hasMany;

    // Method with UDAs - takes Expr!Parent, returns Expr!(Child[])
    @HasManyFK(fk) @HasManyChild!Child
    mixin("static auto " ~ fieldName ~ "(Expr!(typeof(this)) e) {
        return hasMany!(Child, fk, typeof(this))(e);
    }");
}

/// Mixin to define a belongsTo relationship by referencing a FK column.
/// The parent entity type and nullability are derived from the FK column definition.
mixin template BelongsTo(string fieldName, string fkFieldName) {
    import dunamis.core.expr : Expr;
    import std.typecons : Nullable;
    import dunamis.relational.schema.expressions : belongsTo;
    import dunamis.relational.schema.attrs : BelongsToFK, BelongsToParent;
    import dunamis.relational.schema.attrs : extractForeignKeyRef, hasForeignKeyRef, getSqlColumn, hasNullableReturn;

    // Verify it's a foreign key column (has @ForeignKeyRef UDA)
    static assert(hasForeignKeyRef!(__traits(getMember, typeof(this), fkFieldName)),
        "Field '" ~ fkFieldName ~ "' must be a ForeignKey column for BelongsTo");

    // Check if FK column returns nullable type (determines relationship nullability)
    static if (hasNullableReturn!(__traits(getMember, typeof(this), fkFieldName))) {
        @BelongsToFK(fkFieldName)
        @BelongsToParent!(extractForeignKeyRef!(__traits(getMember, typeof(this), fkFieldName)))
        mixin("static auto " ~ fieldName ~ "(Expr!(typeof(this)) e) {
            alias Fk = __traits(getMember, typeof(this), \"" ~ fkFieldName ~ "\");
            return e.belongsTo!(extractForeignKeyRef!Fk, Nullable!(extractForeignKeyRef!Fk), getSqlColumn!Fk, typeof(this))();
        }");
    } else {
        @BelongsToFK(fkFieldName)
        @BelongsToParent!(extractForeignKeyRef!(__traits(getMember, typeof(this), fkFieldName)))
        mixin("static auto " ~ fieldName ~ "(Expr!(typeof(this)) e) {
            alias Fk = __traits(getMember, typeof(this), \"" ~ fkFieldName ~ "\");
            return e.belongsTo!(extractForeignKeyRef!Fk, extractForeignKeyRef!Fk, getSqlColumn!Fk, typeof(this))();
        }");
    }
}

// ============================================================================
// Query Root Mixin
// ============================================================================

/// Mixin to define a root query field that returns all entities of a type.
/// Used in a Query struct to define the schema's entry points.
mixin template Table(Entity, string fieldName) {
    import dunamis.core.expr : Expr;
    import dunamis.relational.schema.attrs : TableEntity;
    import dunamis.relational.schema.expressions : getAll;

    // Method with UDA - follows unified root field signature
    @TableEntity!Entity
    mixin("static auto " ~ fieldName ~ "(Expr!(typeof(this)) parent) {
        return getAll!Entity();
    }");
}

/// Convenience mixin to define multiple table fields at once.
/// Field names are derived from entity type names (lowercased + pluralized).
mixin template Tables(Entities...) {
    static foreach (Entity; Entities) {
        mixin Table!(Entity, defaultFieldName!Entity);
    }
}

/// Derive default field name from entity type (lowercase + "s" suffix)
template defaultFieldName(Entity) {
    enum defaultFieldName = () {
        string name = EntityID!Entity.typeName;
        // Lowercase first character
        if (name.length > 0 && name[0] >= 'A' && name[0] <= 'Z') {
            return cast(char)(name[0] + 32) ~ name[1..$] ~ "s";
        }
        return name ~ "s";
    }();
}
