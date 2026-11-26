using Pkg
Pkg.activate(@__DIR__; io = devnull)
# before Julia 1.11 the [sources] entry of Project.toml is not read
VERSION < v"1.11" && Pkg.develop(Pkg.PackageSpec(; path = dirname(@__DIR__)); io = devnull)
Pkg.instantiate(; io = devnull)
