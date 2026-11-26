version: 2
updates:
  - package-ecosystem: "github-actions"
    directory: "/"
    schedule:
      interval: "weekly"
    # 0 switches version updates off until the launch; remove the line then
    open-pull-requests-limit: 0
  - package-ecosystem: "julia"
    directories:
<<JULIA_DIRECTORIES>>
    schedule:
      interval: "weekly"
    # 0 switches version updates off until the launch; remove the line then
    open-pull-requests-limit: 0
    groups:
      # one pull request for the compatible updates of the week instead of one per package
      julia-minor-and-patch:
        patterns: ["*"]
        update-types: ["minor", "patch"]
