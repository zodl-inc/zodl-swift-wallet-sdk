This page is copyright Znewco, Inc. (d/b/a Zcash Open Development Lab), 2026. It
is posted in order to conform to this standard:
https://github.com/RD-Crypto-Spec/Responsible-Disclosure/tree/d47a5a3dafa5942c8849a93441745fdd186731e6

# Security Disclosures

## Receiving Disclosures

The maintainers of this SDK are committed to working with researchers who submit
security vulnerability notifications to us to resolve those issues on an
appropriate timeline and perform a coordinated release, giving credit to the
reporter if they would like.

We have no email address to report security issues; email is not suitable for
this purpose for both reliability and security reasons (even if encryption is
used). Report a vulnerability by whichever of the following routes matches its
severity under the rubric in `SECURITY.md`:

* **Critical** — create a Signal group with the users `dairaemma.31` and
  `nuttycom.01`. Do not reuse a previous group for a new issue.
* **All other severities** — use the GitHub "Report a Vulnerability" feature at
  https://github.com/zodl-inc/zcash-swift-wallet-sdk/security/advisories

`SECURITY.md` carries the full policy: the severity rubric, what is explicitly
not considered a vulnerability, and the reporting routes above.

## Sending Disclosures

In the case where we become aware of security issues affecting other projects
that have never affected this SDK, our intention is to inform those projects of
security issues on a best effort basis.

In the case where we fix a security issue in this SDK that also affects
neighboring projects, our intention is to engage in responsible disclosures with
them as described in https://github.com/RD-Crypto-Spec/Responsible-Disclosure,
subject to the deviations described in the section below.

## Deviations from the Standard

Zcash is a technology that provides strong privacy. Notes are encrypted to their
destination, and then the monetary base is kept via zero-knowledge proofs
intended to only be creatable by the real holder of Zcash. If this fails, and a
counterfeiting bug results, that counterfeiting bug might be exploited without
any way for blockchain analyzers to identify the perpetrator or which data in
the blockchain has been used to exploit the bug. Rollbacks before that point,
such as have been executed in some other projects in such cases, are therefore
impossible.

The standard describes reporters of vulnerabilities including full details of an
issue, in order to reproduce it. This is necessary for instance in the case of an
external researcher both demonstrating and proving that there really is a
security issue, and that security issue really has the impact that they say it
has - allowing the development team to accurately prioritize and resolve the
issue.

In the case of a counterfeiting bug, however, just like in CVE-2019-7167, we
might decide not to include those details with our reports to partners ahead of
coordinated release, so long as we are sure that they are vulnerable.
