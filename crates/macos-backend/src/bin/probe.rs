fn main() -> Result<(), Box<dyn std::error::Error>> {
    let report = match std::env::args().nth(1).as_deref() {
        Some("doctor") | None => driftwm_macos_backend::doctor()?,
        Some("list") => serde_json::to_value(driftwm_macos_backend::list_windows()?)?,
        Some("probe") => driftwm_macos_backend::probe_fixture()?,
        _ => return Err("usage: driftwm-native-probe [doctor|list|probe]".into()),
    };
    println!("{}", serde_json::to_string_pretty(&report)?);
    Ok(())
}
