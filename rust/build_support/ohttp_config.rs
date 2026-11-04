// This guard runs before SDK header generation and never resolves inputs.
pub const NAMES: [&str; 8] = [
    "ZODL_OHTTP_GATEWAY_HOST_MAINNET",
    "ZODL_OHTTP_GATEWAY_HOST_TESTNET",
    "ZODL_OHTTP_RELAY_URL_MAINNET",
    "ZODL_OHTTP_RELAY_URL_TESTNET",
    "ZODL_OHTTP_SIGNING_PUBKEY_MAINNET",
    "ZODL_OHTTP_SIGNING_PUBKEY_TESTNET",
    "ZODL_OHTTP_KEYS_DNS_NAME_MAINNET",
    "ZODL_OHTTP_KEYS_DNS_NAME_TESTNET",
];

pub fn validate(mut lookup: impl FnMut(&str) -> Option<String>) -> Result<(), String> {
    let mut values = Vec::with_capacity(NAMES.len());
    for name in NAMES {
        let value = lookup(name)
            .filter(|value| !value.is_empty())
            .ok_or_else(|| format!("{name} is required"))?;
        values.push(value);
    }
    for first in (0..NAMES.len()).step_by(2) {
        if values[first].eq_ignore_ascii_case(&values[first + 1]) {
            return Err(format!(
                "{} and {} must differ",
                NAMES[first],
                NAMES[first + 1]
            ));
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn configured(name: &str) -> Option<String> {
        Some(format!("{name}.example.invalid"))
    }

    #[test]
    fn complete_values_are_accepted() {
        assert!(validate(configured).is_ok());
    }

    #[test]
    fn each_missing_and_empty_input_fails_by_name() {
        for missing in NAMES {
            for value in [None, Some(String::new())] {
                let error = validate(|name| {
                    if name == missing {
                        value.clone()
                    } else {
                        configured(name)
                    }
                })
                .unwrap_err();
                assert!(error.contains(missing));
                assert!(!error.contains("example.invalid"));
            }
        }
    }

    #[test]
    fn each_network_pair_must_differ_ignoring_ascii_case() {
        for first in (0..NAMES.len()).step_by(2) {
            for duplicate in ["Private.Example.Invalid", "PRIVATE.EXAMPLE.INVALID"] {
                let error = validate(|name| {
                    if name == NAMES[first] {
                        Some("Private.Example.Invalid".to_string())
                    } else if name == NAMES[first + 1] {
                        Some(duplicate.to_string())
                    } else {
                        configured(name)
                    }
                })
                .unwrap_err();
                assert!(error.contains(NAMES[first]));
                assert!(error.contains(NAMES[first + 1]));
                assert!(!error.contains("Example.Invalid"));
                assert!(!error.contains("EXAMPLE.INVALID"));
            }
        }
    }
}
