%{
  configs: [
    %{
      name: "default",
      files: %{included: ["lib/", "test/", "config/"], excluded: [~r"/_build/", ~r"/deps/"]},
      strict: true,
      checks: %{
        enabled: [
          {Credo.Check.Readability.MaxLineLength, max_length: 100}
        ]
      }
    }
  ]
}
