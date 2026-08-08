module Crystalline::Analysis
  # Collects what a file declares, from the parse alone.
  #
  # Nothing here is resolved. A superclass is the text of a path, a restriction
  # is the text of a restriction, and a `require` is the text between quotes -
  # because that is all a parse can honestly report, and pretending otherwise is
  # how a syntax tier starts disagreeing with the compiler.
  class DeclarationsVisitor < Crystal::Visitor
    getter types = [] of TypeDecl
    getter methods = [] of MethodDecl
    getter ivars = [] of IVarDecl
    getter constants = [] of ConstDecl
    getter requires = [] of RequireDecl

    # The type names enclosing the node being visited, outermost first, and the
    # scopes to restore on the way back out. A declaration can name a scope
    # other than the one it sits in - `class Outer::Inner` names two at once,
    # and `class ::Free` names none - so leaving one restores what was saved
    # rather than counting back.
    @scope = [] of String
    @enclosing = [] of Array(String)
    # `private def` parses as a modifier wrapping the def rather than as a
    # property of it - `Crystal::Def#visibility` is only filled in later, by
    # the semantic pass this tier exists to do without.
    @visibility : Crystal::Visibility = Crystal::Visibility::Public

    def declarations : Declarations
      Declarations.new(
        types: @types,
        methods: @methods,
        ivars: @ivars,
        constants: @constants,
        requires: @requires,
      )
    end

    def visit(node)
      true
    end

    def end_visit(node)
    end

    def visit(node : Crystal::ClassDef)
      enter(node, node.struct? ? DeclKind::Struct : DeclKind::Class,
        superclass: node.superclass.try(&.to_s),
        type_vars: node.type_vars)
    end

    def end_visit(node : Crystal::ClassDef)
      leave(node)
    end

    def visit(node : Crystal::ModuleDef)
      enter(node, DeclKind::Module, type_vars: node.type_vars)
    end

    def end_visit(node : Crystal::ModuleDef)
      leave(node)
    end

    def visit(node : Crystal::LibDef)
      enter(node, DeclKind::Lib)
    end

    def end_visit(node : Crystal::LibDef)
      leave(node)
    end

    def visit(node : Crystal::AnnotationDef)
      enter(node, DeclKind::Annotation)
    end

    def end_visit(node : Crystal::AnnotationDef)
      leave(node)
    end

    def visit(node : Crystal::EnumDef)
      enter(node, DeclKind::Enum)
      # An enum member is a constant on the enum, and its name is all there is
      # to it - `Arg` here carries no restriction worth recording.
      node.members.each do |member|
        next unless member.is_a?(Crystal::Arg)
        record_constant(member.name, member.default_value.try(&.to_s), member)
      end
      true
    end

    def end_visit(node : Crystal::EnumDef)
      leave(node)
    end

    def visit(node : Crystal::Alias)
      name = node.name.to_s
      @types << TypeDecl.new(
        fqn: qualify(name),
        name: name,
        kind: DeclKind::Alias,
        namespace: @scope.dup,
        superclass: node.value.to_s,
        includes: [] of String,
        extends: [] of String,
        type_vars: [] of String,
        doc: node.doc,
        range: Utils.lsp_range_from_node(node),
        file: file_of(node),
      )
      false
    end

    def visit(node : Crystal::VisibilityModifier)
      previous = @visibility
      @visibility = node.modifier
      node.exp.accept(self)
      @visibility = previous
      false
    end

    def visit(node : Crystal::Include)
      current_type.try { |owner| record_mixin(owner, node.name.to_s, :include) }
      false
    end

    def visit(node : Crystal::Extend)
      current_type.try { |owner| record_mixin(owner, node.name.to_s, :extend) }
      false
    end

    def visit(node : Crystal::Def)
      receiver = node.receiver
      owner = if receiver && receiver.to_s != "self"
                receiver.to_s
              else
                @scope.join("::")
              end

      @methods << MethodDecl.new(
        owner: owner,
        name: node.name,
        class_method: !receiver.nil?,
        params: params_of(node),
        return_type: restriction_text(node.return_type),
        visibility: node.visibility.public? ? @visibility : node.visibility,
        doc: node.doc,
        detail: Utils.format_def(node, short: true),
        range: Utils.lsp_range_from_node(node),
        file: file_of(node),
      )
      false
    end

    def visit(node : Crystal::TypeDeclaration)
      var = node.var
      return false unless var.is_a?(Crystal::InstanceVar)
      owner = current_type
      return false unless owner

      @ivars << IVarDecl.new(
        owner: owner,
        name: var.name,
        restriction: restriction_text(node.declared_type),
        range: Utils.lsp_range_from_node(node),
      )
      false
    end

    def visit(node : Crystal::Assign)
      target = node.target
      # A constant, as opposed to an assignment to anything else.
      return true unless target.is_a?(Crystal::Path)

      record_constant(target.to_s, node.value.to_s, node)
      false
    end

    def visit(node : Crystal::Require)
      @requires << RequireDecl.new(
        path: node.string,
        range: Utils.lsp_range_from_node(node),
      )
      false
    end

    # `getter`, `setter` and `property` declare methods that are not written as
    # defs. They are the ordinary way to give a Crystal type its accessors, so a
    # tier that skipped them would be missing most of what most types respond to.
    def visit(node : Crystal::Call)
      owner = current_type
      return true unless owner
      return true unless node.obj.nil?
      return true unless {"getter", "setter", "property",
                          "getter?", "property?",
                          "class_getter", "class_setter", "class_property"}.includes?(node.name)

      class_method = node.name.starts_with?("class_")
      base = node.name.lchop("class_")
      predicate = base.ends_with?('?')
      base = base.rchop('?')
      range = Utils.lsp_range_from_node(node)
      file = file_of(node)

      node.args.each do |arg|
        name, restriction = accessor_target(arg)
        next if name.empty?

        reader = predicate ? "#{name}?" : name

        unless base == "setter"
          @methods << accessor(owner, reader, class_method, restriction, range, file)
        end
        unless base == "getter"
          @methods << accessor(owner, "#{name}=", class_method, nil, range, file,
            params: [ParamDecl.new("value", restriction, nil, false, false, false)])
        end
      end
      false
    end

    # The name an accessor macro is declaring, and its type where one is given.
    # Each of the four ways to write one is a different node.
    private def accessor_target(arg : Crystal::ASTNode) : {String, String?}
      case arg
      when Crystal::TypeDeclaration then {arg.var.to_s, restriction_text(arg.declared_type)}
      when Crystal::SymbolLiteral   then {arg.value, nil}
      when Crystal::Assign          then {arg.target.to_s, nil}
      else                               {arg.to_s, nil}
      end
    end

    # The type currently being visited, or nil at the top level.
    private def current_type : String?
      @scope.empty? ? nil : @scope.join("::")
    end

    # The file a node was parsed from, which is where its declaration lives.
    private def file_of(node : Crystal::ASTNode) : String?
      node.location.try(&.original_filename)
    end

    private def qualify(name : String) : String
      (@scope + name.split("::")).join("::")
    end

    private def enter(node, kind : DeclKind, *, superclass : String? = nil, type_vars : Array(String)? = nil) : Bool
      name_node = node.name
      # `Path#names` already has the name in segments, and gets `::Foo` right
      # where splitting its `to_s` would leave an empty leading one.
      segments = name_node.is_a?(Crystal::Path) ? name_node.names : name_node.to_s.split("::")
      # `class ::Foo` is written against the top level on purpose.
      global = name_node.is_a?(Crystal::Path) && name_node.global?
      namespace = global ? [] of String : @scope.dup

      @types << TypeDecl.new(
        fqn: (namespace + segments).join("::"),
        name: segments.last,
        kind: kind,
        namespace: namespace + segments[0...-1],
        superclass: superclass,
        includes: [] of String,
        extends: [] of String,
        type_vars: type_vars || [] of String,
        doc: node.doc,
        range: Utils.lsp_range_from_node(node),
        file: file_of(node),
      )

      @enclosing << @scope
      @scope = namespace + segments
      true
    end

    private def leave(node) : Nil
      @scope = @enclosing.pop? || [] of String
    end

    # Mixins are written in the body of the type they apply to, and the type was
    # recorded on the way in - so the declaration is amended rather than a
    # second one being made for it.
    private def record_mixin(owner : String, name : String, kind : Symbol) : Nil
      index = @types.rindex { |decl| decl.fqn == owner }
      return unless index

      decl = @types[index]
      @types[index] = kind == :include ? decl.copy_with(includes: decl.includes + [name]) : decl.copy_with(extends: decl.extends + [name])
    end

    private def record_constant(name : String, value : String?, node) : Nil
      @constants << ConstDecl.new(
        fqn: qualify(name),
        name: name.split("::").last,
        namespace: @scope.dup,
        value: value,
        range: Utils.lsp_range_from_node(node),
        file: file_of(node),
      )
    end

    private def accessor(owner : String, name : String, class_method : Bool, restriction : String?, range : LSP::Range, file : String?, params = [] of ParamDecl) : MethodDecl
      MethodDecl.new(
        owner: owner,
        name: name,
        class_method: class_method,
        params: params,
        return_type: params.empty? ? restriction : nil,
        visibility: @visibility,
        doc: nil,
        detail: params.empty? ? name : "#{name}(#{params.join(", ")})",
        range: range,
        file: file,
      )
    end

    private def params_of(node : Crystal::Def) : Array(ParamDecl)
      params = node.args.map_with_index do |arg, index|
        ParamDecl.new(
          name: arg.name,
          restriction: restriction_text(arg.restriction),
          default_value: arg.default_value.try(&.to_s),
          splat: index == node.splat_index,
          double_splat: false,
          block: false,
        )
      end

      node.double_splat.try { |arg| params << param_from(arg, double_splat: true) }
      node.block_arg.try { |arg| params << param_from(arg, block: true) }
      params
    end

    # A restriction as it reads in source.
    #
    # `String?` parses as a union with `Nil`, and printing that back gives
    # `String | ::Nil` - accurate, and not what anybody wrote or wants to read
    # in the margin of their editor.
    private def restriction_text(node : Crystal::ASTNode?) : String?
      return unless node
      return node.to_s unless node.is_a?(Crystal::Union) && node.types.size == 2

      nil_index = node.types.index { |type| type.to_s == "::Nil" || type.to_s == "Nil" }
      return node.to_s unless nil_index

      "#{node.types[1 - nil_index]}?"
    end

    private def param_from(arg : Crystal::Arg, *, double_splat = false, block = false) : ParamDecl
      ParamDecl.new(
        name: arg.name,
        restriction: restriction_text(arg.restriction),
        default_value: arg.default_value.try(&.to_s),
        splat: false,
        double_splat: double_splat,
        block: block,
      )
    end
  end
end
