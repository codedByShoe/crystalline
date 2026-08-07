require "file_utils"
require "./spec_helper"

# Simulates what a session actually looks like: `Controller#when_ready` analyzes
# the project before anyone types, and `didSave` analyzes it again afterwards -
# both from a buffer that compiles. Only then does the user type a receiver,
# which is the state completion is asked about.
private def analyzed_then_typed(analyzed : String, typed : String, filename : String)
  workspace, server, uri = Crystalline::SpecSupport.open_document(analyzed, filename)
  compiled = Crystalline::SpecSupport.run_with_fake_client(server) do
    workspace.compile(server, uri, in_memory: true)
  end
  # A spec that silently lost its analysis would pass for the wrong reason.
  compiled.should_not be_nil
  workspace.analysis_stored?(uri).should be_true

  workspace.opened_documents[uri.to_s].contents = typed
  {workspace, server, uri}
end

private def complete(workspace, server, uri, line, character, trigger = ".")
  Crystalline::SpecSupport.run_with_fake_client(server) do
    workspace.completion(server, uri, LSP::Position.new(line: line, character: character), trigger)
  end
end

private def labels(result : LSP::CompletionList?)
  result.try(&.items.map(&.label)) || [] of String
end

# What a type responds to is a property of the type, not of the buffer the cursor
# happens to sit in, so it can be answered from an analysis that already exists
# instead of building one per keystroke.
describe "completion from a stored analysis" do
  it "offers what a type inherits, not only what is written beside it" do
    # The syntax index can only see `build`. Answering from it alone - which is
    # what returning early on it amounted to - hid every inherited and generated
    # member, so `Widget.` came back with a single entry.
    analyzed = <<-CRYSTAL
    class Widget
      def self.build : Widget
        new
      end
    end

    puts Widget.build
    CRYSTAL

    workspace, server, uri = analyzed_then_typed(
      analyzed, analyzed.sub("puts Widget.build", "Widget."), "analysis_inherited_fixture.cr")
    result = complete(workspace, server, uri, 6, 7)

    labels(result).any?(&.starts_with?("build")).should be_true
    labels(result).any?(&.starts_with?("new")).should be_true
    labels(result).size.should be > 5
    # Answered from an analysis, so the client may filter it as the word grows
    # rather than asking again for every character.
    result.not_nil!.is_incomplete.should be_false
  end

  it "offers a method written since the analysis was made" do
    analyzed = <<-CRYSTAL
    class Widget
      def self.build : Widget
        new
      end
    end

    puts Widget.build
    CRYSTAL

    # Typed after the analysis: no analysis knows about it yet, and waiting for
    # the next build to offer it is exactly the lag worth avoiding.
    typed = analyzed
      .sub("  def self.build", "  def self.freshly_typed\n  end\n\n  def self.build")
      .sub("puts Widget.build", "Widget.")

    workspace, server, uri = analyzed_then_typed(analyzed, typed, "analysis_fresh_method_fixture.cr")
    result = complete(workspace, server, uri, 9, 7)

    labels(result).any?(&.starts_with?("freshly_typed")).should be_true
    # Merged with the analysis rather than replacing it.
    labels(result).any?(&.starts_with?("new")).should be_true
  end

  it "resolves a receiver against the namespace it is written in" do
    analyzed = <<-CRYSTAL
    module Outer
      class Inner
        def self.build : Inner
          new
        end
      end

      class Other
        def run
          Inner.build
        end
      end
    end

    puts Outer::Other.new.run
    CRYSTAL

    workspace, server, uri = analyzed_then_typed(
      analyzed, analyzed.sub("      Inner.build", "      Inner."), "analysis_namespace_fixture.cr")
    result = complete(workspace, server, uri, 9, 12)

    # `Inner` names `Outer::Inner` here, and nothing at the top level.
    labels(result).any?(&.starts_with?("build")).should be_true
    labels(result).any?(&.starts_with?("new")).should be_true
    # Answered from the analysis that already existed: had this fallen back to
    # building one, the request would have memoized a compiler result of its own.
    workspace.completion_result_cached?(uri.to_s).should be_false
  end

  it "answers an instance receiver with a declared project type" do
    analyzed = <<-CRYSTAL
    class Widget
      def spin
        "spinning"
      end
    end

    def use(widget : Widget)
      widget.spin
    end

    puts use(Widget.new)
    CRYSTAL

    workspace, server, uri = analyzed_then_typed(
      analyzed, analyzed.sub("  widget.spin", "  widget."), "analysis_instance_fixture.cr")
    result = complete(workspace, server, uri, 7, 9)

    labels(result).any?(&.starts_with?("spin")).should be_true
    # An instance receiver must not be answered with the type's class methods.
    labels(result).any?(&.starts_with?("allocate")).should be_false
    workspace.completion_result_cached?(uri.to_s).should be_false
  end

  it "falls back instead of failing on a receiver no analysis knows" do
    analyzed = <<-CRYSTAL
    value = 1
    puts value
    CRYSTAL

    workspace, server, uri = analyzed_then_typed(
      analyzed, "value = 1\nNeverDefined.\n", "analysis_unknown_fixture.cr")

    # The point is that this answers at all rather than raising out of the
    # request: an unresolvable name is a normal state while typing.
    labels(complete(workspace, server, uri, 1, 13)).should be_empty
  end
end

# Most published shards are libraries: they declare no target, so every file used
# to be analyzed on its own, one file's worth of the project at a time.
describe "Project#entry_point? for a library shard" do
  it "uses the conventional source file when no target is declared" do
    root = File.tempname("crystalline-library-shard")
    Dir.mkdir_p(File.join(root, "src"))
    File.write(File.join(root, "shard.yml"), "name: mylib\nversion: 0.1.0\n")
    File.write(File.join(root, "src", "mylib.cr"), "module Mylib\nend\n")

    project = Crystalline::Project.new(URI.parse(Crystalline::Utils.file_uri(root)))
    entry = project.entry_point?

    entry.should_not be_nil
    File.realpath(entry.not_nil!.decoded_path).should eq(File.realpath(File.join(root, "src", "mylib.cr")))
  ensure
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end

  it "has no entry point when the conventional source file is absent" do
    root = File.tempname("crystalline-no-entry-point")
    Dir.mkdir_p(File.join(root, "src"))
    File.write(File.join(root, "shard.yml"), "name: headless\nversion: 0.1.0\n")

    project = Crystalline::Project.new(URI.parse(Crystalline::Utils.file_uri(root)))
    project.entry_point?.should be_nil
  ensure
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end
end
