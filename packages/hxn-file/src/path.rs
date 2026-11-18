pub fn application(id: &str) -> Result<(), String> {
    if id.is_empty()
        || id.len() > 128
        || !id.as_bytes()[0].is_ascii_alphanumeric()
        || !id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b".-_".contains(&b))
        || id.ends_with('.')
        || id.contains("..")
        || reserved(id)
    {
        return Err(
            "application ID must be a portable identifier of 1..128 ASCII characters".into(),
        );
    }
    Ok(())
}
fn reserved(name: &str) -> bool {
    let base = name.split('.').next().unwrap_or("").to_ascii_uppercase();
    matches!(base.as_str(), "CON" | "PRN" | "AUX" | "NUL")
        || (base.len() == 4
            && (base.starts_with("COM") || base.starts_with("LPT"))
            && matches!(base.as_bytes()[3], b'1'..=b'9'))
}
pub fn relative(path: &str) -> Result<&str, String> {
    if path.len() > 4096
        || path.is_empty()
        || path
            .chars()
            .any(|c| c.is_ascii_control() || "\\:*?\"<>|".contains(c))
        || path.split('/').any(|s| {
            s.is_empty()
                || s.len() > 240
                || s == "."
                || s == ".."
                || s.ends_with(['.', ' '])
                || reserved(s)
        })
    {
        return Err(
            "file path must be a portable, nonempty relative path without parent traversal".into(),
        );
    }
    Ok(path)
}
pub fn preference(key: &str) -> Result<String, String> {
    if key.is_empty() || key.len() > 96 || key.contains('\0') {
        return Err("preference key must contain 1..96 UTF-8 bytes without NUL".into());
    }
    Ok(key.as_bytes().iter().map(|b| format!("{b:02x}")).collect())
}
