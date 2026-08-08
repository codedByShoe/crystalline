require "./project"
require "./broken_source_fixer"
require "./analysis/*"

# A parse of every file in the workspace, reused until the file changes.
#
# This is the tier that answers without the compiler. Everything it knows comes
# from parsing alone, so it is always available and always cheap - where a
# semantic analysis costs seconds and can only run one at a time. It is
# deliberately ignorant: it knows what the source says, not what it means, and
# an analysis supersedes it wherever the two overlap.
class Crystalline::Index
  # A file parsed once, and the contents it was parsed from.
  record Entry,
    stamp : String,
    methods : Array(Analysis::SourceMethod),
    types : Array({String, LSP::CompletionItemKind}),
    symbols : Array(LSP::DocumentSymbol),
    declarations : Analysis::Declarations

  @entries = {} of String => Entry
  # The shard sources of each project, by project root. Enumerating them means
  # globbing a directory tree, and every completion asks.
  @shard_files = {} of String => Array(String)
  # Entries are read and written from the fibers serving requests, and from the
  # one that builds the index at startup.
  @lock = Mutex.new

  def initialize(@projects : Array(Project))
  end

  # Identifies the contents of a file without reading it.
  def self.disk_stamp(path : String) : String
    info = File.info(path)
    "disk:#{info.modification_time.to_unix_ns}:#{info.size}"
  end

  # An opened buffer, which is superseded whenever the editor changes it.
  def self.buffer_stamp(source : String) : String
    "buffer:#{source.hash}"
  end

  # A buffer rewritten for the request being answered. Never reusable across
  # requests, but shared by everything looking at the same rewrite.
  def self.rewritten_stamp(source : String) : String
    "current:#{source.hash}"
  end

  # The kept parse of *path*, if it is still the parse of *stamp*.
  def cached(path : String, stamp : String) : Entry?
    entry = @lock.synchronize { @entries[path]? }
    entry if entry && entry.stamp == stamp
  end

  # Whether a parse of *path* is being kept for the contents it has on disk.
  def indexed?(path : String) : Bool
    normalized = Path[path].normalize.to_s
    !cached(normalized, Index.disk_stamp(normalized)).nil?
  rescue
    false
  end

  # The parse of *source* as the contents of *path*, reusing the kept one when
  # *stamp* says the contents have not changed.
  def entry_for(path : String, source : String, *, stamp : String) : Entry
    if (kept = cached(path, stamp))
      return kept
    end

    ast = begin
      parse(source, path)
    rescue
      # Only pay for the repair pass when the source does not parse as it is.
      parse(BrokenSourceFixer.fix(source), path)
    end

    methods = Analysis::SourceMethodsVisitor.new.tap { |visitor| ast.accept(visitor) }.methods
    symbols = Analysis::DocumentSymbolsVisitor.new.tap { |visitor| ast.accept(visitor) }.symbols
    declarations = Analysis::DeclarationsVisitor.new.tap { |visitor| ast.accept(visitor) }.declarations
    entry = Entry.new(
      stamp: stamp,
      methods: methods,
      types: flatten_type_symbols(symbols),
      symbols: symbols,
      declarations: declarations,
    )
    @lock.synchronize { @entries[path] = entry }
    entry
  end

  # The crystal files *project* owns, which is everything under it that is not
  # a shard it depends on.
  def files_in(project : Project) : Array(String)
    root = project.root_uri.decoded_path
    Dir.glob(Path[root, "**", "*.cr"].to_s).reject do |path|
      relative_parts = Path[path].relative_to(root).parts
      relative_parts.includes?("lib") || relative_parts.includes?(".git")
    end
  end

  # The crystal files of the shards *project* depends on.
  #
  # Inheritance does not stop at the edge of a project: a type descending from
  # `Kemal::Handler` responds to what Kemal gave it, and a tier that read only
  # project source could not say so. Only each shard's `src` is read - the
  # specs and samples beside it declare types that are nobody's business to
  # offer as completions.
  #
  # Memoized, and deliberately not watched. Shards change when `shards install`
  # is run, which is not something that happens while a file is being typed in;
  # picking that up is what restarting the server is for.
  def shard_files_in(project : Project) : Array(String)
    key = project.root_uri.to_s
    @lock.synchronize do
      @shard_files[key] ||= Dir.glob(Path[project.default_lib_path, "*", "src", "**", "*.cr"].to_s)
    end
  end

  # Every crystal file of every project, falling back to *opened_paths* for a
  # server started without a workspace root.
  def all_files(opened_paths : Array(String)) : Array(String)
    files = @projects.flat_map { |project| files_in(project) }
    files.concat(opened_paths) if files.empty?
    files.uniq!
  end

  # The parse of every file in the project *file_uri* belongs to.
  #
  # *buffers* are the opened documents by normalized path, which supersede what
  # is on disk. *current_source* supersedes both for *file_uri* itself, and is
  # how a request asks about a buffer it has rewritten.
  def project_entries(file_uri : URI, buffers : Hash(String, String), *, current_source : String? = nil) : Array(Entry)
    current_path = Path[file_uri.decoded_path].normalize.to_s
    project = Project.best_fit_for_file(@projects, file_uri)
    own = project ? files_in(project) : buffers.keys.uniq

    entries = own.compact_map do |path|
      normalized = Path[path].normalize.to_s
      begin
        if current_source && normalized == current_path
          entry_for(normalized, current_source, stamp: Index.rewritten_stamp(current_source))
        else
          entry_from(path, normalized, buffers)
        end
      rescue e
        LSP::Log.debug(exception: e) { "Unable to index #{path}" }
        nil
      end
    end

    return entries unless project

    entries.concat(shard_entries(project))
  end

  # Shard files are read once and then reused without asking the filesystem
  # whether they have changed, because within one session they have not. Every
  # completion walks this list, and a few hundred `stat` calls per keystroke is
  # a real cost to pay for an answer that is always the same.
  private def shard_entries(project : Project) : Array(Entry)
    shard_files_in(project).compact_map do |path|
      normalized = Path[path].normalize.to_s
      kept(normalized) || begin
        entry_for(normalized, File.read(path), stamp: Index.disk_stamp(path))
      rescue e
        LSP::Log.debug(exception: e) { "Unable to index #{path}" }
        nil
      end
    end
  end

  # Whatever parse is being kept for *path*, current or not.
  private def kept(path : String) : Entry?
    @lock.synchronize { @entries[path]? }
  end

  # Parse every file of every project once, up front.
  #
  # This is what answers a request the compiler is not free to serve, and it is
  # otherwise built on first use - so the request least able to afford it is the
  # one that pays for reading and parsing the whole project. It needs no
  # compiler, so it runs while the first analysis still holds one.
  def warm(buffers : Hash(String, String)) : Nil
    @projects.each do |project|
      (files_in(project) + shard_files_in(project)).each do |path|
        normalized = Path[path].normalize.to_s
        # An opened buffer is reindexed whenever it changes anyway, and there
        # are few enough of them for that to cost nothing.
        next if buffers.has_key?(normalized)

        stamp = Index.disk_stamp(path)
        entry_for(normalized, File.read(path), stamp: stamp) unless cached(normalized, stamp)
      rescue e
        LSP::Log.debug(exception: e) { "Unable to index #{path}" }
      ensure
        # Requests are served while this runs, and a whole project is a lot of
        # parsing to hold a single-threaded scheduler for.
        Fiber.yield
      end
    end

    LSP::Log.info { "[index] Ready" }
  end

  # The parse of *path*, from the opened buffer if there is one and from disk
  # otherwise.
  private def entry_from(path : String, normalized : String, buffers : Hash(String, String)) : Entry
    if (buffer = buffers[normalized]?)
      entry_for(normalized, buffer, stamp: Index.buffer_stamp(buffer))
    else
      stamp = Index.disk_stamp(path)
      # Checked before reading, which is the whole point of the stamp.
      cached(normalized, stamp) || entry_for(normalized, File.read(path), stamp: stamp)
    end
  end

  # :ditto:
  def entry_from(path : String, buffers : Hash(String, String)) : Entry
    entry_from(path, Path[path].normalize.to_s, buffers)
  end

  private def parse(source : String, path : String) : Crystal::ASTNode
    parser = Crystal::Parser.new(source)
    parser.filename = path
    parser.wants_doc = true
    parser.parse
  end

  private def flatten_type_symbols(symbols : Array(LSP::DocumentSymbol), parent : String? = nil) : Array({String, LSP::CompletionItemKind})
    symbols.flat_map do |symbol|
      qualified_name = parent ? "#{parent}::#{symbol.name}" : symbol.name
      kind = case symbol.kind
             when .class?  then LSP::CompletionItemKind::Class
             when .module? then LSP::CompletionItemKind::Module
             when .enum?   then LSP::CompletionItemKind::Enum
             end

      entries = kind ? [{qualified_name, kind}] : [] of {String, LSP::CompletionItemKind}
      entries.concat(flatten_type_symbols(symbol.children || [] of LSP::DocumentSymbol, qualified_name))
    end
  end
end
