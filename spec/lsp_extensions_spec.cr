require "./spec_helper"

private def request_json(method : String, params : String)
  %({"jsonrpc":"2.0","id":1,"method":#{method.to_json},"params":#{params}})
end

private def deserialize_request(method : String, params : String)
  LSP::RequestMessage.from_json(request_json(method, params))
end

private def round_trip_request(request : LSP::RequestMessage)
  LSP::RequestMessage.from_json(request.to_json)
end

describe "LSP request extensions" do
  position_params = %({"textDocument":{"uri":"file:///fixture.cr"},"position":{"line":2,"character":4}})

  it "dispatches references requests" do
    params = %({"textDocument":{"uri":"file:///fixture.cr"},"position":{"line":2,"character":4},"context":{"includeDeclaration":true}})
    request = deserialize_request("textDocument/references", params)

    request.should be_a(LSP::ReferencesRequest)
    typed_request = request.as(LSP::ReferencesRequest)
    typed_request.params.context.include_declaration.should be_true
    round_trip_request(request).should be_a(LSP::ReferencesRequest)
  end

  it "dispatches document highlight requests" do
    request = deserialize_request("textDocument/documentHighlight", position_params)

    request.should be_a(LSP::DocumentHighlightRequest)
    round_trip_request(request).should be_a(LSP::DocumentHighlightRequest)
  end

  it "dispatches rename requests" do
    params = %({"textDocument":{"uri":"file:///fixture.cr"},"position":{"line":2,"character":4},"newName":"renamed"})
    request = deserialize_request("textDocument/rename", params)

    request.should be_a(LSP::RenameRequest)
    request.as(LSP::RenameRequest).params.new_name.should eq("renamed")
    round_trip_request(request).should be_a(LSP::RenameRequest)
  end

  it "dispatches folding range requests" do
    params = %({"textDocument":{"uri":"file:///fixture.cr"}})
    request = deserialize_request("textDocument/foldingRange", params)

    request.should be_a(LSP::FoldingRangeRequest)
    round_trip_request(request).should be_a(LSP::FoldingRangeRequest)
  end

  it "dispatches workspace symbol requests" do
    request = deserialize_request("workspace/symbol", %({"query":"Widget"}))

    request.should be_a(LSP::WorkspaceSymbolRequest)
    request.as(LSP::WorkspaceSymbolRequest).params.query.should eq("Widget")
    round_trip_request(request).should be_a(LSP::WorkspaceSymbolRequest)
  end

  it "keeps every existing request discriminator" do
    requests = {
      "initialize"                     => {"LSP::InitializeRequest", %({"processId":null,"rootUri":null,"capabilities":{}})},
      "shutdown"                       => {"LSP::ShutdownRequest", "null"},
      "window/showMessageRequest"      => {"LSP::ShowMessageRequest", %({"type":3,"message":"Continue?"})},
      "window/workDoneProgress/create" => {"LSP::WorkDoneProgressCreateRequest", %({"token":"build"})},
      "textDocument/willSaveWaitUntil" => {"LSP::WillSaveWaitUntilRequest", %({"textDocument":{"uri":"file:///fixture.cr"},"reason":1})},
      "textDocument/completion"        => {"LSP::CompletionRequest", position_params},
      "textDocument/formatting"        => {"LSP::DocumentFormattingRequest", %({"textDocument":{"uri":"file:///fixture.cr"},"options":{"tabSize":2,"insertSpaces":true}})},
      "textDocument/rangeFormatting"   => {"LSP::DocumentRangeFormattingRequest", %({"textDocument":{"uri":"file:///fixture.cr"},"range":{"start":{"line":0,"character":0},"end":{"line":1,"character":0}},"options":{"tabSize":2,"insertSpaces":true}})},
      "textDocument/hover"             => {"LSP::HoverRequest", position_params},
      "textDocument/definition"        => {"LSP::DefinitionRequest", position_params},
      "textDocument/signatureHelp"     => {"LSP::SignatureHelpRequest", position_params},
      "textDocument/documentSymbol"    => {"LSP::DocumentSymbolsRequest", %({"textDocument":{"uri":"file:///fixture.cr"}})},
    }

    requests.each do |method, (expected_class, params)|
      deserialize_request(method, params).class.name.should eq(expected_class), method
    end
  end

  it "serializes new result models with LSP field names" do
    range = LSP::Range.new(
      start: LSP::Position.new(line: 1, character: 2),
      end: LSP::Position.new(line: 1, character: 5),
    )
    highlight = LSP::DocumentHighlight.new(range: range, kind: LSP::DocumentHighlightKind::Read)
    fold = LSP::FoldingRange.new(
      start_line: 1,
      start_character: 2,
      end_line: 4,
      end_character: 1,
      kind: LSP::FoldingRangeKind::Region,
      collapsed_text: "section",
    )

    JSON.parse(highlight.to_json)["kind"].as_i.should eq(2)
    fold_json = JSON.parse(fold.to_json)
    fold_json["startLine"].as_i.should eq(1)
    fold_json["endLine"].as_i.should eq(4)
    fold_json["kind"].as_s.should eq("region")
    fold_json["collapsedText"].as_s.should eq("section")
  end
end
