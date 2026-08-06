require "file_utils"
require "./spec_helper"

# Macros resolve relative paths against the process working directory - `ECR`
# embedding, `run`, backticks, and everything built on them such as Kemal's
# `render "src/views/index.ecr"`. The editor decides where the language server
# is started from, so compiling from anywhere but the project root makes those
# macros raise and takes the whole semantic analysis of the project with it.
describe "Workspace#compile from the project root" do
  it "compiles a project from its own root, whatever the server was started from" do
    root = File.tempname("crystalline-project-root")
    Dir.mkdir_p(File.join(root, "src"))

    File.write(File.join(root, "shard.yml"), <<-YAML)
    name: macro_fixture
    version: 0.1.0
    targets:
      macro_fixture:
        main: src/macro_fixture.cr
    YAML

    # The macro records the directory the compiler ran from, the same way a
    # path-reading macro would resolve one.
    main_path = File.join(root, "src", "macro_fixture.cr")
    source = <<-CRYSTAL
    COMPILED_FROM = {{ `pwd`.stringify }}

    puts COMPILED_FROM
    CRYSTAL
    File.write(main_path, source)

    server = Crystalline::SpecSupport.build_server
    workspace = Crystalline::Workspace.new(server, Crystalline::Utils.file_uri(root))
    uri = URI.parse(Crystalline::Utils.file_uri(main_path))
    workspace.open_document(LSP::DidOpenTextDocumentParams.new(
      text_document: LSP::TextDocumentItem.new(
        uri: uri.to_s, language_id: "crystal", version: 1, text: source,
      ),
    ))

    # The spec process runs from the crystalline repository, never from the
    # fixture project, which is exactly the situation being guarded against.
    Dir.current.should_not eq(root)

    result = Crystalline::SpecSupport.run_with_fake_client(server) do
      workspace.compile(server, uri, in_memory: true)
    end

    constant = result.not_nil!.program.types["COMPILED_FROM"].as(Crystal::Const)
    node = constant.value
    node = node.expanded || node if node.is_a?(Crystal::MacroExpression)
    compiled_from = node.as(Crystal::StringLiteral).value.strip
    File.realpath(compiled_from).should eq(File.realpath(root))
  ensure
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end

  it "leaves the working directory untouched after compiling" do
    before = Dir.current
    workspace, server, uri = Crystalline::SpecSupport.open_document("value = 1\nvalue.\n", "cwd_fixture.cr")
    Crystalline::SpecSupport.run_with_fake_client(server) do
      workspace.completion(server, uri, LSP::Position.new(line: 1, character: 6), ".")
    end
    Dir.current.should eq(before)
  end
end
