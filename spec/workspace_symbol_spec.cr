require "file_utils"
require "./spec_helper"

describe "Workspace#workspace_symbols" do
  it "advertises workspace symbol support" do
    Crystalline::SERVER_CAPABILITIES.workspace_symbol_provider.should be_true
  end

  it "searches project Crystal files case-insensitively and prefers open contents" do
    root = File.tempname("crystalline-workspace-symbols")
    src_dir = Path[root, "src"]
    lib_dir = Path[root, "lib"]
    Dir.mkdir_p(src_dir)
    Dir.mkdir_p(lib_dir)

    File.write(Path[root, "shard.yml"], "name: symbol_fixture\n")
    first_path = Path[src_dir, "first.cr"].normalize
    second_path = Path[src_dir, "second.cr"].normalize
    File.write(first_path, "class StaleWidget\nend\n")
    File.write(second_path, "module WidgetTools\n  def build_widget\n  end\nend\n")
    File.write(Path[lib_dir, "vendor.cr"], "class VendorWidget\nend\n")

    server = Crystalline::SpecSupport.build_server
    root_uri = URI.parse("file://#{Path[root].normalize}")
    workspace = Crystalline::Workspace.new(server, root_uri.to_s)
    first_uri = URI.parse("file://#{first_path}")
    workspace.open_document(LSP::DidOpenTextDocumentParams.new(
      text_document: LSP::TextDocumentItem.new(
        uri: first_uri.to_s,
        language_id: "crystal",
        version: 1,
        text: "class FreshWidget\nend\n",
      ),
    ))

    symbols = workspace.workspace_symbols(LSP::WorkspaceSymbolParams.new(query: "WIDGET"))

    symbols.map(&.name).should eq(["build_widget", "FreshWidget", "WidgetTools"])
    symbols.map(&.name).should_not contain("StaleWidget")
    symbols.map(&.name).should_not contain("VendorWidget")
    symbols.find(&.name.==("build_widget")).not_nil!.container_name.should eq("WidgetTools")
  ensure
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end

  it "searches open documents when the editor supplies no workspace root" do
    source = "class StandaloneService\nend\n"
    workspace, _server, _uri = Crystalline::SpecSupport.open_document(source, "standalone_service.cr")

    symbols = workspace.workspace_symbols(LSP::WorkspaceSymbolParams.new(query: "service"))
    symbols.map(&.name).should eq(["StandaloneService"])
  end
end
