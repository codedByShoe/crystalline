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
end
