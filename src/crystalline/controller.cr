require "./workspace"

class Crystalline::Controller
  # The project workspace.
  getter! workspace : Workspace
  # A list of requests that are pending, used when receiving a cancel request.
  @pending_requests : Set(LSP::RequestMessage::RequestId) = Set(LSP::RequestMessage::RequestId).new
  # Used to process certain requests synchronously.
  @documents_lock = Mutex.new
  @compiler_lock = Mutex.new
  # Every message is delegated to its own fiber, and fibers run in parallel when
  # the server is built with `-Dpreview_mt`, so the request bookkeeping below is
  # guarded rather than accessed directly.
  @requests_lock = Mutex.new
  @latest_completion_request : LSP::RequestMessage::RequestId? = nil

  def initialize(@server : LSP::Server)
    @server.start(self)
  end

  def on_init(init_params : LSP::InitializeParams) : Nil
    @workspace = Workspace.new(@server, init_params.root_uri)
  end

  def when_ready : Nil
    # Parsing the project needs no compiler, so it does not queue behind the
    # analysis below - and it is what answers the requests that arrive while
    # that analysis is still running.
    spawn do
      workspace.warm_syntax_index
    end

    # Compile the workspace at once.
    spawn do
      workspace.projects.each do |p|
        if (entry_point = p.entry_point?)
          workspace.compile(@server, entry_point)
        end
      end
    end
  end

  # Whether *id* is still awaited by the client.
  private def pending?(id : LSP::RequestMessage::RequestId) : Bool
    @requests_lock.synchronize { @pending_requests.includes?(id) }
  end

  # Registers *id* as the newest completion request, superseding any older one.
  private def latest_completion_request=(id : LSP::RequestMessage::RequestId)
    @requests_lock.synchronize { @latest_completion_request = id }
  end

  # Whether *id* is both still awaited and the newest completion request.
  private def current_completion_request?(id : LSP::RequestMessage::RequestId) : Bool
    @requests_lock.synchronize do
      @latest_completion_request == id && @pending_requests.includes?(id)
    end
  end

  # The compiler unfortunately prevents declaring the following signature for the time being:
  # def on_request(message : LSP::RequestMessage(T)) : T forall T
  def on_request(message : LSP::RequestMessage)
    @requests_lock.synchronize { @pending_requests << message.id }
    case message
    when LSP::DocumentFormattingRequest
      @documents_lock.synchronize {
        workspace.format_document(message.params).try { |(formatted_document, document)|
          range = LSP::Range.new(
            start: LSP::Position.new(line: 0, character: 0),
            end: document.eof_position,
          )
          [
            LSP::TextEdit.new(
              range: range,
              new_text: formatted_document,
            ),
          ]
        }
      }
    when LSP::DocumentRangeFormattingRequest
      @documents_lock.synchronize {
        workspace.format_document(message.params).try { |(formatted_document, document)|
          [
            LSP::TextEdit.new(
              range: message.params.range,
              new_text: formatted_document,
            ),
          ]
        }
      }
    when LSP::HoverRequest
      @compiler_lock.synchronize do
        return nil unless pending?(message.id)
        file_uri = URI.parse message.params.text_document.uri
        workspace.hover(@server, file_uri, message.params.position)
      end
    when LSP::DefinitionRequest
      @compiler_lock.synchronize do
        return nil unless pending?(message.id)
        file_uri = URI.parse message.params.text_document.uri
        workspace.definitions(@server, file_uri, message.params.position)
      end
    when LSP::ReferencesRequest
      @compiler_lock.synchronize do
        return nil unless pending?(message.id)
        workspace.references(@server, message.params)
      end
    when LSP::DocumentHighlightRequest
      @compiler_lock.synchronize do
        return nil unless pending?(message.id)
        workspace.document_highlights(@server, message.params)
      end
    when LSP::RenameRequest
      @compiler_lock.synchronize do
        return nil unless pending?(message.id)
        workspace.rename(@server, message.params)
      end
    when LSP::SignatureHelpRequest
      @compiler_lock.synchronize do
        return nil unless pending?(message.id)
        file_uri = URI.parse message.params.text_document.uri
        workspace.signature_help(@server, file_uri, message.params.position)
      end
    when LSP::CompletionRequest
      # Completion requests arrive on independent fibers. Keep only the newest
      # request waiting for the compiler so typing cannot build an arbitrarily
      # long queue of obsolete prefixes.
      self.latest_completion_request = message.id
      return nil unless current_completion_request?(message.id)
      file_uri = URI.parse message.params.text_document.uri
      workspace.completion(
        @server,
        file_uri,
        message.params.position,
        message.params.context.try &.trigger_character,
        cancelled: -> { !current_completion_request?(message.id) },
      )
    when LSP::DocumentSymbolsRequest
      @documents_lock.synchronize do
        file_uri = URI.parse message.params.text_document.uri
        document_symbols = workspace.document_symbols(@server, file_uri)

        if @server.client_capabilities.text_document.try &.document_symbol.try &.hierarchical_document_symbol_support
          document_symbols
        else
          document_symbols.try &.reduce([] of LSP::SymbolInformation) { |acc, document_symbol|
            acc.concat(document_symbol.to_symbol_information_array(message.params.text_document.uri))
          }
        end
      end
    when LSP::FoldingRangeRequest
      @documents_lock.synchronize do
        workspace.folding_ranges(message.params)
      end
    when LSP::InlayHintRequest
      # Needs no compiler, so it does not take the lock that serializes what
      # does: an editor asks for these on every scroll.
      @documents_lock.synchronize do
        workspace.inlay_hints(message.params)
      end
    when LSP::WorkspaceSymbolRequest
      @documents_lock.synchronize do
        workspace.workspace_symbols(message.params)
      end
    else
      nil
    end
  rescue e : Crystal::TypeException
    LSP::Log.warn(exception: e) { e.to_s }
    nil
  rescue e : Crystal::SyntaxException
    LSP::Log.warn(exception: e) { e.to_s }
    nil
  ensure
    @requests_lock.synchronize do
      @pending_requests.delete message.id
      @latest_completion_request = nil if @latest_completion_request == message.id
    end
  end

  def on_notification(message : LSP::NotificationMessage) : Nil
    case message
    when LSP::DidOpenNotification
      @documents_lock.synchronize {
        workspace.open_document(message.params)
      }
    when LSP::DidChangeNotification
      @documents_lock.synchronize {
        workspace.update_document(@server, message.params)
      }
    when LSP::DidCloseNotification
      @documents_lock.synchronize {
        workspace.close_document(@server, message.params)
      }
    when LSP::DidSaveNotification
      @documents_lock.synchronize {
        workspace.save_document(@server, message.params)
      }
      file_uri = message.params.text_document.uri
      spawn do
        @compiler_lock.synchronize {
          workspace.compile(
            @server,
            URI.parse(file_uri),
            discard_nil_cached_result: true,
          )
        }
      end
    when LSP::CancelNotification
      @requests_lock.synchronize { @pending_requests.delete message.params.id }
    end
  rescue e : Crystal::TypeException
    LSP::Log.warn(exception: e) { e.to_s }
  rescue e : Crystal::SyntaxException
    LSP::Log.warn(exception: e) { e.to_s }
  end

  def on_response(message : LSP::ResponseMessage, original_message : LSP::RequestMessage?) : Nil
    original_message.try &.on_response(message.result, message.error)
  rescue e : Crystal::TypeException
    LSP::Log.warn(exception: e) { e.to_s }
  rescue e : Crystal::SyntaxException
    LSP::Log.warn(exception: e) { e.to_s }
  end
end
