**English** · [中文](./SECURITY.zh-CN.md)

# Security Policy

## Status

pg-outcry is **open-source reference software**. The core flows (matching, double-entry
settlement, reservations, RLS isolation, reconciliation, wallet approvals) are covered by an
automated end-to-end test suite and a reconciliation invariant check. **It has not undergone an
independent third-party security or financial audit.** Do not custody real user funds on it
without your own audit, hardening, and legal/compliance review.

## Reporting a vulnerability

Please report security issues **privately** — do not open a public issue.

- Use GitHub **Security Advisories** ("Report a vulnerability") on this repo, or
- email the maintainer (see the GitHub profile).

We aim to acknowledge within a few days. Please include reproduction steps and impact.

## Hardening checklist for operators

If you deploy this, at minimum:
- Keep the `service_role` key server-side only; never ship it to browsers. The back-office
  console is an **operator tool** — run it on a trusted, access-controlled machine.
- Front the API with TLS, rate limiting, and WAF.
- **2FA is delegated to the OAuth2 provider** (GitHub/Google enforce their own 2FA at login), so
  pg-outcry doesn't ship a separate TOTP system. To *mandate* 2FA, restrict login to OAuth (disable
  email/password signup) so every account authenticates through an IdP that enforces it; require it
  on operator accounts.
- Review and tighten every RLS policy and the `9900_lockdown` function whitelist for your schema.
- Configure real OAuth providers + email; disable open signups if you require KYC-first onboarding.
- Set per-role `statement_timeout`, connection limits, backups/PITR, and monitoring.
- Wire withdrawals to real custody only behind manual/multi-party approval; keep the audit log immutable.
