require "./index"

# Answers what a name means and what a type responds to, from declarations
# alone.
#
# The compiler answers both of these better, and where it has an answer this is
# not asked. What it has instead is availability: it costs a hash lookup and a
# walk of a few declarations, so it can answer while an analysis is still
# running, while the buffer does not compile, and on the very first keystroke of
# a session.
#
# It stops at the edge of the project. Shards and the standard library are not
# indexed - they are what the compiler is for - so a type inheriting from
# outside the project inherits nothing here.
class Crystalline::Resolver
  alias TypeDecl = Analysis::TypeDecl
  alias MethodDecl = Analysis::MethodDecl
  alias ConstDecl = Analysis::ConstDecl

  @types = Hash(String, Array(TypeDecl)).new
  @methods = Hash(String, Array(MethodDecl)).new
  @constants = Hash(String, Array(ConstDecl)).new

  # Crystal types are open, so the declarations of one type are gathered from
  # wherever they were written rather than expected in one place.
  def initialize(entries : Array(Index::Entry))
    entries.each do |entry|
      entry.declarations.types.each do |decl|
        (@types[decl.fqn] ||= [] of TypeDecl) << decl
      end
      entry.declarations.methods.each do |decl|
        (@methods[decl.owner] ||= [] of MethodDecl) << decl
      end
      entry.declarations.constants.each do |decl|
        (@constants[decl.fqn] ||= [] of ConstDecl) << decl
      end
    end
  end

  # Whether anything in the project declares *fqn*.
  def declared?(fqn : String) : Bool
    @types.has_key?(fqn)
  end

  # The qualified name that *path* refers to when written in *scope*.
  #
  # Crystal looks a name up in the scope it was written in and then outward, so
  # `Inner` inside `module Outer` finds `Outer::Inner` before it finds a
  # top-level `Inner`. A name can also come from what an enclosing type
  # inherits, which is why the ancestors of each scope are tried too.
  def resolve(path : String, scope : Array(String) = [] of String) : String?
    names = segments(path)
    return if names.empty?

    # `::Name` is written against the top level on purpose.
    if path.lstrip.starts_with?("::")
      qualified = names.join("::")
      return @types.has_key?(qualified) ? qualified : nil
    end

    scope.size.downto(0) do |depth|
      container = scope[0...depth]
      qualified = (container + names).join("::")
      return qualified if @types.has_key?(qualified)

      next if container.empty?
      ancestors(container.join("::")).each do |ancestor|
        inherited = "#{ancestor}::#{names.join("::")}"
        return inherited if @types.has_key?(inherited)
      end
    end
  end

  # Everywhere the type *fqn* is declared - its reopenings included, since an
  # open type has as many declaration sites as there are places that add to it.
  def type_declarations(fqn : String) : Array(TypeDecl)
    declarations_of(fqn)
  end

  # The declarations of the constant that *path* refers to when written in
  # *scope*, looked up outward the way `resolve` looks a type up. An enum
  # member is a constant on the enum, so `Color::Red` is answered here too.
  def constant_declarations(path : String, scope : Array(String) = [] of String) : Array(ConstDecl)
    names = segments(path)
    return [] of ConstDecl if names.empty?

    if path.lstrip.starts_with?("::")
      return @constants[names.join("::")]? || [] of ConstDecl
    end

    scope.size.downto(0) do |depth|
      container = scope[0...depth]
      if (found = @constants[(container + names).join("::")]?)
        return found
      end

      next if container.empty?
      ancestors(container.join("::")).each do |ancestor|
        if (found = @constants["#{ancestor}::#{names.join("::")}"]?)
          return found
        end
      end
    end

    [] of ConstDecl
  end

  # Every method *fqn* responds to, its ancestors included, most derived first.
  def members(fqn : String, class_method : Bool, *, include_private : Bool = false) : Array(MethodDecl)
    found = class_method ? class_members(fqn) : instance_members(fqn)
    # A private method is not reachable through a receiver, so completion never
    # wants one - but a bare call from inside the type is exactly how a private
    # method is reached, and a definition lookup does.
    found.reject!(&.visibility.private?) unless include_private
    found.uniq { |method| {method.name, method.detail} }
  end

  # Every type *fqn* inherits from, most derived first.
  #
  # Included modules come before the superclass and later inclusions before
  # earlier ones, which is the order Crystal resolves a call in.
  def ancestors(fqn : String, visited : Set(String) = Set(String).new) : Array(String)
    return [] of String unless visited.add?(fqn)

    result = [] of String
    declarations_of(fqn).each do |decl|
      decl.includes.reverse_each do |name|
        append_ancestor(result, name, decl.namespace, visited)
      end
    end
    declarations_of(fqn).each do |decl|
      decl.superclass.try { |name| append_ancestor(result, name, decl.namespace, visited) }
    end
    result
  end

  private def append_ancestor(result : Array(String), name : String, namespace : Array(String), visited : Set(String)) : Nil
    resolved = resolve(name, namespace)
    return unless resolved

    result << resolved
    result.concat(ancestors(resolved, visited))
  end

  private def instance_members(fqn : String) : Array(MethodDecl)
    ([fqn] + ancestors(fqn)).flat_map { |type| own_methods(type, class_method: false) }
  end

  # Class methods come down the superclass chain only: `include` gives a type
  # instance methods, and it is `extend` that gives it class ones.
  private def class_members(fqn : String) : Array(MethodDecl)
    found = superclass_chain(fqn).flat_map do |type|
      extended = declarations_of(type).flat_map do |decl|
        decl.extends.compact_map { |name| resolve(name, decl.namespace) }
      end
      own_methods(type, class_method: true) + extended.flat_map { |mod| instance_members(mod) }
    end

    found.concat(constructors(fqn))
  end

  # *fqn* and everything it descends from, most derived first.
  private def superclass_chain(fqn : String, visited : Set(String) = Set(String).new) : Array(String)
    return [] of String unless visited.add?(fqn)

    result = [fqn]
    declarations_of(fqn).each do |decl|
      name = decl.superclass
      next unless name
      resolved = resolve(name, decl.namespace)
      next unless resolved

      result.concat(superclass_chain(resolved, visited))
    end
    result
  end

  # `new` is written nowhere. It is what `initialize` means, and a class that
  # declares no `initialize` still has one that takes nothing.
  private def constructors(fqn : String) : Array(MethodDecl)
    decls = declarations_of(fqn)
    return [] of MethodDecl unless decls.any? { |decl| decl.kind.class? || decl.kind.struct? }

    initializers = instance_members(fqn).select(&.name.== "initialize")
    if initializers.empty?
      [new_from(fqn, [] of Analysis::ParamDecl, nil, decls.first.range, decls.first.file)]
    else
      initializers.map { |init| new_from(fqn, init.params, init.doc, init.range, init.file) }
    end
  end

  private def new_from(fqn : String, params : Array(Analysis::ParamDecl), doc : String?, range : LSP::Range, file : String?) : MethodDecl
    MethodDecl.new(
      owner: fqn,
      name: "new",
      class_method: true,
      params: params,
      return_type: fqn,
      visibility: Crystal::Visibility::Public,
      doc: doc,
      detail: params.empty? ? "new" : "new(#{params.join(", ")})",
      range: range,
      file: file,
    )
  end

  private def own_methods(fqn : String, *, class_method : Bool) : Array(MethodDecl)
    (@methods[fqn]? || [] of MethodDecl).select { |method| method.class_method == class_method }
  end

  private def declarations_of(fqn : String) : Array(TypeDecl)
    @types[fqn]? || [] of TypeDecl
  end

  # The names in a path as written, with what cannot take part in a lookup
  # removed: a nilable marker, and the arguments of a generic.
  private def segments(path : String) : Array(String)
    cleaned = path.strip.lchop("::").rchop('?')
    # `Hash(String, Array(Int32))` names `Hash`, and nesting rules out matching
    # the arguments as a bracketed group.
    cleaned = cleaned.split('(').first
    cleaned.split("::").reject(&.empty?)
  end
end
