defmodule Ragex.Editor.Validators.RustTest do
  use ExUnit.Case, async: true

  alias Ragex.Editor.Validators.Rust, as: RustValidator

  @rustc_available System.find_executable("rustc") != nil

  describe "can_validate?/1" do
    test "accepts .rs paths" do
      assert RustValidator.can_validate?("src/lib.rs")
      assert RustValidator.can_validate?("main.rs")
    end

    test "rejects other extensions" do
      refute RustValidator.can_validate?("lib.ex")
      refute RustValidator.can_validate?("main.go")
      refute RustValidator.can_validate?("README.md")
    end

    test "rejects non-binary input" do
      refute RustValidator.can_validate?(nil)
      refute RustValidator.can_validate?(:rust)
    end
  end

  describe "validate/2" do
    @tag :rust
    test "accepts valid Rust" do
      unless @rustc_available, do: :skip

      source = """
      fn add(a: i32, b: i32) -> i32 {
          a + b
      }
      """

      assert {:ok, :valid} = RustValidator.validate(source)
    end

    @tag :rust
    test "rejects a syntax error with a position" do
      unless @rustc_available, do: :skip

      assert {:error, [error | _]} = RustValidator.validate("fn broken( {")
      assert error.severity == :error
      assert is_integer(error.line)
    end

    @tag :rust
    test "rejects a type error" do
      unless @rustc_available, do: :skip

      assert {:error, [error | _]} = RustValidator.validate(~s|fn f() { let x: i32 = "s"; }|)
      assert error.message =~ "mismatched types"
      assert error.line == 1
    end

    @tag :rust
    test "does not report warnings as errors" do
      unless @rustc_available, do: :skip

      # An unused function is a `dead_code` warning; it must not fail validation.
      assert {:ok, :valid} = RustValidator.validate("fn never_called() {}")
    end
  end

  describe "parse_diagnostics/2 (no toolchain needed)" do
    test "returns valid for empty output" do
      assert {:ok, :valid} = RustValidator.parse_diagnostics("", 0)
    end

    test "extracts an error with its primary span" do
      output =
        ~s|{"level":"error","message":"mismatched types","spans":[{"line_start":3,"column_start":9,"is_primary":true}]}|

      assert {:error, [error]} = RustValidator.parse_diagnostics(output, 1)
      assert error.message == "mismatched types"
      assert error.line == 3
      assert error.column == 9
      assert error.severity == :error
    end

    test "ignores warnings" do
      output = ~s|{"level":"warning","message":"unused variable","spans":[]}|
      assert {:ok, :valid} = RustValidator.parse_diagnostics(output, 0)
    end

    test "drops the aborting summary line" do
      output =
        Enum.join(
          [
            ~s|{"level":"error","message":"mismatched types","spans":[{"line_start":1,"column_start":2,"is_primary":true}]}|,
            ~s|{"level":"error","message":"aborting due to 1 previous error","spans":[]}|
          ],
          "\n"
        )

      assert {:error, [error]} = RustValidator.parse_diagnostics(output, 1)
      assert error.message == "mismatched types"
    end

    test "ignores non-JSON lines" do
      output = "compiling something...\n" <> ~s|{"level":"error","message":"boom","spans":[]}|
      assert {:error, [error]} = RustValidator.parse_diagnostics(output, 1)
      assert error.message == "boom"
    end
  end
end
