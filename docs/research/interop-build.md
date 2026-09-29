# Rust core + Swift shell for Mapo: interop and build infrastructure

Research date: 2026-09-28. I checked versions against crates.io, GitHub releases and source at HEAD on that date. I researched interop directly and ran three parallel passes on production apps, the build pipeline and templates, and SwiftUI vs AppKit. I then spot-checked their key claims with `gh`. Anything I could not confirm is listed in section 8.

Toolchain context on this date: Xcode 27 and Swift 6.4 shipped 2026-09-14/15, and macOS 27 is out. macOS 26 Tahoe was the last release for Intel Macs, so macOS 27 is Apple Silicon only. GitHub's `macos-latest` label points to `macos-26` on arm64, and an `xcode-27` preview label exists.

---

## 0. Short answer

**Recommended stack**

1. **Interop.** Use UniFFI 0.32.x with proc-macros, pinned to an exact version, compiled into one `mapo-ffi` staticlib crate.
   - Use it for the control plane only: commands go in, batches of small diffs come out.
   - Put the generated Swift in its own SwiftPM target compiled in Swift 5 language mode. The app itself stays Swift 6 with MainActor default isolation.
2. **Terminal bytes stay off UniFFI.** Either libghostty owns the PTY, or Rust owns it and feeds libghostty through a small C ABI. cmux's MIT-licensed libghostty fork already has the embedder-owned IO mode this needs. A tmux/iTerm2-style daemon is the route to sessions that survive app updates.
3. **State lives in Rust.** One command API serves the Swift UI, the `mapo` CLI socket, the MCP server and the Claude Code hooks.
   - Swift observes it through a listener, which feeds an `AsyncStream`, which one MainActor task drains into `@Observable` stores. This is the Element X pattern.
4. **Build.**
   - arm64-only staticlib, then `uniffi-bindgen-swift`, then an XCFramework inside a local Swift package via `binaryTarget(path:)`, driven by `just`.
   - XcodeGen for the app project.
   - GitHub Actions on `macos-26`.
   - Developer ID signing, `notarytool`, create-dmg, Sparkle 2.10.
5. **UI.** AppKit owns the app lifecycle, windows, split views, lists and trees, menus and the responder chain. SwiftUI draws leaf views.

**Why UniFFI over the alternatives**

- It is what Firefox iOS, Element X, Bitwarden, Proton, WordPress and Bitkey ship. Mullvad moved from hand-written cbindgen FFI to UniFFI between July and September 2026, and said the reason was removing unsafe code.
- It handles async, foreign traits, errors and object lifetimes for you.
- Its weak spots are Swift 6 strictness and slow lifting of large collections. Both can be designed around.
- BoltFFI is faster and Crux adopted it in June 2026, but it is nine months old. swift-bridge is a single-maintainer 0.1.x project. A hand-written C ABI is worth it for one hot path, not for the whole API.

**Best reference repos**

| Repo | Why |
|---|---|
| [hewigovens/jayjay](https://github.com/hewigovens/jayjay) | A shipping Rust + SwiftUI macOS app with almost exactly this build: UniFFI, a local SwiftPM wrapper, XcodeGen, Sparkle, notarization, a bundled Rust CLI, CI on `macos-26`. BSL-1.1 app, Apache-2.0 crates. |
| [ghostty-org/ghostty](https://github.com/ghostty-org/ghostty) | Core library, then C header and module map, then XCFramework, then an AppKit app. The cleanest release workflow to copy. MIT. |
| [manaflow-ai/cmux](https://github.com/manaflow-ai/cmux) | The product Mapo resembles. Libghostty, AppKit windows, an NSTableView sidebar, NSOutlineView file tree. App code is GPL-3.0-or-later: read it, don't copy it. Its [ghostty fork](https://github.com/manaflow-ai/ghostty) and [Bonsplit](https://github.com/manaflow-ai/bonsplit) are MIT. |
| [element-hq/element-x-ios](https://github.com/element-hq/element-x-ios) + [matrix-rust-sdk](https://github.com/matrix-org/matrix-rust-sdk) | The best example of Rust-owned state pushed to Swift as `VectorDiff` batches. |
| [Automattic/wordpress-rs](https://github.com/Automattic/wordpress-rs) | Compiles the UniFFI bindings in `.swiftLanguageMode(.v5)` and switches between a local and a release XCFramework in `Package.swift`. |

**Top risks** are in section 7:

- PTY ownership versus upstream libghostty.
- UniFFI's Swift 6 gaps.
- UniFFI's Swift performance on collections.
- SwiftUI layout and focus bugs.
- Module map collisions between GhosttyKit and the Rust XCFramework.
- Every session dying on each Sparkle update.

---

## 1. Rust and Swift interop options

### 1.1 Comparison

| Option | Latest | Maturity and users | Cost on the hot path, Swift side | Async | Swift called from Rust | Errors | Object lifetimes | Swift 6 |
|---|---|---|---|---|---|---|---|---|
| UniFFI, [mozilla/uniffi-rs](https://github.com/mozilla/uniffi-rs) | 0.32.2, 2026-09-22 | The default choice. About 5k stars, 13M downloads, 222 public reverse deps on crates.io. Used by Firefox iOS/Android, Element X, Bitwarden, Proton Mail/Pass, WordPress, Bitkey, Mullvad, LDK/BDK, Ferrostar, LiveKit, Loro, AWS mls-rs | Primitive calls cost the same as a raw C call. Records, `Vec` and `String` travel through a serialized `RustBuffer`, and Swift lifting is slow today at roughly 2 to 4 µs per record | Swift `async`. The foreign side drives polling, so no Rust runtime is required. No cancellation | Foreign traits, sync or async | `#[derive(uniffi::Error)]` becomes a Swift `Error` enum plus `throws`. Panics become an internal error | `Arc<T>` behind a `u64` handle. The Swift class frees it in `deinit` | Partial. Objects and protocols are `Sendable`. Async code isn't. Xcode 26 default MainActor isolation breaks the generated file |
| BoltFFI, [boltffi/boltffi](https://github.com/boltffi/boltffi) | 0.31.0, 2026-09-28 | Repo created 2025-12-23, about 900 stars, very active. Two public reverse deps. Crux moved to it in 0.19 (2026-06-08). No known shipping macOS app | Primitives and `#[data]` structs of primitives cross without encoding. 10k records take 27 µs against UniFFI's 18.8 ms | Swift `async`, and Task cancellation reaches Rust | Traits, plus `#[ffi_stream]`, which becomes an `AsyncStream`. The stream buffer is lossy by default | Swift `throws` | Handles to objects Rust holds | Exported classes are not yet `Sendable` ([#778](https://github.com/boltffi/boltffi/issues/778)) |
| swift-bridge, [chinedufn/swift-bridge](https://github.com/chinedufn/swift-bridge) | 0.1.59, 2026-01-06. Last commit 2026-09-05 | About 1.1k stars, one maintainer, still 0.1.x. Used mostly by crates that call Apple APIs from Rust, such as Tauri plugins and coreml-rs | No serialization. Shared "transparent" structs, plus `RustString` and `RustVec` wrappers | Rust futures run on a built-in global tokio runtime. Rust can also call Swift async functions | `extern "Swift"` blocks. `Box<dyn FnOnce>` works only Rust to Swift | `Result` becomes `throws`, with typed throws for Swift to Rust | Owned, `Ref` and `RefMut` Swift classes mirror Rust borrows | Requires Swift 6.0 or later. `#[swift_bridge(Sendable)]` |
| Plain C ABI: cbindgen plus a module map plus hand-written Swift | cbindgen 0.29.4, 2026-06-09 | The oldest pattern. Ghostty uses the same shape from Zig; libsignal uses it; Mullvad did until 2026 | Zero overhead. Either side can lend a pointer and length | Hand-rolled: a completion callback plus `withCheckedContinuation` | A C function pointer plus a `void*` context via `Unmanaged`, or `@_cdecl` | Hand-rolled status codes | Manual `*_free`. Easy to leak or double-free | Whatever you write |
| Diplomat 0.16.1 | 2026-08-20 | Used by ICU4X. No Swift backend ([issue #143](https://github.com/rust-diplomat/diplomat/issues/143) is open) | n/a | n/a | n/a | n/a | n/a | n/a |
| Out-of-process IPC over a Unix socket or XPC, using JSON-RPC, protobuf or Cap'n Proto | n/a | Used by tmux, zellij, the WezTerm mux, iTerm2 session servers, VS Code's ptyHost, and Raycast 2.0 (typed clients generated for every layer) | A syscall plus serialization per message. Fine for the control plane, acceptable for byte streams | Natural | Messages | Defined by the protocol | At the process level | n/a |

### 1.2 UniFFI in detail

**Versions and cadence.** Recent releases, from the [changelog](https://github.com/mozilla/uniffi-rs/blob/main/CHANGELOG.md):

| Version | Date |
|---|---|
| 0.29.0 | 2025-02-06 |
| 0.30.0 | 2025-10-08 |
| 0.31.0 | 2026-01-14 |
| 0.32.0 | 2026-06-30 |
| 0.32.1 | 2026-09-08 |
| 0.32.2 | 2026-09-22 |

Each minor version breaks something. The README says: "We consider it ready for production use, but UniFFI is a long way from a 1.0 release." Production apps pin exact versions: Bitwarden uses `=0.32.0`, matrix-rust-sdk and application-services use 0.32.1.

**Proc-macros or UDL.** Both work and can be mixed.

- New projects use proc-macros: `uniffi::setup_scaffolding!()`, `#[uniffi::export]` and `#[derive(uniffi::Record|Enum|Object|Error)]`. Recent features landed there first:
  - renames (0.30 and 0.31)
  - methods on records and enums (0.31)
  - recursive enums, `Box<T>` and `HashSet` (0.32)
- Firefox's application-services still has 14 older UDL components. matrix-rust-sdk is down to a few `[Remote]` types in UDL.
- Bindings come from "library mode", which reads metadata from the compiled library. That means you build before you generate.
- `main` has an unreleased `uniffi_parse_rs` that reads Rust sources directly (`uniffi-bindgen ... src:<crate>`) and removes that step.

A sketch of what Mapo's exported API could look like:

```rust
// crates/mapo-ffi/src/lib.rs
uniffi::setup_scaffolding!();

#[derive(uniffi::Record)]
pub struct TabSnapshot { pub id: u64, pub title: String, pub cwd: String, pub status: TabStatus }

#[derive(uniffi::Enum)]
pub enum CoreEvent { TabUpserted { tab: TabSnapshot }, TabRemoved { id: u64 }, PortsChanged { ports: Vec<PortInfo> } }

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum CoreError { #[error("not found: {id}")] NotFound { id: u64 }, #[error("io: {msg}")] Io { msg: String } }

#[derive(uniffi::Object)]
pub struct Core { /* tokio runtime, state, channels */ }

#[uniffi::export]
impl Core {
    #[uniffi::constructor]
    pub fn new(config: CoreConfig) -> Result<std::sync::Arc<Self>, CoreError> { todo!() }
    pub fn open_tab(&self, workspace: u64, spec: TabSpec) -> Result<u64, CoreError> { todo!() }
    /// Pull-based event pump: resolves with the next coalesced batch.
    pub async fn next_events(&self) -> Vec<CoreEvent> { todo!() }
}

// Foreign trait: Swift implements it, Rust calls it, possibly from a tokio worker thread.
#[uniffi::export(foreign)]
pub trait CoreDelegate: Send + Sync {
    fn on_events(&self, batch: Vec<CoreEvent>);
}
```

**Swift tooling.** `uniffi-bindgen-swift` has shipped since 0.28.2 in October 2024 ([docs](https://mozilla.github.io/uniffi-rs/latest/swift/uniffi-bindgen-swift.html)).

- It always runs in library mode.
- It can emit headers, a single module map and Swift sources separately.
- Flags include `--swift-sources`, `--headers`, `--modulemap`, `--xcframework`, `--module-name`, `--modulemap-filename`, `--link-frameworks` and `--metadata-no-deps`.
- `--xcframework` writes a `framework module`. That is right for an XCFramework of `.framework` bundles, which is what Mozilla's megazord does. For a library XCFramework (`.a` plus `Headers`), write a plain `module MapoFFI { ... }`, as section 3.1 explains.

`uniffi.toml` `[bindings.swift]` options include:

- `module_name`
- `ffi_module_name`
- `generate_immutable_records`
- `generate_codable_conformance` (0.29.2)
- `generate_case_iterable_conformance`
- `omit_checksums`
- `rename`
- `link_frameworks`

Since 0.32, `--config` expects a global config file, so keep a per-crate `uniffi.toml`.

**Async.**

- A Rust `async fn` becomes a Swift `async` function. UniFFI does not need a Rust runtime: Swift drives the future through `rust_future_poll` and a continuation callback ([internals](https://github.com/mozilla/uniffi-rs/blob/main/docs/manual/src/internals/async-overview.md)).
- If the future touches tokio I/O, you have two choices:
  - `#[uniffi::export(async_runtime = "tokio")]`. matrix-rust-sdk and Bitwarden do this, though the docs say "it's not clear if we want to continue to support it".
  - Keep your own tokio runtime, spawn work there, and await a runtime-agnostic channel such as `tokio::sync::mpsc`.
- Cancellation is not supported. From [futures.md](https://github.com/mozilla/uniffi-rs/blob/main/docs/manual/src/futures.md): "We don't directly support cancellation in UniFFI even when the underlying platforms do... There's no builtin way to cancel a future."
  - The generated Swift uses `withUnsafeContinuation` without a cancellation handler, so cancelling the Swift `Task` does not drop the Rust future.
  - matrix-rust-sdk works around this by returning a `TaskHandle` object whose `Drop` aborts the tokio task.

**Foreign traits.**

- `#[uniffi::export(foreign)]` allows Swift-only implementations; `#[uniffi::export(rust, foreign)]` allows both. `with_foreign` is deprecated as of 0.32, and plain "callback interfaces" are soft-deprecated.
- Since 0.29.1 the generated protocols are `Sendable`, so Swift implementations must be too: a final class with immutable state, or `@unchecked Sendable`.
- Rust calls them on whatever thread it happens to be on, so the Swift side must hop to the main actor.
- Method arguments can't be references; everything passes by value.
- UniFFI does nothing about reference cycles between a Swift listener and a Rust object. The [docs](https://github.com/mozilla/uniffi-rs/blob/main/docs/manual/src/foreign_traits.md) say "UniFFI doesn't try to help here".

**Object lifetimes.**

- Objects are `Arc<T>` in Rust, so they are `Send + Sync`. Since 0.30 they cross as `u64` handles.
- The generated `open class ...: @unchecked Sendable` holds the handle, clones it when passing it back to Rust, and calls Rust's free function in `deinit`.
- A `...Protocol` is generated for mocking, and `init(noHandle: NoHandle())` builds fakes for tests (see `uniffi_bindgen/src/bindings/swift/templates/ObjectTemplate.swift`).
- Element X generates its test mocks from those protocols with Sourcery.

**Errors.**

- `Result<T, E>` where `E: uniffi::Error` becomes a Swift `throws` with a generated `enum E: Error`. It also conforms to `LocalizedError` unless you turn that off.
- `#[uniffi(flat_error)]` exposes only the `Display` string.
- A Rust panic becomes an internal error that Swift can catch only if the function `throws`. In a non-throwing function it is a Swift fatal error.
- Bitwarden folds every error into one `BitwardenError` with `#[from]`. Make every exported function that can fail return `Result`.

**Swift 6 status.** I checked the issue tracker on 2026-09-28.

What is fixed:
- 0.29.0 made interfaces `Sendable` (#2318).
- 0.29.1 made generated protocols `Sendable` (#2450).
- 0.31.2 fixed the strict-concurrency warning on callback vtables.

What is still open:
- "Async code doesn't conform to Swift 6 Sendable" ([#2458](https://github.com/mozilla/uniffi-rs/issues/2458), last activity 2026-08-17). One commenter notes the failure appears only at full compile, not under `swiftc -typecheck`.
- The async foreign-trait hard error `#SendingClosureRisksDataRace` ([#2929](https://github.com/mozilla/uniffi-rs/issues/2929)) is fixed on `main` by PR #2943, merged 2026-07-15, but **not in 0.32.2**. I checked the v0.32.2 `Async.swift` template and it still lacks `@Sendable`.
- Xcode 26's "Default Actor Isolation = MainActor" makes the generated file fail to compile ([#2818](https://github.com/mozilla/uniffi-rs/issues/2818)). This is the default for new Xcode 26 app targets, and Element X sets it too. People work around it by prepending `nonisolated` with sed, or by compiling the bindings in their own module.
- Two issues that don't hit everyone:
  - a Swift 6.2 `Data.bytes` name collision ([#2803](https://github.com/mozilla/uniffi-rs/issues/2803))
  - module map `use "_Builtin_stdbool"` lines breaking `canImport` on Xcode 26/27 ([#2917](https://github.com/mozilla/uniffi-rs/issues/2917)). A maintainer says Firefox iOS builds fine on Xcode 27.
- In May 2026 a maintainer wrote, in a thread about packaging: "We don't even have swift 6 working" ([#2888](https://github.com/mozilla/uniffi-rs/issues/2888)).

What works in practice: wordpress-rs compiles the generated file in a separate target with `.swiftLanguageMode(.v5)`. Dory patches the generated file. Firefox iOS adds `@unchecked @retroactive Sendable` extensions marked with TODOs. Do what wordpress-rs does.

**Performance.** This is the part that matters for Mapo.

The numbers below come from BoltFFI's own Swift benchmark suite:
- Setup: GitHub Actions M1 VM, macOS 26.4, UniFFI 0.31, run 2026-06-25.
- Data: [boltffi/benchmarks-dashboard](https://github.com/boltffi/benchmarks-dashboard), `public/data/views/groups/*.json`.

| Case | UniFFI | BoltFFI |
|---|---|---|
| noop / echo i32 | 28.1 ns | 28.9 ns (both at timer resolution) |
| generate 10k small records, Rust to Swift | 18.8 ms | 27 µs |
| 64 KB `Vec<u8>`, Rust to Swift | 43 µs | 13 µs |
| 64 KB echo, before UniFFI 0.32's zero-copy `&[u8]` | 181 µs | 12 µs |
| 100 callbacks | 23.6 µs | 10.8 µs |
| object method loop | 22.6 µs | 9.3 µs |
| string generate | 238 ns | 482 ns |
| async add | about 14 µs | about 14 µs |

- BoltFFI's README headline, "noop 1,416 ns vs <1 ns", does not match its own Swift data. Treat it as marketing, probably taken from Kotlin/JNA runs.
- The cause of UniFFI's slowness was filed on 2026-09-27: "Swift: RustBuffer reading is dominated by `Data.copyBytes` generic dispatch (~10× slower than the Kotlin bindings)" ([#3013](https://github.com/mozilla/uniffi-rs/issues/3013)).
  - It measured 3.7 µs per record when lifting a `Vec` of records through a callback, with 62% of the time in `DataProtocol.copyBytes`.
  - A local patch made it 3.6x to 10.7x faster. This will likely improve, but don't design on the assumption that it will.
- New in 0.32.0 ([bytes docs](https://mozilla.github.io/uniffi-rs/next/types/bytes.html)):
  - Zero-copy `&[u8]` arguments from Swift to Rust: Swift passes `Data`, and the call runs inside `withUnsafeBytes`.
  - `&mut [u8]` becomes `inout Data` for sync functions.
  - Both work only from Swift to Rust, only as arguments, and not in async functions. Bytes from Rust to Swift are still copied through `RustBuffer`.

What this means for Mapo:
1. Don't push full snapshots of big lists, such as file trees or process tables, through UniFFI records at frame rate. Send diffs and coalesce them in Rust, for example one batch per 16 ms.
2. Expose large or lazily read data as objects, since a handle is just a `u64`, or as one `Vec<u8>` in a compact encoding such as postcard or FlatBuffers that Swift decodes.
3. Keep terminal byte streams off UniFFI (see 1.6).

**Known pain points.**

- Library-vs-bindings checksum mismatches at startup. This only bites the dev loop, and only if the build isn't scripted.
- You have to build before you can generate.
- One large generated Swift file per crate.
- Breaking changes every minor version.
- The Swift 6 gaps above.
- No cancellation.
- Serialization cost for collections.
- Reference cycles between Swift listeners and Rust objects.
- The library-mode `--module-name` flag is not applied to `--swift-sources` ([#2362](https://github.com/mozilla/uniffi-rs/issues/2362)).

### 1.3 BoltFFI

Links: [repo](https://github.com/boltffi/boltffi), [docs](https://boltffi.dev).

- **Status.**
  - 0.31.0 came out 2026-09-28. The repo has about 914 stars and an MIT license.
  - The `boltffi` crate has about 70k downloads and two public reverse deps.
  - Crux replaced UniFFI with BoltFFI in 0.19, released 2026-06-08. It now generates a Swift `Core` adapter on top of BoltFFI's `CoreFfi` (see Crux's `CHANGELOG.md`).
- **Model.**
  - You mark types `#[data]` and functions or impls `#[export]`.
  - Primitives and `#[data]` structs of primitives pass by value or pointer without encoding. Strings and collections use a wire encoding.
  - `boltffi pack apple` emits an XCFramework and a `Package.swift`. It supports `include_macos` and `macos_architectures = ["arm64"]`.
- **Async and streams.**
  - Swift gets `async`, and cancelling the Task marks the Rust future cancelled.
  - `#[ffi_stream(item = T)]` becomes a Swift `AsyncStream<T>`, backed by a lock-free ring buffer that holds 256 items by default. When it fills, "new events are dropped. The producer continues without blocking." It can't carry lossless PTY bytes without a large buffer and care.
- **Open issues that matter to Mapo:**
  - exported classes aren't `Sendable` ([#778](https://github.com/boltffi/boltffi/issues/778))
  - fallible class constructors silently drop the error (#529)
  - no separate iOS and macOS deployment targets (#192)
  - multiple modules in one crate on Apple (#771)
- **Verdict.** It is the most interesting new option, with real Swift gains on records and bytes. It is also nine months old, comes from one vendor, and has no known shipping Swift app. A spike behind a thin wrapper is worth doing. I wouldn't build a solo rewrite on it today.

### 1.4 swift-bridge

Links: [repo](https://github.com/chinedufn/swift-bridge), [book](https://chinedufn.github.io/swift-bridge).

- **How it works.**
  - Like cxx, you declare a bridge module, and `build.rs` generates the Swift and C sides.
  - Opaque Rust types become Swift classes in three variants, `Foo`, `FooRef` and `FooRefMut`, which mirror Rust ownership and borrowing.
  - `#[swift_bridge(Sendable)]` checks `Send + Sync`, and `#[swift_bridge(Copy(N))]` covers small plain-data types.
  - The README says: "None of its generated FFI code uses object serialization, cloning, synchronization or any other form of unnecessary overhead."
- **Async.**
  - Rust futures run on a lazily created global multi-thread tokio runtime inside the crate. `src/async_support.rs` carries a `TODO: Audit to make sure that this is safe to be Send/Sync`.
  - Rust can call Swift async functions.
  - Swift 6 async codegen was fixed in January 2026 (#362).
- **Gaps.** Its own type table lists these as not implemented:
  - `&[T]`, `&mut [T]`, `Box<T>`, `Arc<T>`, `[T; N]`
  - closures from Swift into Rust
  - Strings also show up in Swift as `RustString`/`RustStr` rather than `String`.
- **Verdict.** Good for Rust calling Apple APIs, and for cheap calls. But it's a one-maintainer 0.1.x project with far fewer app-scale users than UniFFI.

### 1.5 Plain C ABI with cbindgen

```rust
// Rust: hot path. Lends a buffer to the callee for the duration of the call.
pub type MapoBytesCb = extern "C" fn(ctx: *mut c_void, tab_id: u64, ptr: *const u8, len: usize);
#[no_mangle] pub extern "C" fn mapo_set_output_sink(core: *const Core, cb: MapoBytesCb, ctx: *mut c_void) { /* store */ }
```
```c
// Headers/MapoFFI/module.modulemap. One module map may declare several modules.
module MapoFFI     { header "mapo_ffiFFI.h" export * }   // UniFFI-generated
module MapoHotPath { header "mapo_hot.h" export * }      // cbindgen-generated
```
```swift
let ctx = Unmanaged.passRetained(sink).toOpaque()          // release it when unregistering
mapo_set_output_sink(core, { ctx, tab, ptr, len in
    let sink = Unmanaged<OutputSink>.fromOpaque(ctx!).takeUnretainedValue()
    sink.consume(tab, UnsafeRawBufferPointer(start: ptr, count: len)) // copy or forward before returning
}, ctx)
```

Real code that uses this shape:

- **Ghostty.**
  - `include/ghostty.h` plus `include/module.modulemap` (`module GhosttyKit { umbrella header "ghostty.h" export * }`), packaged by `src/build/XCFrameworkStep.zig`.
  - `wakeup_cb` does `Unmanaged<App>.fromOpaque(ud!)` and then `DispatchQueue.main.async { app.appTick() }`.
- **[libsignal](https://github.com/signalapp/libsignal)** v0.103.1:
  - `#[bridge_fn]` macros generate C, JNI and Node glue from one Rust function, and cbindgen produces `signal_ffi.h`.
  - Swift sees it as a `.systemLibrary` module with hand-written wrappers.
  - `NativeHandleOwner` frees in `deinit`, and `withNativeHandle` uses `withExtendedLifetime`.
  - A `CPromise` C callback is bridged to a `CheckedContinuation` through `Unmanaged`, with cancellation IDs.
  - `SignalFfiErrorRef` passes through `checkError` and becomes `SignalError`.
- **Mullvad.** `ios/MullvadRustRuntime/EphemeralPeerReceiver.swift` uses `@_cdecl("swift_ephemeral_peer_ready")` with `Unmanaged<...>.fromOpaque`. Mullvad is now moving off this to UniFFI proc-macros:
  - commit 1184231a9b, "Use uniffi for the gotatun FFI in mullvad-ios", 2026-07-12
  - PR #11083, "Migrate API access to uniffi on iOS", merged 2026-09-17
  - The motive was less unsafe code, with callback interfaces replacing function pointers. That says a lot about what hand-written FFI costs to maintain.

Use a hand-written C ABI for one or two hot paths, not for the whole API.

### 1.6 High-frequency data: decide who owns the PTY bytes

This choice decides whether any bytes cross the FFI at all. There are three options.

#### Option 1: libghostty owns the PTY

This is the upstream embedding model.

- Upstream `ghostty_surface_config_s` (checked in `include/ghostty.h` on ghostty-org main) takes only `command`, `working_directory`, `env_vars` and `initial_input`. The surface spawns the child and owns it, and the host has no API for feeding bytes in.
- Rust never sees terminal output. Swift passes metadata to Rust through UniFFI calls:
  - the PWD, COMMAND_FINISHED and SHOW_CHILD_EXITED actions
  - `ghostty_surface_foreground_pid`
  - `ghostty_surface_tty_name`
- **Upside:** nothing high-frequency crosses the FFI.
- **Downsides:**
  - Rust can't scrape output. The only access is `ghostty_surface_read_text`.
  - Restarting a server tab means recreating the surface.
  - Every session dies with the app, including on each Sparkle update.

#### Option 2: Rust owns the PTY in-process and feeds libghostty

- cmux's MIT libghostty fork ([manaflow-ai/ghostty](https://github.com/manaflow-ai/ghostty), `include/ghostty.h`) already does this. The code is marked "cmux fork: delete this once upstream libghostty exposes an embedder-owned terminal IO backend". It adds:
  - `ghostty_surface_io_mode_e` with `GHOSTTY_SURFACE_IO_MANUAL`. The embedder owns the PTY, feeds output with `ghostty_surface_process_output(surface, ptr, len)` and receives encoded input through `io_write_cb`.
  - `GHOSTTY_SURFACE_IO_MANUAL_MIRROR`.
  - A `pty_tee_cb` that copies PTY bytes to the embedder even in EXEC mode. That allows log scraping without owning the PTY.
- cmux calls `process_output` off the main actor, from one serial `DispatchQueue` per surface. A lock keeps it from racing surface teardown (`Packages/macOS/CmuxTerminal/.../TerminalSurfaceRemoteOutputLane.swift`).
- cmux publishes prebuilt GhosttyKit XCFrameworks as GitHub releases on its fork and pins them by checksum. Its `docs/ghostty-fork.md` runs to more than 1,800 lines of patch notes, so the fork is large and moves quickly.
- In this model bytes flow from Rust into the terminal at a high rate. Use a C ABI callback that lends a pointer and length, coalesce per frame, and never send one `Vec<u8>` per read through UniFFI callbacks.
- A cleaner variant: the Rust core links against GhosttyKit directly and calls `ghostty_surface_process_output` itself, and `io_write_cb` points straight at a Rust `extern "C"` function. Swift then only creates the view and wires pointers together. I haven't verified whether that's safe from Rust threads; it needs a spike.

#### Option 3: a Rust daemon owns the PTY

This is how tmux, iTerm2 and shpool work.

- The libghostty surface runs a small attach client (`mapo attach <session>`) as its `command`. Bytes travel over a Unix socket, not FFI.
- Sessions survive app restarts and updates. The `mapo` CLI and the MCP server talk to the same daemon.
- iTerm2's session restoration works this way. Its docs say it runs "your jobs within long-lived servers rather than as child processes of iTerm2" ([docs](https://iterm2.com/documentation-restoration.html)).
- [shpool](https://github.com/shell-pool/shpool) is a Rust daemon with about 2k stars that does only persistence. It keeps an in-memory screen so it can redraw on reattach. Its macOS support still has failing tests.
- The cost is more moving parts: a launchd agent, protocol versioning, and signing a helper binary. But it fits Mapo's existing socket-controlled design, and the VS Code ptyHost split Mapo inherits today.

My take: give the Rust core PTY ownership from the start, either option 2 now or option 3 later. The strongest agent-first features need it: "let Claude read the dev server log over MCP", restart policies that keep scrollback, and headless tests of the core with `cargo test`.

#### Delivering state updates to Swift

State updates include tab status from Claude hooks, port lists and file-tree changes. Coalesce them in Rust, deliver batches of small diff records, and apply them on the main actor. UniFFI supports two styles.

- **Pull.** Swift loops on `await core.nextEvents()`. Ordering and backpressure come for free, and there's no foreign trait. LDK Node offers this style: `next_event()`, then `wait_next_event()` or `next_event_async()`, then an `event_handled()` ack. Because the generated async code isn't Swift 6 clean, compile the bindings in Swift 5 mode.
- **Push.** A foreign-trait delegate runs on a Rust thread and yields into an `AsyncStream` continuation. One `@MainActor` task drains the stream.
  - This is Element X's `SDKListener` in `ElementX/Sources/Other/SDKListener.swift`. It finishes the stream in `deinit`, because dropping a continuation doesn't end the stream (SE-0406).
  - Don't spawn a separate `Task { @MainActor in }` per callback if order matters.

```swift
@MainActor @Observable final class AppModel {
    private(set) var tabs: [UInt64: TabSnapshot] = [:]
    private let core: Core
    init(core: Core) { self.core = core }
    func pump() async {
        while !Task.isCancelled {
            for event in await core.nextEvents() {      // suspends off the main thread
                switch event {
                case .tabUpserted(let tab): tabs[tab.id] = tab
                case .tabRemoved(let id): tabs[id] = nil
                case .portsChanged: break
                }
            }
        }
    }
}
```

### 1.7 Others worth knowing

- **typeshare** 1.0.5, from 1Password, generates Swift `Codable` types from Rust for JSON message passing. It isn't a binding generator; pair it with a byte-oriented FFI or IPC.
- **Crux** is an architecture that runs over a thin byte FFI (see 2.8).
- **Interoptopus** 0.16.5 targets C# first. **swift-rs** 1.0.8 goes the other way, Rust calling Swift, and Tauri uses it.
- **Raycast 2.0**, launched 2026-05-14, is a Swift host plus a Rust data layer and indexer, plus Node, plus a React WebView front end.
  - "interfaces are declared in one place and typed clients are generated for every side."
  - On SwiftUI: "It matured in parallel with Raycast and never quite cleared our bar for performance and control" ([blog](https://www.raycast.com/blog/a-technical-deep-dive-into-the-new-raycast)).
  - Raycast keeps a fork of uniffi-rs ([raycast/uniffi-rs](https://github.com/raycast/uniffi-rs)). The post doesn't say whether UniFFI sits on its Swift and Rust boundary.

---

## 2. Production apps with a Rust core and a Swift UI

### 2.1 Versions in production, September 2026

| Project | Interop in use |
|---|---|
| matrix-rust-sdk | UniFFI 0.32.1 |
| application-services | UniFFI 0.32.1 |
| Bitwarden | UniFFI `=0.32.0` |
| wordpress-rs | UniFFI 0.32.0 |
| Proton Pass | UniFFI 0.32 |
| Mullvad iOS | moved from cbindgen to UniFFI; PR merged 2026-09-17 |
| libsignal | hand-written or cbindgen C ABI |
| Delta Chat | hand-written or cbindgen C ABI |
| PhotoRoom | C FFI plus JSON |
| Crux | BoltFFI 0.30.1 |

### 2.2 Element X iOS and matrix-rust-sdk

This is the best reference for pushing state from Rust to Swift.

**Interop.**
- `bindings/matrix-sdk-ffi` is mostly proc-macros.
- A wrapper macro, `matrix_sdk_ffi_macros::export`, adds `async_runtime = "tokio"` to exports that contain an `async fn`.
- matrix-sdk is at 0.19.1, released 2026-09-18.

**Packaging.**
- [matrix-rust-components-swift](https://github.com/matrix-org/matrix-rust-components-swift) is a Swift package. It has `.binaryTarget(url: ...MatrixSDKFFI.xcframework.zip, checksum:)` plus a thin source target of generated Swift.
- Element uses its own fork, [element-hq/matrix-rust-components-swift](https://github.com/element-hq/matrix-rust-components-swift), pinned with `exactVersion: 26.09.25` in its XcodeGen `project.yml`.

**State lives in Rust.**
- Rust exposes observables with `eyeball` / `eyeball-im` (0.9.1, 2026-09-14).
- Lists arrive as `VectorDiff` batches through callback interfaces.
- The initial state arrives as a `Reset` in the same callback.
- Each subscription returns a `TaskHandle` whose `Drop` aborts the Rust task.

```rust
#[matrix_sdk_ffi_macros::export(callback_interface)]
pub trait TimelineListener: SyncOutsideWasm + SendOutsideWasm { fn on_update(&self, diff: Vec<TimelineDiff>); }

pub async fn add_listener(&self, listener: Box<dyn TimelineListener>) -> Arc<TaskHandle> {
    let (items, stream) = self.inner.subscribe().await;
    listener.on_update(vec![TimelineDiff::new(VectorDiff::Reset { values: items })]);
    Arc::new(TaskHandle::new(get_runtime_handle().spawn(async move { /* forward stream diffs */ })))
}
```

- `TimelineDiff` is a `uniffi::Enum` with these variants: Append, Clear, PushFront, PushBack, PopFront, PopBack, Insert, Set, Remove, Truncate and Reset.
- Items are `Arc<TimelineItem>`, so they cross as handles rather than copied records.

**Swift side, Swift 6.2.** The app sets `SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor` and `SWIFT_APPROACHABLE_CONCURRENCY`.
- `SDKListener<T>` is a `nonisolated final class ... Sendable` that conforms to each generated listener protocol.
- `SDKListener.onMainActor` feeds an `AsyncStream` that one `Task { @MainActor ... for await }` drains, in FIFO order with one update in flight.
- `TimelineItemProvider` and `RoomSummaryProvider` turn diffs into a Swift `CollectionDifference` off the main actor (`@concurrent static func processDiffs`), assign the result back, and publish it through `CurrentValueSubject`.

**View models.**
- `StateStoreViewModelV2` is an `@Observable` `Context` holding a `State` struct plus a `ViewAction` enum handled in `process(viewAction:)`.
- `ClientProxy`, `RoomProxy` and `TimelineProxy` wrap UniFFI objects behind Swift protocols and map thrown `ClientError` values to `Result<T, ClientProxyError>`.
- Sourcery generates mocks from the UniFFI protocols.

**Mac.** There is no native macOS target (`SUPPORTS_MACCATALYST: false`, `ARCHS: arm64`). On Macs it runs only as the iOS app on Apple Silicon.

### 2.3 Firefox iOS and application-services

- **Interop.** UniFFI 0.32.1, with a mix of UDL and proc-macros.
- **One static library.**
  - Every component goes into one "megazord" static library (`megazords/ios-rust`), so all components share one Rust std.
  - The separate [rust-components-swift](https://github.com/mozilla/rust-components-swift) repo was archived in December 2025.
  - firefox-ios now has an in-repo local package, `MozillaRustComponents/Package.swift`, with a binaryTarget pointing at a Taskcluster URL and a checksum.
  - The generated Swift is committed.
- **State.**
  - It lives in SQLite owned by Rust.
  - Access is request/response only: Swift wrappers like `RustPlaces` call synchronous UniFFI functions on serial `DispatchQueue`s and return results through completion handlers. Nothing is pushed.
- **Swift 6.** The friction shows as `extension BookmarkNodeData: @unchecked @retroactive Sendable {}` with TODOs.

### 2.4 Bitwarden

- **Interop.**
  - [sdk-internal](https://github.com/bitwarden/sdk-internal) uses UniFFI `=0.32.0` with `#[uniffi::export(async_runtime = "tokio")]`.
  - [sdk-swift](https://github.com/bitwarden/sdk-swift) is a separate package. Its binaryTarget points at an Azure blob, and it compiles the generated Swift with `-suppress-warnings`.
- **Errors.**
  - One `BitwardenError` absorbs every other error through `#[from]`.
  - The `bitwarden-uniffi-error` crate exists because a mismatched error inside `uniffi::custom_type!` panics instead of returning.
- **State runs the other way.** Under "Client-Managed State" (`crates/bitwarden-state`), Swift implements async foreign-trait repositories that Rust calls, such as `func get(id:) async -> Cipher?`.
- **macOS.** The desktop app is Electron.
  - Its macOS AutoFill extension is Swift and calls a Rust `autofill_provider` staticlib through UniFFI (`bitwarden/clients/apps/desktop/desktop_native/autofill_provider`). That library talks to the Electron app over a Unix socket.
  - Its `build.sh` builds arm64 and x86_64, runs `lipo`, generates bindings in library mode and assembles an XCFramework.

### 2.5 1Password

- **Core.** The Rust core is headless and handles sync, the database, crypto and server calls.
- **How frontends talk to it.**
  - Frontends send JSON "invocations" with a completion callback into the embedded core. Inside the core, a tokio loop reads a channel.
  - Types are shared through typeshare. The source is the Syntax podcast, episode 776, 2024-05-31.
  - On the web, a Redux bridge crate keeps core and UI state in sync.
- **Platforms.** iOS is SwiftUI. The Mac app is Electron: they "stopped work on the SwiftUI Mac app" ([1Password blog, 2021-08-12](https://1password.com/blog/1password-8-the-story-so-far)).
- **Unverified:** whether the Mac app is still Electron in 2026, and the exact FFI entry points.

### 2.6 Signal libsignal

See 1.5. It gives maximum control, at the price of a lot of unsafe glue that it maintains itself. This is the model Mullvad just left.

### 2.7 Other apps

**Proton Mail iOS.** The new apps shipped in 2025 with "almost 80%" shared code ([blog](https://proton.me/blog/next-generation-proton-mail-mobile-apps), repo [ProtonMail/ios-mail](https://github.com/ProtonMail/ios-mail)).
- A local UniFFI package, `ProtonPackages/proton_app_uniffi`, built with XcodeGen.
- Observation is "LiveQuery": a callback with no payload, after which Swift re-fetches a snapshot on the MainActor. `WatchHandle.disconnect()` runs in `deinit`.
- Lists use "Scroller" callbacks with typed updates such as `MessageScrollerUpdate`.
- Rust returns result enums (`.ok`/`.error`) instead of throwing.
- Proton Pass uses [proton-pass-common](https://github.com/protonpass/proton-pass-common) with UniFFI 0.32.

**[wordpress-rs](https://github.com/Automattic/wordpress-rs).**
- Its root `Package.swift` (tools version 6.2) switches between a local and a release XCFramework binaryTarget.
- The generated wrapper target builds with `.swiftLanguageMode(.v5)`.
- The Rust SQLite cache sends `update_hook` events through a UniFFI `DatabaseDelegate.didUpdate`, which Swift turns into NotificationCenter, Combine or AsyncSequence events.

**[Bitkey](https://github.com/proto-at-block/bitkey).** Kotlin Multiplatform plus Rust through UniFFI. A local SPM package holds `binaryTarget(path: coreFFI.xcframework)` next to the generated sources.

**[LDK Node](https://github.com/lightningdevkit/ldk-node)** 0.7.0. A pull-based event queue over UniFFI.

**[Delta Chat iOS](https://github.com/deltachat/deltachat-ios).** A C API. A background thread loops on a blocking `dc_get_next_event()` and posts coarse "X changed" notifications; the UI then re-queries.

**Mac desktop apps built on a Rust core are rare.**

- **cmux** is Swift/AppKit on libghostty, which is written in Zig.
  - Its domain state lives in Swift: `final class Workspace: ObservableObject` with `@Published`.
  - Rust appears only in islands:
    - `Native/CommandPaletteNucleoFFI`, a hand-written `extern "C"` cdylib loaded with `dlopen`
    - `Native/DiffSidecar`, a stdio sidecar with a typed protocol
    - `cmux-tui`, a Rust TUI client using `ghostty-vt-sys`
  - There's also a Go `daemon/remote`.
- **Ghostty**'s embedding model is the one to copy for high-frequency work.
  - The core owns the PTY I/O and render threads and draws into the Metal layer itself.
  - Swift receives `action_cb` for semantic actions, and `wakeup_cb` schedules a main-thread tick.
- **Raycast 2.0.** See 1.7.
- **OrbStack.** Swift plus Rust, Go and C. How they interoperate is unverified; the app is closed source.
- **Small repos** worth reading for code but not maturity:
  - `asmuelle/agent-ssh`: SwiftUI/AppKit plus SwiftTerm plus UniFFI. A `PTYBufferManager` flushes every 16 ms, or immediately at 64 KB.
  - `faberline/workbench`, issue #1: plans a Rust PTY sidecar with a versioned protocol.

### 2.8 Crux (redbadger/crux)

**Status.** crux_core 0.20.0 was released 2026-08-07, and master is at 0.21.0, unreleased. It calls itself production-ready and changes a lot.

| Version | Change |
|---|---|
| 0.17, 2026-03-20 | Removed the Capability API. Only `Command` remains |
| 0.19, 2026-06-08 | Replaced UniFFI with BoltFFI. Removed `crux_cli`. Added `EffectRouter` lanes: Serialized, Parked (opaque handles), and handled locally in the core |
| master | Generates a Swift `Core` adapter, an ObservableObject with `core.update(.increment)` and `core.view` (#590 and #594, merged 2026-09-21). Removed serde-generate typegen (#591) |

**Model.**
- A pure `update(event, &mut model) -> Command<Effect, Event>` plus `view(&model) -> ViewModel`.
- Events, effects and the ViewModel cross as bincode bytes. `CoreFfi::update`, `resolve` and `view` return `Vec<u8>`.
- Types come from facet typegen (facet_generate 0.22).
- `examples/counter/apple` uses XcodeGen with macOS and iOS targets.
- Long-lived streams exist (`#[operation(stream)]`, `Command::stream_from_shell`).

**Costs.**
- Every render re-serializes the whole ViewModel; there's no built-in diffing. PhotoRoom had to build key-path patches and automatic ViewModel diffing on top. See their [part 3, 2026-01-15](https://www.photoroom.com/inside-photoroom/building-live-collaboration-in-rust-for-millions-of-users-part-3), which describes Pathogen and Difficient.
- Other risks:
  - bincode 1.3 is unmaintained (#471).
  - Issue #577: the executor can evict a live task in a race.
  - Entries in the stream registry are never freed after a stream ends.
- The README lists Proton as a user. It's unverified that the shipped Proton Mail iOS app uses Crux; its public repo shows plain UniFFI.

**Fit for Mapo: poor as the backbone.**
- Mapo's I/O (PTYs, sockets, file watching, processes) belongs in Rust and must be shared with the CLI and MCP.
- Crux pushes I/O out to the shell by default, and keeping it in Rust depends on the brand-new router.
- Pushing terminal bytes or file-tree changes through `update()` and a full-ViewModel bincode render is wasteful.
- Take the idea, not the framework: a pure, testable reducer in Rust whose effects are run by Rust services.

### 2.9 Patterns to take for Mapo

1. **Rust owns all domain state.** That covers workspaces, tabs, process and server status, setups and ports. The Swift UI, the `mapo` socket CLI, the MCP server and the Claude Code hooks all change it through one command API. This is the reverse of cmux, where state lives in Swift.
2. **Lists travel as diffs.** Use an `eyeball-im` `ObservableVector` and send `VectorDiff` batches through a UniFFI callback, with the initial snapshot as a `Reset`. Every subscription returns a handle that cancels when dropped or deinitialized.
3. **Scalars and coarse events.** Low-frequency scalars can be invalidated and then pulled, Proton-style. Coarse app-wide events can go through a pull queue, as in LDK Node or Delta Chat.
4. **Swift side.**
   - A `nonisolated Sendable` listener feeds an `AsyncStream` that one task drains.
   - Apply diffs off the main actor and publish on it.
   - View models are `@Observable` stores with a State plus ViewAction shape.
   - Bindings live in their own module, in Swift 5 mode.
5. **Terminal bytes never go on the state channel.**
6. **Errors.** Use one flat UniFFI error enum, Bitwarden-style, and have Swift proxies map it to domain `Result`s, Element X-style.

---

## 3. Build pipeline

### 3.1 Shape of the artifact

- **One Rust `staticlib` for the whole core, a "megazord".**
  - Two Rust staticlibs in one app duplicate std and runtime symbols. See the [megazord design doc](https://mozilla.github.io/application-services/book/design/megazords.html) and [ai-coustics on symbol collisions](https://ai-coustics.com/blog/libpatcher).
  - [cargo-xcode](https://gitlab.com/kornelski/cargo-xcode) 1.11.1 says: "You should almost always use static libraries."
  - A cdylib means embedding it in `Contents/Frameworks`, running `install_name_tool -id @rpath/...` and re-signing. cmux does this in a build phase and loads the library with `dlopen`.
- **Build arm64 only.** Your machine runs Darwin 27 (macOS 27), which only runs on Apple Silicon, and jayjay ships arm64 only.
  - To support Intel Macs on macOS 26 or earlier, combine the `aarch64-apple-darwin` and `x86_64-apple-darwin` `.a` files with `lipo -create`.
  - Then run `xcodebuild -create-xcframework -library universal.a -headers H -output X.xcframework`, which gives one `macos-arm64_x86_64` slice.
- **Module map.**
  - Name it `module.modulemap` and write `module MapoFFI { header "..." export * }`, not `framework module`.
  - GhosttyKit and a Rust XCFramework would both put `Headers/module.modulemap` at the root, and the two collide in `$(BUILT_PRODUCTS_DIR)/include` ([swift-build #1746](https://github.com/swiftlang/swift-build/issues/1746), opened 2026-09-17). Mapo would ship both.
  - Nest yours as `Headers/MapoFFI/module.modulemap`, as cargo-swift does.
- **Pin `MACOSX_DEPLOYMENT_TARGET`.**
  - Set it in `.cargo/config.toml` under `[env]` with `force = true`.
  - rustc rebuilds when it changes ([rust#129432](https://github.com/rust-lang/rust/issues/129432)). Without the pin, builds from Xcode and from the terminal keep invalidating each other, and you get "built for newer macOS" linker warnings.
- **Profiles.**
  - Keep `panic = "unwind"`. UniFFI turns panics into Swift errors with `catch_unwind` and "can't always catch panics... when the panic handler is set to abort".
  - Release: `lto = "fat"`, `codegen-units = 1`, `debug = "line-tables-only"`.
  - `-C strip` doesn't touch staticlibs, so strip the final app instead.
  - Never strip the `.a` before library-mode bindgen, which reads UniFFI metadata symbols from it.

### 3.2 Tools for bindings and packaging

- **UniFFI 0.32.2 with `uniffi-bindgen-swift`.** See 1.2.
- **cargo-swift 0.11.1** ([repo](https://github.com/antoniusnaumann/cargo-swift), released 2026-05-20).
  - `cargo swift package -p macos --release -y` produces a SwiftPM package with `.binaryTarget(path:)` plus a Swift target.
  - It supports UniFFI only up to 0.31.1 and lags behind each release. Good for a five-minute prototype, not for Mapo's build.
- **BoltFFI 0.31.0.** `boltffi pack apple`, with `ffi-only`, `bundled` or `split` layouts.
- **swift-bridge 0.1.59.**
  - `build.rs` calls `parse_bridges(...).write_all_concatenated(...)`.
  - Then either an Xcode Run Script with an `.xcfilelist` of outputs, or `swift-bridge-cli create-package --macos ...`.

### 3.3 Hooking it into Xcode

**(a) A Run Script phase that calls cargo.**
- Map `ARCHS`/`TARGET_TRIPLE` to Rust triples, as cmux does.
- Set `ENABLE_USER_SCRIPT_SANDBOXING=NO`. It has defaulted to YES since Xcode 15 and blocks cargo.
- Reset `PATH` and declare output files.
- It's simple, but Xcode leaks `SDKROOT` and friends into cargo and invalidates its caches.

**(b) Recommended: an external script, plus a local SwiftPM wrapper with `.binaryTarget(path:)`.**
- The script is `just` or an xtask that builds the core and the bindings.
- jayjay, Dory, cargo-swift, BoltFFI and Crux all do this.
- It behaves the same under XcodeGen, Tuist, a hand-kept project, and `swift test`.

**(c) A remote `binaryTarget(url:checksum:)`** is for publishing SDKs. Ferrostar, automerge-swift and Firefox iOS use it. Mapo doesn't need it.

```bash
# just ffi: Debug, host arch only, sharing target/debug with cargo test (jayjay's trick)
cargo build -p mapo-ffi
LIB=target/debug/libmapo_ffi.a; XCF=apple/MapoCore/MapoFFI.xcframework
cmp -s "$LIB" "$XCF/macos-arm64/libmapo_ffi.a" && exit 0      # skip the rewrap when unchanged
cargo run -q -p uniffi-bindgen-swift -- "$LIB" build/gen --swift-sources --headers --modulemap --modulemap-filename module.modulemap
mkdir -p build/hdr/MapoFFI && cp build/gen/*.h build/gen/module.modulemap build/hdr/MapoFFI/
cp build/gen/*.swift apple/MapoCore/Sources/MapoBindings/
rm -rf "$XCF" && xcodebuild -create-xcframework -library "$LIB" -headers build/hdr -output "$XCF"
```

```swift
// apple/MapoCore/Package.swift
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "MapoCore",
    platforms: [.macOS("26.0")],
    products: [.library(name: "MapoCore", targets: ["MapoCore"])],
    targets: [
        .binaryTarget(name: "MapoFFI", path: "MapoFFI.xcframework"),
        // Generated by uniffi-bindgen-swift. Swift 5 mode sidesteps UniFFI's Swift 6 gaps (wordpress-rs does this).
        .target(name: "MapoBindings", dependencies: ["MapoFFI"], swiftSettings: [.swiftLanguageMode(.v5)]),
        // Hand-written facades, AsyncStream adapters, stores. Swift 6.
        .target(name: "MapoCore", dependencies: ["MapoBindings"]),
        .testTarget(name: "MapoCoreTests", dependencies: ["MapoCore"]),
    ]
)
```

### 3.4 Generating the Xcode project

- **XcodeGen 2.46.0**, 2026-07-16, MIT.
  - Supports synced folders, `.icon` files and local packages.
  - jayjay, Element X, Proton Mail and the Crux examples all use it.
  - Gitignore the `.xcodeproj`, the `.xcframework` and the generated Swift.
- **Tuist 4.210.0.**
  - Added `.foreignBuild(name:script:inputs:output: .xcframework(path:linking:))` in [PR #9400](https://github.com/tuist/tuist/pull/9400), February 2026. It hashes inputs to decide when to rerun.
  - It's heavier, and the only example I found is Kotlin Multiplatform, not Rust.
- **A hand-kept `.xcodeproj`.** Ghostty, cmux, Dory and Lockbook do this. Synchronized folders in Xcode 16 and later reduce `pbxproj` churn.
- **SwiftPM only, plus a packaging script.**
  - [CodexBar](https://github.com/steipete/CodexBar)'s 672-line `package_app.sh` shows the cost:
    - a hand-written Info.plist
    - `iconutil`
    - embedding Sparkle with `-add_rpath`
    - moving resource bundles
  - The `swift build` CLI copied `.xcassets` without compiling them in SwiftPM before 6.4.
  - `UNUserNotificationCenter` crashes outside a real bundle, and TCC prompts need a bundle ID.
  - Not worth it for an app with entitlements, Sparkle and assets.

A sketch of the XcodeGen spec for Mapo:

```yaml
name: Mapo
options: { bundleIdPrefix: dev.mapo, deploymentTarget: { macOS: "26.0" } }
packages:
  MapoCore: { path: apple/MapoCore }
  Sparkle: { url: https://github.com/sparkle-project/Sparkle, from: 2.10.0 }
targets:
  Mapo:
    type: application
    platform: macOS
    sources: [apple/Mapo]
    dependencies:
      - package: MapoCore
      - package: Sparkle
      - framework: vendor/GhosttyKit.xcframework
    settings:
      base:
        SWIFT_VERSION: "6.0"
        SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor
        ENABLE_HARDENED_RUNTIME: YES
        ARCHS: arm64
```

### 3.5 Keeping the dev loop fast

- Build only the host arch in Debug.
- Skip rewrapping the XCFramework when the `.a` hasn't changed. Dory stamps an input fingerprint with `--if-needed`.
- Share `target/debug` between `cargo test` and the app build.
- Ghostty keeps two XCFramework modes: native for dev, universal for release.
- sccache is of limited use here.
  - It needs incremental compilation off.
  - It can't cache bin, dylib, cdylib or proc-macro crates.
  - It only helps CI, or caching dependencies across worktrees.
- Swift side: Xcode 26 adds `COMPILATION_CACHE_ENABLE_CACHING=YES`.
- Watch out: after an unscripted rebuild, a stale library and fresh bindings produce UniFFI's checksum mismatch at startup. Always regenerate both in one recipe.

### 3.6 Debugging across the boundary

- **Debug builds.** lldb reads Rust DWARF from the `.a` members through the debug map.
- **Release builds.** Xcode's `dsymutil` (`dwarf-with-dsym`) pulls the Rust DWARF into `Mapo.app.dSYM`, as long as the release profile keeps `debug = "line-tables-only"` or more.
- **Breakpoints and Xcode.** Set breakpoints with `breakpoint set -f pty.rs -l 42`, or add the Rust folder to the project for navigation. Xcode has no Rust code intelligence.
- **Rust pretty printers in Xcode.** Add `command script import "<rustc --print sysroot>/lib/rustlib/etc/lldb_lookup.py"` to `~/.lldbinit-Xcode`. That's what `rust-lldb` does.
- **From VS Code.** Attach CodeLLDB to the app's PID. Set `lldb.library` to Xcode's LLDB to get Swift frames ([wiki](https://github.com/vadimcn/codelldb/wiki/Swift)).
- **Crashes.** Ghostty uploads its dSYM zip with `sentry-cli dif upload`.

### 3.7 Testing both sides

- `cargo test` or nextest for the core. This is where most Mapo logic should be tested, with real PTYs.
- `uniffi::build_foreign_language_testcases!("tests/x.swift")` runs Swift test scripts from cargo.
- `swift test` on the MapoCore package covers bindings and facades.
- `xcodebuild test` covers app-hosted tests and UI tests. jayjay shards UI tests with `build-for-testing` and `test-without-building`.

### 3.8 CI on GitHub Actions

- **Runners** (checked against the [runner-images README](https://github.com/actions/runner-images)):
  - `macos-latest` and `macos-26` are arm64.
  - `macos-26-intel` and `macos-15-intel` are x64.
  - `xcode-27` is a preview label.
  - macOS 14 images are deprecated.
- **Cost.** macOS minutes are expensive for private repos. The fork reported $0.062/min, with a 10x multiplier against included minutes. Public repos are free.
- **Doing releases locally.** jayjay runs releases on a laptop through `just shell::release` with a `notarytool` keychain profile. That saves minutes and keeps secrets out of CI.

```yaml
jobs:
  test:
    runs-on: macos-26
    steps:
      - uses: actions/checkout@v7
      - uses: dtolnay/rust-toolchain@stable
      - uses: Swatinem/rust-cache@v2
      - run: brew install just xcodegen xcbeautify
      - run: cargo test --workspace
      - run: just ffi && xcodegen && xcodebuild -scheme Mapo -derivedDataPath build/dd test | xcbeautify
```

### 3.9 Distribution: signing, notarization, DMG, Sparkle

- **Code signing, inside out.**
  - Run `codesign -f -o runtime --timestamp -s "$ID"` without `--deep`.
  - Sign the Rust `mapo` CLI in `Contents/MacOS` first, then Sparkle's `XPCServices/*.xpc`, `Autoupdate`, `Updater.app` and the framework.
  - Sign the app last, with `--entitlements`.
  - Ghostty's comment on the XPC services: they "aren't used since we don't sandbox... still need to be codesigned".
- **Notarization with an App Store Connect API key**, following [Ghostty's release workflow](https://github.com/ghostty-org/ghostty/blob/main/.github/workflows/release-tag.yml):
  ```bash
  xcrun notarytool store-credentials prof --key AuthKey.p8 --key-id "$KID" --issuer "$ISS"
  xcrun notarytool submit Mapo.dmg --keychain-profile prof --wait
  xcrun stapler staple Mapo.dmg
  ```
  - A zip can't be stapled. Staple the `.app`, then re-zip it (jayjay does this).
  - cmux uses Apple ID credentials instead and adds `spctl` / `syspolicy_check`.
  - Alternative: `xcodebuild archive` followed by `-exportArchive` with `method=developer-id`. Lockbook drives this from a Rust xtask.
- **DMG.** Ghostty and cmux use [sindresorhus/create-dmg](https://github.com/sindresorhus/create-dmg) v8.1.0 with `--identity`. dmgbuild and `hdiutil` also work.
- **Sparkle 2.10.0**, released 2026-09-13, needs macOS 12 or later and no longer supports CocoaPods.
  - Run `generate_keys`, then `-x` to export. Put `SUPublicEDKey` and `SUFeedURL` in Info.plist.
  - Build the feed with `generate_appcast --ed-key-file k --download-url-prefix https://github.com/<you>/mapo/releases/download/vX/ dir/`.
  - Host the feed at `releases/latest/download/appcast.xml` (cmux) or raw GitHub (jayjay).
  - cmux notes that `generate_appcast` silently skips the signature if the key doesn't match the app's public key.
- **rcodesign.** apple-codesign 0.29.0 can sign and notarize from Linux, but its last release was November 2024.

### 3.10 Notes specific to a terminal app

- **No sandbox.** A terminal spawns arbitrary processes, so the Mac App Store is out. Distribute with Developer ID plus notarization.
- **Entitlements.** Ghostty's release entitlements have no `cs.*` exceptions, because PTYs and shells work under the hardened runtime. It only adds `automation.apple-events` and TCC resource keys. Add `disable-library-validation` or `allow-jit` only if you `dlopen` libraries signed by someone else or embed a JIT.
- **TCC blames the responsible process.** A child process such as Claude Code's `/voice` is silently denied the microphone unless Mapo is signed with `com.apple.security.device.audio-input` and has `NSMicrophoneUsageDescription` ([cmux #1325](https://github.com/manaflow-ai/cmux/issues/1325)). Ghostty explored a launch helper so children stop counting against the terminal ([#9263](https://github.com/ghostty-org/ghostty/issues/9263)); I didn't confirm what shipped.
- **Updates kill sessions.** A Sparkle update relaunches the app, which kills every in-process PTY, dev server and Claude session. Option 3 in 1.6 is the only fix.

---

## 4. Templates and reference repos

Stars and last push as of 2026-09-28.

| Repo | Stars / pushed / license | What it has | Verdict for Mapo |
|---|---|---|---|
| [hewigovens/jayjay](https://github.com/hewigovens/jayjay) | 162 / 2026-09-28 / BSL-1.1 app, Apache-2.0 crates | A native SwiftUI jj GUI with a UniFFI crate (`crates/jayjay-uniffi`), a local SwiftPM package (`shell/mac/Package.swift`), justfile `ffi` recipes that skip unchanged libraries, XcodeGen, Sparkle (`SparkleUpdater.swift`), notarization, a bundled Rust CLI, and CI on `macos-26` with sharded UI tests | The best blueprint. Copy the build layout; the license allows reading and learning |
| [Augani/dory](https://github.com/Augani/dory) | 1.6k / 2026-09-28 / GPL-3.0 | An I/O-heavy dev-infra app. A universal UniFFI XCFramework with a fingerprint check, a local SwiftPM `binaryTarget`, a Swift 6 patch on the generated bindings, and a hand-kept project | Read it, don't copy it (GPL) |
| [ghostty-org/ghostty](https://github.com/ghostty-org/ghostty) | 61.7k / MIT | Core library, then XCFramework, then an Xcode app. A release workflow with API-key notarization, Sparkle, create-dmg and Sentry dSYMs | Copy the release pipeline and the C ABI pattern |
| [manaflow-ai/cmux](https://github.com/manaflow-ai/cmux) | 27.5k / GPL-3.0+ (server BUSL-1.1) | The closest product analogue: libghostty fork, AppKit windows, NSTableView sidebar, NSOutlineView file tree, release pipeline, entitlement lessons | Study it. Its ghostty fork and Bonsplit are MIT |
| [redbadger/crux](https://github.com/redbadger/crux) examples (counter, weather) | Apache-2.0 | Real macOS targets using XcodeGen, `boltffi pack apple` and Swift 6.2 strict concurrency | Only if you adopt Crux |
| [ianthetechie/uniffi-starter](https://github.com/ianthetechie/uniffi-starter) | 110 / 2026-02-03 / BSD-3 | A good `uniffi-bindgen-swift` + SwiftPM + release-checksum layout | iOS and Android only, with stale CI (macos-14, Xcode 15.3). For learning |
| [cargo-swift](https://github.com/antoniusnaumann/cargo-swift) | 289 / 2026-08-30 / Apache-2.0 | Hello-world packages | A five-minute prototype. Lags UniFFI releases |
| [swift-bridge](https://github.com/chinedufn/swift-bridge) `examples/codegen-visualizer` | MIT/Apache | A minimal macOS app built with a Run Script | Only if you pick swift-bridge |
| [automerge-swift](https://github.com/automerge/automerge-swift) | 325 / 2026-04-02 / MIT | How to package a multi-platform XCFramework library | Reference for packaging only |
| [lockbook](https://github.com/lockbook/lockbook) | 437 / 2026-09-27 / Unlicense | A Rust core, SwiftUI apps, and an xtask that archives, exports and notarizes | A good second reference for the release flow |
| [wordpress-rs](https://github.com/Automattic/wordpress-rs) | 37 / 2026-09-28 / MPL-2.0 | Local/release XCFramework switch; bindings in Swift 5 mode | Copy the `Package.swift` pattern |

These are stale; skip them: simlay/swift-rust-xcode-template (2020), AstroHQ/RustXCFrameworkExample (2021), jariz/Speck (2024), and the BoltFFI starters, which have zero stars.

---

## 5. Mostly SwiftUI, or AppKit with SwiftUI islands?

### 5.1 What real apps do

I read the source at HEAD on 2026-09-28.

**Ghostty** (`macos/Sources`, commit 12752b2).
- 162 Swift files: 57 import SwiftUI, 95 import AppKit/Cocoa.
- The lifecycle is AppKit: `App/main.swift` calls `NSApplicationMain`, with `MainMenu.xib`, xib-based `NSWindow` subclasses, and `BaseTerminalController: NSWindowController`.
- Window content is an `NSHostingView` holding the SwiftUI `TerminalView`.
- Splits:
  - A custom SwiftUI `SplitView` renders an immutable `SplitTree<SurfaceView>` that AppKit owns.
  - [PR #7523](https://github.com/ghostty-org/ghostty/pull/7523) (June 2025) moved all split logic out of SwiftUI. Mitchell Hashimoto: "we've taken a more balanced approach of SwiftUI for views and AppKit for data and business logic, and this has proven a lot more maintainable."
- The terminal is `SurfaceView_AppKit.swift`, a 2,507-line `NSView` implementing `NSTextInputClient`.
- Tabs are native `NSWindow` tabs, with titlebar hacks that broke on Tahoe ([#9597](https://github.com/ghostty-org/ghostty/issues/9597)) and again on macOS 27 ([#13070](https://github.com/ghostty-org/ghostty/issues/13070)).
- Workarounds in source:
  - `NSAlert` "due to SwiftUI bugs"
  - `makeFirstResponder` retried with exponential backoff
  - a `ResponderChainInjector` for the SwiftUI palette
- In [devlog 002](https://mitchellh.com/writing/ghostty-devlog-002) (August 2023), the app was "100% SwiftUI" until non-native fullscreen needed an `NSWindow` subclass.

**cmux** (commit 3da1b53).
- 2,427 Swift files: 338 SwiftUI, 713 AppKit, 73 `NSViewRepresentable`, 24 `NSOutlineView`.
- It starts from a SwiftUI `App`, but the main windows are AppKit (`CmuxMainWindow: NSWindow`).
  - `MainWindowHostingView` shadows a private `NSHostingView` selector, because the hosting view kept growing the window "without bound".
- Terminals live in a window-level AppKit "portal" ([PR #83](https://github.com/manaflow-ai/cmux/pull/83)). Only the selected workspace is mounted.
- The workspace sidebar moved from SwiftUI `LazyVStack` to `NSTableView` in [PR #8270](https://github.com/manaflow-ai/cmux/pull/8270) (July 2026). That fixed "scrollbar stutter from LazyVStack height re-estimation and the seconds-long tap latency after flinging a 100-workspace sidebar".
  - The trigger was [#2586](https://github.com/manaflow-ai/cmux/issues/2586): 100% main-thread CPU in `LazySubviewPlacements.placeSubviews`, which also deadlocked the CLI.
- The file explorer is an `NSOutlineView` "with no SwiftUI intermediaries".
- Splits and tabs use [Bonsplit](https://github.com/manaflow-ai/bonsplit), a SwiftUI API over nested `NSSplitView`s.
- Keyboard handling:
  - One app-wide `NSEvent.addLocalMonitorForEvents` router.
  - Focus context comes from `window.firstResponder` and feeds VS Code-style `ShortcutWhenClause`s.
- Its written rules:
  - Rows below a `Lazy`/`List` boundary get only immutable snapshots plus closures.
  - `TabItemView` is `Equatable`.
  - No state mutation during `body`.
  - Spinners are `CALayer` animations.
  - Everything uses `@Observable`.

**CodeEdit.**
- It runs on the SwiftUI App lifecycle, but uses `NSDocument`, `NSWindowController` and `NSSplitViewController`.
- The project navigator is an `NSOutlineView`, because "SwiftUI's `OutlineGroup` has bugs and is slow" ([#977](https://github.com/CodeEditApp/CodeEdit/issues/977)).
- The editor is [CodeEditTextView](https://github.com/CodeEditApp/CodeEditTextView), a custom AppKit text view.

**SwiftUI-first agent hubs all hit the same wall.**
- **[Supacode](https://github.com/supabitapp/supacode)** uses an `NSOutlineView` file explorer.
  - Its `AGENTS.md` says closure-typed `FocusedValue`s "invalidate the AppKit menu on every body run".
  - [#734](https://github.com/supabitapp/supacode/issues/734): a SwiftUI shimmer made typing lag.
- **[Muxy](https://github.com/muxy-app/muxy)** froze in an infinite `LazySubviewPlacements` layout loop ([#775](https://github.com/muxy-app/muxy/issues/775): 114% CPU, 1.7 GB).
- **[Aizen](https://github.com/vivy-company/aizen)** restarts terminals when switching environments ([#21](https://github.com/vivy-company/aizen/issues/21)), because terminal lifetime is tied to SwiftUI view lifetime.

**Apple.** At [WWDC26 session 272](https://developer.apple.com/videos/play/wwdc2026/272/), Apple said the Xcode Coding Assistant and Logic Pro plugins are SwiftUI inside AppKit apps, and that there are "no expectations that an app needs to be entirely SwiftUI". AppKit still gets new features ([session 289](https://developer.apple.com/videos/play/wwdc2026/289/)).

### 5.2 Where SwiftUI on macOS still falls short, macOS 26/27

- **Big lists and trees.**
  - At WWDC25 Apple claimed lists over 100k items load 6x faster and update 16x faster ([session 256](https://developer.apple.com/videos/play/wwdc2025/256/)).
  - Practitioners see less:
    - 10k items snappy, 50k sluggish ([TrozWare, Aug 2025](https://troz.net/post/2025/swiftui-mac-2025/)).
    - Hierarchical lists still slow ([lemonmojo](https://github.com/lemonmojo/swiftui-hierarchical-list-performance)).
    - Blank areas while scrolling ([Eclectic Light, Apr 2026](https://eclecticlight.co/2026/04/04/explainer-appkit-and-swiftui/)).
    - Still no custom lazy containers (Fatbobman, via [Michael Tsai, Jun 2026](https://mjtsai.com/blog/2026/06/19/swiftui-in-appleos-27/)).
  - The LazyVStack livelocks at cmux and Muxy were in production.
- **Focus.**
  - `@FocusState` and `FocusedValue` drift away from AppKit's first responder once `NSView`s are embedded. cmux's comments say this "broke focus after window switching".
  - `focusedSceneValue` breaks under `DocumentGroup`.
- **Keyboard.** `onKeyPress` fires only for the focused view. User-rebindable shortcuts, chords and context-dependent routing go through `NSMenu` plus `NSEvent` monitors in both Ghostty and cmux.
- **Text.**
  - `TextEditor` with `AttributedString` (macOS 26) is fine for notes but not for code.
  - TextKit 2 has "unstable scrolling, unreliable height estimates" ([Krzyżanowski, Aug 2025](https://blog.krzyzanowskim.com/2025/08/14/textkit-2-the-promised-land/)).
  - Code editor options: [STTextView](https://github.com/krzyzanowskim/STTextView) (GPL-3.0 or commercial), CodeEditSourceEditor (MIT), or `NSTextView`.
- **Split views.**
  - `NavigationSplitView` restores widths wrongly on macOS 27.
  - TrozWare (May 2026) advises against it for multi-window Mac apps.
- **Windows.** I found no public way to use an `NSWindow` subclass with `WindowGroup`. macOS 26 added `NSHostingSceneRepresentation`, so an AppKit app can add SwiftUI `Settings` and `MenuBarExtra` scenes.
- **Drag and drop, context menus, toolbars.**
  - `.contextMenu` doesn't identify the clicked row.
  - Submenus can't be built dynamically.
  - `.reorderable` (WWDC26) has reported crashes.
- **Bridging costs.**
  - An `NSViewRepresentable` is torn down whenever SwiftUI decides its identity changed.
  - `NSHostingView` sizing can loop.
- **Helpful change.** On macOS 26, AppKit tracks `@Observable` reads in `layout`, `draw`, `updateConstraints` and `updateLayer` ([steipete](https://steipete.me/posts/2025/automatic-observation-tracking-uikit-appkit)).
- **Liquid Glass.**
  - Use `NSSplitViewItem(sidebarWithViewController:)` and remove `NSVisualEffectView` from sidebars.
  - Set `prefersCompactControlSizeMetrics` for dense UIs ([WWDC25 session 310](https://developer.apple.com/videos/play/wwdc2025/310/)).
  - Private titlebar hacks break on every OS release.

### 5.3 Recommendation for Mapo's shell

Give AppKit the frame and SwiftUI the leaf views. Target macOS 26 or later.

- **Lifecycle.** `main.swift` calls `NSApplicationMain`, as Ghostty does. Add SwiftUI `Settings` through `NSHostingSceneRepresentation`. Build the `NSMenu` from the keymap, so user rebinds show up in the menu bar.
- **Window.** `MapoWindow: NSWindow` inside a `WorkspaceWindowController` that owns an `NSSplitViewController`.
  - The sidebar item is the workspace rail, as a view-based `NSTableView`, or `NSOutlineView` if workspaces get groups. Draw status badges as cells or `CALayer`s.
  - The content item is the pane area. The per-workspace tab bar sits in a top split-item accessory, as one `NSHostingView` fed with `Equatable` snapshots, or as plain AppKit.
  - An optional inspector item holds the file explorer, an `NSOutlineView` with lazy children.
- **Panes.** A value-type split tree in the model, like Ghostty's `SplitTree`, rendered as nested `NSSplitView`s the way Bonsplit does it. Leaves are container `NSView`s holding a terminal or an editor.
- **SwiftUI islands.**
  - The command palette, in an `NSPanel`. Restore focus when it closes.
  - Settings.
  - Setup and recipe editors.
  - Port and process popovers. A SwiftUI `Table` handles hundreds of rows.
  - Sheets and empty states.
- **Terminal hosting.**
  - `TerminalSurfaceView: NSView` is the first responder and implements `keyDown`, `performKeyEquivalent` and `NSTextInputClient`.
  - A main-actor `SurfaceRegistry` keyed by tab ID keeps surfaces alive until the tab closes, never tying them to re-layout.
  - On workspace switch, detach inactive trees but keep the objects.
- **Focus.**
  - One `@MainActor @Observable FocusModel` (window, workspace, tab, pane) is the source of truth.
  - A `FocusCoordinator` calls `window.makeFirstResponder` only after the view is in a window, and an override of `MapoWindow.makeFirstResponder` feeds clicks back into the model.
  - A local `NSEvent` monitor resolves chords and when-clauses before the terminal sees the key.
  - Use `@FocusState` only inside self-contained SwiftUI islands.

---

## 6. The recommended stack, assembled

```
mapo/
  Cargo.toml                 # workspace
  crates/
    mapo-core/               # domain state, command API, reducer, PTY/process supervision, ports, file watch, setups
    mapo-server/             # Unix socket server for CLI + hooks; MCP (rmcp) handlers call the same command API
    mapo-ffi/                # the one staticlib: UniFFI exports + optional C ABI hot path; uniffi.toml
    mapo-cli/                # `mapo` binary: CLI, `mapo mcp` (stdio MCP proxy to the socket), later `mapo attach`
    uniffi-bindgen-swift/    # tiny bin: fn main() { uniffi::uniffi_bindgen_swift() }
  apple/
    MapoCore/                # local Swift package: MapoFFI.xcframework (binaryTarget), MapoBindings (Swift 5), MapoCore (Swift 6)
    Mapo/                    # AppKit app sources, SwiftUI islands
    project.yml              # XcodeGen
  vendor/GhosttyKit.xcframework   # upstream or cmux-fork prebuilt, pinned by checksum
  justfile                   # ffi, dev, test, release
```

1. **Interop.** UniFFI `=0.32.2`, proc-macros only, one megazord crate. Export a small, coarse API:
   - `Core` with command methods.
   - An event pump, either `async next_events()` or a delegate trait.
   - Snapshot and diff records.
   - One flat error enum.
   - `TaskHandle`-style objects to cancel subscriptions.

   Move to `main` or a later release when PR #2943 and the #3013 speedup ship. Keep a spike budget for BoltFFI behind the `MapoCore` facade.
2. **Hot path.**
   - Terminal bytes never go through UniFFI. Choose option 1, 2 or 3 from section 1.6.
   - With option 2, add a small cbindgen header next to the UniFFI header, both inside `Headers/MapoFFI/`.
   - Coalesce file-tree and port updates in Rust to at most about 60 Hz.
   - Directory listing for the outline view can stay in Swift if the core only needs to publish the cwd.
3. **Swift layering.** Three layers, in this order:
   - `MapoBindings`: generated code, Swift 5 mode.
   - `MapoCore`: hand-written facades, `AsyncStream` adapters and `@Observable` stores, Swift 6.
   - The app: AppKit shell plus SwiftUI islands, with MainActor default isolation.

   Views read immutable snapshots. User intents call core commands; the view never mutates its own copy.
4. **Build.**
   - `just ffi` builds the core for the host arch and regenerates the bindings and XCFramework when the library changed.
   - `just dev` runs `just ffi`, then `xcodegen`, then `xcodebuild`, then launches.
   - Pin `MACOSX_DEPLOYMENT_TARGET=26.0`. Build arm64 only.
5. **Release.** Done locally at first, the jayjay way; move to CI later, Ghostty-style.
   - `xcodebuild archive`, then sign inside out.
   - `notarytool` with an API key, then staple.
   - Build the DMG with create-dmg.
   - `generate_appcast` for Sparkle 2.10, hosted on GitHub Releases.
6. **Rust crates for the core.** These aren't part of interop, but for orientation:
   - rmcp 3.5.0 (MCP)
   - tokio 1.53
   - portable-pty 0.9.0, if Rust owns PTYs
   - notify 9.0.0-rc.5 (file watching)
   - interprocess 2.4.4 (sockets)
   - sysinfo 0.39 / libproc 0.14 (ports and processes)
   - eyeball-im (diffable lists)

---

## 7. Risks

1. **Who owns the PTY.**
   - Upstream libghostty has no embedder-owned IO.
   - Rust-owned PTYs therefore mean depending on cmux's heavily patched fork, with its prebuilt XCFrameworks pinned by checksum. Or you wait for upstream, or you write your own renderer on libghostty-vt.
   - Fork divergence is a real maintenance cost. Keep the GhosttyKit dependency behind one Swift module so it can be swapped.
2. **UniFFI and Swift 6.**
   - Async code isn't Sendable-clean.
   - The async foreign-trait fix isn't released.
   - Xcode 26's default MainActor isolation breaks the generated file.
   - Mitigations: a Swift 5 mode bindings target, exact version pins, and generated code regenerated in one scripted step.
   - Every minor UniFFI release breaks something, so budget upgrade time.
3. **UniFFI's Swift performance on collections.**
   - About 1.9 to 3.7 µs per record today, so 10k records take about 19 ms, more than a frame.
   - Mitigations: diffs, handles, compact byte payloads, and profiling with Instruments early.
4. **SwiftUI layout and focus bugs.**
   - LazyVStack livelocks and focus drift hit cmux, Muxy and Supacode in 2026.
   - Mitigation: AppKit for the frame, lists, trees and responder chain.
5. **Build plumbing.**
   - GhosttyKit's and MapoFFI's module maps collide unless nested.
   - Deployment-target mismatches trigger rebuild storms.
   - Xcode's user-script sandboxing blocks cargo.
   - Checksum mismatches appear when the library and bindings drift apart.
   - Possibly stale XCFramework relinks (unverified).
6. **Sessions die on update or restart.**
   - An in-process design kills dev servers and Claude sessions on every Sparkle relaunch.
   - Plan the daemon (option 3) early enough that the command API is transport-agnostic.
7. **Permissions and licensing.**
   - TCC attributes children's permission prompts to Mapo, so declare the needed entitlements and usage strings.
   - Licensing: cmux app code is GPL-3.0+ and Dory is GPL-3.0. Only read them. cmux's ghostty fork, Bonsplit, Ghostty, wordpress-rs (MPL-2.0 is file-level) and XcodeGen can be used.

---

## 8. Not verified, or still open

- Whether Raycast uses UniFFI on its Swift and Rust boundary. The blog doesn't say; it only shows a fork of uniffi-rs.
- Whether 1Password's Mac app is still Electron in 2026, and its exact FFI entry points.
- Whether the shipped Proton Mail iOS app uses Crux. The README says Proton uses Crux, but the public repo shows plain UniFFI.
- How OrbStack does interop. It's closed source.
- Whether Xcode always relinks when the `.a` inside a local `binaryTarget` XCFramework changes. jayjay's workflow suggests yes; older forum threads report staleness.
- UniFFI #2917 (module map `_Builtin_*` on Xcode 26/27). I didn't test it. Firefox iOS, jayjay and Dory build fine.
- Whether `ghostty_surface_process_output` in cmux's fork is safe to call from a Rust thread. cmux serializes calls per surface on a DispatchQueue, so a spike is needed.
- BoltFFI's README speed claims. Its own Swift data shows parity for primitives and big wins only for records and bytes.
- Tuist `.foreignBuild` with cargo. Only a Kotlin Multiplatform example exists.
- Whether Swift 6.4, which makes Swift Build the SwiftPM default, fixes asset catalogs or app bundling for pure-SwiftPM apps.
- Whether a SwiftUI `WindowGroup` API for `NSWindow` subclasses exists in macOS 27. I found none.
- The UI stacks of Nova, Tower, Proxyman, TablePlus, Kaleidoscope, Superset, Orca and Conductor weren't checked.
- The GitHub Actions macOS per-minute price comes from a research pass. I didn't recheck it against GitHub's billing page.
