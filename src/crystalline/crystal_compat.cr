# Crystal 1.21.0's embeddable compiler references `Crystal::Command::Exit`,
# but that enum is only defined by the compiler CLI. Requiring the CLI is not
# an option for embedders because it loads the full tool stack (including
# dependencies such as `markd`). Define the enum until the compiler library's
# error handling no longer depends on the CLI implementation.
{% if compare_versions(Crystal::VERSION, "1.21.0") >= 0 && compare_versions(Crystal::VERSION, "1.22.0") < 0 %}
  class Crystal::Command
    enum Exit
      OK             = 0
      FAILURE        = 1
      USAGE_ERROR    = 1
      CODE_ERROR     = 1
      SOFTWARE_ERROR = 1
    end
  end
{% end %}
