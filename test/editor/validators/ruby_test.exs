defmodule Ragex.Editor.Validators.RubyTest do
  use ExUnit.Case, async: true

  alias Ragex.Editor.Validators.Ruby, as: RubyValidator

  @ruby_available System.find_executable("ruby") != nil

  describe "validate/2" do
    @tag :ruby
    test "validates correct Ruby syntax" do
      unless @ruby_available, do: :skip

      source = """
      class Calculator
        def add(a, b)
          a + b
        end
      end
      """

      assert {:ok, :valid} = RubyValidator.validate(source)
    end

    @tag :ruby
    test "rejects invalid Ruby syntax" do
      unless @ruby_available, do: :skip

      source = """
      def broken(
        this is not valid
      """

      assert {:error, errors} = RubyValidator.validate(source)
      assert [_ | _] = errors
      assert hd(errors).severity == :error
    end

    @tag :ruby
    test "reports line number for syntax errors" do
      unless @ruby_available, do: :skip

      source = """
      class Foo
        def bar
          if true
        end
      end
      """

      assert {:error, [error | _]} = RubyValidator.validate(source)
      assert is_integer(error.line)
    end

    @tag :ruby
    test "validates empty Ruby file" do
      unless @ruby_available, do: :skip

      assert {:ok, :valid} = RubyValidator.validate("")
    end

    @tag :ruby
    test "validates simple expressions" do
      unless @ruby_available, do: :skip

      source = """
      x = 42
      puts x
      [1, 2, 3].map { |n| n * 2 }
      """

      assert {:ok, :valid} = RubyValidator.validate(source)
    end
  end

  describe "can_validate?/1" do
    test "returns true for .rb files" do
      assert RubyValidator.can_validate?("app/models/user.rb")
      assert RubyValidator.can_validate?("script.rb")
    end

    test "returns false for non-Ruby files" do
      refute RubyValidator.can_validate?("module.ex")
      refute RubyValidator.can_validate?("script.py")
      refute RubyValidator.can_validate?("index.js")
    end

    test "returns false for non-string input" do
      refute RubyValidator.can_validate?(nil)
      refute RubyValidator.can_validate?(42)
    end
  end
end
