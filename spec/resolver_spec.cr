require "./spec_helper"

private def resolver_for(*sources : String) : Crystalline::Resolver
  index = Crystalline::Index.new([] of Crystalline::Project)
  entries = sources.map_with_index do |source, i|
    index.entry_for("/tmp/resolver_fixture_#{i}.cr", source, stamp: "fixture#{i}")
  end
  Crystalline::Resolver.new(entries.to_a)
end

private def member_names(resolver, fqn, class_method = false)
  resolver.members(fqn, class_method).map(&.name)
end

describe Crystalline::Resolver do
  describe "resolving a name to the type it means" do
    it "prefers the innermost scope the name could belong to" do
      resolver = resolver_for <<-CRYSTAL
      module Outer
        class Inner
        end
      end

      class Inner
      end
      CRYSTAL

      resolver.resolve("Inner", ["Outer"]).should eq("Outer::Inner")
      resolver.resolve("Inner", [] of String).should eq("Inner")
    end

    it "looks outward when the innermost scope has no such name" do
      resolver = resolver_for <<-CRYSTAL
      module Outer
        module Middle
        end

        class Sibling
        end
      end
      CRYSTAL

      resolver.resolve("Sibling", ["Outer", "Middle"]).should eq("Outer::Sibling")
    end

    it "reads a leading :: as naming the top level" do
      resolver = resolver_for <<-CRYSTAL
      module Outer
        class Config
        end
      end

      class Config
      end
      CRYSTAL

      resolver.resolve("::Config", ["Outer"]).should eq("Config")
      resolver.resolve("Config", ["Outer"]).should eq("Outer::Config")
    end

    it "sees through a generic argument list and a nilable marker" do
      resolver = resolver_for("class Holder\nend\n")

      resolver.resolve("Holder(String)", [] of String).should eq("Holder")
      resolver.resolve("Holder?", [] of String).should eq("Holder")
      resolver.resolve("Holder(Hash(String, Int32))", [] of String).should eq("Holder")
    end

    it "finds a name that comes from what the enclosing type inherits" do
      resolver = resolver_for <<-CRYSTAL
      class Base
        class Helper
        end
      end

      class Child < Base
        def use
        end
      end
      CRYSTAL

      # `Helper` written inside `Child` is `Base::Helper`, because Child is a
      # Base and everything Base names is in scope.
      resolver.resolve("Helper", ["Child"]).should eq("Base::Helper")
    end

    it "answers nothing for a name the project does not declare" do
      resolver = resolver_for("class Known\nend\n")

      resolver.resolve("Unknown", [] of String).should be_nil
      resolver.resolve("", [] of String).should be_nil
    end
  end

  describe "what a type responds to" do
    it "includes what it inherits, across files" do
      resolver = resolver_for(
        "class Base\n  def inherited_one\n  end\nend\n",
        "class Child < Base\n  def own_one\n  end\nend\n")

      names = member_names(resolver, "Child")
      names.should contain("own_one")
      names.should contain("inherited_one")
      # Most derived first, so an override shadows what it overrides.
      names.index("own_one").not_nil!.should be < names.index("inherited_one").not_nil!
    end

    it "includes what a mixin brings, later inclusions first" do
      resolver = resolver_for <<-CRYSTAL
      module First
        def tag(a : Int32)
        end
      end

      module Second
        def tag(b : String)
        end
      end

      class Widget
        include First
        include Second
      end
      CRYSTAL

      members = resolver.members("Widget", false)
      members.map(&.name).should contain("tag")
      # `include Second` comes last and so wins the lookup.
      members.first.owner.should eq("Second")
    end

    it "leaves out what a receiver cannot reach" do
      resolver = resolver_for <<-CRYSTAL
      class Widget
        def visible
        end

        private def hidden
        end
      end
      CRYSTAL

      member_names(resolver, "Widget").should eq(["visible"])
    end

    it "gathers the declarations of a type reopened in another file" do
      resolver = resolver_for(
        "class Widget\n  def first\n  end\nend\n",
        "class Widget\n  def second\n  end\nend\n")

      member_names(resolver, "Widget").sort.should eq(["first", "second"])
    end

    it "offers the accessors a macro declared" do
      resolver = resolver_for <<-CRYSTAL
      class Base
        property size : Int32
      end

      class Widget < Base
        getter name : String
      end
      CRYSTAL

      names = member_names(resolver, "Widget")
      names.should contain("name")
      names.should contain("size")
      names.should contain("size=")
    end

    it "finds what is written inside an enum" do
      resolver = resolver_for <<-CRYSTAL
      module Outer
        enum Severity
          Low
          High

          def label
          end
        end
      end
      CRYSTAL

      resolver.resolve("Severity", ["Outer"]).should eq("Outer::Severity")
      member_names(resolver, "Outer::Severity").should contain("label")
    end

    it "comes back from a cycle instead of following it" do
      resolver = resolver_for <<-CRYSTAL
      class A < B
        def from_a
        end
      end

      class B < A
        def from_b
        end
      end
      CRYSTAL

      member_names(resolver, "A").sort.should eq(["from_a", "from_b"])
    end
  end

  describe "what a type responds to as a type" do
    it "offers new for the initialize a class declares" do
      resolver = resolver_for <<-CRYSTAL
      class Widget
        def initialize(@name : String)
        end
      end
      CRYSTAL

      new_method = resolver.members("Widget", true).find(&.name.== "new").not_nil!
      new_method.params.map(&.name).should eq(["name"])
      new_method.return_type.should eq("Widget")
    end

    it "offers a new that takes nothing when no initialize is written" do
      resolver = resolver_for("class Widget\nend\n")

      resolver.members("Widget", true).map(&.name).should eq(["new"])
    end

    it "offers new for an initialize a class inherits" do
      resolver = resolver_for(
        "class Base\n  def initialize(@id : Int32)\n  end\nend\n",
        "class Child < Base\nend\n")

      new_method = resolver.members("Child", true).find(&.name.== "new").not_nil!
      new_method.params.map(&.name).should eq(["id"])
    end

    it "offers no new for a module" do
      resolver = resolver_for("module Helpers\n  def self.build\n  end\nend\n")

      names = member_names(resolver, "Helpers", class_method: true)
      names.should contain("build")
      names.should_not contain("new")
    end

    it "takes class methods down the superclass chain" do
      resolver = resolver_for(
        "class Base\n  def self.build\n  end\nend\n",
        "class Child < Base\n  def self.make\n  end\nend\n")

      names = member_names(resolver, "Child", class_method: true)
      names.should contain("make")
      names.should contain("build")
    end

    it "tells include from extend" do
      resolver = resolver_for <<-CRYSTAL
      module Mixed
        def mixed_in
        end
      end

      class Widget
        include Mixed
      end

      class Gadget
        extend Mixed
      end
      CRYSTAL

      # `include` gives instance methods, `extend` gives class methods, and
      # putting either in the wrong list is the sort of thing a user notices.
      member_names(resolver, "Widget", class_method: false).should contain("mixed_in")
      member_names(resolver, "Widget", class_method: true).should_not contain("mixed_in")

      member_names(resolver, "Gadget", class_method: true).should contain("mixed_in")
      member_names(resolver, "Gadget", class_method: false).should_not contain("mixed_in")
    end
  end
end
