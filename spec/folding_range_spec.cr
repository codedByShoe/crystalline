require "./spec_helper"

describe "folding ranges" do
  it "collects nested multiline declarations and control flow" do
    source = <<-CRYSTAL
    class Widget
      def render(enabled)
        if enabled
          2.times do
            puts "enabled"
          end
        end
      end
    end
    CRYSTAL

    parser = Crystal::Parser.new(source)
    ranges = Crystalline::Analysis::FoldingRangeVisitor.new.tap { |visitor|
      parser.parse.accept(visitor)
    }.ranges

    ranges.map { |range| {range.start_line, range.end_line} }.should eq([
      {0, 8},
      {1, 7},
      {2, 6},
      {3, 5},
    ])
  end

  it "covers other multiline syntax and skips single-line constructs" do
    source = <<-CRYSTAL
    module Example
      enum State
        Ready
        Done
      end

      while running?
        tick
      end

      value = 1 if enabled?
    end
    CRYSTAL

    parser = Crystal::Parser.new(source)
    ranges = Crystalline::Analysis::FoldingRangeVisitor.new.tap { |visitor|
      parser.parse.accept(visitor)
    }.ranges

    ranges.map { |range| {range.start_line, range.end_line} }.should eq([
      {0, 11},
      {1, 4},
      {6, 8},
    ])
  end

  it "serves ranges from an open workspace document" do
    source = <<-CRYSTAL
    def greet
      puts "hello"
    end
    CRYSTAL
    workspace, _server, uri = Crystalline::SpecSupport.open_document(source)
    params = LSP::FoldingRangeParams.new(
      text_document: LSP::TextDocumentIdentifier.new(uri: uri.to_s),
    )

    ranges = workspace.folding_ranges(params)

    ranges.should_not be_nil
    ranges.not_nil!.map { |range| {range.start_line, range.end_line} }.should eq([{0, 2}])
  end

  it "folds explicit exception handlers without synthetic duplicates" do
    source = <<-CRYSTAL
    begin
      risky_operation
    rescue
      recover
    end
    CRYSTAL

    parser = Crystal::Parser.new(source)
    ranges = Crystalline::Analysis::FoldingRangeVisitor.new.tap { |visitor|
      parser.parse.accept(visitor)
    }.ranges

    ranges.map { |range| {range.start_line, range.end_line} }.should eq([{0, 4}])
  end

  it "advertises folding range support" do
    Crystalline::SERVER_CAPABILITIES.folding_range_provider.should eq(true)
  end
end
