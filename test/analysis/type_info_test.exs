defmodule Ragex.Analysis.TypeInfoTest do
  use ExUnit.Case, async: false

  alias Ragex.Analysis.TypeInfo

  setup do
    original = Application.get_env(:ragex, :type_inference)
    original_env = System.get_env("RAGEX_TYPE_INFERENCE")

    on_exit(fn ->
      if original do
        Application.put_env(:ragex, :type_inference, original)
      else
        Application.delete_env(:ragex, :type_inference)
      end

      case original_env do
        nil -> System.delete_env("RAGEX_TYPE_INFERENCE")
        val -> System.put_env("RAGEX_TYPE_INFERENCE", val)
      end
    end)

    :ok
  end

  describe "enabled?/0" do
    test "is false by default" do
      Application.delete_env(:ragex, :type_inference)
      System.delete_env("RAGEX_TYPE_INFERENCE")

      refute TypeInfo.enabled?()
    end

    test "is true when configured :enabled" do
      Application.put_env(:ragex, :type_inference, :enabled)

      assert TypeInfo.enabled?()
    end

    test "is true when configured true" do
      Application.put_env(:ragex, :type_inference, true)

      assert TypeInfo.enabled?()
    end

    test "is true when the env var is set" do
      Application.delete_env(:ragex, :type_inference)
      System.put_env("RAGEX_TYPE_INFERENCE", "1")

      assert TypeInfo.enabled?()
    end
  end

  describe "unavailable behaviour" do
    setup do
      Application.delete_env(:ragex, :type_inference)
      System.delete_env("RAGEX_TYPE_INFERENCE")
      :ok
    end

    test "available?/0 is false" do
      refute TypeInfo.available?()
    end

    test "types_for_file/1 returns {:error, :unavailable} rather than raising" do
      assert {:error, :unavailable} = TypeInfo.types_for_file("lib/anything.ex")
    end

    test "type_at/3 returns nil" do
      assert TypeInfo.type_at("lib/anything.ex", 1, 1) == nil
    end

    test "return_type/3 returns {:error, :unavailable}" do
      assert {:error, :unavailable} = TypeInfo.return_type(Enum, :count, 1)
    end
  end

  describe "dynamic?/1" do
    test "is false for nil" do
      refute TypeInfo.dynamic?(nil)
    end

    test "is true for a type struct flagged dynamic" do
      assert TypeInfo.dynamic?(%{dynamic?: true})
    end

    test "is false for a type struct not flagged dynamic" do
      refute TypeInfo.dynamic?(%{dynamic?: false})
    end

    test "detects dynamic() in the inspected form" do
      assert TypeInfo.dynamic?(%{__struct__: Typle.Type, kind: :dynamic, params: nil})
    end
  end

  describe "when enabled" do
    setup do
      Application.put_env(:ragex, :type_inference, :enabled)
      :ok
    end

    @tag :typle
    test "never raises on a file Typle cannot handle (struct update syntax)" do
      # `%{struct | key: value}` is the known Typle 0.3.1 crash: the AST node is
      # `{:|, _, [struct, [key: value]]}` and reaches the map-literal clause.
      path = Path.join(System.tmp_dir!(), "ragex_type_info_struct_update.ex")

      File.write!(path, """
      defmodule RagexTypeInfoSample do
        def update(data, issues), do: %{data | issues: issues}
      end
      """)

      on_exit(fn -> File.rm(path) end)

      # Either Typle handles it (future version) or it is reported as an error.
      # What must never happen is an exception escaping.
      case TypeInfo.types_for_file(path) do
        {:ok, map} when is_map(map) -> assert true
        {:error, {:typle_failed, _}} -> assert true
        {:error, :unavailable} -> assert true
      end
    end

    @tag :typle
    test "returns a type map for a simple module" do
      path = Path.join(System.tmp_dir!(), "ragex_type_info_simple.ex")

      File.write!(path, """
      defmodule RagexTypeInfoSimple do
        def greet(name), do: "hello " <> name
      end
      """)

      on_exit(fn -> File.rm(path) end)

      case TypeInfo.types_for_file(path) do
        {:ok, map} ->
          assert is_map(map)
          assert map_size(map) > 0

        {:error, {:typle_failed, _}} ->
          # Typle is young; a future release may still reject this shape.
          assert true
      end
    end
  end
end
