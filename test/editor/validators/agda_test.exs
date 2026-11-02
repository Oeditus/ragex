defmodule Ragex.Editor.Validators.AgdaTest do
  use ExUnit.Case, async: false

  alias Ragex.Editor.Validators.Agda

  @moduletag :agda
  @moduletag skip: is_nil(System.find_executable("agda"))

  setup do
    root =
      Path.join(System.tmp_dir!(), "ragex_agda_library_#{System.unique_integer([:positive])}")

    config = Path.join(root, "config")
    library = Path.join(root, "library")
    manifest = Path.join(library, "fixture.agda-lib")
    original_agda_dir = System.get_env("AGDA_DIR")

    File.mkdir_p!(config)
    File.mkdir_p!(Path.join(library, "RagexFixture/Nested"))
    File.write!(manifest, "name: ragex-fixture\ninclude: .\n")
    File.write!(Path.join(config, "libraries"), manifest <> "\n")
    File.write!(Path.join(config, "defaults"), "ragex-fixture\n")

    File.write!(
      Path.join(library, "RagexFixture/Nested/Target.agda"),
      "module RagexFixture.Nested.Target where\noriginal = Set\n"
    )

    File.write!(
      Path.join(library, "RagexFixture/Nested/Dependency.agda"),
      "module RagexFixture.Nested.Dependency where\ndata Token : Set where\n  token : Token\n"
    )

    System.put_env("AGDA_DIR", config)

    on_exit(fn ->
      if original_agda_dir do
        System.put_env("AGDA_DIR", original_agda_dir)
      else
        System.delete_env("AGDA_DIR")
      end

      File.rm_rf!(root)
    end)

    :ok
  end

  test "validates edited library modules while preserving sibling imports" do
    code = """
    module RagexFixture.Nested.Target where
    open import RagexFixture.Nested.Dependency using (Token; token)
    edited : Token
    edited = token
    """

    assert {:ok, :valid} = Agda.validate(code, path: "RagexFixture/Nested/Target.agda")
  end

  test "reports scope errors from edited content rather than validating the library copy" do
    code = """
    module RagexFixture.Nested.Target where
    edited = unknownName
    """

    assert {:error, [error | _]} =
             Agda.validate(code, path: "RagexFixture/Nested/Target.agda")

    assert error.message =~ "unknownName"
    refute error.message =~ "AmbiguousTopLevelModuleName"
  end

  test "validates literate modules that replace a library's plain source" do
    code = """
    \\begin{code}
    module RagexFixture.Nested.Target where
    open import RagexFixture.Nested.Dependency using (Token; token)
    edited : Token
    edited = token
    \\end{code}
    """

    assert {:ok, :valid} = Agda.validate(code, path: "RagexFixture/Nested/Target.lagda")
  end
end
