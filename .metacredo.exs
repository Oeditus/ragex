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
          ~r"/\.git/"
        ]
      },
      checks: %{
        enabled: :all,
        disabled: [
          # Suppress hardcoded URL findings in CI
          {MetaCredo.Check.Security.HardcodedValue, []}
        ]
      }
    }
  ]
}
