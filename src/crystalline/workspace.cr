require "uri"
require "yaml"
require "./text_document"
require "./compilation_lock"
require "./index"
require "./resolver"
require "./inlay_hints"
require "./progress"
require "./project"
require "./result_cache"
require "./analysis/*"

class Crystalline::Workspace
  # A successful analysis, and the target it was produced from.
  record StoredAnalysis,
    target : String,
    result : Crystal::Compiler::Result

  # The previous compilation results, indexed by compilation entry point.
  @result_cache : Crystalline::ResultCache = Crystalline::ResultCache.new
  # Completion rewrites remove the fragment after a receiver, so `value.`,
  # `value.up`, and `value.upc` all have the same semantic input. Retain the
  # latest result per document instead of compiling that input repeatedly.
  @completion_cache = {} of String => {String, Crystal::Compiler::Result, Crystal::Location}
  @completion_items_cache = {} of String => {String, Array(LSP::CompletionItem)}
  # Completion items for a standalone receiver expression such as
  # `uninitialized String`. That analysis loads the prelude and the project's
  # shards but never the project's own sources, so its answer depends on nothing
  # an editing session changes and is worth keeping for the whole session.
  @receiver_items_cache = {} of String => Array(LSP::CompletionItem)
  # When the dependencies of each project were last recomputed.
  @dependency_attempts = {} of String => Time::Instant
  # The most recent successful analysis of each project. What a type responds to
  # is answered from here rather than from an analysis of the buffer being typed
  # in, which costs a whole project build per keystroke. A shard without an entry
  # point has no project-wide analysis to speak of, so this holds whichever file
  # was compiled last - a partial view that is still worth asking.
  @analyses = {} of String => StoredAnalysis
  @analyses_lock = Mutex.new
  # Requests are served from independent fibers, which run in parallel when the
  # server is built with `-Dpreview_mt`. Each piece of mutable state below is
  # only touched while holding its lock.
  @completion_cache_lock = Mutex.new
  @documents_lock = Mutex.new
  @dependency_attempts_lock = Mutex.new
  # The workspace filesystem uri.
  getter root_uri : URI?
  # A list of documents that are openened in the text editor.
  getter opened_documents = {} of String => TextDocument
  # A list of projects in this workspace
  getter projects = [] of Project
  # What the workspace knows from parsing alone, which is everything it can
  # answer without waiting for the compiler.
  getter index : Index

  def initialize(server : LSP::Server, root_uri : String?)
    if (@root_uri = root_uri.try &->URI.parse(String))
      @projects = Project.find_in_workspace_root @root_uri.not_nil!
      if @projects.size > 0
        LSP::Log.info {
          <<-LOG
          "[workspace] Found projects:
          #{@projects.map(&.root_uri.decoded_path).join('\n')}
          LOG
        }
      end
    end
    @index = Index.new(@projects)
  end

  # The document opened at *uri*, if any.
  private def document_at(uri : String) : TextDocument?
    @documents_lock.synchronize { @opened_documents[uri]? }
  end

  # A stable copy of the opened documents, safe to iterate while other fibers
  # open, close or update documents.
  private def documents_snapshot : Hash(String, TextDocument)
    @documents_lock.synchronize { @opened_documents.dup }
  end

  def open_document(params : LSP::DidOpenTextDocumentParams)
    raw_uri = params.text_document.uri
    uri = URI.parse(raw_uri)
    project = Project.best_fit_for_file(@projects, uri)
    document = TextDocument.new(uri, project, params.text_document.text, params.text_document.version)
    @documents_lock.synchronize { @opened_documents[raw_uri] = document }
  end

  def update_document(server : LSP::Server, params : LSP::DidChangeTextDocumentParams)
    file_uri = params.text_document.uri
    document_at(file_uri).try { |document|
      content_changes = params.content_changes.map { |change|
        {change.text, change.range}
      }
      document.update_contents(content_changes, version: params.text_document.version)

      document.project?.try(&.entry_point?).try { |entry|
        @result_cache.invalidate(entry.to_s)
      }
    }
    @result_cache.invalidate(file_uri)
    # A cached completion result was compiled against every *other* document as
    # it was at that time, so editing this one makes all of them stale. This
    # document keeps its own entry: its cache key embeds its contents, so a
    # meaningful edit misses on its own.
    invalidate_completion_caches(except: file_uri)
    # Diagnostics are produced from a saved document version. Clear them as
    # soon as the buffer changes so stale errors are not shown against new text.
    Diagnostics.new.init_value(file_uri).publish(server, versions: document_versions)
  end

  def close_document(server : LSP::Server, params : LSP::DidCloseTextDocumentParams)
    file_uri = params.text_document.uri
    document = @documents_lock.synchronize { @opened_documents.delete(file_uri) }
    @result_cache.invalidate(file_uri)
    # Nothing will ever hit this document's completion entry again, and a cached
    # result holds a whole typed program. The remaining entries were compiled
    # against the buffer that just went away, so drop those too.
    invalidate_completion_caches
    Diagnostics.new.init_value(file_uri).publish(server) unless document.try(&.project?)
  end

  def save_document(server : LSP::Server, params : LSP::DidSaveTextDocumentParams)
    file_uri = params.text_document.uri
    @result_cache.invalidate(file_uri)
  end

  # Whether a memoized completion result is currently kept for *uri*. A cached
  # result is only valid while every document it was compiled from is unchanged,
  # so this is worth asserting on.
  def completion_result_cached?(uri : String) : Bool
    @completion_cache_lock.synchronize { @completion_cache.has_key?(uri) }
  end

  # Whether analyzed items are being kept for the receiver *expression* as it
  # would be resolved from *file_uri*.
  def receiver_items_cached?(file_uri : URI, expression : String) : Bool
    key = receiver_items_cache_key(file_uri, expression)
    @completion_cache_lock.synchronize { @receiver_items_cache.has_key?(key) }
  end

  # Drop memoized completion results, optionally keeping the entry for a single
  # document uri.
  private def invalidate_completion_caches(*, except : String? = nil)
    @completion_cache_lock.synchronize do
      if except
        @completion_cache.select! { |uri, _| uri == except }
        @completion_items_cache.select! { |uri, _| uri == except }
      else
        @completion_cache.clear
        @completion_items_cache.clear
      end
    end
  end

  def format_document(params : LSP::DocumentFormattingParams) : {String, TextDocument}?
    document_at(params.text_document.uri).try { |document|
      {Crystal.format(document.contents), document}
    }
  rescue e
    # swallow exceptions silently
  end

  def format_document(params : LSP::DocumentRangeFormattingParams) : {String, TextDocument}?
    document_at(params.text_document.uri).try { |document|
      range = params.range
      contents_lines = document.contents.lines(chomp: false)[range.start.line..range.end.line]
      contents_lines[-1] = contents_lines.last[...range.end.character] if range.end.character > 0
      contents_lines[0] = contents_lines.first[range.start.character...]
      {Crystal.format(contents_lines.join), document}
    }
  rescue e
    # swallow exceptions silently
  end

  # Macros resolve relative paths against the process working directory - `ECR`
  # embedding, `read_file`, `run`, and everything built on them such as Kemal's
  # `render "src/views/index.ecr"`. The editor decides where the server process
  # is started from, so compile from the project root the way a `crystal build`
  # in a terminal would, otherwise those macros raise and semantic analysis of
  # the whole project is lost.
  private def in_project_directory(project : Project?, &)
    root = project.try(&.root_uri.decoded_path)
    return yield unless root && Dir.exists?(root)
    # Safe despite being process-wide state: every compilation holds
    # `@@compilation_lock`, and everything else here works on absolute paths.
    Dir.cd(root) { yield }
  end

  # How long to wait before recomputing the dependencies of a project whose last
  # attempt left it with nothing.
  DEPENDENCY_RETRY_INTERVAL = 10.seconds

  # Recompute the dependencies of *project* if they look incomplete, at most
  # once per `DEPENDENCY_RETRY_INTERVAL`.
  #
  # A failed calculation leaves the project with no dependencies, which is the
  # very condition that asks for another attempt - so an entry point that does
  # not compile makes every request pay for two compilations instead of one, for
  # as long as it stays broken. Waiting between attempts bounds that to one
  # wasted compilation per interval while still recovering on its own once the
  # entry point is fixed.
  private def recalculate_stale_dependencies(server, project)
    return unless project.dependencies.size < 2

    now = @result_cache.monotonic_now
    key = project.root_uri.to_s
    due = @dependency_attempts_lock.synchronize do
      last_attempt = @dependency_attempts[key]?
      if last_attempt.nil? || now - last_attempt >= DEPENDENCY_RETRY_INTERVAL
        @dependency_attempts[key] = now
        true
      else
        false
      end
    end

    recalculate_dependencies(server, project) if due
  end

  # Run a top level semantic analysis to compute dependencies.
  def recalculate_dependencies(server, project)
    return unless (target = project.entry_point?)

    lib_path = project.default_lib_path
    # Runs the compiler, so it takes the same lock as a regular compilation.
    result = @@compilation_lock.synchronize do
      in_project_directory(project) do
        Analysis.compile(server, target, lib_path: lib_path, ignore_diagnostics: true, wants_doc: false, top_level: true, compiler_flags: project.flags)
      end
    end
    result.try { |r|
      project.dependencies = r.program.requires
    }
  rescue
    nil
  end

  # Allow one compilation at a time.
  class_getter compilation_lock = CompilationLock.new

  # How long a completion will wait for the compiler to become free before
  # answering without it. This is a budget for what a person will sit through
  # watching for a popup, so it does not scale with the size of the project -
  # the whole point is that a big project cannot spend the seconds it needs.
  COMPLETION_COMPILE_BUDGET = 1.second

  # Use the crystal compiler to typecheck the program.
  def compile(
    server : LSP::Server,
    file_uri : URI,
    *,
    in_memory = false,
    ignore_diagnostics = server.client_capabilities.ignore_diagnostics?,
    ignore_cached_result = false,
    do_not_cache_result = false,
    wants_doc = false,
    text_overrides = nil,
    fail_fast = false,
    top_level = false,
    discard_nil_cached_result = false,
    cancelled : Proc(Bool)? = nil,
  )
    # If a project has less than 1 dependency, it could mean that the last
    # dependency calculation failed (likely because of a syntax error). So we
    # try again, but not on every single request.
    @projects.each do |project|
      recalculate_stale_dependencies(server, project)
    end

    project = Project.best_fit_for_file(@projects, file_uri)

    # LSP::Log.info { "Compiling #{file_uri}, project: #{project.try(&.root_uri.decoded_path)}" }

    if project && (entry_point = project.entry_point?)
      target = entry_point
      progress = Progress.new(
        token: "workspace/compile",
        title: "Building project",
        message: target.decoded_path
      )
    else
      # The file is not a project dependency.
      target = file_uri.not_nil!
      progress = Progress.new(
        token: "workspace/compile",
        title: "Building",
        message: target.decoded_path
      )
    end

    target_string = target.to_s
    # Check if we can serve the result from the cache.
    if !ignore_cached_result && @result_cache.exists?(target_string) && !@result_cache.invalidated?(target_string)
      cached_result = @result_cache.get(target_string)
      return cached_result unless cached_result.nil? && discard_nil_cached_result
    end

    # Wait for pending compilations to finish…
    @@compilation_lock.synchronize do
      return if cancelled.try(&.call)

      # Check again the cache in case some previous compilation that ran while waiting for the mutex to unlock is still valid.
      if !ignore_cached_result && @result_cache.exists?(target_string) && !@result_cache.invalidated?(target_string)
        cached_result = @result_cache.get(target_string)
        return cached_result unless cached_result.nil? && discard_nil_cached_result
      end

      sync_channel = Channel(Crystal::Compiler::Result?).new

      progress.report(server) do
        file_overrides = nil
        sources = nil
        # Store the start of the compilation.
        compilation_start = @result_cache.monotonic_now
        if in_memory
          # Tell the compiler to load the opened files from memory, not from the filesystem.
          file_overrides = Hash(String, String).new
          documents_snapshot.each { |uri_str, text_document|
            contents = text_overrides.try(&.[uri_str]?) || text_document.contents
            contents = fix_source(contents)

            if target_string == uri_str
              # If the entry point itself needs to be loaded from memory.
              sources = [
                Crystal::Compiler::Source.new(target.decoded_path, contents),
              ]
            end
            file_path = URI.parse(uri_str).decoded_path
            file_overrides[file_path] = contents
          }
        end

        lib_path = project.try(&.default_lib_path)
        versions_at_start = document_versions
        diagnostics_current = -> { document_versions == versions_at_start }
        result = in_project_directory(project) do
          Analysis.compile(
            server,
            sources || target,
            lib_path: lib_path,
            file_overrides: file_overrides,
            ignore_diagnostics: ignore_diagnostics,
            wants_doc: wants_doc,
            fail_fast: fail_fast,
            top_level: top_level,
            compiler_flags: project.try(&.flags) || [] of String,
            diagnostic_versions: versions_at_start,
            diagnostics_current: diagnostics_current,
          )
        end
        invalidated_during_compilation = @result_cache.invalidated?(target_string, since: compilation_start)
        # Store the result in the cache, unless a client event invalided the previous cache.
        # For instance if a compilation is running, but the user saved the document in the meantime (before completion)
        # then we discard the result because it is already outdated.
        unless do_not_cache_result
          @result_cache.set(target_string, result, unless_invalidated_since: compilation_start)
        end

        if invalidated_during_compilation && !ignore_diagnostics
          diagnostics = Diagnostics.new
          documents_snapshot.each_key { |uri| diagnostics.init_value(uri) }
          diagnostics.publish(server, versions: document_versions)
        end

        if result
          store_analysis(project, target_string, result)
          if project.try(&.entry_point?)
            # Store the project dependencies.
            project.not_nil!.dependencies = result.program.requires
          end
          "Completed successfully."
        else
          "Completed with errors."
        end
      ensure
        sync_channel.send(result)
      end

      select
      when result = sync_channel.receive
        result
        # Just in case…
      when timeout 120.seconds
        progress.send_progress_end(server)
        nil
      end
    end
  end

  private def document_versions : Hash(String, Int32)
    documents_snapshot.compact_map do |uri, document|
      document.version.try { |version| {uri, version} }
    end.to_h
  end

  private def append_markdown_doc(contents : Array(String), doc : String?)
    if doc
      contents << "----------"
      contents << <<-MARKDOWN
      #{doc}
      MARKDOWN
    end
  end

  private def code_markdown(str : String?, *, language = "") : String
    if str
      <<-MARKDOWN
      ```#{language}
      #{str}
      ```
      MARKDOWN
    else
      ""
    end
  end

  def hover(server : LSP::Server, file_uri : URI, position : LSP::Position)
    result = self.compile(server, file_uri, in_memory: true, wants_doc: true)
    location = Crystal::Location.new(
      file_uri.decoded_path,
      line_number: position.line + 1,
      column_number: position.character + 1
    )
    result.try { |r|
      Analysis.nodes_at_cursor(r, location)
    }.try do |nodes, _context|
      n = nodes.last?
      contents = [] of String

      # LSP::Log.info { "Node at cursor: #{n}" }
      # LSP::Log.info { "Node class: #{n.class}" }
      # LSP::Log.info { "Node expansion: #{n.expanded if n.responds_to? :expanded}" }
      # LSP::Log.info { "Node type: #{n.try &.type?}" }
      # LSP::Log.info { "Node type class: #{n.try &.type?.try &.class}" }
      # LSP::Log.info { "Nodes classes: #{nodes.map &.class}" }
      # LSP::Log.info { "Context: #{_context}" }

      if n.is_a? Crystal::Def || n.is_a? Crystal::Macro
        contents << code_markdown(Utils.format_def(n), language: "crystal")
        append_markdown_doc contents, n.doc
      elsif (n.is_a? Crystal::MacroExpression || n.is_a? Crystal::MacroIf) && n.expanded
        contents << code_markdown(n.expanded.to_s, language: "crystal")
      elsif n.responds_to? :resolved_type
        str = ""
        if n.responds_to? :name
          str += "#{n.name}: #{n.resolved_type}"
        else
          str += n.resolved_type.to_s
          str = n.to_s if str.empty?
        end
        contents << code_markdown(str, language: "crystal")
        append_markdown_doc contents, n.resolved_type.doc
      elsif n.is_a? Crystal::Call
        if (definition = n.target_defs.try &.first?)
          contents << code_markdown(Utils.format_def(definition), language: "crystal")
        elsif n.expanded && n.expanded_macro
          contents << code_markdown(n.expanded.to_s, language: "crystal")
        end
        append_markdown_doc contents, (definition || n.expanded_macro).try &.doc
      elsif n.is_a? Crystal::Path
        node_type = n.type? || Utils.resolve_path(n, nodes)
        if node_type
          contents << code_markdown(node_type.to_s, language: "crystal")
          append_markdown_doc contents, node_type.doc
        end
      elsif n
        str = ""
        if n.responds_to? :name
          str += "#{n.name}: #{n.type? || "?"}"
        else
          str += n.type?.to_s
          str = n.to_s if str.empty?
        end
        contents << code_markdown(str, language: "crystal")
        append_markdown_doc contents, n.doc
      end

      LSP::Hover.new(
        contents: LSP::MarkupContent.new(
          kind: LSP::MarkupKind::MarkDown,
          value: contents.join "\n",
        ),
      )
    end
  rescue
    nil
  end

  def definitions(server : LSP::Server, file_uri : URI, position : LSP::Position)
    result = self.compile(server, file_uri, in_memory: true, wants_doc: true)
    location = Crystal::Location.new(
      file_uri.decoded_path,
      line_number: position.line + 1,
      column_number: position.character + 1
    )
    result.try { |r|
      Analysis.definitions_at_cursor(r, location)
    }.try do |definitions|
      node = definitions.node
      definitions.locations.try &.map { |start_loc, end_loc|
        if node.is_a? Crystal::Path || node.is_a? Crystal::Require
          target_uri = Utils.file_uri(start_loc.original_filename || "")
          origin_location = node.location.not_nil!
          origin_end_location = definitions.node.end_location || Crystal::Location.new(
            file_uri.decoded_path,
            line_number: origin_location.line_number + 1,
            column_number: 0
          )

          origin_selection_range = LSP::Range.new(
            start: LSP::Position.new(line: origin_location.line_number - 1, character: origin_location.column_number - 1),
            end: LSP::Position.new(line: origin_end_location.line_number - 1, character: origin_end_location.column_number),
          )
          target_range = LSP::Range.new(
            start: LSP::Position.new(line: start_loc.line_number - 1, character: start_loc.column_number - 1),
            end: LSP::Position.new(line: end_loc.line_number - 1, character: end_loc.column_number),
          )

          LSP::LocationLink.new(
            target_uri: target_uri,
            origin_selection_range: origin_selection_range,
            target_range: target_range,
            target_selection_range: target_range,
          )
        else
          LSP::Location.new(
            uri: Utils.file_uri(start_loc.original_filename || ""),
            range: LSP::Range.new(
              start: LSP::Position.new(line: start_loc.line_number - 1, character: start_loc.column_number - 1),
              end: LSP::Position.new(line: end_loc.line_number - 1, character: end_loc.column_number),
            ),
          )
        end
      }
    end
  rescue
    nil
  end

  def references(server : LSP::Server, params : LSP::ReferenceParams)
    file_uri = URI.parse(params.text_document.uri)
    result = self.compile(server, file_uri, in_memory: true, wants_doc: true)
    location = Crystal::Location.new(
      file_uri.decoded_path,
      line_number: params.position.line + 1,
      column_number: params.position.character + 1
    )
    result.try do |compiled|
      Analysis.references_at_cursor(
        compiled,
        location,
        include_declaration: params.context.include_declaration,
      )
    end
  rescue e
    LSP::Log.debug(exception: e) { "Unable to find references: #{e.message}" }
    nil
  end

  def document_highlights(server : LSP::Server, params : LSP::DocumentHighlightParams)
    reference_params = LSP::ReferenceParams.new(
      text_document: params.text_document,
      position: params.position,
      context: LSP::ReferenceContext.new(include_declaration: true),
    )

    references(server, reference_params).try do |locations|
      locations.compact_map do |location|
        next unless location.uri == params.text_document.uri
        LSP::DocumentHighlight.new(
          range: location.range,
          kind: LSP::DocumentHighlightKind::Text,
        )
      end
    end
  end

  # What a rename may produce: a local or method name with an optional sigil or
  # suffix, or a constant. Anything else - spaces, operators, a dotted path -
  # would be written verbatim into every reference site.
  RENAME_NEW_NAME_PATTERN = /\A@{0,2}[A-Za-z_]\w*[?!=]?\z/

  # Words the lexer will never read as an identifier, so a rename to or from
  # one can only produce code that does not parse.
  CRYSTAL_KEYWORDS = Set{
    "abstract", "alias", "annotation", "as", "asm", "begin", "break", "case",
    "class", "def", "do", "else", "elsif", "end", "ensure", "enum", "extend",
    "false", "for", "fun", "if", "in", "include", "instance_sizeof", "is_a?",
    "lib", "macro", "module", "next", "nil", "of", "offsetof", "out",
    "pointerof", "private", "protected", "require", "rescue", "responds_to?",
    "return", "select", "self", "sizeof", "struct", "super", "then", "true",
    "type", "typeof", "uninitialized", "union", "unless", "until", "when",
    "while", "with", "yield",
  }

  # The range a rename at *position* would replace, or nothing when the cursor
  # is not on something renameable. Answered from the buffer alone so the
  # rename UI opens instantly: the reference search that a rename actually
  # needs runs when the new name is submitted.
  def prepare_rename(params : LSP::PrepareRenameParams) : LSP::Range?
    document = document_at(params.text_document.uri)
    return unless document

    line = document.contents.lines(chomp: false)[params.position.line]?
    return unless line

    bounds = rename_symbol_bounds(line, params.position.character)
    return unless bounds

    start_char, end_char = bounds
    symbol = line[start_char...end_char]
    return unless symbol.matches?(RENAME_NEW_NAME_PATTERN)
    return if CRYSTAL_KEYWORDS.includes?(symbol)

    LSP::Range.new(
      start: LSP::Position.new(line: params.position.line, character: start_char),
      end: LSP::Position.new(line: params.position.line, character: end_char),
    )
  end

  # The bounds of the identifier under *cursor*, sigils included.
  private def rename_symbol_bounds(line : String, cursor : Int32) : {Int32, Int32}?
    ident = ->(char : Char) { char.ascii_alphanumeric? || char == '_' }

    # A cursor on the sigil of `@name` is on the symbol too.
    while line[cursor]? == '@'
      cursor += 1
    end

    start_char = cursor
    while start_char > 0 && ident.call(line[start_char - 1])
      start_char -= 1
    end
    while start_char > 0 && line[start_char - 1] == '@'
      start_char -= 1
    end

    end_char = cursor
    while (char = line[end_char]?) && ident.call(char)
      end_char += 1
    end
    # `?` and `!` end a method name - unless an `=` follows, where they were
    # an operator (`x != 2`) rather than part of the name.
    end_char += 1 if line[end_char]?.in?('?', '!') && line[end_char + 1]? != '='

    {start_char, end_char} unless start_char == end_char
  end

  def rename(server : LSP::Server, params : LSP::RenameParams)
    return nil unless params.new_name.matches?(RENAME_NEW_NAME_PATTERN)
    return nil if CRYSTAL_KEYWORDS.includes?(params.new_name)

    reference_params = LSP::ReferenceParams.new(
      text_document: params.text_document,
      position: params.position,
      context: LSP::ReferenceContext.new(include_declaration: true),
    )

    references(server, reference_params).try do |locations|
      next nil if locations.empty?

      edits_by_uri = locations.group_by(&.uri).transform_values do |document_locations|
        document_locations.map do |location|
          LSP::TextEdit.new(range: location.range, new_text: params.new_name)
        end
      end

      supports_document_changes = server.client_capabilities.workspace.try(&.workspace_edit).try(&.document_changes)
      unless supports_document_changes
        next LSP::WorkspaceEdit.new(changes: edits_by_uri, document_changes: nil)
      end

      document_changes = edits_by_uri.map do |uri, edits|
        LSP::TextDocumentEdit.new(
          text_document: LSP::VersionedTextDocumentIdentifier.new(uri: uri, version: nil),
          edits: edits,
        )
      end

      LSP::WorkspaceEdit.new(
        changes: {} of String => Array(LSP::TextEdit),
        document_changes: document_changes,
      )
    end
  end

  def signature_help(server : LSP::Server, file_uri : URI, position : LSP::Position)
    result = self.compile(server, file_uri, in_memory: true, wants_doc: true)
    location = Crystal::Location.new(
      file_uri.decoded_path,
      line_number: position.line + 1,
      column_number: position.character + 1
    )
    result.try { |r|
      Analysis.nodes_at_cursor(r, location)
    }.try do |nodes, _context|
      call = nodes.reverse_each.find(&.is_a?(Crystal::Call)).as?(Crystal::Call)
      call.try do |c|
        target_defs = c.target_defs
        next nil unless target_defs && target_defs.size > 0

        # `target_defs` only holds the overload(s) actually matched by the call as
        # currently typed. Look up every def sharing the same name on the resolved
        # owner too, so signature help can list sibling overloads (e.g. while the
        # user is still choosing which one to use), not just the matched one.
        owner = target_defs.first.owner
        defs = owner.defs.try(&.[c.name]?).try(&.map(&.def)) || target_defs

        # The index of the argument the cursor is currently in, based on how many
        # of the call's already-parsed arguments start before the cursor location.
        active_parameter = c.args.index { |arg|
          arg_location = arg.location
          arg_location.nil? || location < arg_location
        } || c.args.size

        signatures = defs.map { |d|
          LSP::SignatureInformation.new(
            label: Utils.format_def(d, short: true),
            documentation: d.doc.try { |doc|
              LSP::MarkupContent.new(kind: LSP::MarkupKind::MarkDown, value: doc)
            },
            parameters: d.args.map { |arg| LSP::ParameterInformation.new(label: arg.to_s) },
          )
        }

        # Prefer whichever overload the compiler actually matched for this call;
        # fall back to the first overload whose arity can fit the active parameter.
        active_signature = defs.index { |d| target_defs.includes?(d) } ||
                           defs.index { |d| d.args.size > active_parameter || d.splat_index || d.double_splat } ||
                           0

        LSP::SignatureHelp.new(
          signatures: signatures,
          active_signature: active_signature,
          active_parameter: active_parameter,
        )
      end
    end
  rescue
    nil
  end

  def completion(server : LSP::Server, file_uri : URI, position : LSP::Position, trigger_character : String?, *, cancelled : Proc(Bool)? = nil)
    text_document = document_at(file_uri.to_s)
    return unless text_document

    contents = text_document.contents
    raw_lines = contents.lines(chomp: false)
    document_lines = fix_source(contents).lines(chomp: false)
    # The fixer only ever appends to existing lines, but a source it cannot
    # repair may still come back short. Falling back to the untouched lines
    # keeps a cursor on the last line from raising out of the request.
    document_lines.concat(raw_lines[document_lines.size..]) if document_lines.size < raw_lines.size
    current_line = document_lines[position.line]?
    return unless current_line

    completion_context = CompletionContext.detect(current_line, position.character, trigger_character)
    return unless completion_context

    trigger_character = completion_context.trigger_character

    # Project-local type paths are available from syntax alone. This is both
    # faster and more resilient than compiling an entire application merely to
    # answer `Namespace::`.
    if trigger_character == ":"
      if syntax_result = syntax_type_completion(file_uri, completion_context, position.line)
        return syntax_result unless syntax_result.items.empty?
      end
    end

    if trigger_character == "."
      # What the syntax index can see is what the buffer says right now, which is
      # not much: only the methods spelled out in project source. It is merged
      # into the analysis rather than answered from on its own, because returning
      # it alone hides everything a type inherits or generates - `Type.` used to
      # come back with the one or two methods written next to it.
      syntax_items = syntax_method_items(file_uri, contents, position, completion_context)
      if analysis_result = analysis_method_completion(file_uri, contents, position, completion_context, syntax_items)
        return analysis_result unless analysis_result.items.empty?
      end
      if syntax_items && !syntax_items.empty?
        # Only what the buffer spells out, with nothing a type inherits or
        # generates, because no analysis was there to be asked. Incomplete, so
        # the client keeps asking as typing continues and takes the full answer
        # as soon as one exists.
        return finalize_completion(syntax_items, completion_context, position.line, incomplete: true)
      end
    end

    # Completion clients invoke this request for every partial identifier.
    # Keep that high-frequency path syntax-only; compiling the application for
    # `n`, `na`, and `nam` makes ordinary typing queue seconds of stale work.
    if trigger_character.nil?
      return syntax_context_completion(file_uri, contents, position, completion_context)
    end

    document_lines[position.line] = completion_context.rewritten_line
    # Force the compiler load the file from this Hash.
    text_overrides = {
      file_uri.to_s => document_lines.join,
    }

    location = Crystal::Location.new(
      file_uri.decoded_path,
      line_number: position.line + 1,
      column_number: completion_context.analysis_column,
    )

    completion_cache_key = completion_source_key(contents, position, completion_context)

    cached_items = @completion_cache_lock.synchronize { @completion_items_cache[file_uri.to_s]? }
    if cached_items && cached_items[0] == completion_cache_key
      return finalize_completion(cached_items[1], completion_context, position.line)
    end

    # Literal and explicitly typed local receivers can be analyzed in a tiny
    # standalone source. This avoids a whole-project build for the most common
    # completion while editing, and continues to work when unrelated project
    # code is temporarily invalid.
    receiver_expression = standalone_receiver_expression(contents, position, completion_context)
    receiver_items_key = receiver_expression.try { |expression| receiver_items_cache_key(file_uri, expression) }
    # Editing invalidates the caches keyed by document contents on every
    # keystroke, but the answer for `uninitialized String` is the same one it was
    # the last time any document asked - and recomputing it means analyzing the
    # prelude again, which is the bulk of what a `.` completion costs.
    if receiver_items_key && (items = cached_receiver_items(receiver_items_key))
      return finalize_completion(items, completion_context, position.line)
    end

    cached = @completion_cache_lock.synchronize { @completion_cache[file_uri.to_s]? }.try do |cached_source, cached_result, cached_location|
      {cached_result, cached_location} if cached_source == completion_cache_key
    end
    result = cached.try(&.[0])
    location = cached.try(&.[1]) || location
    analyzed_receiver_expression = false

    # Everything past this point runs the compiler, and only one analysis runs
    # at a time. A compilation that is nearly over is worth waiting out, but the
    # project-wide analysis at startup is not: answering once it finishes means
    # answering a keystroke that stopped being interesting many keystrokes ago.
    # Give up instead, and say the answer is incomplete so the client asks again
    # as typing continues - by which time there is an analysis to answer from.
    if !result && !@@compilation_lock.wait_until_available(COMPLETION_COMPILE_BUDGET)
      LSP::Log.debug { "Gave up waiting to compile a completion of #{file_uri}" }
      return LSP::CompletionList.new(is_incomplete: true, items: [] of LSP::CompletionItem)
    end

    if !result && receiver_expression
      fast_result = fast_receiver_compile(server, file_uri, receiver_expression)
      if fast_result
        result, location = fast_result
        analyzed_receiver_expression = true
        store_completion_result(file_uri, completion_cache_key, result, location)
      end
    end

    # Trigger a compilation that will not fail fast only when the semantic
    # input differs from the last completion for this document.
    result ||= self.compile(
      server,
      file_uri,
      in_memory: true,
      ignore_cached_result: true,
      discard_nil_cached_result: true,
      wants_doc: true,
      text_overrides: text_overrides,
      # Prevent showing diagnostics and caching results since the diagnostics can be inaccurate
      ignore_diagnostics: true,
      do_not_cache_result: true,
      cancelled: cancelled,
    ).tap do |compiled_result|
      store_completion_result(file_uri, completion_cache_key, compiled_result, location) if compiled_result
    end
    unless result
      LSP::Log.debug { "Completion compilation returned no result for #{file_uri}" }
      return
    end

    nodes, cursor_context = Analysis.nodes_at_cursor(result, location)
    nodes.last?.try do |n|
      completion_items = [] of LSP::CompletionItem

      # LSP::Log.info { "Node at cursor: #{n}" }
      # LSP::Log.info { "Node class: #{n.class}" }
      # LSP::Log.info { "Node type: #{n.type?}" }
      # LSP::Log.info { "Node type class: #{n.type?.try &.class}" }
      # LSP::Log.info { "Node type defs: #{n.type?.try &.defs}" }

      range = completion_context.completion_range(position.line)

      case trigger_character
      when "."
        node_type = n.type?
        node_type = node_type.base_type if node_type.responds_to? :base_type

        # We are looking for methods…
        if node_type.responds_to? :defs
          completion_items.concat(member_completion_items(node_type.not_nil!, n.type?, range))
        end
      when ":"
        # We are looking for module types…
        node_type = n.type?

        if n.is_a? Crystal::Path
          node_type ||= Utils.resolve_path(n, nodes)
        end

        node_type = node_type.instance_type if node_type.is_a? Crystal::MetaclassType

        if node_type.is_a? Crystal::ModuleType
          Analysis.all_submodules(result, node_type).uniq(&.to_s).each { |type|
            type_string = type.to_s
            insertion = type_string.lchop("#{node_type}::")

            text_edit = LSP::TextEdit.new(
              range: range,
              new_text: insertion,
            )

            completion_items << LSP::CompletionItem.new(
              label: type_string,
              text_edit: text_edit,
              kind: Crystalline::Utils.map_completion_kind(type, default: LSP::CompletionItemKind::Module),
              documentation: type.doc.try { |doc|
                LSP::MarkupContent.new(
                  kind: LSP::MarkupKind::MarkDown,
                  value: doc,
                )
              },
            )
          }
        end
      else
        # Context autocompletion. Note that an absent trigger character is
        # answered by `syntax_context_completion` above, so this is reached for
        # `@` and for any other character a client may decide to trigger on.
        context = Analysis.context_at(result, location) || Hash(String, Crystal::Type).new
        if trigger_character == "@"
          if self_type = cursor_context["self"]?.try(&.[0])
            variables = if completion_context.replace_start - completion_context.analysis_column == 2
                          owner_type = self_type.is_a?(Crystal::MetaclassType) ? self_type.instance_type : self_type
                          owner_type.all_class_vars
                        else
                          self_type.all_instance_vars
                        end
            variables.each do |name, variable|
              if variable_type = variable.type?
                context[name] = variable_type
              end
            end
          end
          context.select!(&.starts_with?("@"))
        end
        context.each { |name, type|
          label = "#{name} : #{type}"
          insertion = if trigger_character == "@"
                        name.lchop(name.starts_with?("@@") ? "@@" : "@")
                      else
                        name
                      end
          text_edit = LSP::TextEdit.new(
            range: range,
            new_text: insertion,
          )
          completion_items << LSP::CompletionItem.new(
            label: label,
            text_edit: text_edit,
            kind: LSP::CompletionItemKind::Variable,
            documentation: type.doc.try { |doc|
              LSP::MarkupContent.new(
                kind: LSP::MarkupKind::MarkDown,
                value: doc,
              )
            },
          )
        }
      end

      @completion_cache_lock.synchronize do
        @completion_items_cache[file_uri.to_s] = {completion_cache_key, completion_items}
      end
      # Only what the standalone analysis produced is reusable across documents:
      # items from a whole-project build describe this project's code, which the
      # next keystroke can change.
      if receiver_items_key && analyzed_receiver_expression
        store_receiver_items(receiver_items_key, completion_items)
      end
      finalize_completion(completion_items, completion_context, position.line)
    end
  rescue e
    LSP::Log.debug(exception: e) { "Unable to complete at #{file_uri}:#{position.line + 1}:#{position.character + 1}" }
    nil
  end

  # Everything *type* responds to, as completion items. *receiver_type* is what
  # the receiver itself resolved to, and only tells inherited members apart from
  # the type's own.
  private def member_completion_items(type : Crystal::Type, receiver_type : Crystal::Type?, range : LSP::Range) : Array(LSP::CompletionItem)
    items = [] of LSP::CompletionItem

    Analysis.all_defs(type).each do |def_name, definition, owner_type, nesting|
      next if definition.visibility.private?
      next if definition.doc.try(&.includes?(":nodoc:"))

      items << member_completion_item(
        def_name, definition, owner_type, receiver_type, nesting, range,
        LSP::CompletionItemKind::Function,
      )
    end

    Analysis.all_macros(type).each do |macro_name, macro_def, owner_type, nesting|
      next if macro_def.visibility.private?
      next if macro_def.doc.try(&.includes?(":nodoc:"))

      items << member_completion_item(
        macro_name, macro_def, owner_type, receiver_type, nesting, range,
        LSP::CompletionItemKind::Method,
      )
    end

    items
  end

  private def member_completion_item(
    name : String,
    definition : Crystal::Def | Crystal::Macro,
    owner_type : Crystal::Type,
    receiver_type : Crystal::Type?,
    nesting : Int32,
    range : LSP::Range,
    kind : LSP::CompletionItemKind,
  ) : LSP::CompletionItem
    owner_prefix = "*Inherited from: #{owner_type.name}*\n\n" if owner_type.responds_to?(:name) && owner_type != receiver_type
    documentation = (owner_prefix || "") + (definition.doc || "")

    LSP::CompletionItem.new(
      label: Utils.format_def(definition, short: true),
      insert_text: name,
      kind: kind,
      filter_text: name,
      detail: Utils.format_def(definition),
      text_edit: LSP::TextEdit.new(range: range, new_text: name),
      sort_text: (nesting + 1).chr.to_s + name,
      documentation: LSP::MarkupContent.new(
        kind: LSP::MarkupKind::MarkDown,
        value: documentation,
      ),
    )
  end

  private def store_completion_result(file_uri : URI, key : String, result : Crystal::Compiler::Result, location : Crystal::Location)
    @completion_cache_lock.synchronize do
      @completion_cache[file_uri.to_s] = {key, result, location}
    end
  end

  private def completion_source_key(contents : String, position : LSP::Position, context : CompletionContext) : String
    lines = contents.lines(chomp: false)
    line = lines[position.line]? || ""
    before = line[0...context.replace_start]? || line
    after = line[context.replace_end..]? || ""
    lines[position.line] = before + after if position.line < lines.size
    "#{context.trigger_character}\0#{lines.join}"
  end

  private def finalize_completion(source_items : Array(LSP::CompletionItem), context : CompletionContext, line : Int32, *, incomplete = false) : LSP::CompletionList
    range = context.completion_range(line)
    completion_items = source_items.map do |source_item|
      item = source_item
      item.preselect = false
      if edit = item.text_edit
        item.text_edit = LSP::TextEdit.new(range: range, new_text: edit.new_text)
      end
      item
    end

    fragment = context.filter_fragment
    unless fragment.empty?
      completion_items.select! do |item|
        candidate = item.text_edit.try(&.new_text) || item.filter_text || item.insert_text || item.label
        candidate.starts_with?(fragment)
      end
    end

    completion_items.uniq! do |item|
      {item.label, item.detail, item.kind, item.text_edit.try(&.new_text)}
    end

    if selected_element_index = completion_items.each_index.min_by? do |index|
         item = completion_items[index]
         item.sort_text || item.label
       end
      selected_element = completion_items[selected_element_index]
      selected_element.preselect = true
      completion_items[selected_element_index] = selected_element
    end

    LSP::CompletionList.new(is_incomplete: incomplete, items: completion_items)
  end

  # The standalone expression that stands in for the receiver at *position*,
  # when it is one that can be analyzed without the rest of the project.
  private def standalone_receiver_expression(contents : String, position : LSP::Position, context : CompletionContext) : String?
    return unless context.trigger_character == "."

    receiver = context.analysis_prefix.strip
    if literal_completion_expression?(receiver)
      normalized_receiver_expression(receiver)
    elsif receiver.matches?(/\A[a-z_]\w*[!?]?\z/)
      local_receiver_expression(receiver, contents, position)
    end
  end

  # Every string literal is the same receiver as far as completion is concerned,
  # so analyzing one is worth reusing for the next. Only literals whose type is
  # unambiguous from their first character are folded: a numeric literal carries
  # its own width in a suffix, and a collection literal carries the types of its
  # elements, so both are analyzed as written.
  private def normalized_receiver_expression(value : String) : String
    type = case value
           when /\A"/                   then "String"
           when /\A'/                   then "Char"
           when /\A(?:true|false)\s*\z/ then "Bool"
           end

    type ? "uninitialized #{type}" : value
  end

  # How many receiver expressions to remember the items of.
  RECEIVER_ITEMS_CACHE_LIMIT = 64

  # Items analyzed from a receiver expression depend on the prelude and on the
  # shards reachable from *file_uri*, and on nothing else - so the lib path is
  # all that has to be part of the key alongside the expression itself.
  private def receiver_items_cache_key(file_uri : URI, expression : String) : String
    "#{Project.best_fit_for_file(@projects, file_uri).try(&.default_lib_path)}\0#{expression}"
  end

  private def cached_receiver_items(key : String) : Array(LSP::CompletionItem)?
    @completion_cache_lock.synchronize { @receiver_items_cache[key]? }
  end

  private def store_receiver_items(key : String, items : Array(LSP::CompletionItem))
    return if items.empty?

    @completion_cache_lock.synchronize do
      # Bounded, so a long session cannot accumulate the methods of every type it
      # ever completed on. Entries are equally valuable, so evict the oldest.
      @receiver_items_cache.shift? if @receiver_items_cache.size >= RECEIVER_ITEMS_CACHE_LIMIT
      @receiver_items_cache[key] = items
    end
  end

  private def fast_receiver_compile(server : LSP::Server, file_uri : URI, expression : String) : {Crystal::Compiler::Result, Crystal::Location}?
    synthetic_name = "__crystalline_receiver"
    source = Crystal::Compiler::Source.new(
      "__crystalline_completion__.cr",
      "#{synthetic_name} = #{expression}\n#{synthetic_name}\n",
    )
    project = Project.best_fit_for_file(@projects, file_uri)
    # Small as it is, this still runs a compiler, so it queues behind any other
    # compilation instead of running alongside one.
    result = @@compilation_lock.synchronize do
      in_project_directory(project) do
        Analysis.compile(
          server,
          [source],
          lib_path: project.try(&.default_lib_path),
          ignore_diagnostics: true,
          wants_doc: true,
        )
      end
    end
    return unless result

    location = Crystal::Location.new(
      source.filename,
      line_number: 2,
      column_number: synthetic_name.size,
    )
    {result, location}
  rescue e
    LSP::Log.debug(exception: e) { "Unable to analyze local receiver quickly" }
    nil
  end

  # A standalone expression that stands in for a local receiver, so its methods
  # can be analyzed without building the whole application.
  private def local_receiver_expression(receiver : String, contents : String, position : LSP::Position) : String?
    # A declared type is the most reliable answer, and the only one available
    # inside a method the program never instantiates - which is most methods,
    # since the compiler only types what the entry point actually reaches.
    if declared = declared_type_for(receiver, contents, position)
      return "uninitialized #{declared}"
    end

    binding = contents.lines[0...position.line].reverse_each.find do |line|
      line.matches?(/^\s*#{Regex.escape(receiver)}\s*(?::\s*[^=]+?)?\s*=\s*.+$/)
    end
    return unless binding

    match = binding.match(/^\s*#{Regex.escape(receiver)}\s*(?::\s*([^=]+?))?\s*=\s*(.+)$/)
    return unless match

    explicit_type = match[1]?.try(&.strip)
    value = match[2].strip
    if explicit_type
      "uninitialized #{explicit_type}"
    elsif literal_completion_expression?(value)
      normalized_receiver_expression(value)
    end
  end

  # The declared type of a local: a type restriction on a parameter of an
  # enclosing def, or a `name : Type` declaration.
  private def declared_type_for(receiver : String, contents : String, position : LSP::Position) : String?
    escaped = Regex.escape(receiver)
    declaration = Regex.new("^\\s*#{escaped}\\s*:\\s*(#{TYPE_NAME_PATTERN})")
    parameter = Regex.new("(?:\\A|[(,]|\\s)#{escaped}\\s*:\\s*(#{TYPE_NAME_PATTERN})")

    lines = contents.lines
    lines[0..position.line]?.try &.reverse_each do |line|
      if match = line.match(declaration)
        return match[1]
      end

      params = line.match(DEF_PARAMETERS_PATTERN).try(&.[1])
      if params && (match = params.match(parameter))
        return match[1]
      end
    end
  end

  private def literal_completion_expression?(value : String) : Bool
    value.starts_with?('"') || value.starts_with?('\'') || value.starts_with?('[') ||
      value.starts_with?('{') || value.starts_with?('/') || value.starts_with?(':') ||
      value.matches?(/\A(?:true|false|nil)\b/) || value.matches?(/\A[+-]?\d/)
  end

  # A type name, as written in a type restriction.
  TYPE_NAME_PATTERN = "[A-Z]\\w*(?:::[A-Z]\\w*)*(?:\\([^)]*\\))?\\??"
  # `name : Type`, where the declaration is the whole statement.
  DECLARATION_PATTERN = Regex.new("^\\s*([a-z_]\\w*)\\s*:\\s*(#{TYPE_NAME_PATTERN})\\s*(?:=|$)")
  # The parameter list of a def signature.
  DEF_PARAMETERS_PATTERN = /^\s*(?:(?:private|protected)\s+)?(?:abstract\s+)?def\s+[^(]*\(([^)]*)\)/
  # A single `name : Type` parameter. Instance and class variable parameters are
  # skipped: they declare a member, not a local.
  PARAMETER_PATTERN = Regex.new("(?:\\A|[(,]|\\s)([a-z_]\\w*)\\s*:\\s*(#{TYPE_NAME_PATTERN})")

  private def type_restriction_item(name : String, type : String, range : LSP::Range) : LSP::CompletionItem
    LSP::CompletionItem.new(
      label: "#{name} : #{type}",
      kind: LSP::CompletionItemKind::Variable,
      text_edit: LSP::TextEdit.new(range: range, new_text: name),
    )
  end

  private def syntax_context_completion(file_uri : URI, contents : String, position : LSP::Position, context : CompletionContext) : LSP::CompletionList
    items = [] of LSP::CompletionItem
    range = context.completion_range(position.line)
    lines_before_cursor = contents.lines[0..position.line]

    lines_before_cursor.each do |line|
      if match = line.match(/^\s*([a-z_]\w*)\s*(?::\s*([^=]+?))?\s*=\s*(.+)$/)
        name = match[1]
        explicit_type = match[2]?.try(&.strip)
        inferred_type = explicit_type || literal_type_name(match[3].strip) || "local"
        items << LSP::CompletionItem.new(
          label: "#{name} : #{inferred_type}",
          kind: LSP::CompletionItemKind::Variable,
          text_edit: LSP::TextEdit.new(range: range, new_text: name),
        )
      end
    end

    # Type restrictions name variables too, but only where they actually declare
    # one: a standalone declaration, or a parameter of a def signature. Scanning
    # for `name : Type` anywhere also matches hash keys and named arguments,
    # which are not variables in scope here.
    lines_before_cursor.each do |line|
      if match = line.match(DECLARATION_PATTERN)
        items << type_restriction_item(match[1], match[2], range)
      end

      next unless params = line.match(DEF_PARAMETERS_PATTERN).try(&.[1])
      params.scan(PARAMETER_PATTERN).each do |match|
        items << type_restriction_item(match[1], match[2], range)
      end
    end

    syntax_type_symbols(file_uri).each do |qualified_name, kind|
      items << LSP::CompletionItem.new(
        label: qualified_name,
        kind: kind,
        text_edit: LSP::TextEdit.new(range: range, new_text: qualified_name),
      )
    end

    finalize_completion(items, context, position.line)
  end

  private def literal_type_name(value : String) : String?
    case value
    when /^"/                then "String"
    when /^'/                then "Char"
    when /^:\w/              then "Symbol"
    when /^(?:true|false)\b/ then "Bool"
    when /^[+-]?\d+\.\d/     then "Float64"
    when /^[+-]?\d/          then "Int32"
    when /^\[/               then "Array"
    when /^\{/               then "Hash"
    when /^\//               then "Regex"
    end
  end

  # A project that has never been analyzed has nothing to answer from, and a
  # shard without an entry point only ever has a partial view - so this is keyed
  # by project and always allowed to come back empty.
  private def store_analysis(project : Project?, target : String, result : Crystal::Compiler::Result)
    @analyses_lock.synchronize do
      @analyses[analysis_key(project)] = StoredAnalysis.new(target, result)
    end
  end

  private def stored_analysis(project : Project?) : StoredAnalysis?
    @analyses_lock.synchronize { @analyses[analysis_key(project)]? }
  end

  # A server started on a single file has no project, and everything it opens
  # shares the one analysis.
  private def analysis_key(project : Project?) : String
    project.try(&.root_uri.to_s) || ""
  end

  # Whether an analysis of the project *file_uri* belongs to is available.
  def analysis_stored?(file_uri : URI) : Bool
    !stored_analysis(Project.best_fit_for_file(@projects, file_uri)).nil?
  end

  # Answer a `.` on a receiver whose type is named in the source - `User.`,
  # `News::Article.`, `User.new.`, or a local with a declared type - from the
  # most recent analysis of the project.
  #
  # What a type responds to is a property of the type, not of the buffer the
  # cursor sits in, so this needs no analysis of the text being typed: looking
  # the name up in an analysis that already exists costs microseconds where
  # building one costs about a second. The cost is that a type whose members are
  # generated by a macro reflects the last build rather than the current buffer;
  # members written by hand are covered by merging in *syntax_items*.
  private def analysis_method_completion(
    file_uri : URI,
    contents : String,
    position : LSP::Position,
    context : CompletionContext,
    syntax_items : Array(LSP::CompletionItem)?,
  ) : LSP::CompletionList?
    receiver = context.analysis_prefix.strip
    path, class_method = receiver_type_path(receiver, contents, position)
    return unless path

    project = Project.best_fit_for_file(@projects, file_uri)
    analysis = stored_analysis(project)
    return unless analysis

    # The buffer is mid-edit and does not parse - the receiver is followed by a
    # period and nothing else - so the namespaces are read from the same repaired
    # source the syntax index is built from.
    repaired = contents.lines(chomp: false)
    repaired[position.line] = context.rewritten_line if position.line < repaired.size
    namespaces = enclosing_namespaces(file_uri, repaired.join, position)

    instance_type = lookup_type_path(analysis.result.program, path, namespaces)
    return unless instance_type
    receiver_type = class_method ? instance_type.metaclass : instance_type

    range = context.completion_range(position.line)
    items = member_completion_items(receiver_type, receiver_type, range)
    return if items.empty?

    # Whatever the analysis already knows about wins: it carries documentation
    # and a full signature. What it does not know about was written since the
    # analysis was made, which is exactly what has to be merged in.
    if syntax_items
      known = items.compact_map(&.insert_text).to_set
      items.concat(syntax_items.reject { |item| known.includes?(item.insert_text) })
    end

    finalize_completion(items, context, position.line)
  rescue e
    LSP::Log.debug(exception: e) { "Unable to complete #{file_uri} from a stored analysis" }
    nil
  end

  # The type path a receiver names, and whether the receiver is that type itself
  # rather than an instance of it.
  private def receiver_type_path(receiver : String, contents : String, position : LSP::Position) : {String?, Bool}
    if receiver.matches?(/\A[A-Z]\w*(?:::[A-Z]\w*)*\z/)
      {receiver, true}
    elsif match = receiver.match(/\A([A-Z]\w*(?:::[A-Z]\w*)*)\.new(?:\(.*\))?\z/)
      {match[1], false}
    elsif receiver.matches?(/\A[a-z_]\w*[!?]?\z/)
      {declared_type_for(receiver, contents, position), false}
    else
      {nil, false}
    end
  end

  # Resolve *path* the way the compiler would at this point in the file: from
  # the innermost enclosing namespace outwards, so `User` inside `module News`
  # finds `News::User` before a top level `User`.
  private def lookup_type_path(program : Crystal::Program, path : String, namespaces : Array(String)) : Crystal::Type?
    names = path.split("::").reject(&.empty?)
    return if names.empty?

    namespaces.size.downto(0) do |depth|
      container = if depth.zero?
                    program
                  else
                    program.lookup_path(Crystal::Path.new(namespaces[0...depth])).as?(Crystal::Type)
                  end
      next unless container

      found = container.lookup_path(Crystal::Path.new(names))
      return found.instance_type if found.is_a?(Crystal::Type)
    end
  rescue e
    LSP::Log.debug(exception: e) { "Unable to resolve #{path}" }
    nil
  end

  # The types enclosing *position*, outermost first.
  private def enclosing_namespaces(file_uri : URI, contents : String, position : LSP::Position) : Array(String)
    path = Path[file_uri.decoded_path].normalize.to_s
    # The same stamp the syntax index uses for a rewritten buffer, so the two
    # share one parse of it rather than each paying for their own.
    symbols = @index.entry_for(path, contents, stamp: Index.rewritten_stamp(contents)).symbols
    names = [] of String

    while (symbol = symbols.find { |candidate|
            (candidate.kind.class? || candidate.kind.module? || candidate.kind.enum?) &&
            candidate.range.start.line <= position.line &&
            position.line <= candidate.range.end.line
          })
      names << symbol.name
      symbols = symbol.children || break
    end

    names
  rescue e
    LSP::Log.debug(exception: e) { "Unable to determine the namespaces enclosing #{file_uri}" }
    [] of String
  end

  private def syntax_method_completion(file_uri : URI, contents : String, position : LSP::Position, context : CompletionContext) : LSP::CompletionList?
    items = syntax_method_items(file_uri, contents, position, context)
    return if items.nil? || items.empty?

    finalize_completion(items, context, position.line)
  end

  private def syntax_method_items(file_uri : URI, contents : String, position : LSP::Position, context : CompletionContext) : Array(LSP::CompletionItem)?
    written, class_method = syntax_receiver_type(context.analysis_prefix.strip, contents, position)
    return unless written

    # The buffer is mid-edit, so the receiver line is replaced by one that
    # parses before anything is asked of it.
    parse_lines = contents.lines(chomp: false)
    parse_lines[position.line] = context.rewritten_line
    repaired = parse_lines.join

    resolver = Resolver.new(@index.project_entries(file_uri, buffer_sources, current_source: repaired))
    # `Inner.` inside `module Outer` means `Outer::Inner`, and the receiver as
    # written says nothing about which one that is.
    fqn = resolver.resolve(written, enclosing_namespaces(file_uri, repaired, position))
    return unless fqn

    range = context.completion_range(position.line)
    resolver.members(fqn, class_method).map do |method|
      LSP::CompletionItem.new(
        label: method.detail,
        insert_text: method.name,
        filter_text: method.name,
        kind: LSP::CompletionItemKind::Method,
        documentation: method.doc.try { |doc| LSP::MarkupContent.new(kind: LSP::MarkupKind::MarkDown, value: doc) },
        text_edit: LSP::TextEdit.new(range: range, new_text: method.name),
      )
    end
  end

  # The type a receiver names, as written, and whether it was named as a type
  # rather than as a value of one.
  private def syntax_receiver_type(receiver : String, contents : String, position : LSP::Position) : {String?, Bool}
    if receiver.matches?(/\A(?:::)?[A-Z]\w*(?:::[A-Z]\w*)*\z/)
      return {receiver, true}
    end

    if match = receiver.match(/((?:::)?[A-Z]\w*(?:::[A-Z]\w*)*)\.new(?:\(.*\))?$/)
      return {match[1], false}
    end

    return {nil, false} unless receiver.matches?(/\A[a-z_]\w*[!?]?\z/)

    lines_before_cursor = contents.lines[0...position.line]
    lines_before_cursor.reverse_each do |line|
      if match = line.match(/^\s*#{Regex.escape(receiver)}\s*:\s*((?:::)?[A-Z]\w*(?:::[A-Z]\w*)*)/)
        return {match[1], false}
      elsif match = line.match(/^\s*#{Regex.escape(receiver)}\s*=\s*((?:::)?[A-Z]\w*(?:::[A-Z]\w*)*)\.new\b/)
        return {match[1], false}
      end
    end

    prefix = lines_before_cursor.join("\n")
    matches = prefix.scan(/\b#{Regex.escape(receiver)}\s*:\s*((?:::)?[A-Z]\w*(?:::[A-Z]\w*)*)/)
    {matches.last?.try(&.[1]), false}
  end

  private def source_methods(file_uri : URI, current_source : String) : Array(Analysis::SourceMethod)
    @index.project_entries(file_uri, buffer_sources, current_source: current_source).flat_map(&.methods)
  end

  # Parse every file of every project once, up front, so the first request that
  # needs the index is not the one that pays to build it.
  def warm_syntax_index : Nil
    @index.warm(buffer_sources)
  end

  # Whether a parse of *path* is being kept for the contents it has on disk.
  def syntax_indexed?(path : String) : Bool
    @index.indexed?(path)
  end

  # The contents of every opened document, indexed by normalized path. An opened
  # buffer supersedes what is on disk.
  private def buffer_sources : Hash(String, String)
    documents_snapshot.each_with_object({} of String => String) do |(uri, document), acc|
      acc[Path[URI.parse(uri).decoded_path].normalize.to_s] = document.contents
    end
  end

  private def syntax_type_completion(file_uri : URI, context : CompletionContext, line : Int32) : LSP::CompletionList?
    namespace = context.analysis_prefix.match(/([A-Z]\w*(?:::[A-Z]\w*)*)$/).try(&.[1])
    return unless namespace

    range = context.completion_range(line)
    items = syntax_type_symbols(file_uri).compact_map do |qualified_name, kind|
      parent, separator, insertion = qualified_name.rpartition("::")
      next unless separator == "::" && parent == namespace
      next unless insertion.starts_with?(context.filter_fragment)

      LSP::CompletionItem.new(
        label: qualified_name,
        text_edit: LSP::TextEdit.new(range: range, new_text: insertion),
        kind: kind,
      )
    end

    finalize_completion(items.uniq(&.label).sort_by(&.label), context, line)
  end

  private def syntax_type_symbols(file_uri : URI) : Array({String, LSP::CompletionItemKind})
    @index.project_entries(file_uri, buffer_sources).flat_map(&.types)
  end

  def document_symbols(server : LSP::Server, file_uri : URI)
    document_at(file_uri.to_s).try { |text_document|
      parser = Crystal::Parser.new(fix_source(text_document.contents))
      parser.filename = file_uri.decoded_path
      parser.wants_doc = false

      Analysis::DocumentSymbolsVisitor.new.tap { |visitor|
        parser.parse.accept(visitor)
      }.symbols
    }
  end

  # The types and parameter names an editor draws inline.
  #
  # Answered from the index, so it costs a parse of one buffer and a walk of it
  # - no compiler, and no waiting for one. A client asks for these on every
  # scroll and every edit, which rules out anything slower.
  def inlay_hints(params : LSP::InlayHintParams) : Array(LSP::InlayHint)?
    file_uri = URI.parse(params.text_document.uri)
    document = document_at(params.text_document.uri)
    return unless document

    contents = document.contents
    ast = Crystal::Parser.new(fix_source(contents)).tap(&.filename=(file_uri.decoded_path)).parse
    resolver = Resolver.new(@index.project_entries(file_uri, buffer_sources, current_source: contents))

    InlayHints.new(resolver, params.range).tap { |visitor| ast.accept(visitor) }.hints
  rescue e
    LSP::Log.debug(exception: e) { "Unable to produce inlay hints for #{params.text_document.uri}" }
    nil
  end

  def folding_ranges(params : LSP::FoldingRangeParams)
    document_at(params.text_document.uri).try { |text_document|
      parser = Crystal::Parser.new(fix_source(text_document.contents))
      parser.filename = URI.parse(params.text_document.uri).decoded_path
      parser.wants_doc = false

      Analysis::FoldingRangeVisitor.new.tap { |visitor|
        parser.parse.accept(visitor)
      }.ranges
    }
  end

  def workspace_symbols(params : LSP::WorkspaceSymbolParams)
    query = params.query.downcase
    buffers = buffer_sources

    # A workspace-less server is still useful in editors that open individual
    # files without sending a root URI.
    @index.all_files(buffers.keys).flat_map do |path|
      uri = Utils.file_uri(Path[path].normalize.to_s)
      @index.entry_from(path, buffers).symbols.flat_map(&.to_symbol_information_array(uri))
    rescue e
      LSP::Log.debug(exception: e) { "Unable to collect symbols from #{path}: #{e.message}" }
      [] of LSP::SymbolInformation
    end.select { |symbol| query.empty? || symbol.name.downcase.includes?(query) }
      .sort_by { |symbol| {symbol.name.downcase, symbol.location.uri, symbol.location.range.start.line} }
  end

  private def fix_source(source : String) : String
    # LSP::Log.info { "Fixing source: #{source}" }
    Crystal::Parser.parse(source)
    # LSP::Log.info { "No need to fix source!" }
    source
  rescue
    fixed_source = BrokenSourceFixer.fix(source)
    # LSP::Log.info { "Fixed source: #{fixed_source}" }
    fixed_source
  end
end
