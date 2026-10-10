defmodule Ragex.Cure.LoaderTest do
  use ExUnit.Case, async: false

  alias Ragex.Cure.Loader

  describe "load_beams/1" do
    test "loads beams for modules that are not available yet" do
      [{module, binary}] =
        Code.compile_string("defmodule Ragex.Cure.LoaderTest.Fresh do\n  def ok, do: :ok\nend")

      :code.purge(module)
      :code.delete(module)
      :code.purge(module)

      on_exit(fn ->
        :code.purge(module)
        :code.delete(module)
        :code.purge(module)
      end)

      assert [^module] = Loader.load_beams([{~c"cure/ebin/#{module}.beam", binary}])
      assert module.ok() == :ok
    end

    test "never replaces a module that is already available" do
      original = Enum.module_info(:md5)

      assert [] = Loader.load_beams([{~c"cure/ebin/Elixir.Enum.beam", <<"not a beam">>}])
      assert Enum.module_info(:md5) == original
    end

    test "skips entries that are not beam files" do
      assert [] = Loader.load_beams([{~c"cure/priv/std/option.cure", "mod Option"}])
    end
  end

  describe "ensure_loaded/0" do
    test "returns :ok or a not-available error without raising" do
      assert Loader.ensure_loaded() in [:ok, {:error, :cure_not_available}]
    end

    test "concurrent callers never observe a partially loaded compiler" do
      results =
        1..32
        |> Task.async_stream(
          fn _ ->
            case Loader.ensure_loaded() do
              :ok ->
                {:ok,
                 Enum.map(
                   [Cure.Compiler.Lexer, Cure.Compiler.Parser, Cure.Edition],
                   &match?({:module, _}, Code.ensure_loaded(&1))
                 )}

              other ->
                other
            end
          end,
          max_concurrency: 32,
          timeout: 60_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      for result <- results do
        case result do
          {:ok, loaded} -> assert Enum.all?(loaded)
          {:error, :cure_not_available} -> :ok
        end
      end
    end
  end
end
