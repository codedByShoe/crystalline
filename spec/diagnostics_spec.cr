require "./spec_helper"

describe Crystalline::Diagnostics do
  it "publishes the document version with diagnostics and clears" do
    output = IO::Memory.new
    server = LSP::Server.new(IO::Memory.new, output, Crystalline::SERVER_CAPABILITIES)
    uri = "file:///tmp/versioned_diagnostics.cr"

    Crystalline::Diagnostics.new
      .init_value(uri)
      .publish(server, versions: {uri => 7})

    message = output.to_s
    message.should contain(%("uri":"#{uri}"))
    message.should contain(%("version":7))
    message.should contain(%("diagnostics":[]))
  end

  it "keeps published diagnostics on screen while the buffer changes" do
    output = IO::Memory.new
    server = LSP::Server.new(IO::Memory.new, output, Crystalline::SERVER_CAPABILITIES)
    server.client_capabilities = LSP::ClientCapabilities.new
    workspace = Crystalline::Workspace.new(server, nil)
    uri = "file:///tmp/kept_diagnostics.cr"

    workspace.open_document(LSP::DidOpenTextDocumentParams.new(
      text_document: LSP::TextDocumentItem.new(
        uri: uri,
        language_id: "crystal",
        version: 1,
        text: "value = 1\n",
      ),
    ))
    workspace.update_document(server, LSP::DidChangeTextDocumentParams.new(
      text_document: LSP::VersionedTextDocumentIdentifier.new(uri: uri, version: 2),
      content_changes: [
        LSP::DidChangeTextDocumentParams::TextDocumentContentChangeEvent.new(
          range: nil,
          text: "value = 2\n",
        ),
      ],
    ))

    # An edit must not blank the diagnostics from the last compilation: they
    # are replaced when the next compilation publishes, not before.
    output.to_s.should_not contain("publishDiagnostics")
  end
end
