# zkVM-agnostic guests

A guest built once, naming no zkVM, is linked against each zkVM's SDK to run on it. The SDKs come
from the zkVM side (Ere's `sdk-*` releases): per zkVM, `libzkvm.a`, `zkvm.ld`, and optionally
`zkvm.features` and `zkvm-lto-plugin.so`. This directory is the guest side:

```text
zkvm/
├── targets/        the guest targets: riscv64im-unknown-none-elf (no_std), riscv64im-unknown-zkvm-elf (std)
├── rust-toolchain  the stable toolchain guest objects are built with
├── platform/       ere-platform-zkvm: the guest's runtime and ere `Platform`
├── abi.txt         the guest ABI: every symbol a guest may take from an SDK
└── link.sh         the link command
```

## Build a guest object

The guest is a `staticlib` crate defining `int main(void)` that uses `ere-platform-zkvm`:

```rust
#![no_std]

use ere_platform_zkvm::{ZkvmPlatform, run};

#[unsafe(no_mangle)]
extern "C" fn main() -> i32 {
    run(my_guest::entrypoint::<ZkvmPlatform>)
}
```

It is built with `lto = "fat"` and `-Clinker-plugin-lto` into an archive of LLVM bitcode (plus native
`compiler_builtins`) whose only undefined symbols are in `abi.txt`. `.github/actions/build-guest-object`
does this in CI; locally:

```bash
RUSTC_BOOTSTRAP=1 RUSTFLAGS='-Clinker-plugin-lto -Cpasses=lower-atomic' \
  cargo +$(cat zkvm/rust-toolchain) build --release \
  -Zbuild-std=core,alloc -Zbuild-std-features=compiler-builtins-mem -Zjson-target-spec \
  --target zkvm/targets/riscv64im-unknown-none-elf.json \
  --config 'profile.release.lto="fat"' --config profile.release.codegen-units=1 \
  --config 'profile.release.panic="abort"' --manifest-path <guest>/Cargo.toml
```

- `riscv64im-unknown-none-elf` is the stock bare-metal spec with compare-and-swap, which
  `alloc::sync` needs. A guest runs on one thread, so `-Cpasses=lower-atomic` lowers its atomics to
  plain loads and stores and the code needs no `A` extension.
- The toolchain is stable. `RUSTC_BOOTSTRAP=1` admits the two `-Z` options a Tier 3 target needs.
  Its LLVM (22.1.2) must be no newer than the linker's, because bitcode is only read forward.
- A guest that uses `std` builds for `riscv64im-unknown-zkvm-elf` with `-Zbuild-std=std,panic_abort`
  and `--cfg getrandom_backend="custom"`, where upstream's zkVM port of `std` calls `sys_*`
  functions. `ere-platform-zkvm` defines those on the guest ABI (`sys_panic` aborts, `sys_write` is
  dropped, `sys_rand` is fixed).

## The guest ABI

`abi.txt` holds the zkvm-standards guest ABI (`_start`, `read_input`, `write_output` and the
`zkvm_*` accelerators) plus two symbols the standards do not cover yet:

- `abort`, failed termination, which the `no_std` panic handler calls.
- `sys_alloc_aligned(bytes, align)`, the zkVM's heap, which never frees. It backs the guest's global
  allocator: zkVM libraries allocate from the memory the standards' `_heap_start`/`_heap_end` give
  the application, so until they keep their scratch memory apart, a guest allocates through them.

## Link

```bash
LD_LLD=ld.lld zkvm/link.sh <sdk> <guest.a> <guest.elf> [llvm-option...]
```

`link.sh` rejects a guest object that does not define `main`, defines an ABI symbol, or needs a
symbol outside the ABI. If the SDK has a `zkvm.features` file, it appends its features to every
function's `target-features` attribute in the guest's bitcode, so the zkVM's extensions are used
without a per-zkVM build. It then runs one fixed command,
`ld.lld -T <sdk>/zkvm.ld -L <sdk> --gc-sections --fat-lto-objects --lto-O3`, loading the SDK's
`zkvm-lto-plugin.so` if it has one. Options after the output reach LTO as `-mllvm`: this guest's
tuning on this zkVM, and for SP1 the scheduling direction `cargo prove build` uses for every guest
(`-misched-prera-direction=bottomup -misched-postra-direction=bottomup`).

`.github/workflows/link-guest.yml` links a guest object against each SDK of an Ere release, runs
the `zkvm_execution` test on the ELFs, and optionally packages them with their program VKs.
