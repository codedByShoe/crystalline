require "uri"
require "./project"

class Crystalline::TextDocument
  getter uri : URI
  @inner_contents : Array(String) = [] of String
  getter version : Int32?
  getter? project : Project?

  def initialize(@uri, @project, contents : String, @version : Int32? = nil)
    self.contents = contents
  end

  def contents=(contents : String)
    @inner_contents = contents.lines(chomp: false)
  end

  def contents : String
    @inner_contents.join
  end

  def lines_nb : Int32
    @inner_contents.size
  end

  def eof_position : LSP::Position
    if (last_line = @inner_contents.last?)
      if last_line.ends_with?("\n")
        LSP::Position.new(line: @inner_contents.size, character: 0)
      else
        LSP::Position.new(line: @inner_contents.size - 1, character: last_line.size)
      end
    else
      LSP::Position.new(line: 0, character: 0)
    end
  end

  def update_contents(content_changes : Array({String, LSP::Range?}), version : Int32? = nil)
    content_changes.each { |change|
      update_contents(*change, version: version)
    }
  end

  private def update_contents(contents : String, range : LSP::Range? = nil, version : Int32? = nil)
    if range
      # Incremental update
      partial_update(contents, range, version) unless superseded?(version)
    else
      # Full update
      full_update(contents, version)
    end
  end

  # The protocol only promises that document versions increase, never that they
  # increase one at a time: neovim numbers its changes with the buffer's
  # changedtick, so `didOpen` at version 0 is routinely followed by a change at
  # version 4. Requiring consecutive versions drops that change - and with it
  # every later one, since the document version then never advances again -
  # leaving the server working from the text as it was when the file was opened.
  #
  # Notifications arrive in order on a single connection, so the only version
  # worth refusing is one that moves backwards.
  private def superseded?(version : Int32?) : Bool
    current = @version
    return false unless current && version
    version < current
  end

  private def partial_update(contents : String, range : LSP::Range, version : Int32? = nil)
    prefix = @inner_contents[range.start.line]?.try &.[...range.start.character] || ""
    suffix = @inner_contents[range.end.line]?.try &.[range.end.character..]? || @inner_contents[range.end.line]? || ""
    replacement_lines = String.build { |str|
      str << prefix << contents << suffix
    }.lines(chomp: false)
    @inner_contents = (@inner_contents[...range.start.line]? || [] of String) + replacement_lines + (@inner_contents[range.end.line + 1...]? || [] of String)
    @version = version if version
  end

  private def full_update(contents : String, version : Int32? = nil)
    self.contents = contents
    @version = version if version
  end
end
