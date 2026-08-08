require "./spec_helper"

# Opens every file of *files* as an in-memory document of one workspace, so
# the parse index sees them all as the project.
private def open_workspace(files : Hash(String, String)) : {Crystalline::Workspace, LSP::Server}
  server = Crystalline::SpecSupport.build_server
  workspace = Crystalline::Workspace.new(server, nil)

  files.each do |name, text|
    workspace.open_document(LSP::DidOpenTextDocumentParams.new(
      text_document: LSP::TextDocumentItem.new(
        uri: "file:///tmp/#{name}",
        language_id: "crystal",
        version: 1,
        text: text,
      ),
    ))
  end

  {workspace, server}
end

private def syntax_definitions_at(workspace : Crystalline::Workspace, file : String, line : Int32, character : Int32) : Array(LSP::Location)?
  workspace.syntax_definitions(
    URI.parse("file:///tmp/#{file}"),
    LSP::Position.new(line: line, character: character),
  )
end

private NEWS_SOURCE = <<-CRYSTAL
module News
  class Article
    def title
      "t"
    end
  end
end
CRYSTAL

describe "Workspace#syntax_definitions" do
  it "finds a type declared in another file" do
    workspace, _server = open_workspace({
      "widgets.cr" => "class Widget\n  def render\n  end\nend\n",
      "app.cr"     => "w = Widget.new\n",
    })

    locations = syntax_definitions_at(workspace, "app.cr", 0, 5).not_nil!
    locations.size.should eq(1)
    locations.first.uri.should eq("file:///tmp/widgets.cr")
    locations.first.range.start.line.should eq(0)
  end

  it "resolves the path segment the cursor is on, not the whole path" do
    workspace, _server = open_workspace({
      "news.cr" => NEWS_SOURCE,
      "use.cr"  => "a = News::Article.new\n",
    })

    on_news = syntax_definitions_at(workspace, "use.cr", 0, 5).not_nil!
    on_news.first.uri.should eq("file:///tmp/news.cr")
    on_news.first.range.start.line.should eq(0)

    on_article = syntax_definitions_at(workspace, "use.cr", 0, 12).not_nil!
    on_article.first.range.start.line.should eq(1)
  end

  it "answers `.new` with the type it constructs" do
    workspace, _server = open_workspace({
      "news.cr" => NEWS_SOURCE,
      "use.cr"  => "a = News::Article.new\n",
    })

    locations = syntax_definitions_at(workspace, "use.cr", 0, 19).not_nil!
    locations.first.uri.should eq("file:///tmp/news.cr")
    locations.first.range.start.line.should eq(1)
  end

  it "finds a method through a receiver whose type the source spells out" do
    workspace, _server = open_workspace({
      "news.cr" => NEWS_SOURCE,
      "use.cr"  => "def show(article : News::Article)\n  article.title\nend\n",
    })

    locations = syntax_definitions_at(workspace, "use.cr", 1, 11).not_nil!
    locations.first.uri.should eq("file:///tmp/news.cr")
    locations.first.range.start.line.should eq(2)
  end

  it "finds constants and enum members" do
    workspace, _server = open_workspace({
      "config.cr" => "module Config\n  TIMEOUT = 5\nend\nenum Color\n  Red\n  Green\nend\n",
      "use.cr"    => "x = Config::TIMEOUT\ny = Color::Red\n",
    })

    on_timeout = syntax_definitions_at(workspace, "use.cr", 0, 14).not_nil!
    on_timeout.first.uri.should eq("file:///tmp/config.cr")
    on_timeout.first.range.start.line.should eq(1)

    on_red = syntax_definitions_at(workspace, "use.cr", 1, 12).not_nil!
    on_red.first.range.start.line.should eq(4)
  end

  it "reaches a private method through a bare call, and answers nothing for the unknown" do
    workspace, _server = open_workspace({
      "calc.cr" => <<-CRYSTAL,
      class Calculator
        def compute
          helper_value
        end

        private def helper_value
          1
        end
      end
      CRYSTAL
    })

    locations = syntax_definitions_at(workspace, "calc.cr", 2, 6).not_nil!
    locations.first.range.start.line.should eq(5)

    syntax_definitions_at(workspace, "calc.cr", 2, 0).should be_nil
    syntax_definitions_at(workspace, "calc.cr", 3, 2).should be_nil # `end` is a keyword
  end
end

describe "Workspace#definitions" do
  it "falls back to the parse index inside a method the compiler never types" do
    source = <<-CRYSTAL
    class Calculator
      def compute
        helper_value
      end

      private def helper_value
        1
      end
    end

    CRYSTAL

    workspace, server, uri = Crystalline::SpecSupport.open_document(source, "unreached_definition_fixture.cr")
    locations = Crystalline::SpecSupport.run_with_fake_client(server) do
      workspace.definitions(server, uri, LSP::Position.new(line: 2, character: 6))
    end

    # `Calculator` is never instantiated, so `compute` is never typed and the
    # compiler has nothing to say about the call - the parse index does.
    locations.should_not be_nil
    location = locations.not_nil!.first.as(LSP::Location)
    location.range.start.line.should eq(5)
  end
end
