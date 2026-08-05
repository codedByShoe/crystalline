require "./spec_helper"

describe "Workspace#signature_help" do
  it "lists every overload and picks the active one by argument count" do
    source = <<-CRYSTAL
    def greet(name : String)
      "Hello, \#{name}!"
    end

    def greet(name : String, loud : Bool)
      loud ? "HELLO, \#{name}!" : "Hello, \#{name}!"
    end

    greet("World", true)
    CRYSTAL

    workspace, server, uri = Crystalline::SpecSupport.open_document(source)

    call_line = source.lines.index(&.starts_with?("greet(")).not_nil!
    # Cursor right after the comma (before "true"), i.e. inside the second argument slot.
    cursor_character = source.lines[call_line].index(", ").not_nil! + 1

    result = Crystalline::SpecSupport.run_with_fake_client(server) do
      workspace.signature_help(server, uri, LSP::Position.new(line: call_line, character: cursor_character))
    end

    result.should_not be_nil
    help = result.not_nil!

    # Lists both overloads sharing the `greet` name, not just the one the
    # compiler matched for this specific call.
    help.signatures.size.should eq(2)
    help.signatures.map(&.label).should contain("greet (name : String)")
    help.signatures.map(&.label).should contain("greet (name : String, loud : Bool)")
    help.active_parameter.should eq(1)
    # The 2-argument overload is the one actually matched for this call.
    help.signatures[help.active_signature.not_nil!].label.should eq("greet (name : String, loud : Bool)")
  end

  it "returns nil outside of a call" do
    source = <<-CRYSTAL
    x = 1
    CRYSTAL

    workspace, server, uri = Crystalline::SpecSupport.open_document(source)

    result = Crystalline::SpecSupport.run_with_fake_client(server) do
      workspace.signature_help(server, uri, LSP::Position.new(line: 0, character: 1))
    end

    result.should be_nil
  end
end
