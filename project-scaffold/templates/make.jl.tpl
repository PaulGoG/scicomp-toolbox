include(joinpath(@__DIR__, "activate.jl"))

using <<PKG>>
using Documenter

DocMeta.setdocmeta!(<<PKG>>, :DocTestSetup, :(using <<PKG>>); recursive = true)

makedocs(;
    modules = [<<PKG>>],
    authors = "<<AUTHORS_TEXT>>",
    sitename = "<<PKG>>.jl",
    # named here, so that a local build does not depend on a git remote
    repo = Remotes.GitHub("<<USER>>", "<<PKG>>.jl"),
    format = Documenter.HTML(;
        canonical = "https://<<USER>>.github.io/<<PKG>>.jl",
        edit_link = "<<BRANCH>>",
        assets = String[],
    ),
    pages = ["Home" => "index.md"],
)

deploydocs(; repo = "github.com/<<USER>>/<<PKG>>.jl", devbranch = "<<BRANCH>>")
