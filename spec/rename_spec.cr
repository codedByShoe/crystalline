require "./spec_helper"

private def rename_at(source : String, line : Int32, character : Int32, new_name : String, *, supports_document_changes = false)
  workspace, server, uri = Crystalline::SpecSupport.open_document(source)
  if supports_document_changes
    server.client_capabilities = LSP::ClientCapabilities.new(
      workspace: LSP::ClientCapabilities::Workspace.new(
        workspace_edit: LSP::WorkspaceEditClientCapabilities.new(document_changes: true),
      ),
    )
  end
  params = LSP::RenameParams.new(
    text_document: LSP::TextDocumentIdentifier.new(uri: uri.to_s),
    position: LSP::Position.new(line: line, character: character),
    new_name: new_name,
  )

  Crystalline::SpecSupport.run_with_fake_client(server) do
    workspace.rename(server, params)
  end
end

describe "Workspace#rename" do
  it "renames the selected overload, its declaration, and all resolved calls" do
    source = <<-CRYSTAL
    def convert(value : Int32)
      value.to_s
    end

    def convert(value : String)
      value
    end

    convert(1)
    convert("one")
    convert(2)
    CRYSTAL

    workspace_edit = rename_at(source, 8, 2, "render", supports_document_changes: true).not_nil!
    document_changes = workspace_edit.document_changes.not_nil!.as(Array(LSP::TextDocumentEdit))
    document_changes.size.should eq(1)

    edits = document_changes.first.edits.sort_by { |edit| {edit.range.start.line, edit.range.start.character} }
    edits.map(&.new_text).should eq(["render", "render", "render"])
    edits.map { |edit| {edit.range.start.line, edit.range.start.character, edit.range.end.character} }.should eq([
      {0, 4, 11},
      {8, 0, 7},
      {10, 0, 7},
    ])
  end

  it "does not rename a same-named local in another scope" do
    source = <<-CRYSTAL
    def first
      value = 1
      value
    end

    def second
      value = 2
      value
    end

    first
    second
    CRYSTAL

    workspace_edit = rename_at(source, 2, 3, "result").not_nil!
    edits = workspace_edit.changes.values.first
    edits.map(&.range.start.line).sort.should eq([1, 2])
  end

  it "rejects an empty replacement and unresolved cursor positions" do
    source = "value = 1\n"
    rename_at(source, 0, 2, "").should be_nil
    rename_at(source, 0, 8, "renamed").should be_nil
  end

  it "rejects a replacement that is not an identifier" do
    source = "value = 1\n"
    rename_at(source, 0, 2, "two words").should be_nil
    rename_at(source, 0, 2, "Bad::Path").should be_nil
    rename_at(source, 0, 2, "1starts_with_digit").should be_nil
    rename_at(source, 0, 2, "def").should be_nil
  end

  it "advertises prepare support" do
    options = Crystalline::SERVER_CAPABILITIES.rename_provider.as(LSP::RenameOptions)
    options.prepare_provider.should be_true
  end
end

private def prepare_rename_at(source : String, line : Int32, character : Int32) : LSP::Range?
  workspace, _server, uri = Crystalline::SpecSupport.open_document(source)
  workspace.prepare_rename(LSP::PrepareRenameParams.new(
    text_document: LSP::TextDocumentIdentifier.new(uri: uri.to_s),
    position: LSP::Position.new(line: line, character: character),
  ))
end

describe "Workspace#prepare_rename" do
  it "returns the range of the identifier under the cursor" do
    range = prepare_rename_at("value = 1\n", 0, 2).not_nil!
    {range.start.character, range.end.character}.should eq({0, 5})
  end

  it "spans the whole symbol from any cursor position inside it, sigils and suffixes included" do
    source = <<-CRYSTAL
    @counter = 1
    list.empty?
    CRYSTAL

    range = prepare_rename_at(source, 0, 0).not_nil!
    {range.start.character, range.end.character}.should eq({0, 8})

    range = prepare_rename_at(source, 1, 7).not_nil!
    {range.start.character, range.end.character}.should eq({5, 11})
  end

  it "refuses whitespace, operators, and keywords" do
    source = <<-CRYSTAL
    def render
    end
    x != 2
    CRYSTAL

    prepare_rename_at(source, 0, 1).should be_nil # `def` is a keyword
    prepare_rename_at(source, 2, 2).should be_nil # the `!=` operator
  end

  it "does not read the `!` of `!=` as a method suffix" do
    range = prepare_rename_at("x != 2\n", 0, 0).not_nil!
    {range.start.character, range.end.character}.should eq({0, 1})
  end
end
