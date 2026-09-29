//! Runtime and [`Platform`] for guest programs that name no zkVM and are linked against a zkVM SDK
//! (`libzkvm.a` and `zkvm.ld`). The SDK provides `_start`, the [zkvm-standards] IO and accelerator
//! symbols, and two more a guest needs until the standards cover them: `abort` (failed
//! termination) and `sys_alloc_aligned` (the zkVM's heap).
//!
//! The crate works in two modes, chosen by the guest's target (`../targets`):
//!
//! - **`no_std`** on `riscv64im-unknown-none-elf`. This crate is the guest's runtime: its global
//!   allocator takes memory from `sys_alloc_aligned`, and its panic handler calls `abort`.
//! - **`std`** on `riscv64im-unknown-zkvm-elf`, where upstream's zkVM port of `std` calls `sys_*`
//!   functions. This crate defines those an SDK does not export, on the symbols above, and [`run`]
//!   routes panics to `abort`.
//!
//! The allocator uses the SDK's heap rather than the `_heap_start`/`_heap_end` region the
//! zkvm-standards reserve for the application: zkVM libraries allocate from that same region today.
//!
//! [zkvm-standards]: https://github.com/eth-act/zkvm-standards

#![cfg_attr(bare_metal, no_std)]

pub use ere_platform_core::Platform;

#[cfg(any(bare_metal, target_os = "zkvm"))]
unsafe extern "C" {
    /// Failed termination, provided by the zkVM SDK.
    fn abort() -> !;
}

/// [`Platform`] backed by the zkVM SDK: input and output use the standard `read_input` and
/// `write_output` symbols.
#[derive(Debug)]
pub struct ZkvmPlatform;

impl Platform for ZkvmPlatform {}

/// Runs `guest` as the program's `main`: returns `0` when it returns, and terminates through the
/// SDK's `abort` when it panics.
///
/// Under `std`, a panic would otherwise end with a trapping instruction, which zkVMs do not agree
/// on. Without `std`, this crate's panic handler already calls `abort`.
pub fn run(guest: impl FnOnce()) -> i32 {
    #[cfg(target_os = "zkvm")]
    std::panic::set_hook(std::boxed::Box::new(|_| unsafe { abort() }));
    guest();
    0
}

/// The `no_std` runtime.
#[cfg(bare_metal)]
mod runtime {
    use core::alloc::{GlobalAlloc, Layout};

    unsafe extern "C" {
        /// The zkVM's heap: `bytes` bytes aligned to `align`, never freed.
        fn sys_alloc_aligned(bytes: usize, align: usize) -> *mut u8;
    }

    struct SdkHeap;

    unsafe impl GlobalAlloc for SdkHeap {
        unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
            unsafe { sys_alloc_aligned(layout.size(), layout.align()) }
        }

        // The SDK's heap does not free.
        unsafe fn dealloc(&self, _: *mut u8, _: Layout) {}
    }

    #[global_allocator]
    static HEAP: SdkHeap = SdkHeap;

    #[panic_handler]
    fn panic(_: &core::panic::PanicInfo<'_>) -> ! {
        unsafe { super::abort() }
    }
}

/// The `sys_*` functions `std` calls on `target_os = "zkvm"` that an SDK does not export.
/// `sys_alloc_aligned` comes from the SDK.
#[cfg(target_os = "zkvm")]
mod std_abi {
    /// A panic's message is dropped: the standards define no console.
    #[unsafe(no_mangle)]
    unsafe extern "C" fn sys_panic(_msg_ptr: *const u8, _len: usize) -> ! {
        unsafe { super::abort() }
    }

    /// Standard output and error are dropped: the standards define no console.
    #[unsafe(no_mangle)]
    unsafe extern "C" fn sys_write(_fd: u32, _write_buf: *const u8, _nbytes: usize) {}

    /// A validation guest must be deterministic, so `std`'s randomness (hash map seeds) is fixed.
    #[unsafe(no_mangle)]
    unsafe extern "C" fn sys_rand(recv_buf: *mut u32, words: usize) {
        unsafe { core::ptr::write_bytes(recv_buf, 0, words) };
    }

    // Randomness is never available to the guest itself.
    getrandom::register_custom_getrandom!(no_randomness);

    fn no_randomness(_: &mut [u8]) -> Result<(), getrandom::Error> {
        Err(getrandom::Error::UNSUPPORTED)
    }
}
