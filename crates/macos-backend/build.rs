use std::{env, path::PathBuf, process::Command};
fn main() {
    println!("cargo:rerun-if-changed=../../native/backend/bridge.m");
    println!("cargo:rerun-if-changed=../../native/fixture/fixture.m");
    if env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("macos") {
        return;
    }
    let out = PathBuf::from(env::var_os("OUT_DIR").expect("Cargo OUT_DIR"));
    for (source, name) in [
        ("../../native/backend/bridge.m", "bridge"),
        ("../../native/fixture/fixture.m", "fixture"),
    ] {
        let status = Command::new("xcrun")
            .args([
                "clang",
                "-fobjc-arc",
                "-mmacosx-version-min=26.0",
                "-Wall",
                "-Wextra",
                "-Werror",
                "-c",
                source,
                "-o",
            ])
            .arg(out.join(format!("{name}.o")))
            .status()
            .expect("run clang");
        assert!(status.success(), "native adapter compilation failed");
    }
    assert!(
        Command::new("ar")
            .arg("crs")
            .arg(out.join("libdriftwm_native.a"))
            .arg(out.join("bridge.o"))
            .arg(out.join("fixture.o"))
            .status()
            .expect("run ar")
            .success()
    );
    println!("cargo:rustc-link-search=native={}", out.display());
    println!("cargo:rustc-link-lib=static=driftwm_native");
    for framework in [
        "AppKit",
        "ApplicationServices",
        "CoreGraphics",
        "Foundation",
    ] {
        println!("cargo:rustc-link-lib=framework={framework}");
    }
}
