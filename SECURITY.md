This page is copyright Znewco, Inc. (d/b/a Zcash Open Development Lab), 2026. It
is posted in order to conform to this standard:
https://github.com/RD-Crypto-Spec/Responsible-Disclosure/tree/d47a5a3dafa5942c8849a93441745fdd186731e6

# Security Disclosures

## Vulnerability Categorization

The maintainers of this SDK have defined the following categories for
vulnerabilities. This vulnerability scoring is used by the maintainers to
prioritize how urgently each potential vulnerability needs to be fixed; it's
not a metric to be gamed for payouts from any bounty program.

The categories are written for a light client wallet SDK: this library does not
validate consensus rules, and it trusts the light wallet server it is pointed
at for the correctness of the data that server returns. See "Not Vulnerability"
below for what follows from that.

### Critical

* Exposure of spending keys, unified full viewing keys, or seed material to any
  party other than the wallet's user — for instance by emitting them to logs,
  transmitting them to a server, or writing them outside the storage the host
  application designated for them.
* Remotely-exploitable vulnerabilities that may result in individual user loss
  of funds or compromise of their devices without user interaction. Think on
  the order of vulnerabilities that might result in remote code execution or
  remote key extraction.
* Vulnerabilities that could result in deanonymization of users of this SDK as
  a class, or exposure of the shielded transaction graph, beyond what is
  acknowledged by the light wallet threat model.

### High

* Vulnerabilities that cause a transaction to be constructed other than as the
  host application requested it — paying a different recipient, a different
  amount, or from a different account.
* Other vulnerabilities that might result in remotely-triggered individual user
  loss of funds. This does not include vulnerabilities resulting from careless
  or intentional API misuse by the host application.
* Deanonymization of an individual user beyond what is acknowledged by the
  light wallet threat model — for instance a network request pattern that
  discloses which notes or addresses belong to a wallet to a party that the
  threat model does not already trust with that information.

### Moderate

* Other vulnerabilities that might result in individual user loss of funds.

### Low

* Individual user wallet DoS.

### Not Vulnerability

The following categories of problems are explicitly not considered vulnerabilities.

* Bugs that may cause temporary unavailability of funds which can be resolved,
  in the limit, by a wallet re-scan or importing keys into another wallet.
* Behavior that is explicitly or implicitly acknowledged in the
  [light wallet threat model](https://zcash.readthedocs.io/en/latest/rtd_pages/wallet_threat_model.html).
  Light wallet servers are considered explicitly trusted for the correctness of
  the data that they return to users, and misbehavior arising from processing
  maliciously-crafted compact block or transaction data returned from light wallet
  servers is not considered a vulnerability unless its processing results
  in a compromise that risks loss of funds or deanonymization beyond what
  is acknowledged by the light wallet threat model.
* Consequences of a host application misusing this SDK's public API — for
  instance passing key material where a memo is expected, persisting key
  material itself, or ignoring a documented precondition.

## Receiving Disclosures

The maintainers of this SDK are committed to working with researchers who submit
security vulnerability notifications to us to resolve those issues on an
appropriate timeline and perform a coordinated release, giving credit to the
reporter if they would like.

We have no email address to report security issues; email is not suitable for
this purpose for both reliability and security reasons (even if encryption is
used).

For critical vulnerabilities, please create a Signal group with the following
users to report a security issue. Do not reuse a previous group for a new
issue.

```
dairaemma.31
nuttycom.01
```

For all other vulnerabilities, please use the GitHub "Report a Vulnerability"
feature for this repository, available at:

* https://github.com/zodl-inc/zcash-swift-wallet-sdk/security/advisories

Report severity according to the rubric above. Overstating the severity of a
reported vulnerability MAY MAKE THE REPORTER INELIGIBLE FOR COMPENSATION UNDER
ANY BUG BOUNTY PROGRAM that may apply.

## Sending Disclosures

For our commitments when we become aware of security issues affecting other
projects, and for our deviations from the responsible disclosure standard named
at the top of this page, see `responsible_disclosure.md`.
