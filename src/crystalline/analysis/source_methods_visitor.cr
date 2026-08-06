module Crystalline::Analysis
  record SourceMethod,
    owner : String,
    name : String,
    class_method : Bool,
    detail : String

  # Collects methods that are visible directly in source without requiring
  # semantic analysis. This keeps project methods available while the edited
  # program is temporarily unable to compile.
  class SourceMethodsVisitor < Crystal::Visitor
    getter methods = [] of SourceMethod
    @owners = [] of String

    def visit(node)
      true
    end

    def visit(node : Crystal::ClassDef | Crystal::ModuleDef)
      name = node.name.to_s
      owner = if @owners.empty? || name.includes?("::")
                name
              else
                "#{@owners.last}::#{name}"
              end
      @owners << owner
      true
    end

    def end_visit(node : Crystal::ClassDef | Crystal::ModuleDef)
      @owners.pop
    end

    def visit(node : Crystal::Def)
      receiver = node.receiver
      owner = if receiver && receiver.to_s != "self"
                receiver.to_s
              else
                @owners.last?
              end
      return false unless owner
      return false if node.visibility.private?
      return false if node.doc.try(&.includes?(":nodoc:"))

      class_method = !receiver.nil?
      @methods << SourceMethod.new(
        owner: owner,
        name: node.name,
        class_method: class_method,
        detail: Utils.format_def(node, short: true),
      )
      if node.name == "initialize" && !class_method
        @methods << SourceMethod.new(
          owner: owner,
          name: "new",
          class_method: true,
          detail: "new(#{node.args.join(", ")})",
        )
      end
      false
    end

    def visit(node : Crystal::Call)
      return true unless (owner = @owners.last?)
      return true unless node.obj.nil?
      return true unless {"getter", "setter", "property"}.includes?(node.name)

      node.args.each do |arg|
        name = arg.is_a?(Crystal::TypeDeclaration) ? arg.var.to_s : arg.to_s
        @methods << SourceMethod.new(owner, name, false, name) unless node.name == "setter"
        @methods << SourceMethod.new(owner, "#{name}=", false, "#{name}=(value)") unless node.name == "getter"
      end
      false
    end

    def end_visit(node)
    end
  end
end
