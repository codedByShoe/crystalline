require "spec"
require "../src/crystalline/requires"
require "../src/crystalline/*"

# Specs bypass `Crystalline.init`, so mirror its compiler environment setup.
Crystalline::EnvironmentConfig.run

# Test-only: production code sets `client_capabilities` during the real
# `initialize` handshake (see `LSP::Server#handshake`, private). Specs that
# drive `Workspace` need it populated without going through a real socket.
class LSP::Server
  def client_capabilities=(capabilities : LSP::ClientCapabilities)
    @client_capabilities = capabilities
  end
end

module Crystalline::SpecSupport
  def self.build_server : LSP::Server
    server = LSP::Server.new(IO::Memory.new, IO::Memory.new, Crystalline::SERVER_CAPABILITIES)
    server.client_capabilities = LSP::ClientCapabilities.new
    server
  end

  # `Workspace#compile` gates the actual compilation on the client
  # acknowledging a `window/workDoneProgress/create` request (see
  # `Progress#report`) before it runs — in production the editor replies
  # automatically, but nothing does that here. This runs *block* in a fiber
  # and acts as a fake client that immediately acknowledges any such request
  # the server sends, so the compile can proceed instead of blocking until
  # `Workspace`'s 120s timeout.
  def self.run_with_fake_client(server : LSP::Server, &block : -> T) : T forall T
    channel = Channel(T).new

    spawn do
      channel.send(block.call)
    end

    loop do
      if (req = server.requests_sent.values.find(&.is_a?(LSP::WorkDoneProgressCreateRequest)).as?(LSP::WorkDoneProgressCreateRequest))
        server.requests_sent.delete(req.id)
        req.on_response(nil, nil)
      end

      select
      when result = channel.receive
        return result
      when timeout(5.milliseconds)
      end
    end
  end

  # Opens *source* as an in-memory document at a throwaway `file://` uri and
  # returns `{workspace, server, uri}` ready to drive a `Workspace` request.
  def self.open_document(source : String, filename = "crystalline_spec_fixture.cr") : {Workspace, LSP::Server, URI}
    server = build_server
    workspace = Workspace.new(server, nil)
    uri = URI.parse("file:///tmp/#{filename}")

    workspace.open_document(LSP::DidOpenTextDocumentParams.new(
      text_document: LSP::TextDocumentItem.new(
        uri: uri.to_s,
        language_id: "crystal",
        version: 1,
        text: source,
      ),
    ))

    {workspace, server, uri}
  end
end
