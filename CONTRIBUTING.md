# Contributing

Thank you for considering a contribution to Raven Server Install.

## License and Developer Certificate of Origin

This project is licensed under [AGPL-3.0-or-later](./LICENSE). By submitting a contribution, you agree that your contribution is licensed under the same terms.

### Sign-off requirement

We use the [Developer Certificate of Origin](https://developercertificate.org/) (DCO) v1.1 to certify the provenance of contributions. Every commit must include a `Signed-off-by:` trailer:

```text
Signed-off-by: Your Real Name <your.email@example.com>
```

Add it automatically with `git commit -s`. The name and email must match the commit author identity. CI rejects commits without a sign-off.

### Full DCO text

```
Developer Certificate of Origin
Version 1.1

Copyright (C) 2004, 2006 The Linux Foundation and its contributors.

Everyone is permitted to copy and distribute verbatim copies of this
license document, but changing it is not allowed.


Developer's Certificate of Origin 1.1

By making a contribution to this project, I certify that:

(a) The contribution was created in whole or in part by me and I
    have the right to submit it under the open source license
    indicated in the file; or

(b) The contribution is based upon previous work that, to the best
    of my knowledge, is covered under an appropriate open source
    license and I have the right under that license to submit that
    work with modifications, whether created in whole or in part
    by me, under the same open source license (unless I am
    permitted to submit under a different license), as indicated
    in the file; or

(c) The contribution was provided directly to me by some other
    person who certified (a), (b) or (c) and I have not modified
    it.

(d) I understand and agree that this project and the contribution
    are public and that a record of the contribution (including all
    personal information I submit with it, including my sign-off) is
    maintained indefinitely and may be redistributed consistent with
    this project and the open source license(s) involved.
```

## Pre-commit hooks

This repo ships with hooks that block real IPs, secrets, and other sensitive content from leaking into commits. Install them once after cloning:

```bash
scripts/install-hooks.sh
```

The hooks read live IP values from `roles/hosts.yml` (gitignored), so they pick up your inventory automatically.

## Testing changes

The role suite includes Ansible render + `xray -test` validation:

```bash
./tests/run.sh
```

To skip the Docker-based `xray -test` step (e.g. on a control machine without Docker):

```bash
SKIP_XRAY_TEST=1 ./tests/run.sh
```

See `CLAUDE.md` for the full deploy / development reference.

## Reporting security issues

Do not open a public issue for security vulnerabilities. Use GitHub Security Advisories ("Report a vulnerability" button on the Security tab) or contact the maintainer directly.
