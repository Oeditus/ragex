defmodule Ragex.Analyzers.DirectoryDiscoveryTest do
  use ExUnit.Case, async: false

  alias Ragex.Analyzers.Directory
  alias Ragex.Graph.Store

  setup do
    tmp = Path.join(System.tmp_dir!(), "ragex_discovery_#{System.unique_integer([:positive])}")
    root = Path.join(tmp, "project")
    cache = Path.join(tmp, "cache")
    File.mkdir_p!(root)
    previous_cache = Application.get_env(:ragex, :cache_root)
    Application.put_env(:ragex, :cache_root, cache)

    on_exit(fn ->
      Store.clear()
      Store.sync()
      File.rm_rf!(tmp)

      if previous_cache do
        Application.put_env(:ragex, :cache_root, previous_cache)
      else
        Application.delete_env(:ragex, :cache_root)
      end
    end)

    {:ok, root: root, tmp: tmp, cache: cache}
  end

  test "nested anchored ignores exclude generated bundles while retaining source scripts", %{
    root: root
  } do
    git!(root, ["init", "--quiet"])
    write!(root, ".gitignore", "/scripts/\n")
    write!(root, "apps/api/.gitignore", "/priv/static/assets/\n")
    write!(root, "apps/api/priv/static/assets/js/bundle.js", "not valid source")
    source = write!(root, "apps/api/assets/js/source.js", "export const source = true;")
    script = write!(root, "apps/data/priv/scripts/source.exs", ":ok")
    write!(root, "scripts/local.exs", ":ignored")

    assert MapSet.new(Directory.discover_files(root)) == MapSet.new([source, script])
  end

  test "honors negation and retains tracked files even when ignored", %{root: root} do
    git!(root, ["init", "--quiet"])
    write!(root, ".gitignore", "*.ex\n!keep.ex\n")
    keep = write!(root, "keep.ex", ":keep")
    tracked = write!(root, "tracked.ex", ":tracked")
    write!(root, "ignored.ex", ":ignored")
    git!(root, ["add", "--force", "tracked.ex"])

    assert MapSet.new(Directory.discover_files(root)) == MapSet.new([keep, tracked])
  end

  test "honors repository-local and configured global excludes", %{root: root, tmp: tmp} do
    git!(root, ["init", "--quiet"])
    write!(root, ".git/info/exclude", "local.ex\n")
    global = write!(tmp, "global-ignore", "global.ex\n")
    git!(root, ["config", "core.excludesFile", global])
    write!(root, "local.ex", ":ignored")
    write!(root, "global.ex", ":ignored")
    source = write!(root, "source.ex", ":source")

    assert [^source] = Directory.discover_files(root)
  end

  test "resolves paths relative to the requested repository subdirectory", %{root: root} do
    git!(root, ["init", "--quiet"])
    write!(root, "outside.ex", ":outside")
    write!(root, "apps/api/.gitignore", "/priv/static/assets/\n")
    write!(root, "apps/api/priv/static/assets/bundle.js", "not valid source")
    source = write!(root, "apps/api/lib/source.ex", ":source")

    assert [^source] = Directory.discover_files(Path.join(root, "apps/api"))
  end

  test "supports a gitdir file rather than assuming .git is a directory", %{root: root, tmp: tmp} do
    git!(root, ["init", "--quiet", "--separate-git-dir", Path.join(tmp, "metadata")])
    write!(root, "nested/.gitignore", "ignored.ex\n")
    write!(root, "nested/ignored.ex", ":ignored")
    source = write!(root, "nested/source.ex", ":source")

    assert File.regular?(Path.join(root, ".git"))
    assert [^source] = Directory.discover_files(root)
  end

  test "preserves depth, explicit exclusions, supported types and default build exclusions", %{
    root: root
  } do
    git!(root, ["init", "--quiet"])
    source = write!(root, "source.ex", ":source")
    nested = write!(root, "lib/nested.ex", ":nested")
    write!(root, "lib/deep/deep.ex", ":deep")
    write!(root, "custom/excluded.ex", ":excluded")
    write!(root, "deps/tracked.ex", ":excluded")
    write!(root, "README.md", "not source")
    git!(root, ["add", "--force", "deps/tracked.ex"])

    assert [^source] = Directory.discover_files(root, max_depth: 0)

    assert MapSet.new(Directory.discover_files(root, max_depth: 1, exclude_patterns: ["custom"])) ==
             MapSet.new([source, nested])
  end

  test "omits missing tracked files and preserves spaces and newlines in filenames", %{root: root} do
    git!(root, ["init", "--quiet"])
    deleted = write!(root, "deleted.ex", ":deleted")
    git!(root, ["add", "deleted.ex"])
    File.rm!(deleted)
    spaced = write!(root, "a source.ex", ":spaced")
    newline = write!(root, "another\nsource.ex", ":newline")

    assert MapSet.new(Directory.discover_files(root)) == MapSet.new([spaced, newline])
  end

  test "falls back outside a repository and when Git is unavailable", %{root: root} do
    source = write!(root, "source.ex", ":source")
    write!(root, ".gitignore", "*.js\n")
    write!(root, "bundle.js", "not valid source")
    write!(root, "_build/derived.ex", ":excluded")
    assert [^source] = Directory.discover_files(root)
    git!(root, ["init", "--quiet"])

    previous_path = System.get_env("PATH")
    System.put_env("PATH", "")

    try do
      assert [^source] = Directory.discover_files(root)
    after
      if previous_path do
        System.put_env("PATH", previous_path)
      else
        System.delete_env("PATH")
      end
    end
  end

  @tag timeout: 120_000
  test "a fresh VM restores the cache and never retries ignored bundles", %{
    root: root,
    cache: cache
  } do
    git!(root, ["init", "--quiet"])
    write!(root, "apps/api/.gitignore", "/priv/static/assets/\n")
    write!(root, "apps/api/priv/static/assets/bundle.js", "not valid JavaScript {{{")

    write!(root, "apps/api/lib/source.ex", """
    defmodule DiscoveryRestartSource do
      def value, do: :ok
    end
    """)

    assert {:ok, %{total: 1, success: 1, errors: 0}} =
             Directory.analyze_directory(root,
               watch: false,
               notify: false,
               generate_embeddings: false
             )

    code = """
    [root, cache] = System.argv()
    Logger.configure(level: :error)
    Application.ensure_all_started(:crypto)
    Application.put_env(:ragex, :store_backend, :ets)
    Application.put_env(:ragex, :cache_root, cache)
    Application.put_env(:ragex, :cache, enabled: true)
    {:ok, _} = Task.Supervisor.start_link(name: Ragex.TaskSupervisor)
    {:ok, _} = Ragex.Graph.Store.start_link()
    :ok = Ragex.Graph.Store.load_project(root)
    {:ok, %{total: 1, success: 0, analyzed: 0, skipped: 1, errors: 0}} =
      Ragex.Analyzers.Directory.analyze_directory(root,
        watch: false, notify: false, generate_embeddings: false)
    :ok = GenServer.stop(Ragex.Graph.Store)
    IO.puts("WARM_RESTART_OK")
    """

    paths = Enum.flat_map(:code.get_path(), fn path -> ["-pa", to_string(path)] end)
    args = ["--erl", "+S 2:2"] ++ paths ++ ["-e", code, "--", root, cache]
    {output, status} = System.cmd(System.find_executable("elixir"), args, stderr_to_stdout: true)
    assert status == 0, output
    assert output =~ "WARM_RESTART_OK"
  end

  defp write!(root, relative, content) do
    path = Path.join(root, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    path
  end

  defp git!(root, args) do
    {output, status} = System.cmd("git", ["-C", root | args], stderr_to_stdout: true)
    assert status == 0, output
    output
  end
end
