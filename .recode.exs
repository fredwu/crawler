[
  version: "0.8.0",
  autocorrect: true,
  dry: false,
  verbose: false,
  inputs: ["{mix,.formatter}.exs", "{apps,config,lib,test}/**/*.{ex,exs}"],
  formatter: {Recode.Formatter, []},
  tasks: [
    {Recode.Task.AliasExpansion, []},
    {Recode.Task.AliasOrder, []},
    {Recode.Task.Dbg, [autocorrect: false]},
    {Recode.Task.EnforceLineLength, [active: false]},
    {Recode.Task.FilterCount, []},
    {Recode.Task.IOInspect, [autocorrect: false]},
    {Recode.Task.Nesting, []},
    {Recode.Task.PipeFunOne, []},
    {Recode.Task.SinglePipe, []},
    {Recode.Task.Specs, [active: false, exclude: "test/**/*.{ex,exs}", config: [only: :visible]]},
    {Recode.Task.TagFIXME, [exit_code: 2]},
    {Recode.Task.TagTODO, [exit_code: 4]},
    {Recode.Task.TestFile, []},
    {Recode.Task.UnusedVariable, [active: false]}
  ]
]
