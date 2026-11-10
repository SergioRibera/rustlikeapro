# CLI and configuration

> Read when: building a command-line interface, parsing arguments, loading configuration files or environment variables, or deciding exit codes and what goes to stdout vs stderr.

## Argument parsing: `clap` with derive

`clap` (v4, `derive` feature) is the default. The derive API keeps the CLI a typed description of itself.

```rust
use std::path::PathBuf;
use clap::{Parser, Subcommand, ValueEnum};

/// Short description shown in --help (first doc line).
#[derive(Debug, Parser)]
#[command(version, about, long_about = None)]
pub struct Cli {
    /// Increase verbosity (-v, -vv).
    #[arg(short, long, action = clap::ArgAction::Count, global = true)]
    pub verbose: u8,

    /// Config file path.
    #[arg(long, env = "MYAPP_CONFIG", value_name = "FILE")]
    pub config: Option<PathBuf>,

    #[command(subcommand)]
    pub command: Command,
}

#[derive(Debug, Subcommand)]
pub enum Command {
    /// Export a recording.
    Export {
        input: PathBuf,
        #[arg(short, long, value_enum, default_value_t = Format::Json)]
        format: Format,
        #[arg(short, long)]
        output: Option<PathBuf>,
    },
}

#[derive(Debug, Clone, Copy, ValueEnum)]
pub enum Format {
    Json,
    Markdown,
}
```

- **`ValueEnum` for closed choices.** You get validation, `--help` listing and shell completion. Never use a `String` that is matched later.
- **`env = "…"`** (requires clap's `env` feature) gives env-var fallback with correct precedence: CLI flag > env var > default.
- Doc comments become help text; keep the first line short.
- Parse into typed values (`PathBuf`, numbers, `ValueEnum`, custom `value_parser`) at the boundary. Downstream code never re-parses strings.
- Use `#[arg(value_parser = clap::value_parser!(u16).range(1..))]` for bounded numbers, rather than validating later.
- Test the CLI definition once: `Cli::command().debug_assert()` in a unit test catches conflicting flags at test time.

  ```rust
  #[test]
  fn cli_definition_is_valid() {
      use clap::CommandFactory;
      Cli::command().debug_assert();
  }
  ```

- Shell completions and man pages: `clap_complete` / `clap_mangen`, generated from a build step or an `xtask`, not hand-written.

## The `main` shape

Keep `main` thin: parse, init observability, load config, call into the library-like core, map the result to an exit code.

```rust
use std::process::ExitCode;

fn main() -> ExitCode {
    let cli = Cli::parse();
    init_tracing(cli.verbose);

    match run(cli) {
        Ok(()) => ExitCode::SUCCESS,
        Err(err) => {
            report(&err);          // human-readable, to stderr
            err.exit_code()        // typed mapping, see below
        }
    }
}
```

- `run` lives in a module, or in a `-core` crate when the logic is reusable, and returns the typed top-level error. `main` is the **reporting layer**, the only place where a reporting type (miette / color-eyre / a typed top-level enum) is allowed (see `references/errors.md`).
- Map errors to exit codes with a method on the error type instead of scattered `std::process::exit` calls. `process::exit` skips destructors (unflushed buffers, temp files).

  ```rust
  impl AppError {
      pub fn exit_code(&self) -> ExitCode {
          match self {
              Self::Usage(_) => ExitCode::from(2),
              Self::NotFound { .. } => ExitCode::from(3),
              Self::Io { .. } => ExitCode::from(74), // EX_IOERR (sysexits.h)
          }
      }
  }
  ```

  The convention is 0 for success, 1 for generic failure and 2 for usage errors (clap already uses 2 for argument errors). Document any other codes in `--help` or the README.

## stdout vs stderr

| Stream | Contains |
|---|---|
| **stdout** | the program's *output*: data the user asked for, machine-readable results (`--json`) |
| **stderr** | diagnostics: logs, progress, warnings, error reports |

- A CLI must be pipe-safe: `myapp export x | jq` must never see a log line on stdout. The `tracing` fmt layer writes to stdout by default. In CLIs, configure it with `.with_writer(std::io::stderr)`.
- Offer `--json` (or `--format json`) for any output a script might consume, and keep it stable. It is API.
- Handle broken pipes: `println!` panics on `EPIPE` when stdout is closed (`myapp | head`). Write through a locked `stdout()` and treat `ErrorKind::BrokenPipe` as a clean exit.
- Respect `NO_COLOR` and non-TTY output: disable colors when stdout/stderr is not a terminal (`std::io::IsTerminal`).

## Configuration

### Layering and precedence

Standard precedence, highest wins: **CLI flags > environment variables > config file(s) > built-in defaults**.

Model the config as a typed struct with `Default`, deserialize it, then apply overrides. The struct is the single source of truth:

```rust
#[derive(Debug, Clone, serde::Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct Config {
    pub listen: std::net::SocketAddr,
    pub max_connections: NonZeroU32,
    pub log_level: LogLevel, // an enum, not a String: "debgu" fails at load time
}

#[derive(Debug, Clone, Copy, Default, serde::Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum LogLevel {
    Error,
    Warn,
    #[default]
    Info,
    Debug,
    Trace,
}

impl From<LogLevel> for tracing::level_filters::LevelFilter {
    fn from(level: LogLevel) -> Self {
        match level {
            LogLevel::Error => Self::ERROR,
            LogLevel::Warn => Self::WARN,
            LogLevel::Info => Self::INFO,
            LogLevel::Debug => Self::DEBUG,
            LogLevel::Trace => Self::TRACE,
        }
    }
}

impl Default for Config {
    fn default() -> Self { /* sensible, documented defaults */ }
}
```

- `#[serde(default)]` lets partial files work. `deny_unknown_fields` turns typos (`max_conections`) into errors instead of silent defaults. Use it for human-edited config files (see `references/serialization.md` for the trade-offs).
- Validate after loading. Use invariant-carrying types (`NonZeroU32`, `SocketAddr`, newtypes) so an invalid config cannot be represented, and add a `fn validate(&self) -> Result<(), ConfigError>` for cross-field rules.
- Report config errors with the file path and the offending key. Typed error variants such as `ConfigError::Parse { path, source }` give this for free.

### Crates

Choose based on need, and keep it honest:

- **Hand-rolled**: `toml::from_str` (or `serde_json`) into `Config`, then apply env/CLI overrides explicitly. Least magic, fully typed. Often the best choice for small tools.
- **`figment`**: composable providers (`Toml::file`, `Env::prefixed("MYAPP_")`, `Serialized::defaults`) merged into a typed struct, with errors that point at the source. A good fit for layered config.
- **`config`** crate: a similar layered model with a builder; widely used.

Whichever you pick, the output is your typed `Config`. Library code never reads env vars or files directly; it receives the config struct.

### Locations

- Use the platform-correct directories crate (`directories` / `dirs`) for config, cache and data paths. Never hardcode `~/.config`, because it breaks on Windows and macOS.
- Allow an explicit override (`--config FILE` / `MYAPP_CONFIG`).
- Never write secrets into a config file that might be committed. Read them from env vars or a secret store, and wrap them in `secrecy::SecretString`.

### Environment variables

- Prefix all of them (`MYAPP_*`) to avoid collisions.
- Read them in one place, at startup, into the typed config. `std::env::var` calls scattered through the code are hidden global inputs.
- Edition 2024: `std::env::set_var`/`remove_var` are `unsafe` (not thread-safe). Don't mutate the environment at runtime. In tests, pass config explicitly instead.

## Checklist

- [ ] `clap` derive; `ValueEnum` for choices; `Cli::command().debug_assert()` test.
- [ ] Thin `main` returning `ExitCode`; typed error → exit code mapping; no `process::exit` in logic.
- [ ] Output on stdout, diagnostics on stderr; `--json` for scriptable output; broken pipe handled.
- [ ] Typed `Config` with `Default`, documented precedence, validation, path-bearing errors.
- [ ] Env vars prefixed and read once; no secrets in config files.
