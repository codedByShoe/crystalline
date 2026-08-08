require "./spec_helper"

private def declarations_for(source : String) : Crystalline::Analysis::Declarations
  parser = Crystal::Parser.new(source)
  parser.filename = "/tmp/declarations_fixture.cr"
  parser.wants_doc = true
  visitor = Crystalline::Analysis::DeclarationsVisitor.new
  parser.parse.accept(visitor)
  visitor.declarations
end

private def type_named(declarations, fqn : String)
  declarations.types.find(&.fqn.==(fqn)).should_not be_nil
end

private def method_named(declarations, owner : String, name : String)
  declarations.methods.find { |m| m.owner == owner && m.name == name }.should_not be_nil
end

describe Crystalline::Analysis::DeclarationsVisitor do
  describe "the scope a declaration is written in" do
    it "qualifies a type by the types enclosing it" do
      declarations = declarations_for <<-CRYSTAL
      module Outer
        class Inner
        end
      end
      CRYSTAL

      inner = type_named(declarations, "Outer::Inner").not_nil!
      inner.name.should eq("Inner")
      inner.namespace.should eq(["Outer"])
      inner.kind.class?.should be_true
    end

    it "reads a compound name as the namespaces it names" do
      declarations = declarations_for <<-CRYSTAL
      class Outer::Inner
        def go
        end
      end
      CRYSTAL

      inner = type_named(declarations, "Outer::Inner").not_nil!
      inner.namespace.should eq(["Outer"])
      # And what is written inside it belongs to all of it, not to the last
      # segment alone.
      method_named(declarations, "Outer::Inner", "go")
    end

    it "reads a compound name written inside another scope" do
      declarations = declarations_for <<-CRYSTAL
      module Top
        class Middle::Bottom
          def go
          end
        end
      end
      CRYSTAL

      type_named(declarations, "Top::Middle::Bottom")
      method_named(declarations, "Top::Middle::Bottom", "go")
    end

    it "puts a globally named type at the top level and leaves the scope intact" do
      declarations = declarations_for <<-CRYSTAL
      module Outer
        class ::Free
        end

        class Bound
        end
      end
      CRYSTAL

      free = type_named(declarations, "Free").not_nil!
      free.namespace.should be_empty
      # The scope `Free` interrupted has to come back, or everything declared
      # after it lands in the wrong place.
      type_named(declarations, "Outer::Bound")
    end

    it "restores the scope after each of a run of sibling types" do
      declarations = declarations_for <<-CRYSTAL
      module A
        class One
        end
        class Two
        end
        module B
          class Three
          end
        end
        class Four
        end
      end
      CRYSTAL

      declarations.types.map(&.fqn).should eq(
        ["A", "A::One", "A::Two", "A::B", "A::B::Three", "A::Four"])
    end
  end

  describe "what a type says about itself" do
    it "records a superclass as written, not resolved" do
      declarations = declarations_for <<-CRYSTAL
      module Outer
        class Inner < Base
        end
      end
      CRYSTAL

      inner = type_named(declarations, "Outer::Inner").not_nil!
      # `Base` here may mean `Outer::Base` or `::Base`. Recording the text and
      # the scope leaves that for whoever can answer it.
      inner.superclass.should eq("Base")
      inner.namespace.should eq(["Outer"])
    end

    it "records mixins against the type that mixes them in" do
      declarations = declarations_for <<-CRYSTAL
      class Widget
        include Enumerable(String)
        include Comparable
        extend Forwardable
      end
      CRYSTAL

      widget = type_named(declarations, "Widget").not_nil!
      widget.includes.should eq(["Enumerable(String)", "Comparable"])
      widget.extends.should eq(["Forwardable"])
    end

    it "tells a struct from a class and records type variables" do
      declarations = declarations_for <<-CRYSTAL
      struct Pair(A, B)
      end

      module Holder(T)
      end
      CRYSTAL

      type_named(declarations, "Pair").not_nil!.kind.struct?.should be_true
      type_named(declarations, "Pair").not_nil!.type_vars.should eq(["A", "B"])
      type_named(declarations, "Holder").not_nil!.kind.module?.should be_true
      type_named(declarations, "Holder").not_nil!.type_vars.should eq(["T"])
    end

    it "records enums, libs, annotations and aliases" do
      declarations = declarations_for <<-CRYSTAL
      enum Color
        Red
        Green = 2
      end

      lib LibFoo
      end

      annotation Marker
      end

      alias Names = Array(String)
      CRYSTAL

      type_named(declarations, "Color").not_nil!.kind.enum?.should be_true
      type_named(declarations, "LibFoo").not_nil!.kind.lib?.should be_true
      type_named(declarations, "Marker").not_nil!.kind.annotation?.should be_true

      names = type_named(declarations, "Names").not_nil!
      names.kind.alias?.should be_true
      names.superclass.should eq("Array(String)")

      declarations.constants.map(&.fqn).should contain("Color::Red")
      declarations.constants.find(&.fqn.==("Color::Green")).not_nil!.value.should eq("2")
    end
  end

  describe "what a type responds to" do
    it "records a method with its parameters as written" do
      declarations = declarations_for <<-CRYSTAL
      class Widget
        def resize(width : Int32, height = 10, *rest, **options, &block) : Nil
        end
      end
      CRYSTAL

      resize = method_named(declarations, "Widget", "resize").not_nil!
      resize.class_method.should be_false
      resize.return_type.should eq("Nil")
      resize.params.map(&.name).should eq(["width", "height", "rest", "options", "block"])
      resize.params[0].restriction.should eq("Int32")
      resize.params[1].default_value.should eq("10")
      resize.params[2].splat.should be_true
      resize.params[3].double_splat.should be_true
      resize.params[4].block.should be_true
    end

    it "tells a class method from an instance method and keeps visibility" do
      declarations = declarations_for <<-CRYSTAL
      class Widget
        def self.build
        end

        private def internal
        end
      end
      CRYSTAL

      method_named(declarations, "Widget", "build").not_nil!.class_method.should be_true
      method_named(declarations, "Widget", "internal").not_nil!.visibility.private?.should be_true
      # Kept rather than dropped: a private method is still worth offering
      # inside the type that declares it.
      method_named(declarations, "Widget", "build").not_nil!.visibility.public?.should be_true
    end

    it "records the accessors a macro declares" do
      declarations = declarations_for <<-CRYSTAL
      class Widget
        getter name : String
        setter label : String
        property size : Int32
        getter? enabled : Bool
        class_property registry : Array(String)
        getter :legacy
        getter counted = 0
      end
      CRYSTAL

      # Most Crystal types get most of their API this way, so a tier that only
      # read `def` would be missing the majority of what they respond to.
      method_named(declarations, "Widget", "name").not_nil!.return_type.should eq("String")
      declarations.methods.find { |m| m.owner == "Widget" && m.name == "name=" }.should be_nil

      declarations.methods.find { |m| m.owner == "Widget" && m.name == "label" }.should be_nil
      method_named(declarations, "Widget", "label=")

      method_named(declarations, "Widget", "size")
      method_named(declarations, "Widget", "size=").not_nil!.params.map(&.restriction).should eq(["Int32"])

      method_named(declarations, "Widget", "enabled?")
      method_named(declarations, "Widget", "registry").not_nil!.class_method.should be_true
      method_named(declarations, "Widget", "legacy")
      method_named(declarations, "Widget", "counted")
    end

    it "records instance variable declarations" do
      declarations = declarations_for <<-CRYSTAL
      class Widget
        @name : String
        @size : Int32 = 0

        def initialize
          @untyped = 1
        end
      end
      CRYSTAL

      # Named as written, `@` and all, which is also how one is completed.
      declarations.ivars.map(&.name).should eq(["@name", "@size"])
      declarations.ivars.first.owner.should eq("Widget")
      declarations.ivars.first.restriction.should eq("String")
    end

    it "records a method written at the top level with no owner" do
      declarations = declarations_for("def helper\nend\n")

      declarations.methods.first.owner.should eq("")
    end
  end

  it "records requires as written" do
    declarations = declarations_for <<-CRYSTAL
    require "json"
    require "./relative"
    require "../up/*"
    CRYSTAL

    declarations.requires.map(&.path).should eq(["json", "./relative", "../up/*"])
  end

  it "records constants" do
    declarations = declarations_for <<-CRYSTAL
    VERSION = "1.0"

    module Config
      DEFAULT = 42
    end
    CRYSTAL

    declarations.constants.map(&.fqn).should eq(["VERSION", "Config::DEFAULT"])
    declarations.constants.last.value.should eq("42")
  end
end
