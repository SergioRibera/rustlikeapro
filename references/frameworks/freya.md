# Freya UI framework

> Read when: working in a project that depends on `freya` (Rust GUI on Skia). For general Freya API usage, hooks and elements, also load the dedicated `freya` skill if your agent has it installed; this file only holds the engineering rules that cause real rewrites when ignored.

**Verified against freya 0.5.0-rc.13** (`freya-core`, `freya-components`, `freya-engine` sources in `~/.cargo/registry`, 2026-11). Freya is pre-1.0 and its API moves between release candidates. Before relying on any signature below, check the version in the project's `Cargo.lock`. If it differs, re-verify against `~/.cargo/registry/src/*/freya-core-<version>/src/elements/extensions.rs`.

## What changed from older guidance (rc.8 → rc.13)

| Topic | rc.8 (old) | rc.13 (current) |
|---|---|---|
| Layout accessor on `LayoutExt` | `fn get_layout(&mut self) -> &mut LayoutData` | `fn layout_mut(&mut self) -> &mut LayoutData` |
| Text style accessor on `TextStyleExt` | `fn get_text_style_data(&mut self)` | `fn text_style_data_mut(&mut self) -> &mut TextStyleData` |
| Size / position / constraints traits | implemented manually per component | **blanket impls**: `impl<T: ContainerExt> ContainerSizeExt for T {}`, same for `ContainerPositionExt` and `ContainerConstraintsExt` |
| Custom drawing | `canvas(RenderCallback::new(..))` element in `freya-components/src/canvas.rs` | `rect().background(RenderCallback::new(move \|ctx: &mut RenderContext\| ..))`; `RenderCallback` lives in `freya-core/src/style/render_callback.rs` |
| `RenderCallback` equality | `eq` always returned `true`, so a closure never saw new captured values | `eq` is `Rc::ptr_eq`: a callback built in this render is a *new* `Rc`, so it differs from last render's and gets re-applied |
| Skia aliases | you had to alias by hand | `freya_engine::prelude` already exports `SkColor`, `SkImage`, `SkPath`, `SkRect`, `SkPaint`… (it *also* glob-exports the unaliased names) |

## Rule 1 — implement the framework's extension traits, never hand-roll builders

Never write your own `.width()`, `.position()`, `.font_size()` builder methods on a custom component. Freya's extension traits provide that chainable API. Store the data as fields and implement the low-level accessor traits. The higher-level traits then come for free:

```rust
use freya::prelude::*;

#[derive(PartialEq)]
pub struct ImageButton {
    label: Cow<'static, str>,
    layout: LayoutData,
    text_style: TextStyleData,
}

impl LayoutExt for ImageButton {
    fn layout_mut(&mut self) -> &mut LayoutData {
        &mut self.layout
    }
}

impl TextStyleExt for ImageButton {
    fn text_style_data_mut(&mut self) -> &mut TextStyleData {
        &mut self.text_style
    }
}

// Marker impl: unlocks .padding(), and through blanket impls also
// ContainerSizeExt (.width/.height/.expanded), ContainerPositionExt
// (.position/.margin) and ContainerConstraintsExt (.min_width/...).
impl ContainerExt for ImageButton {}
```

- **Do not** also write `impl ContainerSizeExt for ImageButton {}`. In rc.13 that conflicts with the blanket impl and fails to compile.
- In `render()`, pass the stored data through: `.layout(self.layout.clone())` and `.text_style(self.text_style.clone())`. `LayoutExt::layout` and `TextStyleExt::text_style` replace the data wholesale.
- `Component` requires `PartialEq + 'static`, so derive `PartialEq` on component structs. Freya's diffing relies on it.

## Rule 2 — a component owns its fixed assets

A component with a fixed visual identity (specific button textures, a specific icon) owns those assets as `const` bytes in its own module. They are not constructor parameters. Callers pass semantic data only: label, callbacks, layout overrides.

```rust
// inside src/components/image_button.rs — the textures are this component's business
const BTN_BYTES: &[u8] =
    include_bytes!(concat!(env!("CARGO_MANIFEST_DIR"), "/assets/images/btn.png"));
const BTN_OVER_BYTES: &[u8] =
    include_bytes!(concat!(env!("CARGO_MANIFEST_DIR"), "/assets/images/btn_over.png"));
const BTN_PRESSED_BYTES: &[u8] =
    include_bytes!(concat!(env!("CARGO_MANIFEST_DIR"), "/assets/images/btn_pressed.png"));

// ✓ caller
ImageButton::new("LOGIN").position(Position::new_absolute().top(20.).left(40.))

// ✗ caller should not know about textures
ImageButton::new("LOGIN", BTN_BYTES, BTN_OVER_BYTES, BTN_PRESSED_BYTES)
```

Anchor the path with `concat!(env!("CARGO_MANIFEST_DIR"), …)` rather than `"../../assets/…"`. A relative `include_bytes!` path is resolved from the source file's location, so it breaks as soon as the file moves to a different module depth.

## Rule 3 — extract styled primitives as components

A repeated style combination (font family list + color + alignment) belongs in a dedicated component, not in `label()` / `rect()` chains copy-pasted across screens. The style then changes in one place.

```
src/
  components.rs        // shared constants + `mod image_button; pub use image_button::*;`
  components/
    image_button.rs
    mc_label.rs
```

- `components.rs` is the module root (`foo.rs` + `foo/`, never `mod.rs`). It holds the shared constants (font names, font sizes, palette colors) and re-exports the submodules.
- Submodules import shared values with `use super::{FONT, PALETTE_…}`.
- Font names defined there are the same `&str` passed to `LaunchConfig::with_font` in `main.rs`, so the string is never duplicated.

## Rule 4 — custom drawing with `RenderCallback`

In rc.13, custom painting goes through a `Fill`. A `RenderCallback` converts into `Fill` and is set as an element's background (or text color):

```rust
fn spinner(angle: f32) -> impl IntoElement {
    rect()
        .expanded()
        .background(RenderCallback::new(move |ctx: &mut RenderContext| {
            if let RenderTarget::Background { canvas, .. } = &ctx.target {
                draw_spinner(canvas, ctx.origin, ctx.size, angle);
            }
        }))
}
```

- **Capture by value is correct now.** `PartialEq for RenderCallback` is `Rc::ptr_eq`, so a callback built during this render compares unequal to last render's. The fresh closure, with the fresh captured value, is what gets used.
- **The old `Rc<RefCell<T>>` workaround is obsolete for rc.13+.** Previously `eq` always returned `true`, so a by-value capture was stuck at its first value. Drop the workaround unless the project is pinned to an older RC, and check the lockfile before deciding.
- **Remaining pitfall:** if you cache the callback itself across renders (e.g. `use_hook(|| RenderCallback::new(..))`), it keeps the same `Rc` and never sees new values. Build it in `render()`, or read the changing value through shared state inside the closure.
- After input that changes what the canvas shows outside normal state updates, request a redraw (`Platform::get().send(UserEvent::RequestRedraw)`, as in the upstream README example).
- `RenderContext` gives you `origin`, `size` and `scale_factor`. Convert logical to physical pixels with `scale_factor` instead of assuming 1.0.

## Rule 5 — naming conflicts between Freya and Skia types

`freya::prelude::Color` (a `u32` wrapper in `freya-core/src/style/color.rs`) and Skia's `Color` are different types. `freya_engine::prelude` already re-exports Skia types with `Sk` prefixes (`SkColor`, `SkColor4f`, `SkImage`, `SkPath`, `SkRect`, `SkPoint`…). It **also** glob-exports the unprefixed names. So:

```rust
use freya::prelude::*;
use freya_engine::prelude::{SkColor, SkPaint, SkPath, SkRect}; // ✓ explicit, prefixed

// ✗ use freya_engine::prelude::*;  — glob brings a second `Color`/`Image` into scope
```

Import engine items explicitly by their `Sk*` names. Never glob-import `freya_engine::prelude` next to `freya::prelude`.

## Rule 6 — engineering rules that apply to Freya too

- Components are types: put behaviour in `impl Component for X` and helper methods on `X`, not loose functions spread across screens. Pure drawing helpers (`draw_spinner`) are fine as module-private functions next to the component that uses them.
- `RenderCallback::call` borrows a `RefCell` mutably. Never call a callback re-entrantly from inside itself, or `borrow_mut` will panic.
- Keep state in hooks (`use_state`, `use_hook`) and pass plain data into child components. Components that take `PartialEq` data diff cheaply.
- For performance investigations (frame drops, slow layout), `sismo` ships a `sismo-freya` crate with render-phase spans. See `references/ecosystem.md`.
- Headless UI tests: `freya-testing` exists in the registry. Prefer it over manual window tests, and run them in CI under `xvfb-run` only when a real window is required.

## Verification checklist when the Freya version changes

1. `grep -n "fn layout_mut\|fn text_style_data_mut" freya-core-*/src/elements/extensions.rs`: accessor names.
2. `grep -n "impl<T: ContainerExt>" …/extensions.rs`: which traits are blanket-implemented.
3. `sed -n '/impl PartialEq for RenderCallback/,/^}/p' freya-core-*/src/style/render_callback.rs`: callback diff semantics.
4. `sed -n 1,40p freya-engine-*/src/lib.rs`: which `Sk*` aliases exist.
5. Update the "Verified against" stamp at the top of this file.
