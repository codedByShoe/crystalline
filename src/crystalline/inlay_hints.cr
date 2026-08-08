require "./resolver"

# Builds the hints an editor draws inline: the type of a local, and the name of
# the parameter an argument is being passed as.
#
# Crystal writes very few types down, which is what makes these worth having and
# also what makes them hard: most of the answers are inferred, and inference is
# the compiler's. So this says nothing it cannot read off the source - a
# literal, a `.new`, a declared return type, a declared parameter - and stays
# quiet everywhere else. A hint that is merely plausible is worse than no hint,
# because it is drawn as though it were fact.
class Crystalline::InlayHints < Crystal::Visitor
  getter hints = [] of LSP::InlayHint

  # The types enclosing the node being visited, outermost first.
  @scope = [] of String
  @enclosing = [] of Array(String)
  # The locals in view, by name. Filled in from parameter restrictions and from
  # assignments already walked past, which is exactly what is in scope.
  @locals = {} of String => String

  # A call whose name is not an ordinary identifier is an operator or an index,
  # and naming the parameters of `a + b` helps nobody.
  CALLABLE_NAME = /\A[a-z_]\w*[!?=]?\z/

  def initialize(@resolver : Resolver, @range : LSP::Range)
  end

  def visit(node)
    true
  end

  def end_visit(node)
  end

  def visit(node : Crystal::ClassDef | Crystal::ModuleDef | Crystal::EnumDef | Crystal::LibDef)
    name_node = node.name
    segments = name_node.is_a?(Crystal::Path) ? name_node.names : name_node.to_s.split("::")
    global = name_node.is_a?(Crystal::Path) && name_node.global?

    @enclosing << @scope
    @scope = (global ? [] of String : @scope) + segments
    true
  end

  def end_visit(node : Crystal::ClassDef | Crystal::ModuleDef | Crystal::EnumDef | Crystal::LibDef)
    @scope = @enclosing.pop? || [] of String
  end

  # A method body is its own set of locals, and its parameters are the ones
  # whose types are written down.
  def visit(node : Crystal::Def)
    outer = @locals
    @locals = {} of String => String
    node.args.each do |arg|
      arg.restriction.try { |restriction| @locals[arg.name] = restriction.to_s }
    end

    node.body.accept(self)
    @locals = outer
    false
  end

  def visit(node : Crystal::Assign)
    # Walked first, so a call on the right hand side still gets its own hints.
    node.value.accept(self)

    target = node.target
    return false unless target.is_a?(Crystal::Var)

    type = derived_type(node.value)
    return false unless type

    @locals[target.name] = type
    target.end_location.try { |location| add(location.line_number - 1, location.column_number, ": #{type}", :type) }
    false
  end

  def visit(node : Crystal::Call)
    add_parameter_hints(node)
    true
  end

  # The name each positional argument is being passed as.
  private def add_parameter_hints(call : Crystal::Call) : Nil
    return if call.args.empty?
    return unless call.name.matches?(CALLABLE_NAME)

    method = callee(call)
    return unless method

    params = method.params
    # A splat takes an unknown number of arguments with it, so nothing after it
    # can be matched up by position.
    return if params.any? { |param| param.splat || param.double_splat }

    call.args.each_with_index do |argument, index|
      param = params[index]?
      break unless param
      next if param.block
      next if names_itself?(argument, param.name)

      location = argument.location
      next unless location

      add(location.line_number - 1, location.column_number - 1, "#{param.name}:", :parameter, padding_right: true)
    end
  end

  # The one method a call can be referring to, or nothing when that is not
  # clear. Overloads that agree on their parameter names are still an answer;
  # overloads that disagree are not.
  private def callee(call : Crystal::Call) : Analysis::MethodDecl?
    candidates = candidates_for(call)
    return if candidates.empty?

    matching = candidates.select { |method| method.name == call.name && arity_fits?(method, call.args.size) }
    first = matching.first?
    return unless first
    return unless matching.all? { |method| method.params.map(&.name) == first.params.map(&.name) }

    first
  end

  private def candidates_for(call : Crystal::Call) : Array(Analysis::MethodDecl)
    obj = call.obj
    unless obj
      # A bare call reaches what the enclosing type responds to, and then what
      # is defined at the top level.
      enclosing = @scope.empty? ? nil : @scope.join("::")
      own = enclosing ? @resolver.members(enclosing, false) + @resolver.members(enclosing, true) : [] of Analysis::MethodDecl
      return own + @resolver.members("", false)
    end

    receiver = receiver_type(obj)
    return [] of Analysis::MethodDecl unless receiver

    fqn, class_method = receiver
    @resolver.members(fqn, class_method)
  end

  # The type a receiver names, and whether it was named as a type rather than
  # as a value of one.
  private def receiver_type(node : Crystal::ASTNode) : {String, Bool}?
    case node
    when Crystal::Path
      @resolver.resolve(node.to_s, @scope).try { |fqn| {fqn, true} }
    when Crystal::Var
      @locals[node.name]?.try { |written| @resolver.resolve(written, @scope).try { |fqn| {fqn, false} } }
    when Crystal::Call
      # `Widget.new.render` - the receiver is an instance of whatever was built.
      return unless node.name == "new"
      obj = node.obj
      return unless obj.is_a?(Crystal::Path)
      @resolver.resolve(obj.to_s, @scope).try { |fqn| {fqn, false} }
    end
  end

  private def arity_fits?(method : Analysis::MethodDecl, count : Int32) : Bool
    positional = method.params.reject { |param| param.block || param.double_splat }
    required = positional.count { |param| param.default_value.nil? && !param.splat }

    count >= required && count <= positional.size
  end

  # `render(width)` passed to a parameter called `width` says nothing twice.
  #
  # A bare name is only a `Var` once the parser has seen it assigned; a getter
  # or a not-yet-assigned local reads as a call to itself, and reads to a person
  # as exactly the same repetition.
  private def names_itself?(argument : Crystal::ASTNode, name : String) : Bool
    case argument
    when Crystal::Var         then argument.name == name
    when Crystal::InstanceVar then argument.name.lchop('@') == name
    when Crystal::Call        then argument.obj.nil? && argument.args.empty? && argument.name == name
    else                           false
    end
  end

  # What an expression evaluates to, where the source says so outright.
  private def derived_type(node : Crystal::ASTNode) : String?
    case node
    when Crystal::StringLiteral     then "String"
    when Crystal::CharLiteral       then "Char"
    when Crystal::SymbolLiteral     then "Symbol"
    when Crystal::BoolLiteral       then "Bool"
    when Crystal::NilLiteral        then "Nil"
    when Crystal::RegexLiteral      then "Regex"
    when Crystal::NumberLiteral     then number_type(node.kind)
    when Crystal::ArrayLiteral      then node.of.try { |of| "Array(#{of})" }
    when Crystal::HashLiteral       then node.of.try { |of| "Hash(#{of.key}, #{of.value})" }
    when Crystal::TupleLiteral      then "Tuple"
    when Crystal::NamedTupleLiteral then "NamedTuple"
    when Crystal::ProcLiteral       then "Proc"
    when Crystal::Path              then @resolver.resolve(node.to_s, @scope).try { |fqn| "#{fqn}.class" }
    when Crystal::Call
      if node.name == "new" && (obj = node.obj)
        @resolver.resolve(obj.to_s, @scope) || obj.to_s
      else
        callee(node).try(&.return_type)
      end
    end
  end

  private def number_type(kind : Crystal::NumberKind) : String
    case kind
    when .i8?   then "Int8"
    when .i16?  then "Int16"
    when .i32?  then "Int32"
    when .i64?  then "Int64"
    when .i128? then "Int128"
    when .u8?   then "UInt8"
    when .u16?  then "UInt16"
    when .u32?  then "UInt32"
    when .u64?  then "UInt64"
    when .u128? then "UInt128"
    when .f32?  then "Float32"
    else             "Float64"
    end
  end

  private def add(line : Int32, character : Int32, label : String, kind : LSP::InlayHintKind, *, padding_right = false) : Nil
    # The client asks about what is on screen, and drawing the rest of the file
    # costs the same as drawing what it asked for.
    return unless @range.start.line <= line <= @range.end.line

    @hints << LSP::InlayHint.new(
      position: LSP::Position.new(line: line, character: character),
      label: label,
      kind: kind,
      padding_left: false,
      padding_right: padding_right,
    )
  end
end
