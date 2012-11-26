require 'spec_helper'

describe 'Type inference: const' do
  it "types a constant" do
    input = parse "A = 1"
    mod = infer_type input
    input.target.type.should eq(mod.int)
  end

  it "types a constant reference" do
    assert_type("A = 1; A") { int }
  end

  it "types a nested constant" do
    assert_type("class B; A = 1; end; B::A") { int }
  end

  it "types a constant inside a def" do
    assert_type(%q(
      class Foo
        A = 1

        def foo
          A
        end
      end

      Foo.new.foo
      )) { int }
  end

  it "finds nearest constant first" do
    assert_type(%q(
      A = 1

      class Foo
        A = 2.5

        def foo
          A
        end
      end

      Foo.new.foo
      )) { float }
  end
end