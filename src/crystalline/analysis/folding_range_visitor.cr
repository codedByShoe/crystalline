module Crystalline::Analysis
  class FoldingRangeVisitor < Crystal::Visitor
    getter ranges = [] of LSP::FoldingRange

    {% for node_type in %w(
                          Def Macro ClassDef ModuleDef AnnotationDef EnumDef
                          LibDef FunDef CStructOrUnionDef If Unless Case Select
                          While Until Block MacroIf MacroFor
                        ) %}
      def visit(node : Crystal::{{node_type.id}})
        append_range(node)
        true
      end
    {% end %}

    def visit(node : Crystal::ExceptionHandler)
      append_range(node) unless node.implicit
      true
    end

    def visit(node)
      true
    end

    def end_visit(node)
    end

    private def append_range(node : Crystal::ASTNode)
      start_location = node.location
      end_location = node.end_location
      return unless start_location && end_location
      return if start_location.line_number >= end_location.line_number

      @ranges << LSP::FoldingRange.new(
        start_line: start_location.line_number - 1,
        end_line: end_location.line_number - 1,
      )
    end
  end
end
