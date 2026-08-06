require "file_utils"
require "./spec_helper"

# Counts how often the dependency calculation is actually run.
private class CountingWorkspace < Crystalline::Workspace
  getter recalculations = 0

  def recalculate_dependencies(server, project)
    @recalculations += 1
    super
  end
end

# A dependency calculation is a whole top level semantic analysis of the project.
# It is retried whenever a project has no dependencies to speak of, which is also
# the state a failed calculation leaves behind - so an entry point that does not
# compile used to make every single request pay for that analysis on top of the
# one it asked for.
describe "Workspace dependency recalculation" do
  it "does not retry a failing dependency calculation on every request" do
    root = File.tempname("crystalline-broken-entry-point")
    Dir.mkdir_p(File.join(root, "src"))

    File.write(File.join(root, "shard.yml"), <<-YAML)
    name: broken_fixture
    version: 0.1.0
    targets:
      broken_fixture:
        main: src/broken_fixture.cr
    YAML

    main_path = File.join(root, "src", "broken_fixture.cr")
    source = "require \"./no_such_file\"\n"
    File.write(main_path, source)

    server = Crystalline::SpecSupport.build_server
    workspace = CountingWorkspace.new(server, Crystalline::Utils.file_uri(root))
    uri = URI.parse(Crystalline::Utils.file_uri(main_path))
    workspace.open_document(LSP::DidOpenTextDocumentParams.new(
      text_document: LSP::TextDocumentItem.new(
        uri: uri.to_s, language_id: "crystal", version: 1, text: source,
      ),
    ))

    3.times do
      Crystalline::SpecSupport.run_with_fake_client(server) do
        workspace.compile(server, uri, in_memory: true, ignore_cached_result: true, do_not_cache_result: true)
      end
    end

    # The entry point never becomes valid, so the dependencies stay empty and
    # every one of those requests still looked like it needed a calculation.
    workspace.projects.all? { |project| project.dependencies.size < 2 }.should be_true
    workspace.recalculations.should eq(1)
  ensure
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end
end
