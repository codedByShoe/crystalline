require "./spec_helper"

private def hints_for(source : String, from = 0, to = 9999) : Array(LSP::InlayHint)
  workspace, _server, uri = Crystalline::SpecSupport.open_document(source, "inlay_hints_fixture.cr")
  workspace.inlay_hints(LSP::InlayHintParams.new(
    text_document: LSP::TextDocumentIdentifier.new(uri: uri.to_s),
    range: LSP::Range.new(
      start: LSP::Position.new(line: from, character: 0),
      end: LSP::Position.new(line: to, character: 0),
    ),
  )) || [] of LSP::InlayHint
end

# Draws the hints back into the source, the way the editor does, so that what a
# spec expects is what a person would see.
private def drawn(source : String) : String
  lines = source.lines(chomp: false)
  hints = hints_for(source).sort_by { |hint| {-hint.position.line, -hint.position.character} }

  hints.each do |hint|
    line = lines[hint.position.line]
    character = hint.position.character
    label = hint.padding_right ? "#{hint.label} " : hint.label
    lines[hint.position.line] = line[0...character] + label + line[character..]
  end

  lines.join
end

describe "inlay hints" do
  describe "the type of a local" do
    it "names what a literal is" do
      source = <<-CRYSTAL
      count = 5
      name = "hello"
      ratio = 1.5
      flag = true
      letter = 'x'
      tag = :done

      CRYSTAL

      drawn(source).should eq <<-CRYSTAL
      count: Int32 = 5
      name: String = "hello"
      ratio: Float64 = 1.5
      flag: Bool = true
      letter: Char = 'x'
      tag: Symbol = :done

      CRYSTAL
    end

    it "says nothing where the type is already written" do
      source = "typed : Int32 = 7\n"

      drawn(source).should eq(source)
    end

    it "names each target of a multiple assignment" do
      source = <<-CRYSTAL
      count, name = 5, "five"

      CRYSTAL

      drawn(source).should eq <<-CRYSTAL
      count: Int32, name: String = 5, "five"

      CRYSTAL
    end

    it "stays quiet when a multiple assignment unpacks a single value" do
      source = <<-CRYSTAL
      pair = {1, "one"}
      count, name = pair

      CRYSTAL

      drawn(source).should eq <<-CRYSTAL
      pair: Tuple = {1, "one"}
      count, name = pair

      CRYSTAL
    end

    it "names what was constructed, qualified as it resolves" do
      source = <<-CRYSTAL
      module Outer
        class Widget
        end

        class Other
          def run
            made = Widget.new
          end
        end
      end

      CRYSTAL

      drawn(source).should contain("made: Outer::Widget = Widget.new")
    end

    it "names a declared return type" do
      source = <<-CRYSTAL
      class Widget
        def self.build : Array(String)
          [] of String
        end

        def run
          result = Widget.build
        end
      end

      CRYSTAL

      drawn(source).should contain("result: Array(String) = Widget.build")
    end

    it "says nothing about a call whose return type is not written down" do
      source = <<-CRYSTAL
      class Widget
        def self.build
          new
        end

        def run
          result = Widget.build
        end
      end

      CRYSTAL

      # Inferring it is the compiler's job, and guessing would be drawn as fact.
      drawn(source).should eq(source)
    end

    it "names a constructed type it cannot place, as written" do
      # `.new` on a name yields an instance of that name whether or not the
      # index has heard of it, which is the only reason this works for the
      # standard library at all.
      drawn("buffer = IO::Memory.new\n").should eq("buffer: IO::Memory = IO::Memory.new\n")
    end
  end

  describe "the parameter an argument is passed as" do
    it "names the parameters of a call within the same type" do
      source = <<-CRYSTAL
      class Widget
        def resize(width : Int32, height : Int32)
        end

        def run
          resize(10, 20)
        end
      end

      CRYSTAL

      drawn(source).should contain("resize(width: 10, height: 20)")
    end

    it "names the parameters of a constructor" do
      source = <<-CRYSTAL
      class Widget
        def initialize(@label : String, @size : Int32)
        end
      end

      made = Widget.new("box", 3)

      CRYSTAL

      drawn(source).should contain(%(Widget.new(label: "box", size: 3)))
    end

    it "names the parameters of a call on a local whose type it knows" do
      source = <<-CRYSTAL
      class Widget
        def resize(width : Int32)
        end
      end

      class Other
        def run(widget : Widget)
          widget.resize(10)
        end
      end

      CRYSTAL

      drawn(source).should contain("widget.resize(width: 10)")
    end

    it "says nothing twice" do
      source = <<-CRYSTAL
      class Widget
        def resize(width : Int32)
        end

        def run
          width = 4
          resize(width)
        end
      end

      CRYSTAL

      # The argument already reads as the parameter name.
      drawn(source).should contain("resize(width)")
    end

    it "leaves operators alone" do
      source = <<-CRYSTAL
      class Widget
        def +(other : Widget)
        end

        def run(a : Widget, b : Widget)
          a + b
        end
      end

      CRYSTAL

      drawn(source).should contain("a + b")
    end

    it "stays quiet when overloads disagree about what they call things" do
      source = <<-CRYSTAL
      class Widget
        def draw(width : Int32)
        end

        def draw(height : String)
        end

        def run
          draw(10)
        end
      end

      CRYSTAL

      # Two candidates fit and they do not agree, so there is no one answer.
      drawn(source).should contain("draw(10)")
    end

    it "stays quiet once a splat makes position meaningless" do
      source = <<-CRYSTAL
      class Widget
        def log(level : String, *rest)
        end

        def run
          log("warn", 1, 2)
        end
      end

      CRYSTAL

      drawn(source).should contain(%(log("warn", 1, 2)))
    end

    it "says nothing about a method it cannot find" do
      source = <<-CRYSTAL
      class Widget
        def run
          undeclared(1, 2)
        end
      end

      CRYSTAL

      drawn(source).should eq(source)
    end
  end

  it "answers only for the range the client asked about" do
    source = <<-CRYSTAL
    first = 1
    second = 2
    third = 3

    CRYSTAL

    labels = hints_for(source, from: 1, to: 1).map(&.label)

    labels.should eq([": Int32"])
  end

  it "kinds a type hint and a parameter hint differently" do
    source = <<-CRYSTAL
    class Widget
      def resize(width : Int32)
      end

      def run
        size = 4
        resize(size)
      end
    end

    CRYSTAL

    hints = hints_for(source)

    hints.find(&.label.==(": Int32")).not_nil!.kind.should eq(LSP::InlayHintKind::Type)
    hints.find(&.label.==("width:")).not_nil!.kind.should eq(LSP::InlayHintKind::Parameter)
  end
end
