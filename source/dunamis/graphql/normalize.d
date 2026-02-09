/// Encapsulated code-generation template for field normalization.
///
/// NormalizeFieldsCode computes a complete mixin string that converts all fields
/// of a source type (plain fields, plain methods, computed fields) into uniform
/// static Expr methods. Separated from plugin.d to avoid circular .imported
/// forward references during NormalizePlugin instantiation.
module dunamis.graphql.normalize;

/// Eponymous template that builds the complete NormalizeFields mixin string.
///
/// Generates:
/// - `_normalizedSource` field (carries original entity data through plugin chain)
/// - Static Expr methods for PK plain fields (ordered first)
/// - Forwarded computed fields (via _computedFieldCode)
/// - Static Expr methods for non-PK plain fields
/// - Static Expr methods for plain methods
///
/// Uses function literals instead of named helpers — no `_nf_read_*` or
/// `_nf_call_*` symbols leak into the target struct.
template NormalizeFieldsCode(SourceType, alias TypeMap) {
    import dunamis.core.types : isPlainField;
    import dunamis.relational.schema.attrs : hasPrimaryKeyAttr;
    import dunamis.core.discovery : getFieldMembers, isComputedField;

    private enum string _use = "dunamis.core.expr.use";
    private enum string _Expr = "dunamis.core.expr.Expr";
    private enum string _wrap = "dunamis.graphql.transform.wrapEntityResult";

    enum NormalizeFieldsCode = () {
        string result = "@(dunamis.graphql.schema.udas.GqlHidden) package(dunamis.graphql) SourceType _normalizedSource;\n";

        // PK plain fields first (ordering: id before other fields)
        static foreach (member; __traits(allMembers, SourceType)) {
            static if (isPlainField!(SourceType, member) && hasPrimaryKeyAttr!(SourceType, member)) {
                result ~= _plainFieldCode(member);
            }
        }

        // Forward computed fields (already static Expr methods)
        static foreach (member; getFieldMembers!SourceType) {
            static if (isComputedField!(SourceType, member)) {
                result ~= _computedFieldCode!member;
            }
        }

        // Non-PK plain fields
        static foreach (member; __traits(allMembers, SourceType)) {
            static if (isPlainField!(SourceType, member) && !hasPrimaryKeyAttr!(SourceType, member)) {
                result ~= _plainFieldCode(member);
            }
        }

        // Plain methods
        static foreach (member; getFieldMembers!SourceType) {
            static if (!isComputedField!(SourceType, member)) {
                result ~= _plainMethodCode(member);
            }
        }

        return result;
    }();

    /// Generate code for a normalized plain field (read from _normalizedSource).
    private static string _plainFieldCode(string member) {
        return
            "@(__traits(getAttributes, __traits(getMember, SourceType, \"" ~ member ~ "\"))) " ~
            "static auto " ~ member ~ "(" ~ _Expr ~ "!(typeof(this)) _self) { " ~
            "return " ~ _wrap ~ "!(TypeMap)(" ~
            _use ~ "(function(typeof(this) _n) { return _n._normalizedSource." ~ member ~
            "; }, _self)); }\n";
    }

    /// Generate code for a normalized plain method (call on _normalizedSource).
    private static string _plainMethodCode(string member) {
        return
            "@(__traits(getAttributes, __traits(getMember, SourceType, \"" ~ member ~ "\"))) " ~
            "static auto " ~ member ~ "(" ~ _Expr ~ "!(typeof(this)) _self) { " ~
            "return " ~ _wrap ~ "!(TypeMap)(" ~
            _use ~ "(function(typeof(this) _n) { return _n._normalizedSource." ~ member ~
            "(); }, _self)); }\n";
    }

    /// Generate code for a forwarded computed field.
    /// Unlike ForwardFieldCode (which references `fieldName` as a bare symbol),
    /// this embeds the field name as a quoted string literal so it works when
    /// mixed in at a site where only SourceType and TypeMap are in scope.
    private template _computedFieldCode(string member) {
        import std.conv : to;
        import dunamis.graphql.forward : ForwardFieldImpl;

        alias Impl = ForwardFieldImpl!(SourceType, member, TypeMap);

        // _I references the member as a quoted string — safe at any mixin site
        private enum string _I =
            "dunamis.graphql.forward.ForwardFieldImpl!(SourceType, \"" ~ member ~ "\", TypeMap)";

        private enum string _paramList = () {
            string result = "dunamis.core.expr.Expr!(typeof(this)) " ~ Impl.srcParamNames[0];
            static foreach (i; 1 .. Impl.SrcParams.length) {{
                result ~= ", " ~ _I ~ ".SrcParams[" ~ i.to!string ~ "] " ~ Impl.srcParamNames[i];
                static if (!is(Impl.SrcDefaults[i] == void))
                    result ~= " = " ~ _I ~ ".SrcDefaults[" ~ i.to!string ~ "]";
            }}
            return result;
        }();

        private enum string _argList = () {
            string result = "dunamis.graphql.entity_cast.pluginEntityCast!(" ~ _I ~ ".SrcEntity)(" ~ Impl.srcParamNames[0] ~ ")";
            static foreach (i; 1 .. Impl.SrcParams.length)
                result ~= ", " ~ Impl.srcParamNames[i];
            return result;
        }();

        enum _computedFieldCode =
            "@(__traits(getAttributes, " ~ _I ~ ".srcFn)) " ~
            "static auto " ~ member ~ "(" ~ _paramList ~ ") { " ~
            "return dunamis.graphql.transform.wrapEntityResult!(TypeMap)(" ~
            _I ~ ".srcFn(" ~ _argList ~ ")); }\n";
    }
}
