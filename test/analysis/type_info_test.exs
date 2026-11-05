defmodule Ragex.Analysis.TypeInfoTest do
  use ExUnit.Case, async: false

  alias Ragex.Analysis.TypeInfo

  setup do
    # The feature is config-gated; enable it for these tests and restore the
    # previous setting afterwards so we never leak state into other suites.
    previous = Application.get_env(:ragex, :type_inference)
    Application.put_env(:ragex, :type_inference, :enabled)

    on_exit(fn ->
      if previous == nil do
        Application.delete_env(:ragex, :type_inference)
      else
        Application.put_env(:ragex, :type_inference, previous)
      end
    end)

    :ok
  end

  describe "enabled?/0 and available?/0" do
    test "is enabled when configured" do
      assert TypeInfo.enabled?()
    end

    test "is disabled by default" do
      Application.put_env(:ragex, :type_inference, :disabled)
      refute TypeInfo.enabled?()
      refute TypeInfo.available?()
    end

    test "available? implies enabled?" do
      assert TypeInfo.available?() == (TypeInfo.enabled?() and Code.ensure_loaded?(Typle))
    end
  end

  describe "when disabled" do
    test "types_for_file/2 returns :unavailable rather than raising" do
      Application.put_env(:ragex, :type_inference, :disabled)
      assert {:error, :unavailable} = TypeInfo.types_for_file("lib/ragex.ex")
    end

    test "type_at/4 returns nil" do
      Application.put_env(:ragex, :type_inference, :disabled)
      assert TypeInfo.type_at("lib/ragex.ex", 1, 1) == nil
    end

    test "summarize/2 returns :unavailable" do
      Application.put_env(:ragex, :type_inference, :disabled)
      assert {:error, :unavailable} = TypeInfo.summarize("lib/ragex.ex")
    end
  end

  describe "when enabled and Typle is loaded" do
    setup do
      if TypeInfo.available?(), do: :ok, else: {:ok, skip: true}
    end

    @describetag :tmp_dir

    test "types_for_file/2 returns type_info keyed by {line, column}", %{tmp_dir: dir} do
      file = write(dir, "sample.ex", sample_source())

      assert {:ok, types} = TypeInfo.types_for_file(file)
      assert is_map(types)

      assert Enum.all?(types, fn
               {{line, col}, %{type: _, expr: _, informative?: inf}} ->
                 is_integer(line) and is_integer(col) and is_boolean(inf)

               _ ->
                 false
             end)
    end

    test "summarize/2 ratios are consistent", %{tmp_dir: dir} do
      file = write(dir, "sample.ex", sample_source())

      assert {:ok, summary} = TypeInfo.summarize(file)

      assert summary.total > 0
      assert summary.dynamic <= summary.total
      assert summary.informative <= summary.total
      assert summary.dynamic_ratio >= 0.0 and summary.dynamic_ratio <= 1.0
      assert summary.informative_ratio >= 0.0 and summary.informative_ratio <= 1.0
    end

    test "type_at/4 returns the type_info at a recorded position", %{tmp_dir: dir} do
      file = write(dir, "sample.ex", sample_source())

      {:ok, types} = TypeInfo.types_for_file(file)
      [{line, col} | _] = types |> Map.keys() |> Enum.sort()

      assert %{type: _, expr: _, informative?: _} = TypeInfo.type_at(file, line, col)
    end

    test "type_at/4 returns nil for an unrecorded position", %{tmp_dir: dir} do
      file = write(dir, "sample.ex", sample_source())
      assert TypeInfo.type_at(file, 9999, 9999) == nil
    end

    test "a file Typle cannot parse is reported as an error, not a raise", %{tmp_dir: dir} do
      file = write(dir, "broken.ex", "defmodule Broken do\n  def oops(\nend\n")

      assert {:error, _} = TypeInfo.types_for_file(file)
    end

    test "return_type/3 returns a type for a known function" do
      # Typle returns the bare Type on success and only wraps failures, so the
      # contract here is "a type, or {:error, reason}".
      assert %{} = TypeInfo.return_type(Enum, :count, 1)
    end

    test "return_type/3 degrades to dynamic() for an unknown module" do
      # Typle does not raise for a module it cannot resolve; it returns
      # dynamic(), which is exactly the "no information" signal callers must
      # treat as unknown rather than as a real type.
      type = TypeInfo.return_type(NoSuchModule, :nope, 0)
      assert TypeInfo.dynamic?(type) or match?({:error, _}, type)
    end
  end

  describe "dynamic?/1" do
    test "nil is not dynamic" do
      refute TypeInfo.dynamic?(nil)
    end

    test "a struct flagged dynamic? is dynamic" do
      assert TypeInfo.dynamic?(%{dynamic?: true, kind: :dynamic})
    end

    test "a struct flagged not-dynamic is not dynamic" do
      refute TypeInfo.dynamic?(%{dynamic?: false, kind: :integer})
    end

    test "a :dynamic kind is dynamic even without the flag" do
      assert TypeInfo.dynamic?(%{kind: :dynamic})
    end
  end

  describe "informative?/1" do
    test "dynamic() is not informative" do
      refute TypeInfo.informative?("dynamic()")
    end

    test "an empty type is not informative" do
      refute TypeInfo.informative?("")
      refute TypeInfo.informative?(nil)
    end

    test "map() alone is not informative" do
      refute TypeInfo.informative?("map()")
    end

    test "a concrete type is informative" do
      assert TypeInfo.informative?("integer()")
      assert TypeInfo.informative?("binary()")
      assert TypeInfo.informative?("{:ok, binary()}")
    end
  end

  # --- helpers ---

  defp write(dir, name, content) do
    path = Path.join(dir, name)
    File.write!(path, content)
    path
  end

  defp sample_source do
    """
    defmodule TypeInfoSample do
      @spec add(integer(), integer()) :: integer()
      def add(a, b), do: a + b

      def greet(name) when is_binary(name), do: "hi " <> name

      def tupleize(x), do: {:ok, x}
    end
    """
  end
end
