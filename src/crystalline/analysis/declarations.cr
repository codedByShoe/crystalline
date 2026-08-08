module Crystalline::Analysis
  # What a type declaration is introducing. `Crystal::ClassDef` covers both
  # classes and structs, so this is not simply the node class.
  enum DeclKind
    Class
    Struct
    Module
    Enum
    Lib
    Alias
    Annotation
  end

  # A parameter, as written. Nothing here is resolved: a restriction is the text
  # of the restriction, which is all a parse can honestly report.
  record ParamDecl,
    name : String,
    restriction : String?,
    default_value : String?,
    splat : Bool,
    double_splat : Bool,
    block : Bool do
    def to_s(io : IO) : Nil
      io << '*' if splat
      io << "**" if double_splat
      io << '&' if block
      io << name
      io << " : " << restriction if restriction
      io << " = " << default_value if default_value
    end
  end

  # A type declaration.
  #
  # Crystal types are open, so one type is as many of these as there are places
  # that declare it - two files, or two blocks in one file. Whoever reads these
  # merges them; none of them is the whole type on its own.
  #
  # `superclass`, `includes` and `extends` are paths exactly as written, which
  # is why `namespace` travels with them: `Base` inside `module Outer` may mean
  # `Outer::Base` or `::Base`, and only the scope it was written in can say.
  record TypeDecl,
    fqn : String,
    name : String,
    kind : DeclKind,
    namespace : Array(String),
    superclass : String?,
    includes : Array(String),
    extends : Array(String),
    type_vars : Array(String),
    doc : String?,
    range : LSP::Range

  # A method declaration. `owner` is the qualified name of the type it was
  # written in, and is empty for a method at the top level.
  record MethodDecl,
    owner : String,
    name : String,
    class_method : Bool,
    params : Array(ParamDecl),
    return_type : String?,
    visibility : Crystal::Visibility,
    doc : String?,
    detail : String,
    range : LSP::Range

  # `@name : Type` written in the body of a type. The restriction is the only
  # thing that says what an instance variable holds without inference, which is
  # what makes these worth keeping.
  record IVarDecl,
    owner : String,
    name : String,
    restriction : String?,
    range : LSP::Range

  # A constant, an alias target, or an enum member - anything reachable through
  # `::` that is not itself a type declaration.
  record ConstDecl,
    fqn : String,
    name : String,
    namespace : Array(String),
    value : String?,
    range : LSP::Range

  # `require "path"`, with the path exactly as written. Resolving it to a file
  # needs the shard layout and the compiler's search path, which is a later
  # problem than collecting them.
  record RequireDecl,
    path : String,
    range : LSP::Range

  # Everything one file declares.
  record Declarations,
    types : Array(TypeDecl),
    methods : Array(MethodDecl),
    ivars : Array(IVarDecl),
    constants : Array(ConstDecl),
    requires : Array(RequireDecl) do
    def self.empty : Declarations
      new(
        types: [] of TypeDecl,
        methods: [] of MethodDecl,
        ivars: [] of IVarDecl,
        constants: [] of ConstDecl,
        requires: [] of RequireDecl,
      )
    end
  end
end
