# Usage: elixir scripts/verify_hex_package.exs path/to/ragex-VERSION.tar
# Reads the built archive, not the checkout's current Mix configuration.
import ExUnit.Assertions

[archive] = System.argv()
{:ok, entries} = :erl_tar.extract(String.to_charlist(archive), [:memory])
files = Map.new(entries)
{:ok, tokens, _} = files[~c"metadata.config"] |> String.to_charlist() |> :erl_scan.string()

terms =
  Enum.chunk_while(
    tokens,
    [],
    fn
      {:dot, _} = token, acc -> {:cont, Enum.reverse([token | acc]), []}
      token, acc -> {:cont, [token | acc]}
    end,
    fn [] -> {:cont, []} end
  )

metadata =
  Map.new(terms, fn tokens ->
    {:ok, term} = :erl_parse.parse_term(tokens)
    term
  end)

requirements =
  Map.new(metadata["requirements"], fn fields ->
    fields = Map.new(fields)
    {fields["app"], fields}
  end)

expected = %{
  "bumblebee" => "~> 0.7.1 or ~> 0.8.0",
  "nx" => "~> 0.12.0 or ~> 1.0",
  "exla" => "~> 0.12.0 or ~> 1.0",
  "nx_image" => "~> 0.1.2 or ~> 0.2.0"
}

for {app, requirement} <- expected do
  assert requirements[app]["requirement"] == requirement
  assert requirements[app]["optional"] == true
end

for {_app, fields} <- requirements do
  refute Map.has_key?(fields, "override")
  assert fields["repository"] == "hexpm"
end

{:ok, contents} = :erl_tar.extract({:binary, files[~c"contents.tar.gz"]}, [:compressed, :memory])
contents = Map.new(contents)
root = Path.join(System.tmp_dir!(), "ragex_hex_verify_#{System.pid()}")
File.mkdir_p!(Path.join(root, "lib/ragex"))

try do
  for name <- ["mix.exs", "lib/ragex/cuda_detector.ex"] do
    File.write!(Path.join(root, name), Map.fetch!(contents, String.to_charlist(name)))
  end

  code = """
  Mix.start()
  Mix.env(:prod)
  import ExUnit.Assertions
  Code.require_file("mix.exs", hd(System.argv()))
  config = Ragex.MixProject.project()

  for dep <- config[:deps] do
    {_app, requirement, opts} =
      case dep do
        {app, requirement, opts} -> {app, requirement, opts}
        {app, requirement} when is_binary(requirement) -> {app, requirement, []}
      end

    assert is_binary(requirement)
    refute Keyword.has_key?(opts, :override)
    refute Keyword.has_key?(opts, :path)
    refute Keyword.has_key?(opts, :git)
  end

  for app <- [:nx, :exla] do
    {^app, requirement, _opts} = List.keyfind(config[:deps], app, 0)
    assert Version.match?("0.12.0", requirement)
    assert Version.match?("1.0.0", requirement)
    refute Version.match?("0.13.1", requirement)
  end
  """

  {output, status} =
    System.cmd(System.find_executable("elixir"), ["--erl", "+S 2:2", "-e", code, "--", root],
      cd: root,
      env: [
        {"RAGEX_HEX_BUILD", nil},
        {"LOCAL_METACREDO", "1"},
        {"LOCAL_METASTATIC", "1"},
        {"EXLA_CPU_ONLY", "true"},
        {"XLA_TARGET", "cpu"}
      ],
      stderr_to_stdout: true
    )

  assert status == 0, output
after
  File.rm_rf!(root)
end

IO.puts("Hex metadata and packaged downstream :prod dependencies verified")
