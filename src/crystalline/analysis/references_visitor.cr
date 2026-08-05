module Crystalline::Analysis
  class ReferencesVisitor < Crystal::Visitor
    alias LocationKey = Tuple(String, Int32, Int32)

    private enum TargetKind
      Method
      Path
      Local
      Instance
      Class
    end

    getter locations = [] of LSP::Location

    @target_locations : Set(LocationKey)
    @target_kind : TargetKind
    @target_name : String
    @seen_locations = Set(Tuple(String, Int32, Int32, Int32, Int32)).new
    @declaration_nodes = Set(UInt64).new
    @visited_types = Set(Crystal::Type).new
    @scoped_vars = Hash(String, Crystal::Location?).new
    @scope_stack = [] of Hash(String, Crystal::Location?)

    def initialize(target : Crystal::ASTNode, target_locations : Array({Crystal::Location, Crystal::Location}), @include_declaration : Bool)
      @target_locations = target_locations.to_set { |start_location, _| location_key(start_location) }
      @target_kind, @target_name = target_identity(target)
    end

    private def target_identity(node : Crystal::ASTNode) : {TargetKind, String}
      case node
      when Crystal::Call, Crystal::Def, Crystal::Macro
        {TargetKind::Method, node.name}
      when Crystal::Path
        {TargetKind::Path, node.to_s}
      when Crystal::ClassDef, Crystal::ModuleDef, Crystal::AnnotationDef, Crystal::EnumDef, Crystal::LibDef
        {TargetKind::Path, node.name.to_s}
      when Crystal::InstanceVar
        {TargetKind::Instance, node.name}
      when Crystal::ClassVar
        {TargetKind::Class, node.name}
      when Crystal::Arg, Crystal::Var
        {TargetKind::Local, node.name}
      else
        {TargetKind::Local, node.to_s}
      end
    end

    def process(result : Crystal::Compiler::Result)
      # Top-level code contains declarations, constants, and expanded requires.
      result.node.accept(self)
      process_type(result.program)
      result.program.file_modules.each_value { |file_module| process_type(file_module) }
      @locations.sort_by! { |location| {location.uri, location.range.start.line, location.range.start.character} }
      @locations
    end

    private def process_type(type : Crystal::Type) : Nil
      return if @visited_types.includes?(type)
      @visited_types << type

      if type.is_a?(Crystal::NamedType) || type.is_a?(Crystal::Program) || type.is_a?(Crystal::FileModule)
        type.types?.try &.each_value { |inner_type| process_type(inner_type) }
      end

      if type.is_a?(Crystal::GenericType)
        type.each_instantiated_type { |instance| process_type(instance) }
      end

      process_type(type.metaclass) if type.metaclass != type

      if type.is_a?(Crystal::DefInstanceContainer)
        type.def_instances.each_value { |typed_def| typed_def.accept(self) }
      end
    end

    private def expanded(location : Crystal::Location) : Crystal::Location
      location.expanded_location || location
    end

    private def location_key(location : Crystal::Location) : LocationKey
      loc = expanded(location)
      {(loc.original_filename || loc.filename).to_s, loc.line_number, loc.column_number}
    end

    private def target?(location : Crystal::Location?) : Bool
      location ? @target_locations.includes?(location_key(location)) : false
    end

    private def target?(locations : Array(Crystal::Location)?) : Bool
      locations.try(&.any? { |location| target?(location) }) || false
    end

    private def add_location(location : Crystal::Location?, size : Int32) : Nil
      return unless location
      loc = expanded(location)
      filename = (loc.original_filename || loc.filename).to_s
      start_line = loc.line_number - 1
      start_character = loc.column_number - 1
      end_character = start_character + Math.max(size, 1)
      key = {filename, start_line, start_character, start_line, end_character}
      return unless @seen_locations.add?(key)

      @locations << LSP::Location.new(
        uri: "file://#{filename}",
        range: LSP::Range.new(
          start: LSP::Position.new(line: start_line, character: start_character),
          end: LSP::Position.new(line: start_line, character: end_character),
        ),
      )
    end

    private def add_node(node : Crystal::ASTNode) : Nil
      add_location(node.name_location || node.location, node.name_size)
    end

    private def declaration?(node : Crystal::ASTNode) : Bool
      target?(node.location) || target?(node.name_location)
    end

    def visit(node)
      true
    end

    def visit_any(node : Crystal::Def | Crystal::Assign | Crystal::Block)
      case node
      when Crystal::Def
        @scope_stack << @scoped_vars
        @scoped_vars = Hash(String, Crystal::Location?).new
        node.vars.try &.each { |name, meta_var| @scoped_vars[name] = meta_var.location || node.location }
        node.args.each do |arg|
          @scoped_vars[arg.name] = arg.location || node.location
          if @include_declaration && @target_kind.local? && @target_name == arg.name && target?(arg.location || node.location)
            add_node(arg)
          elsif @include_declaration && @target_kind.instance? && @target_name.lchop('@') == arg.name && target?(arg.location || node.location)
            add_location(arg.location, @target_name.size)
          end
        end
        add_node(node) if @include_declaration && @target_kind.method? && declaration?(node)
      when Crystal::Block
        @scope_stack << @scoped_vars
        @scoped_vars = @scoped_vars.dup
        node.vars.try &.each { |name, meta_var| @scoped_vars[name] = meta_var.location || node.location }
        node.args.each do |arg|
          @scoped_vars[arg.name] = arg.location || node.location
          add_node(arg) if @include_declaration && @target_kind.local? && @target_name == arg.name && target?(arg.location || node.location)
        end
      when Crystal::Assign
        target = node.target
        @declaration_nodes << target.object_id
        if target.is_a?(Crystal::Var)
          @scoped_vars[target.name] = node.location
        end
      end
      super
    end

    def end_visit_any(node : Crystal::Def | Crystal::Block)
      @scoped_vars = @scope_stack.pop
    end

    def visit(node : Crystal::Call)
      return true unless @target_kind.method? && node.name == @target_name
      matches = node.target_defs.try(&.any? { |definition| target?(definition.location) }) || false
      matches ||= node.expanded_macro.try { |macro_definition| target?(macro_definition.location) } || false
      add_location(node.name_location || node.location, node.name_size) if matches
      true
    end

    def visit(node : Crystal::Macro)
      add_node(node) if @include_declaration && @target_kind.method? && node.name == @target_name && declaration?(node)
      true
    end

    def visit(node : Crystal::Path)
      return true unless @target_kind.path?
      target = node.target_const || node.target_type
      if target.is_a?(Crystal::Type)
        target = target.instance_type
      end
      if target && target?(target.locations) && (@include_declaration || !@declaration_nodes.includes?(node.object_id))
        add_node(node)
      end
      true
    end

    def visit(node : Crystal::Var)
      if @target_kind.local? && node.name == @target_name && (definition = @scoped_vars[node.name]?) && target?(definition)
        add_node(node) if @include_declaration || !@declaration_nodes.includes?(node.object_id)
      end
      true
    end

    def visit(node : Crystal::InstanceVar)
      return true unless @target_kind.instance? && node.name == @target_name
      # Instance variables don't retain their MetaTypeVar on the AST node, but
      # the typed node's enclosing def does expose the owning `self` type.
      variable = @current_self_type.try(&.lookup_instance_var?(node.name)) rescue nil
      if variable
        if target?(variable.location) && (@include_declaration || !@declaration_nodes.includes?(node.object_id))
          add_node(node)
        end
      end
      true
    end

    def visit(node : Crystal::ClassVar)
      return true unless @target_kind.class? && node.name == @target_name
      variable = node.var rescue nil
      if variable && target?(variable.location) && (@include_declaration || !@declaration_nodes.includes?(node.object_id))
        add_location(node.location, node.name.size)
      end
      true
    end

    def visit(node : Crystal::ClassDef | Crystal::ModuleDef | Crystal::AnnotationDef | Crystal::EnumDef | Crystal::LibDef)
      resolved_type = node.resolved_type rescue nil
      if @include_declaration && @target_kind.path? && resolved_type && target?(resolved_type.locations)
        add_location(node.name_location || node.location, node.name.name_size)
      end
      true
    end

    @current_self_type : Crystal::Type?
    @self_type_stack = [] of Crystal::Type?

    def visit(node : Crystal::Def)
      @self_type_stack << @current_self_type
      @current_self_type = node.owner rescue nil
      true
    end

    def end_visit(node : Crystal::Def)
      @current_self_type = @self_type_stack.pop
    end

    def visit(node : Crystal::Require)
      node.expanded.try &.accept(self)
      false
    end
  end
end
