fn main() -> Result<(), Box<dyn std::error::Error>> {
    let nonce = std::env::args().nth(1).ok_or("expected fixture nonce")?;
    driftwm_macos_backend::run_fixture(&nonce)?;
    Ok(())
}
