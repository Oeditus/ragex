defmodule Ragex.Cure.LoaderTest do
  use ExUnit.Case, async: false

  alias Ragex.Cure.Loader

  # The Cure toolchain is not installed in CI; see `--exclude cure` in
  # .github/workflows/ci.yml.
  @moduletag :cure

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

  describe "find_executable/0" do
    test "returns a path to an existing escript, or nil" do
      case Loader.find_executable() do
        nil -> :ok
        path -> assert File.regular?(path)
      end
    end

    test "honours CURE_ESCRIPT for an unusual checkout location" do
      dir =
        Path.join(System.tmp_dir!(), "ragex_cure_escript_#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      escript = Path.join(dir, "cure")
      # A shebang-prefixed executable is how the released escript looks.
      File.write!(escript, "#! /usr/bin/env escript\n")
      File.chmod!(escript, 0o755)
      on_exit(fn -> File.rm_rf!(dir) end)

      previous_home = System.get_env("CURE_HOME")
      previous_escript = System.get_env("CURE_ESCRIPT")

      System.delete_env("CURE_HOME")
      System.put_env("CURE_ESCRIPT", escript)

      on_exit(fn ->
        if previous_home,
          do: System.put_env("CURE_HOME", previous_home),
          else: System.delete_env("CURE_HOME")

        if previous_escript,
          do: System.put_env("CURE_ESCRIPT", previous_escript),
          else: System.delete_env("CURE_ESCRIPT")
      end)

      assert Loader.find_executable() == escript
    end

    test "honours CURE_HOME" do
      dir = Path.join(System.tmp_dir!(), "ragex_cure_home_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(dir, "bin"))
      escript = Path.join([dir, "bin", "cure"])
      File.write!(escript, "#! /usr/bin/env escript\n")
      File.chmod!(escript, 0o755)
      on_exit(fn -> File.rm_rf!(dir) end)

      previous_home = System.get_env("CURE_HOME")
      previous_escript = System.get_env("CURE_ESCRIPT")

      System.put_env("CURE_HOME", dir)
      System.delete_env("CURE_ESCRIPT")

      on_exit(fn ->
        if previous_home,
          do: System.put_env("CURE_HOME", previous_home),
          else: System.delete_env("CURE_HOME")

        if previous_escript,
          do: System.put_env("CURE_ESCRIPT", previous_escript),
          else: System.delete_env("CURE_ESCRIPT")
      end)

      assert Loader.find_executable() == escript
    end

    test "ignores a plain text file that merely happens to be named cure" do
      dir = Path.join(System.tmp_dir!(), "ragex_cure_fake_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      fake = Path.join(dir, "cure")
      File.write!(fake, "not an escript\n")
      on_exit(fn -> File.rm_rf!(dir) end)

      previous_home = System.get_env("CURE_HOME")
      previous_escript = System.get_env("CURE_ESCRIPT")

      System.delete_env("CURE_HOME")
      System.put_env("CURE_ESCRIPT", fake)

      on_exit(fn ->
        if previous_home,
          do: System.put_env("CURE_HOME", previous_home),
          else: System.delete_env("CURE_HOME")

        if previous_escript,
          do: System.put_env("CURE_ESCRIPT", previous_escript),
          else: System.delete_env("CURE_ESCRIPT")
      end)

      refute Loader.find_executable() == fake
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
