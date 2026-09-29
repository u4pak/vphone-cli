# Apple Account sign-in in the guest

**Status (2026-09-29):** sign-in fails on `17,3_27.0_24A435` (27.0 RC) with
"Verification Failed — An unknown error occurred". `vphone-vm` now asks
Virtualization for FairPlay and strong identity. Validated on-device: both
devices attach and anisette provisioning now succeeds, but sign-in still fails
one step later. See "After FairPlay and strong identity" below.

## What fails

`akd`'s log during a sign-in attempt, in order:

1. `ADIGetIDMSRouting failed! Error: -45059`: `adid` has never been
   provisioned, so there is no anisette.
2. `Kicking off Anisette provisioning…`, then `midStartProvisioning` returns
   HTTP 200 and `ADIProvisioningStart succeeded!`.
3. BAA signing of the provisioning request asks `mobileactivationd` for the
   device certificate and gets `Failed to query UCRT healing support`
   (`MobileActivation.ErrorDomain -1`, underlying `-4`). The guest is activated
   through the `mobileactivationd.should_hactivate` patch, so it holds no UCRT.
   `mobileactivationd` schedules `com.apple.mobileactivationd.UCRT.OOB`, which
   cannot succeed.
4. `midFinishProvisioning` returns HTTP 200, but
   `ADIProvisioningEnd failed. Error: -43004`.
5. The retry's start request gets HTTP 503, and akd reports
   `AKAnisetteError -8007` ("No Anisette for you today!").
6. `SRP authentication with server failed … -8001`: the password is never
   checked.

In the same attempt, Preferences logs `Failed to generate signature: -43004`, the
same code from a different signer.

The `hv_vmm_present` flag is not in this chain. Masking it from AuthKit and the
other account dylibs (reverted in `e65933a`) left the failure unchanged.

## Why: two host devices the VM does not get

In the guest, `fairplayd.H2`, `fairplaydeviceidentityd` and
`com_apple_driver_FairPlayIOKit` (5 user clients) are up. But:

* `AvpFairPlayDriver` is not in the registry. It matches only the VirtIO device
  `0x1a08106b` (see `Research/Kernel/kernel_fairplay_kexts.md`), which the VM
  was not given.
* `AppleVirtualPlatformIdentityService`, `…IdentityMessenger`,
  `…IdentityVirtioMessenger` and `…IdentityUserClient` have zero instances
  (`IOKitDiagnostics` class counts): the driver is loaded with no device.

On the reporting host (Xcode 27.1 beta, macOS 27 SDK), `Virtualization.framework` exposes no configuration class for
either device (none of its 284 classes mention FairPlay or identity). The
VirtualMachine XPC service implements both:

| Setting | XPC service device |
| --- | --- |
| `fairplay_enabled` | `VzCore::Hardware::AvpFairPlayDevice`, `com.apple.virtualization.avp.fairplay-device` |
| `strong_identity_enabled`, `avp_strong_identity` | `VzCore::Hardware::AvpStrongIdentity`, `com.apple.AppleVirtualPlatform.Identity.Virtio` |
| (not yet linked to a setting) | `AvpProvisioningDevice`, `com.apple.virtualization.avp.provisioning-device` |

The switches are private methods on `VZMacPlatformConfiguration`:
`_setFairPlayEnabled:` / `_isFairPlayEnabled` and `_setStrongIdentityEnabled:` /
`_isStrongIdentityEnabled`. Both are off for the platform version 3 research
hardware model `vphone-vm` builds. `_setProductionModeEnabled:` also exists and
is left alone.

## What `vphone-vm` does now

`VPhoneVirtualMachine` turns both on before validation and logs the result as
`[vphone] FairPlay: on|off, strong identity: on|off`. If validation refuses
them, it logs a warning and starts the VM without them rather than failing.

## Validation steps

1. Create a new VM with a build that has this change. Check the launch log for
   `FairPlay: on, strong identity: on`, and for the refusal warning.
2. In the guest, `ioreg -l | grep -i -E "AvpFairPlay|VirtualPlatformIdentity"`
   should now show `AvpFairPlayDriver` and an `AppleVirtualPlatformIdentity`
   service with an instance.
3. Capture `logs.syslog` for `akd` during sign-in and compare against the chain
   above: provisioning should now pass step 4. If it still stops at step 3, the
   missing UCRT from the activation patch is the next blocker.

## After FairPlay and strong identity

Same guest, relaunched with both enabled:

* The registry has `AvpFairPlayDriver` (4 `AvpFairPlayUserClient`s) and
  `AppleVirtualPlatformIdentityVirtioMessenger` →
  `AppleVirtualPlatformIdentityService`.
* akd: `Anisette succeeded, but BAA failed. This is not expected. Not blocking`.
  The `-45059` / `-43004` / 503 chain is gone. BAA still fails:
  `UCRT is unavailable` (`MobileActivation -4`).
* `fetchAuthMode` gets HTTP 440 (`AKAuthenticationServerError 440`), and akd
  carries on.
* akd waits 30 s for an APNs token and gets none
  (`APS connection … still returned nil for -publicToken!`,
  `Skipping piggybacking, missing push token`), then carries on.
* The SRP init request returns HTTP 200, but the body has no selected protocol:
  `AppleIDAuthSupport: setError: 2:selected protocol key missing`, then
  `AKAuthenticationServerError -3000076`. That is the sign-in failure now. The
  server's own status message is `<private>` in the log.

Next candidates, in order: read the server's message with private log data
enabled; let a throwaway VM activate for real (block
`mobileactivationd.should_hactivate`) so it can get a UCRT; APNs.

## If this is not enough

The fallback is the approach ipatool took (its commit `abd86cb`): run Apple's
device-identity code in an emulator on the host, and have a guest hook in `akd`
fetch anisette from the host over vsock. That is a separate, much larger piece
of work.
