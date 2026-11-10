# Serialization

> Read when: deriving `Serialize`/`Deserialize`, designing a config, wire or storage format, choosing a binary codec, or evolving a format without breaking old data.

## serde is the default, not a mandate

`serde` is the ecosystem default for Rust serialization and usually the right choice. It is **not** mandatory. Some projects deliberately avoid it:

- Example (istmo): it bans serde by design and uses `bincode` 2's own `Encode`/`Decode` derives, to keep the dependency tree and compile times small and the wire format explicit. (A design choice that predates the bincode advisory below; new projects should pick a maintained format.)
- Any project with a "no serde" rule in its `AGENTS.md`/`CLAUDE.md` wins over this file.

Check the project's decision log before adding `serde` to a crate that does not already have it.

### Feature-gate serde in libraries

A library should not force serde on its users:

```toml
[features]
serde = ["dep:serde"]

[dependencies]
serde = { workspace = true, optional = true, features = ["derive"] }
```

```rust
#[derive(Debug, Clone, PartialEq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct DeviceInfo { … }
```

## Derive patterns

```rust
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "snake_case")]
pub struct Settings {
    pub display_name: String,
    #[serde(default)]
    pub retries: u8,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub proxy: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub tags: Vec<String>,
    #[serde(rename = "type")]
    pub kind: Kind,
}

#[derive(Debug, Clone, Copy, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Kind {
    Primary,
    Mirror,
}
```

- `rename_all` gives one casing for the whole container: `snake_case` for TOML/JSON configs, `camelCase` when interoperating with JS APIs. Keep the Rust names idiomatic and let serde map them.
- `#[serde(default)]` on a field or container makes it tolerant of missing keys. A container-level default requires `Default` on the struct.
- `skip_serializing_if = "Option::is_none"` keeps output clean. Pair it with `default` so a skipped field deserializes back.
- **Enum representation is API.** The default is externally tagged (`{"Primary": {...}}`). Choose deliberately:
  - `#[serde(tag = "type")]` (internally tagged) for readable JSON;
  - `#[serde(tag = "t", content = "c")]` (adjacently tagged);
  - `#[serde(untagged)]` only when you must accept heterogeneous input. Untagged errors are vague and matching is order-dependent.
- Prefer newtypes with `#[serde(transparent)]` for IDs: `struct UserId(u64)` serializes as a plain number.
- Never `#[derive(Serialize)]` on a type holding secrets without `#[serde(skip)]` or a redacting wrapper.

## `deny_unknown_fields`: trade-offs

| Use it | Avoid it |
|---|---|
| Human-edited config files: a typo should error, not silently fall back to a default | Wire protocols and APIs that must accept data from **newer** peers (forward compatibility) |
| Strict input validation at a trust boundary | Types used with `#[serde(flatten)]` (they are incompatible) |

The two goals conflict: strictness catches mistakes, tolerance allows old readers to read new data. Decide per type, and write the reason down.

## Versioned formats

Anything persisted (files, databases, caches) or sent between processes of different versions needs an evolution strategy *before* the first release.

- **Additive changes only**, by default: new fields are `Option<T>` or `#[serde(default)]`; never rename or retype an existing field in place.
- **Explicit version tag** for formats that will change shape:

  ```rust
  #[derive(serde::Deserialize)]
  #[serde(tag = "version")]
  enum StoredState {
      #[serde(rename = "1")] V1(StateV1),
      #[serde(rename = "2")] V2(StateV2),
  }

  impl From<StoredState> for State {
      fn from(s: StoredState) -> Self {
          match s {
              StoredState::V1(v1) => State::from(StateV2::from(v1)), // migrate forward
              StoredState::V2(v2) => State::from(v2),
          }
      }
  }
  ```

  The in-memory `State` stays clean; migrations are `From` chains, each tested.
- **Binary formats** (postcard, bitcode, bincode) are positional. Reordering, inserting or removing a field breaks every existing file. Version them with a leading magic + version header, and never change a released layout in place.
- Keep **golden files** of each released format version in `tests/fixtures/` and test that the current code still reads them. Snapshot tests (`insta`) work well for serialized output.

## Choosing a format

| Format | Use for |
|---|---|
| JSON (`serde_json`) | APIs, interop, debugging, `--json` CLI output |
| TOML (`toml`) | human-edited config files |
| `bitcode` | fast, compact Rust-to-Rust binary IPC and storage (serde or its own derives) |
| `rkyv` | zero-copy deserialization for large read-mostly data (mmap, caches) |
| ~~`bincode`~~ | **unmaintained** ([RUSTSEC-2025-0141](https://rustsec.org/advisories/RUSTSEC-2025-0141), 2025-12-16; 3.0.0 is a tombstone release). `cargo deny` flags it; existing users can stay on a pinned 1.3.3/2.x knowingly, new code picks postcard, bitcode, rkyv or wincode |
| `postcard` | compact binary for embedded/`no_std` and constrained links; stable, documented wire format |
| MessagePack (`rmp-serde`), CBOR (`ciborium`) | binary interop with non-Rust peers |
| `prost` / Protobuf, Cap'n Proto | cross-language schemas with enforced evolution rules |

- Prefer a format with a **specified** wire format when data outlives one binary version or crosses language boundaries.
- Avoid deprecated or unmaintained crates (`serde_yaml` is archived; if YAML is unavoidable, pick a maintained fork and record that choice in the decision log).

## Zero-copy deserialization

Borrow from the input instead of allocating when the input buffer outlives the value:

```rust
#[derive(serde::Deserialize)]
struct Record<'a> {
    #[serde(borrow)]
    name: &'a str,
    #[serde(borrow)]
    note: std::borrow::Cow<'a, str>, // borrows when possible, owns when escaping is needed
}

let rec: Record<'_> = serde_json::from_str(&input)?;
```

- `&'a str` fails on JSON strings that contain escapes; `Cow<'a, str>` with `#[serde(borrow)]` handles both cases.
- Use `DeserializeOwned` bounds when the value must outlive the buffer (e.g., reading from a `Read` stream).
- Only optimize this in measured hot paths; owned types are simpler.

## Untrusted input

Deserializing attacker-controlled data is a security boundary (see `references/security.md`):

- Limit input size *before* parsing (`Read::take`, body size limits).
- Bound collection sizes and recursion depth; positional binary decoders trust length prefixes, so cap the input buffer and validate counts before allocating.
- Validate after deserializing: convert the DTO into domain types via `TryFrom`, which enforces invariants.
- Fuzz parsers for custom formats (`cargo fuzz`).

## DTO vs domain types

Keep wire/storage structs (DTOs) separate from domain types once the two start to diverge:

```rust
impl TryFrom<SettingsDto> for Settings {
    type Error = SettingsError;
    fn try_from(dto: SettingsDto) -> Result<Self, Self::Error> { … }
}
```

This lets the domain type use `NonZero*`, newtypes and enums freely, while the DTO stays compatible with old data.

## Checklist

- [ ] serde allowed by the project's rules? Feature-gated in libraries.
- [ ] `rename_all`, `default` + `skip_serializing_if` pairs, deliberate enum representation.
- [ ] `deny_unknown_fields` decision made per type and documented.
- [ ] Persisted/wire formats versioned; golden fixtures per released version.
- [ ] Untrusted input size-limited and validated through `TryFrom`.
