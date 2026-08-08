require "file_utils"
require "./spec_helper"

private def with_project(&)
  root = File.tempname("crystalline-index")
  Dir.mkdir_p(File.join(root, "src"))
  Dir.mkdir_p(File.join(root, "lib", "dep", "src"))
  File.write(File.join(root, "shard.yml"), "name: indexed\nversion: 0.1.0\n")
  yield root
ensure
  FileUtils.rm_r(root) if root && Dir.exists?(root)
end

private def index_for(root : String) : Crystalline::Index
  Crystalline::Index.new(Crystalline::Project.find_in_workspace_root(URI.parse(Crystalline::Utils.file_uri(root))))
end

private def type_names(entries)
  entries.flat_map(&.types).map(&.[0])
end

describe Crystalline::Index do
  it "reuses a parse for as long as the stamp says the contents are the same" do
    index = Crystalline::Index.new([] of Crystalline::Project)

    index.entry_for("/tmp/x.cr", "class First\nend\n", stamp: "s")
    # The stamp decides what is current, not the source handed over with it -
    # that is what makes it safe to skip reading the file at all.
    reused = index.entry_for("/tmp/x.cr", "class Second\nend\n", stamp: "s")
    reused.types.map(&.[0]).should eq(["First"])

    fresh = index.entry_for("/tmp/x.cr", "class Second\nend\n", stamp: "t")
    fresh.types.map(&.[0]).should eq(["Second"])
  end

  it "indexes a buffer that is mid-edit" do
    # Which is the state every buffer being typed in is, and the state the
    # index is most worth having in.
    index = Crystalline::Index.new([] of Crystalline::Project)

    entry = index.entry_for("/tmp/halfway.cr", "class Halfway\n  def in_progress\n", stamp: "s")

    entry.types.map(&.[0]).should eq(["Halfway"])
  end

  it "raises rather than guess at source the repair pass cannot fix" do
    # Every caller indexes file by file and rescues around each one, so a file
    # this broken costs its own entry and nothing else.
    index = Crystalline::Index.new([] of Crystalline::Project)

    expect_raises(Crystal::SyntaxException) do
      index.entry_for("/tmp/hopeless.cr", "class Hopeless\n  def oops(\n", stamp: "s")
    end
  end

  it "prefers an opened buffer to what is on disk" do
    with_project do |root|
      path = File.join(root, "src", "thing.cr")
      File.write(path, "class OnDisk\nend\n")
      index = index_for(root)
      uri = URI.parse(Crystalline::Utils.file_uri(path))

      type_names(index.project_entries(uri, {} of String => String)).should eq(["OnDisk"])

      buffers = {Path[path].normalize.to_s => "class InBuffer\nend\n"}
      type_names(index.project_entries(uri, buffers)).should eq(["InBuffer"])
    end
  end

  it "prefers the source a request rewrote to the buffer it came from" do
    with_project do |root|
      path = File.join(root, "src", "thing.cr")
      File.write(path, "class OnDisk\nend\n")
      index = index_for(root)
      uri = URI.parse(Crystalline::Utils.file_uri(path))
      buffers = {Path[path].normalize.to_s => "class InBuffer\nend\n"}

      entries = index.project_entries(uri, buffers, current_source: "class Rewritten\nend\n")

      type_names(entries).should eq(["Rewritten"])
    end
  end

  it "lists only project source as the workspace's own symbols" do
    with_project do |root|
      File.write(File.join(root, "src", "own.cr"), "class Own\nend\n")
      File.write(File.join(root, "lib", "dep", "src", "dep.cr"), "class Dep\nend\n")
      index = index_for(root)

      # A symbol search is asking what *this* workspace contains. Answering it
      # with every type in every dependency would bury that.
      files = index.all_files([] of String).map { |path| File.basename(path) }

      files.should contain("own.cr")
      files.should_not contain("dep.cr")
    end
  end

  it "reads shard source when resolving a name" do
    with_project do |root|
      own = File.join(root, "src", "own.cr")
      File.write(own, "class Own\nend\n")
      File.write(File.join(root, "lib", "dep", "src", "dep.cr"), "class Dep\nend\n")
      index = index_for(root)

      # The other half of the same boundary: what a name means, and what a type
      # inherits, both run through the shards a project depends on.
      entries = index.project_entries(URI.parse(Crystalline::Utils.file_uri(own)), {} of String => String)

      type_names(entries).should contain("Own")
      type_names(entries).should contain("Dep")
    end
  end

  it "reuses a shard parse rather than restamping it on every request" do
    with_project do |root|
      own = File.join(root, "src", "own.cr")
      shard = File.join(root, "lib", "dep", "src", "dep.cr")
      File.write(own, "class Own\nend\n")
      File.write(shard, "class Dep\nend\n")
      index = index_for(root)
      uri = URI.parse(Crystalline::Utils.file_uri(own))

      index.project_entries(uri, {} of String => String)
      # Shards do not change while a session is open, so a later request must
      # not go back to the filesystem for them - a few hundred `stat` calls per
      # keystroke is the cost this avoids. Deleting one proves it never looked.
      File.delete(shard)

      type_names(index.project_entries(uri, {} of String => String)).should contain("Dep")
    end
  end

  it "falls back to the opened files when there is no project" do
    index = Crystalline::Index.new([] of Crystalline::Project)

    index.all_files(["/tmp/loose.cr"]).should eq(["/tmp/loose.cr"])
  end
end
