require "./spec_helper"

private def references_for(source : String, line : Int32, character : Int32, *, include_declaration = false)
  workspace, server, uri = Crystalline::SpecSupport.open_document(source)
  params = LSP::ReferenceParams.new(
    text_document: LSP::TextDocumentIdentifier.new(uri: uri.to_s),
    position: LSP::Position.new(line: line, character: character),
    context: LSP::ReferenceContext.new(include_declaration: include_declaration),
  )

  Crystalline::SpecSupport.run_with_fake_client(server) do
    workspace.references(server, params)
  end
end

private def reference_ranges(locations : Array(LSP::Location)?)
  locations.not_nil!.map do |location|
    range = location.range
    {range.start.line, range.start.character, range.end.line, range.end.character}
  end.sort
end

describe "Workspace#references" do
  it "finds calls to the selected method and optionally includes its declaration" do
    source = <<-CRYSTAL
    def greet(name : String)
      "Hello, \#{name}"
    end

    greet("one")
    greet("two")
    CRYSTAL

    reference_ranges(references_for(source, 4, 2)).should eq([
      {4, 0, 4, 5},
      {5, 0, 5, 5},
    ])

    reference_ranges(references_for(source, 4, 2, include_declaration: true)).should eq([
      {0, 4, 0, 9},
      {4, 0, 4, 5},
      {5, 0, 5, 5},
    ])

    # The declaration resolves to the same symbol as either call site.
    reference_ranges(references_for(source, 0, 6)).should eq([
      {4, 0, 4, 5},
      {5, 0, 5, 5},
    ])
  end

  it "finds references to a local variable without leaking across methods" do
    source = <<-CRYSTAL
    def calculate(value)
      doubled = value * 2
      doubled + value
    end

    def unrelated
      doubled = 10
      doubled
    end

    calculate(3)
    unrelated
    CRYSTAL

    reference_ranges(references_for(source, 2, 2)).should eq([
      {2, 2, 2, 9},
    ])

    reference_ranges(references_for(source, 2, 2, include_declaration: true)).should eq([
      {1, 2, 1, 9},
      {2, 2, 2, 9},
    ])
  end

  it "distinguishes method overloads by their resolved declaration" do
    source = <<-CRYSTAL
    def convert(value : Int32)
      value.to_s
    end

    def convert(value : String)
      value
    end

    convert(1)
    convert("one")
    CRYSTAL

    reference_ranges(references_for(source, 8, 2, include_declaration: true)).should eq([
      {0, 4, 0, 11},
      {8, 0, 8, 7},
    ])
  end

  it "finds references to a resolved type" do
    source = <<-CRYSTAL
    class Widget
    end

    Widget.new
    Widget.new
    CRYSTAL

    reference_ranges(references_for(source, 3, 2)).should eq([
      {3, 0, 3, 6},
      {4, 0, 4, 6},
    ])

    reference_ranges(references_for(source, 3, 2, include_declaration: true)).should eq([
      {0, 6, 0, 12},
      {3, 0, 3, 6},
      {4, 0, 4, 6},
    ])

    reference_ranges(references_for(source, 0, 8)).should eq([
      {3, 0, 3, 6},
      {4, 0, 4, 6},
    ])
  end

  it "finds instance-variable references through their owning type" do
    source = <<-CRYSTAL
    class Counter
      def initialize(@value : Int32)
      end

      def read
        @value
      end
    end

    Counter.new(1).read
    CRYSTAL

    reference_ranges(references_for(source, 5, 6)).should eq([
      {5, 4, 5, 10},
    ])

    reference_ranges(references_for(source, 5, 6, include_declaration: true)).should eq([
      {1, 17, 1, 23},
      {5, 4, 5, 10},
    ])
  end

  it "finds class-variable references without confusing methods at the same location" do
    source = <<-CRYSTAL
    class Registry
      @@items = 0

      def self.items
        @@items
      end
    end

    Registry.items
    CRYSTAL

    reference_ranges(references_for(source, 4, 6)).should eq([
      {4, 4, 4, 11},
    ])

    reference_ranges(references_for(source, 4, 6, include_declaration: true)).should eq([
      {1, 2, 1, 9},
      {4, 4, 4, 11},
    ])
  end

  it "returns nil when there is no resolvable symbol at the cursor" do
    source = "1 + 2\n"
    references_for(source, 0, 0).should be_nil
  end
end

describe "Workspace#document_highlights" do
  it "uses the references analysis and limits results to the current document" do
    source = <<-CRYSTAL
    def greet
    end

    greet
    greet
    CRYSTAL
    workspace, server, uri = Crystalline::SpecSupport.open_document(source)
    params = LSP::DocumentHighlightParams.new(
      text_document: LSP::TextDocumentIdentifier.new(uri: uri.to_s),
      position: LSP::Position.new(line: 3, character: 2),
    )

    highlights = Crystalline::SpecSupport.run_with_fake_client(server) do
      workspace.document_highlights(server, params)
    end.not_nil!

    highlights.map(&.range.start.line).sort.should eq([0, 3, 4])
    highlights.each(&.kind.should(eq(LSP::DocumentHighlightKind::Text)))
  end
end
