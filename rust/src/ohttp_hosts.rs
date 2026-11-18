//! The compiled list of third-party hosts a gateway is taken to carry until its own list was
//! fetched. The installed lists (`ohttp_config.rs`) start from it.

/// The third-party hosts a gateway is taken to carry until its own list was fetched.
pub(crate) const BOOTSTRAP_THIRD_PARTY_HOSTS: &[&str] = &[
    // Vote servers
    "vote.zodl.com",
    "prod.vote-chain-primary.valargroup.org",
    "voting.valargroup.dev",
    "ru.zcash.space",
    "147-182-192-212.sslip.io",
    "134-209-215-69.sslip.io",
    "mnval01.zcash.legends.sh",
    "zvote-1.stardust.rest",
    "zvote.zodl.com",
    "zvote.keplr.app",
    "zvote.zfnd.org",
    "v.ombie.cash",
    "svote.zcashlabs.com",
    "207-180-214-226.sslip.io",
    "vote.atlasstaking.com",
    "zvote.polkachu.com",
    "zvote.cros-nest.net",
    "vote.infra.cypherpunk.com",
    // PIR endpoints (delegation): fail closed through OHTTP when Tor is OFF and
    // the servers are predefined.
    "lb-pir-primary.valargroup.org",
    "lb-pir-backup.valargroup.org",
    "zpir-1.stardust.rest",
];

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_bootstrap_list_is_21_plain_lower_case_hosts() {
        assert_eq!(BOOTSTRAP_THIRD_PARTY_HOSTS.len(), 21);
        let holder = slipstream_core::ohttp::ThirdPartyHosts::new(BOOTSTRAP_THIRD_PARTY_HOSTS);
        assert_eq!(holder.bootstrap_len(), 21);
        for host in BOOTSTRAP_THIRD_PARTY_HOSTS {
            assert_eq!(holder.carried_authority(host).as_deref(), Some(*host));
            assert!(!host.contains(':'));
        }
        assert!(!holder.is_carried("evil.vote.zodl.com"));
        assert!(!holder.is_carried("valargroup.org"));
    }
}
