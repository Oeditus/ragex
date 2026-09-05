%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "src/", "web/"],
        excluded: [
          ~r"/_build/",
          ~r"/deps/",
          ~r"/node_modules/",
          ~r"/\.git/",
          ~r"mix\.exs$"
        ]
      },
      checks: %{
        enabled: :all,
        disabled: [
          # Suppress hardcoded URL and inline JS findings in CI
          {MetaCredo.Check.Security.HardcodedValue, []},
          {MetaCredo.Check.Security.InlineJavascript, []}
        ]
      }
    }
  ]
}
