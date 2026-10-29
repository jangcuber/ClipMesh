# Narrow iOS build compatibility patches

Upstream sources retain their original licenses and version metadata.

- `netdev` 0.46.3: its Darwin IPv6 flag ioctl references `libc::in6_ifreq`, which libc 0.2.191 exposes only on macOS. iOS still enumerates all interface addresses but reports these optional IPv6 address flags as unknown.
- `netwatch` 0.19.3: its BSD routing-message module uses libc constants missing on iOS. iOS now enumerates interfaces normally through netdev/getifaddrs, checks for changes every five seconds, and reports unavailable default-route/home-router hints as unknown. Other platforms use unchanged upstream implementations. This adds modest background polling; assess battery behavior in device validation.

These patches avoid inventing private routing socket structures or disabling transport authentication/TLS. Reevaluate against an upstream release that builds for `aarch64-apple-ios` before removing them.

## Upstream source and licenses

- `netdev` 0.46.3: https://github.com/shellrow/netdev/tree/4505d238696975a97b029c1b8607487453c0f86e (MIT; original `LICENSE` retained).
- `netwatch` 0.19.3: https://github.com/n0-computer/net-tools/tree/0030e57fc70981895bb86212ff0f059cc41c8a4e/netwatch (MIT OR Apache-2.0; upstream repository `LICENSE-MIT` and `LICENSE-APACHE` included). Its crates.io package omitted these repository-root license files; these copies come from the exact commit recorded in `.cargo_vcs_info.json`.

ClipMesh changes are documented above and confined to the iOS compatibility paths. Public source publication does not change the original license terms or authorship.
