fn main() {
    // `bare_metal`: the `no_std` mode, on the bare-metal RISC-V guest target (see the crate docs).
    println!("cargo::rustc-check-cfg=cfg(bare_metal)");
    let arch = std::env::var("CARGO_CFG_TARGET_ARCH").unwrap_or_default();
    let os = std::env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    if arch == "riscv64" && os == "none" {
        println!("cargo::rustc-cfg=bare_metal");
    }
}
