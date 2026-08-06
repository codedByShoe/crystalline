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

  it "completes methods on a top-level local receiver" do
    source = <<-CRYSTAL
    name = "something"
    name.
    CRYSTAL

    result, _, _, _ = completion_at(source, 1, 5)
    completion_labels(result).any?(&.starts_with?("upcase")).should be_true
  end

  it "completes methods on a direct string literal" do
    result, _, _, _ = completion_at(%q("something".), 0, 12)
    completion_labels(result).any?(&.starts_with?("upcase")).should be_true
  end

  it "completes project class and instance methods from source" do
    source = <<-CRYSTAL
    class User
      getter name : String

      def initialize(@name : String)
      end

      def self.find(id : Int32)
      end
    end

    User.
    CRYSTAL
    class_result, _, _, _ = completion_at(source, 10, 5, "completion_source_methods_fixture.cr")
    completion_labels(class_result).any?(&.starts_with?("find")).should be_true
    completion_labels(class_result).any?(&.starts_with?("new")).should be_true

    instance_source = source.sub("User.", "user : User = User.new(\"A\")\nuser.")
    instance_result, _, _, _ = completion_at(instance_source, 11, 5, "completion_source_instance_methods_fixture.cr")
    completion_labels(instance_result).should contain("name")
  end

  it "reuses semantic results while the receiver expression is unchanged" do
    source = <<-CRYSTAL
    name = "something"
    name.
    CRYSTAL

    result, workspace, server, uri = completion_at(source, 1, 5, "completion_reuse_fixture.cr")
    completion_labels(result).any?(&.starts_with?("upcase")).should be_true

    workspace.opened_documents[uri.to_s].contents = source.sub("name.", "name.up")
    repeated = Crystalline::SpecSupport.run_with_fake_client(server) do
      workspace.completion(server, uri, LSP::Position.new(line: 1, character: 7), nil)
    end
    completion_labels(repeated).any?(&.starts_with?("upcase")).should be_true
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

  it "completes on the last line of a source the fixer cannot repair" do
    # `BrokenSourceFixer` leaves an unbalanced parenthesis alone. Completion maps
    # the cursor onto the fixed source, so a source coming back one line short
    # used to raise out of the request and answer nothing at all.
    source = "local_value = 42\nfoo(\n\n"

    result, _, _, _ = completion_at(source, 2, 0, "completion_trailing_line_fixture.cr")
    result.should_not be_nil
    completion_labels(result).any?(&.starts_with?("local_value :")).should be_true
  end

  it "drops memoized results when another document changes" do
    source = <<-CRYSTAL
    value = 1
    value.
    CRYSTAL
    workspace, server, uri = Crystalline::SpecSupport.open_document(source, "completion_dependent_fixture.cr")
    first = Crystalline::SpecSupport.run_with_fake_client(server) do
      workspace.completion(server, uri, LSP::Position.new(line: 1, character: 6), ".")
    end
    completion_labels(first).any?(&.starts_with?("bit_length")).should be_true

    other_uri = URI.parse("file:///tmp/completion_dependency_fixture.cr")
    workspace.open_document(LSP::DidOpenTextDocumentParams.new(
      text_document: LSP::TextDocumentItem.new(
        uri: other_uri.to_s,
        language_id: "crystal",
        version: 1,
        text: "class Unrelated\nend\n",
      ),
    ))
    workspace.update_document(server, LSP::DidChangeTextDocumentParams.new(
      text_document: LSP::VersionedTextDocumentIdentifier.new(uri: other_uri.to_s, version: 2),
      content_changes: [
        LSP::DidChangeTextDocumentParams::TextDocumentContentChangeEvent.new(
          range: nil,
          text: "class Unrelated\n  def added_method\n  end\nend\n",
        ),
      ],
    ))

    # The edited document is not the one being completed, so the answer can only
    # be correct if editing it invalidated the memoized result.
    workspace.completion_result_cached?(uri.to_s).should be_false
  end

  it "does not offer named arguments or hash keys as local variables" do
    # The cursor sits on an empty line so that nothing is filtered out by the
    # typed fragment: every candidate the syntax pass produced is visible here.
    source = "real_local = 1\nbuild(config: Config)\noptions = {timeout: Time}\n\n"

    result, _, _, _ = completion_at(source, 3, 0, "completion_noise_fixture.cr")
    labels = completion_labels(result)
    labels.any?(&.starts_with?("real_local ")).should be_true
    labels.any?(&.starts_with?("config ")).should be_false
    labels.any?(&.starts_with?("timeout ")).should be_false
  end

  it "still offers method parameters declared with a type restriction" do
    source = <<-CRYSTAL
    def calculate(input_value : Int32, other : String)
      inp
    end
    CRYSTAL

    result, _, _, _ = completion_at(source, 1, 5, "completion_parameter_fixture.cr")
    completion_labels(result).any?(&.starts_with?("input_value : Int32")).should be_true
  end

  it "completes on a parameter with a type restriction inside an uncalled method" do
    # Nothing calls this method, so the compiler never types its body - but the
    # signature says what the receiver is, which is enough to answer.
    source = <<-CRYSTAL
    class Mailer
      def self.normalize(value : String) : String
        value.
      end
    end
    CRYSTAL

    result, _, _, _ = completion_at(source, 2, 10, "completion_parameter_receiver_fixture.cr")
    completion_labels(result).any?(&.starts_with?("strip")).should be_true
  end

  it "completes in the middle of an existing identifier" do
    # Editing existing code puts the cursor inside a word: `value.|strip`. Only
    # the typed part - here nothing at all - may narrow the candidates, or the
    # word that is about to be replaced filters out every method.
    source = <<-CRYSTAL
    value = "something"
    value.strip
    CRYSTAL

    result, _, _, _ = completion_at(source, 1, 6, "completion_midword_fixture.cr")
    labels = completion_labels(result)
    labels.any?(&.starts_with?("upcase")).should be_true
    labels.any?(&.starts_with?("strip")).should be_true

    # The accepted item still replaces the whole word, not just the prefix.
    item = result.not_nil!.items.find(&.label.starts_with?("upcase")).not_nil!
    edit = item.text_edit.not_nil!
    edit.range.start.character.should eq(6)
    edit.range.end.character.should eq(11)
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
