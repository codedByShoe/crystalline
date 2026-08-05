require "lsp/server"

module LSP
  macro finished
    class ReferencesRequest < RequestMessage(Array(Location)?)
      @method = "textDocument/references"
      property params : ReferenceParams
    end

    class DocumentHighlightRequest < RequestMessage(Array(DocumentHighlight)?)
      @method = "textDocument/documentHighlight"
      property params : DocumentHighlightParams
    end

    class RenameRequest < RequestMessage(WorkspaceEdit?)
      @method = "textDocument/rename"
      property params : RenameParams
    end

    class FoldingRangeRequest < RequestMessage(Array(FoldingRange)?)
      @method = "textDocument/foldingRange"
      property params : FoldingRangeParams
    end

    class WorkspaceSymbolRequest < RequestMessage(Array(SymbolInformation)?)
      @method = "workspace/symbol"
      property params : WorkspaceSymbolParams
    end
  end

  struct ReferenceParams
    include TextDocumentPositionParams
    include WorkDoneProgressParams
    include PartialResultParams
    include Initializer
    include JSON::Serializable

    property context : ReferenceContext
  end

  struct ReferenceContext
    include Initializer
    include JSON::Serializable

    @[JSON::Field(key: "includeDeclaration")]
    property include_declaration : Bool
  end

  struct DocumentHighlightParams
    include TextDocumentPositionParams
    include WorkDoneProgressParams
    include Initializer
    include JSON::Serializable
  end

  Enum.number DocumentHighlightKind do
    Text  = 1
    Read  = 2
    Write = 3
  end

  struct DocumentHighlight
    include Initializer
    include JSON::Serializable

    property range : Range
    property kind : DocumentHighlightKind?
  end

  struct RenameParams
    include TextDocumentPositionParams
    include WorkDoneProgressParams
    include Initializer
    include JSON::Serializable

    @[JSON::Field(key: "newName")]
    property new_name : String
  end

  struct FoldingRangeParams
    include WorkDoneProgressParams
    include PartialResultParams
    include Initializer
    include JSON::Serializable

    @[JSON::Field(key: "textDocument")]
    property text_document : TextDocumentIdentifier
  end

  Enum.string FoldingRangeKind do
    Comment
    Imports
    Region
  end

  struct FoldingRange
    include Initializer
    include JSON::Serializable

    @[JSON::Field(key: "startLine")]
    property start_line : Int32

    @[JSON::Field(key: "startCharacter")]
    property start_character : Int32?

    @[JSON::Field(key: "endLine")]
    property end_line : Int32

    @[JSON::Field(key: "endCharacter")]
    property end_character : Int32?

    property kind : FoldingRangeKind?

    @[JSON::Field(key: "collapsedText")]
    property collapsed_text : String?
  end

  struct WorkspaceSymbolParams
    include WorkDoneProgressParams
    include PartialResultParams
    include Initializer
    include JSON::Serializable

    property query : String
  end

  class RequestMessage(Result)
    json_discriminator "method", {
      initialize:                       InitializeRequest,
      shutdown:                         ShutdownRequest,
      "window/showMessageRequest":      ShowMessageRequest,
      "window/workDoneProgress/create": WorkDoneProgressCreateRequest,
      "textDocument/willSaveWaitUntil": WillSaveWaitUntilRequest,
      "textDocument/completion":        CompletionRequest,
      "textDocument/formatting":        DocumentFormattingRequest,
      "textDocument/rangeFormatting":   DocumentRangeFormattingRequest,
      "textDocument/hover":             HoverRequest,
      "textDocument/definition":        DefinitionRequest,
      "textDocument/signatureHelp":     SignatureHelpRequest,
      "textDocument/documentSymbol":    DocumentSymbolsRequest,
      "textDocument/references":        ReferencesRequest,
      "textDocument/documentHighlight": DocumentHighlightRequest,
      "textDocument/rename":            RenameRequest,
      "textDocument/foldingRange":      FoldingRangeRequest,
      "workspace/symbol":               WorkspaceSymbolRequest,
    }, default: UnknownRequest
  end
end
