defmodule Ragex.DependencyProfilesTest do
  use ExUnit.Case, async: true

  test "development and test keep the latest local stack and original storage" do
    assert_profile("""
    for env <- [:dev, :test] do
      config = profile.(env, false)
      deps = Map.new(config[:deps], fn {app, requirement, opts} -> {app, {requirement, opts}} end)

      assert config[:lockfile] == "mix.lock"
      assert config[:deps_path] == "deps"
      assert config[:build_path] == "_build"

      for {app, version} <- [bumblebee: "0.8.0", nx: "1.0.0", exla: "1.0.0", nx_image: "0.2.0"] do
        {requirement, opts} = Map.fetch!(deps, app)
        assert Version.match?(version, requirement)
        assert opts[:optional]
      end

      overrides = for {app, {_, opts}} <- deps, opts[:override], do: app
      assert Enum.sort(overrides) == [:exla, :nx, :nx_image]
      refute Version.match?("0.13.1", elem(deps[:exla], 0))
    end
    """)
  end

  test "explicit Hex mode and downstream prod are override-free with separate storage" do
    assert_profile("""
    for {env, flag} <- [dev: true, test: true, prod: false, prod: true] do
      config = profile.(env, flag)
      deps = Map.new(config[:deps], fn {app, requirement, opts} -> {app, {requirement, opts}} end)

      assert config[:lockfile] == "mix.hex.lock"
      assert config[:deps_path] == "deps_hex"
      assert config[:build_path] == "_build_hex"

      for {_, {_, opts}} <- deps do
        refute Keyword.has_key?(opts, :override)
        refute Keyword.has_key?(opts, :path)
        refute Keyword.has_key?(opts, :git)
      end

      for app <- [:nx, :exla] do
        {requirement, opts} = Map.fetch!(deps, app)
        assert opts[:optional]
        assert Version.match?("0.12.0", requirement)
        assert Version.match?("1.0.0", requirement)
        refute Version.match?("0.13.0", requirement)
        refute Version.match?("0.13.1", requirement)
        refute Version.match?("2.0.0", requirement)
      end

      for {app, versions} <- [bumblebee: ["0.7.1", "0.8.0"], nx_image: ["0.1.2", "0.2.0"]] do
        {requirement, opts} = Map.fetch!(deps, app)
        assert opts[:optional]
        for version <- versions, do: assert(Version.match?(version, requirement))
      end

      assert deps[:fine] == {"~> 0.1.6", [optional: true, runtime: false]}
      assert elem(deps[:image], 1)[:optional]
    end
    """)
  end

  test "Hex and downstream profiles ignore sibling checkout overrides" do
    assert_profile("""
    System.put_env("LOCAL_METACREDO", "1")
    System.put_env("LOCAL_METASTATIC", "1")

    for {env, flag} <- [dev: true, prod: false] do
      deps = profile.(env, flag)[:deps]
      assert {:metacredo, "~> 0.1", []} == normalize.(List.keyfind(deps, :metacredo, 0))
      assert {:metastatic, "~> 0.44", []} == normalize.(List.keyfind(deps, :metastatic, 0))
    end

    deps = profile.(:dev, false)[:deps]
    assert {:metacredo, nil, [path: "../metacredo"]} = List.keyfind(deps, :metacredo, 0)
    assert {:metastatic, nil, [path: "../metastatic", override: true]} =
             List.keyfind(deps, :metastatic, 0)
    """)
  end

  defp assert_profile(assertions) do
    root = Path.expand("../..", __DIR__)

    code = """
    Mix.start()
    Mix.env(:dev)
    import ExUnit.Assertions
    Code.require_file("mix.exs", hd(System.argv()))

    normalize = fn
      {app, requirement, opts} -> {app, requirement, opts}
      {app, opts} when is_list(opts) -> {app, nil, opts}
      {app, requirement} -> {app, requirement, []}
    end

    profile = fn env, hex? ->
      Mix.env(env)
      if hex?, do: System.put_env("RAGEX_HEX_BUILD", "1"), else: System.delete_env("RAGEX_HEX_BUILD")
      config = Ragex.MixProject.project()
      Keyword.update!(config, :deps, &Enum.map(&1, normalize))
    end

    #{assertions}
    """

    {output, status} =
      System.cmd(System.find_executable("elixir"), ["--erl", "+S 2:2", "-e", code, "--", root],
        cd: root,
        env: [
          {"XLA_TARGET", "cpu"},
          {"EXLA_CPU_ONLY", "true"},
          {"RAGEX_HEX_BUILD", nil},
          {"LOCAL_METACREDO", nil},
          {"LOCAL_METASTATIC", nil}
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output
  end
end
