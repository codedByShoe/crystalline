require "./spec_helper"

private def completion_at(source : String, line : Int32, character : Int32, filename = "completion_fixture.cr")
  workspace, server, uri = Crystalline::SpecSupport.open_document(source, filename)
  result = Crystalline::SpecSupport.run_with_fake_client(server) do
    workspace.completion(server, uri, LSP::Position.new(line: line, character: character), nil)
  end
  {result, workspace, server, uri}
end

private def completion_labels(result : LSP::CompletionList?)
  result.not_nil!.items.map(&.label)
end

describe "Workspace#completion" do
  it "advertises the supported completion triggers" do
    options = Crystalline::SERVER_CAPABILITIES.completion_provider.not_nil!
    options.trigger_characters.should eq([".", ":", "@"])
  end

  it "completes receiver methods without duplicate or compiler-internal candidates" do
    source = <<-CRYSTAL
    class Greeter
      def initialize(@name : String)
      end

      def greeting
        @name.
      end
    end

    puts Greeter.new("World").greeting
    CRYSTAL

    result, _, _, _ = completion_at(source, 5, 10)
    completion_labels(result).any?(&.starts_with?("upcase")).should be_true
    completion_labels(result).should_not contain("initialize_header (bytesize : Int32, length : Int32 = 0)")

    identities = result.not_nil!.items.map { |item| {item.label, item.detail, item.kind, item.text_edit.try(&.new_text)} }
    identities.uniq.size.should eq(identities.size)
  end

  it "completes types inside a namespace" do
    source = <<-CRYSTAL
    module Outer
      class Inner
      end
    end

    Outer::In
    CRYSTAL

    result, _, _, _ = completion_at(source, 5, 9)
    completion_labels(result).should contain("Outer::Inner")
  end

  it "completes a partially typed local variable" do
    source = <<-CRYSTAL
    local_value = 42
    local_val
    CRYSTAL

    result, _, _, _ = completion_at(source, 1, 9)
    completion_labels(result).any?(&.starts_with?("local_value :")).should be_true
    item = result.not_nil!.items.find(&.label.starts_with?("local_value :")).not_nil!
    item.text_edit.not_nil!.new_text.should eq("local_value")
  end

  it "completes locals and arguments inside an instantiated method" do
    source = <<-CRYSTAL
    def calculate(input_value : Int32)
      intermediate = input_value + 1
      inter
    end

    puts calculate(1)
    CRYSTAL

    result, _, _, _ = completion_at(source, 2, 7)
    completion_labels(result).any?(&.starts_with?("intermediate :")).should be_true

    argument_source = source.sub("inter\n", "inp\n")
    argument_result, _, _, _ = completion_at(argument_source, 2, 5, "completion_argument_fixture.cr")
    completion_labels(argument_result).any?(&.starts_with?("input_value :")).should be_true
  end

  it "completes instance variables in an instantiated method" do
    source = <<-CRYSTAL
    class Greeter
      def initialize(@name : String)
      end

      def greeting
        @na
      end
    end

    puts Greeter.new("World").greeting
    CRYSTAL

    result, _, _, _ = completion_at(source, 5, 7)
    completion_labels(result).should contain("@name : String")
  end

  it "completes class variables without duplicating their sigil" do
    source = <<-CRYSTAL
    class Registry
      @@count = 1

      def self.current
        @@cou
      end
    end

    puts Registry.current
    CRYSTAL

    result, _, _, _ = completion_at(source, 4, 9)
    item = result.not_nil!.items.find(&.label.starts_with?("@@count :")).not_nil!
    item.text_edit.not_nil!.new_text.should eq("count")
  end

  it "completes methods on self" do
    source = <<-CRYSTAL
    class Greeter
      def greeting
        "hello"
      end

      def run
        self.gre
      end
    end

    puts Greeter.new.run
    CRYSTAL

    result, _, _, _ = completion_at(source, 6, 12)
    completion_labels(result).any?(&.starts_with?("greeting")).should be_true
  end

  it "does not reuse a regular cached AST for rewritten completion source" do
    original = <<-CRYSTAL
    value = 1
    value.bi
    CRYSTAL
    result, workspace, server, uri = completion_at(original, 1, 8, "completion_cache_fixture.cr")
    completion_labels(result).any?(&.starts_with?("bit_length")).should be_true

    Crystalline::SpecSupport.run_with_fake_client(server) do
      workspace.compile(server, uri, in_memory: true)
    end.should_not be_nil

    workspace.opened_documents[uri.to_s].contents = <<-CRYSTAL
    value = "hello"
    value.up
    CRYSTAL

    changed_result = Crystalline::SpecSupport.run_with_fake_client(server) do
      workspace.completion(server, uri, LSP::Position.new(line: 1, character: 8), nil)
    end
    labels = completion_labels(changed_result)
    labels.any?(&.starts_with?("upcase")).should be_true
    labels.any?(&.starts_with?("bit_length")).should be_false
  end

  it "still completes when a different line is temporarily incomplete" do
    source = <<-CRYSTAL
    class Greeter
      def initialize(@name : String)
      end

      def greeting
        @name.up
      end
    end

    puts Greeter.new("World").greeting
    unfinished =
    CRYSTAL

    result, _, _, _ = completion_at(source, 5, 12)
    completion_labels(result).any?(&.starts_with?("upcase")).should be_true
  end
end
