require "file_utils"
require "./spec_helper"

# Holds the compilation lock for the duration of *block*, the way the project
# wide analysis holds it for the first seconds of a session.
private def while_compiling(&)
  holding = Channel(Nil).new
  release = Channel(Nil).new

  spawn do
    Crystalline::Workspace.compilation_lock.synchronize do
      holding.send(nil)
      release.receive
    end
  end

  holding.receive
  begin
    yield
  ensure
    release.send(nil)
  end
end

# Starts a compilation that ends on its own after *span*, and returns once it is
# under way. Stands in for the ordinary case: something short is already running.
private def compiling_for(span : Time::Span) : Nil
  holding = Channel(Nil).new

  spawn do
    Crystalline::Workspace.compilation_lock.synchronize do
      holding.send(nil)
      sleep span
    end
  end

  holding.receive
end

# Runs *block* on its own fiber and fails rather than hanging if it blocks: the
# regression this guards against is a request that never comes back in time.
private def within(span : Time::Span, &block : -> LSP::CompletionList?) : LSP::CompletionList?
  channel = Channel(LSP::CompletionList? | Exception).new

  spawn do
    channel.send(block.call)
  rescue e
    channel.send(e)
  end

  select
  when reply = channel.receive
    raise reply if reply.is_a?(Exception)
    reply
  when timeout(span)
    fail "the request did not return within #{span}, so it queued behind the running compilation"
  end
end

describe Crystalline::CompilationLock do
  it "reports whether a compilation could be started" do
    lock = Crystalline::CompilationLock.new

    lock.available?.should be_true
    lock.synchronize { lock.available?.should be_false }
    lock.available?.should be_true
  end

  it "waits no longer than it is given for a compilation to finish" do
    lock = Crystalline::CompilationLock.new
    holding = Channel(Nil).new

    spawn do
      lock.synchronize do
        holding.send(nil)
        sleep 5.seconds
      end
    end
    holding.receive

    elapsed = Time.measure { lock.wait_until_available(100.milliseconds).should be_false }
    elapsed.should be < 2.seconds
  end

  it "returns as soon as a compilation finishes rather than on a timer" do
    lock = Crystalline::CompilationLock.new
    holding = Channel(Nil).new

    spawn do
      lock.synchronize do
        holding.send(nil)
        sleep 50.milliseconds
      end
    end
    holding.receive

    elapsed = Time.measure { lock.wait_until_available(10.seconds).should be_true }
    elapsed.should be < 2.seconds
    # And it left the lock behind for whoever asked.
    lock.available?.should be_true
  end

  it "still lets only one compilation run at a time" do
    lock = Crystalline::CompilationLock.new
    order = [] of Int32
    done = Channel(Nil).new

    lock.synchronize do
      spawn do
        lock.synchronize { order << 2 }
        done.send(nil)
      end
      # Give the waiting fiber every chance to run early if it can.
      3.times { Fiber.yield }
      order << 1
    end

    done.receive
    order.should eq([1, 2])
  end

  it "reports a nested compilation instead of deadlocking on one" do
    lock = Crystalline::CompilationLock.new

    expect_raises(Exception, /within a compilation/) do
      lock.synchronize { lock.synchronize { } }
    end

    # The lock is usable again: the failed attempt never took the token.
    lock.available?.should be_true
  end
end

# A session begins with a project wide analysis that takes as long as the
# project is big. Until this, every completion arriving in that window waited it
# out, so the first thing a user typed answered tens of seconds later.
describe "completion while an analysis is running" do
  it "answers instead of queueing behind the compiler" do
    workspace, server, uri = Crystalline::SpecSupport.open_document(
      "x = 1\n\"abc\".\n", "busy_compiler_fixture.cr")

    result = while_compiling do
      within(5.seconds) do
        workspace.completion(server, uri, LSP::Position.new(line: 1, character: 6), ".")
      end
    end

    result.should_not be_nil
    # Nothing to say about a `String` receiver without the compiler, but saying
    # so at once beats saying it once the analysis is over.
    result.not_nil!.items.should be_empty
    # Which is what tells the client to ask again rather than filter this answer
    # locally for the rest of the word being typed.
    result.not_nil!.is_incomplete.should be_true
  end

  it "answers a receiver it can analyze once the compiler is free" do
    workspace, server, uri = Crystalline::SpecSupport.open_document(
      "x = 1\n\"abc\".\n", "free_compiler_fixture.cr")

    result = Crystalline::SpecSupport.run_with_fake_client(server) do
      workspace.completion(server, uri, LSP::Position.new(line: 1, character: 6), ".")
    end

    result.should_not be_nil
    result.not_nil!.items.map(&.label).any?(&.starts_with?("upcase")).should be_true
    result.not_nil!.is_incomplete.should be_false
  end

  it "waits out a compilation that is nearly over rather than giving up on one" do
    # Giving up the moment the compiler is busy would answer nothing here, and
    # a compilation short enough to sit through is the ordinary case: saves and
    # earlier completions run them constantly.
    workspace, server, uri = Crystalline::SpecSupport.open_document(
      "x = 1\n\"abc\".\n", "brief_compiler_fixture.cr")

    compiling_for(200.milliseconds)
    result = Crystalline::SpecSupport.run_with_fake_client(server) do
      workspace.completion(server, uri, LSP::Position.new(line: 1, character: 6), ".")
    end

    result.should_not be_nil
    result.not_nil!.items.map(&.label).any?(&.starts_with?("upcase")).should be_true
    result.not_nil!.is_incomplete.should be_false
  end
end

# An answer built from the syntax index alone is missing everything a type
# inherits or generates. A client told that answer is complete filters it
# locally as the word grows and never asks again, so it keeps the partial answer
# for the rest of the word - long after an analysis could have replaced it.
describe "completion without an analysis to answer from" do
  it "marks a syntax-only answer incomplete" do
    source = <<-CRYSTAL
    class Widget
      def self.build
      end
    end

    Widget.
    CRYSTAL

    workspace, server, uri = Crystalline::SpecSupport.open_document(source, "syntax_only_fixture.cr")
    workspace.analysis_stored?(uri).should be_false

    result = within(5.seconds) do
      workspace.completion(server, uri, LSP::Position.new(line: 5, character: 7), ".")
    end

    result.should_not be_nil
    result.not_nil!.items.map(&.label).any?(&.starts_with?("build")).should be_true
    result.not_nil!.is_incomplete.should be_true
  end

  it "offers what a receiver inherits" do
    source = <<-CRYSTAL
    class Base
      def inherited_method
      end
    end

    class Widget < Base
      def own_method
      end
    end

    widget = Widget.new
    widget.
    CRYSTAL

    workspace, server, uri = Crystalline::SpecSupport.open_document(source, "inheriting_fixture.cr")
    line = source.lines.index("widget.").not_nil!

    result = within(5.seconds) do
      workspace.completion(server, uri, LSP::Position.new(line: line, character: 7), ".")
    end

    labels = result.not_nil!.items.map(&.label)
    labels.any?(&.starts_with?("own_method")).should be_true
    # Which the receiver only responds to because of what it descends from, and
    # which used to need a whole project analysis to know about.
    labels.any?(&.starts_with?("inherited_method")).should be_true
    # Answered from the parse: no analysis existed and no compilation was run.
    workspace.analysis_stored?(uri).should be_false
    workspace.completion_result_cached?(uri.to_s).should be_false
  end

  it "offers a constructor for the initialize a receiver declares" do
    source = <<-CRYSTAL
    class Widget
      def initialize(@name : String)
      end

      def self.described
      end
    end

    Widget.
    CRYSTAL

    workspace, server, uri = Crystalline::SpecSupport.open_document(source, "constructing_fixture.cr")
    line = source.lines.index("Widget.").not_nil!

    result = within(5.seconds) do
      workspace.completion(server, uri, LSP::Position.new(line: line, character: 7), ".")
    end

    labels = result.not_nil!.items.map(&.label)
    labels.any?(&.starts_with?("described")).should be_true
    # `new` is written nowhere in that source. It is what `initialize` means.
    labels.any?(&.starts_with?("new")).should be_true
  end

  it "resolves a receiver against the namespace it is written in" do
    source = <<-CRYSTAL
    module Outer
      class Inner
        def inner_method
        end
      end

      class Other
        def run
          Inner.new.
        end
      end
    end

    class Inner
      def top_level_method
      end
    end
    CRYSTAL

    workspace, server, uri = Crystalline::SpecSupport.open_document(source, "scoped_fixture.cr")
    line = source.lines.index("      Inner.new.").not_nil!

    result = within(5.seconds) do
      workspace.completion(server, uri, LSP::Position.new(line: line, character: 16), ".")
    end

    labels = result.not_nil!.items.map(&.label)
    # `Inner` written inside `Outer` is `Outer::Inner`, never the one beside it.
    labels.any?(&.starts_with?("inner_method")).should be_true
    labels.any?(&.starts_with?("top_level_method")).should be_false
  end
end

describe "Workspace#warm_syntax_index" do
  it "parses the project up front instead of on the first request that needs it" do
    root = File.tempname("crystalline-warm-index")
    Dir.mkdir_p(File.join(root, "src"))
    Dir.mkdir_p(File.join(root, "lib", "other", "src"))
    Dir.mkdir_p(File.join(root, "lib", "other", "spec"))

    File.write(File.join(root, "shard.yml"), "name: warm\nversion: 0.1.0\n")
    main_path = File.join(root, "src", "warm.cr")
    helper_path = File.join(root, "src", "helper.cr")
    shard_path = File.join(root, "lib", "other", "src", "other.cr")
    shard_spec_path = File.join(root, "lib", "other", "spec", "other_spec.cr")
    File.write(main_path, "class Warm\n  def go\n  end\nend\n")
    File.write(helper_path, "module Helper\nend\n")
    File.write(shard_path, "module Other\nend\n")
    File.write(shard_spec_path, "class OtherSpecHelper\nend\n")

    server = Crystalline::SpecSupport.build_server
    workspace = Crystalline::Workspace.new(server, Crystalline::Utils.file_uri(root))

    workspace.syntax_indexed?(main_path).should be_false

    workspace.warm_syntax_index

    workspace.syntax_indexed?(main_path).should be_true
    workspace.syntax_indexed?(helper_path).should be_true
    # Inheritance does not stop at the edge of the project, so neither does the
    # index: what a shard declares is part of what a project type responds to.
    workspace.syntax_indexed?(shard_path).should be_true
    # Only each shard's `src` though. What its own specs declare is nobody's
    # business to offer as a completion.
    workspace.syntax_indexed?(shard_spec_path).should be_false
  ensure
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end

  it "indexes what it can when a file cannot be parsed" do
    root = File.tempname("crystalline-warm-index-broken")
    Dir.mkdir_p(File.join(root, "src"))

    File.write(File.join(root, "shard.yml"), "name: warm_broken\nversion: 0.1.0\n")
    good_path = File.join(root, "src", "good.cr")
    File.write(good_path, "class Good\nend\n")
    File.write(File.join(root, "src", "broken.cr"), "class Broken\n  def (((\n")

    server = Crystalline::SpecSupport.build_server
    workspace = Crystalline::Workspace.new(server, Crystalline::Utils.file_uri(root))

    workspace.warm_syntax_index

    workspace.syntax_indexed?(good_path).should be_true
  ensure
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end
end
