// DyldSharedCacheAccountHypervisorMaskPatcher.swift — hide the hypervisor from the Apple Account dylibs only.
//
// Why this exists
// ---------------
// Signing in to an Apple Account in the guest fails with "Verification Failed —
// An unknown error occurred" on a `standard` VM. AuthKit, AAAFoundation, CoreCDP,
// DeviceIdentity and the other identity dylibs each read
// `sysctlbyname("kern.hv_vmm_present")` once, cache the answer, and feed it into
// the device posture they present to Apple's account servers
// (`Research/Patches/hv_vmm_present_usermode_xrefs.md`, "AAAFoundation, AuthKit,
// …"). On a stock research VM that answer is 1.
//
// The full concealment that used to hide it — `kernelcache_exp.hv_vmm` plus
// `hv_vmm_dsc` — renames the kernel OID for everybody and is off in `standard`
// since it bricks a 26.4 guest through `bluetoothd`. This patch is the narrow
// half that does not need the rename: it touches only the dylibs listed in
// ``maskedInstallNames`` and leaves every other reader — bluetoothd, graphics,
// ML, MobileGestalt — on the real answer.
//
// ipatool's fix for the same symptom (its commit abd86cb) is to sign the
// authenticate request with FairPlay SAP. In the guest that signing is done by
// iOS itself, so there is nothing of ipatool's to port; what differs between a
// guest and a phone is what these dylibs report about the hardware.
//
// What the patch is
// -----------------
// Byte 0 of `"kern.hv_vmm_present\0"` in each listed dylib becomes `'X'`, giving
// `"Xern.hv_vmm_present"`. `Xern` is not a top-level sysctl namespace, so the
// name-to-MIB walk fails before reaching any OID and `sysctlbyname` returns
// ENOENT. The callers' defensive `cbnz w0, skip` then leaves their cached
// `is_vmm` byte at its BSS zero: not a VM.
//
// Byte 0, not byte 5 like `DyldSharedCacheHypervisorVirtualMachinePatcher`,
// because byte 5 produces `kern.Xv_vmm_present`, which is exactly the name the
// kernel rename creates. Under `extended` that would resolve and read 1 again. A
// byte-0 name never resolves, so the patch means the same thing with or without
// the kernel rename, and the two DSC patches can both be on: `hv_vmm_dsc` leaves
// these dylibs pristine and searches only for its own byte-5 form, so neither
// patch ever sees the other's writes.
//
// Every written page is re-attested, exactly as in the full concealment — see
// that file's "TXM and the page hashes".

import Foundation
import VPhonePatchKit

/// Masks `kern.hv_vmm_present` from the Apple Account and store dylibs in a
/// chunked dyld shared cache.
public enum DyldSharedCacheAccountHypervisorMaskPatcher {
    // MARK: - The cstring and its mask

    /// `"kern.hv_vmm_present\0"`, shared with the full concealment so the two
    /// cannot disagree about what they are looking for.
    public static let needle = DyldSharedCacheHypervisorVirtualMachinePatcher.needle

    /// Index of the masked byte: the `'k'` of `kern.`.
    public static let maskOffset = 0

    /// What that byte is before the patch.
    public static let originalByte = UInt8(ascii: "k")

    /// What it becomes.
    public static let maskedByte = UInt8(ascii: "X")

    /// `"Xern.hv_vmm_present\0"` — what a patched site reads as.
    public static let maskedNeedle: Data = {
        var masked = needle
        masked[masked.startIndex + maskOffset] = maskedByte
        return masked
    }()

    // MARK: - Which dylibs

    /// The dylibs that are told they are on real hardware, by `LC_ID_DYLIB`
    /// install name.
    ///
    /// Each one is a sign-in, attestation, push or store participant, and all
    /// were already on the concealment's blacklist, so `extended` VMs have run
    /// with exactly this answer in them. MobileActivation, FindMyBase and the
    /// consumer services on that blacklist are left out on purpose: activation
    /// works on a `standard` VM today, and nothing here needs to change it.
    public static let maskedInstallNames: [String] = [
        // ── Apple Account sign-in and Cloud Data Protection.
        "/System/Library/PrivateFrameworks/AuthKit.framework/AuthKit",
        "/System/Library/PrivateFrameworks/AAAFoundation.framework/AAAFoundation",
        "/System/Library/PrivateFrameworks/CoreCDP.framework/CoreCDP",

        // ── Device attestation and anti-abuse.
        "/System/Library/PrivateFrameworks/DeviceIdentity.framework/DeviceIdentity",
        "/System/Library/PrivateFrameworks/DeviceCheckInternal.framework/DeviceCheckInternal",

        // ── Push and identity services the sign-in registers with.
        "/System/Library/PrivateFrameworks/ApplePushService.framework/ApplePushService",
        "/System/Library/PrivateFrameworks/IDSFoundation.framework/IDSFoundation",

        // ── Media & Purchases.
        "/System/Library/PrivateFrameworks/AppStoreUtilities.framework/AppStoreUtilities",
    ]

    /// Set form, for the per-site membership test.
    public static let maskedSet = Set(maskedInstallNames)

    // MARK: - Result

    /// What one run did.
    public struct Result: Sendable {
        /// Sites this run masked (or, on a dry run, would have).
        public let masked: Int
        /// Sites found already masked, re-attested only.
        public let alreadyMasked: Int
        /// Pristine sites in dylibs not on the list, left alone.
        public let leftAlone: Int
        /// Sites refused: unreadable, or bytes that are neither form.
        public let refused: Int
        /// Listed dylibs this cache carries the cstring in, masked or not.
        public let installNamesSeen: Set<String>
        /// The re-attestation pass, or `nil` when there were no pages to cover.
        public let reattestation: DyldSharedCacheReattestation?

        /// Listed dylibs with no site in this cache: renamed, merged, or no
        /// longer reading the sysctl.
        public var installNamesMissing: [String] {
            maskedInstallNames.filter { !installNamesSeen.contains($0) }
        }

        public var isFullyAttested: Bool {
            reattestation?.isFullyAttested ?? true
        }
    }

    // MARK: - The DSC patch

    /// Mask the listed dylibs in the cache under `chunksDirectory`.
    @discardableResult
    public static func patch(
        chunksDirectory: URL,
        dryRun: Bool = false,
        log: ((String) -> Void)? = DyldSharedCacheCodeSignature.stderrLog,
    ) throws -> Result {
        let chunks = try DyldSharedCacheChunkSet(directory: chunksDirectory)
        return try patch(in: chunks, dryRun: dryRun, log: log)
    }

    /// Mask the listed dylibs in an already-open cache.
    @discardableResult
    public static func patch(
        in chunks: DyldSharedCacheChunkSet,
        dryRun: Bool = false,
        log: ((String) -> Void)? = DyldSharedCacheCodeSignature.stderrLog,
    ) throws -> Result {
        log?("  [.] locating cstring \"kern.hv_vmm_present\\0\" in \(maskedSet.count) account dylib(s)…")
        let pristineSites = try chunks.findStringVMAs(needle).sorted()
        let maskedSites = try chunks.findStringVMAs(maskedNeedle).sorted()

        var masked = 0
        var leftAlone = 0
        var refused = 0
        var seen: Set<String> = []
        var plannedSpans: [DyldSharedCacheWriteSpan] = []
        var reattestOnlySpans: [DyldSharedCacheWriteSpan] = []

        for vma in pristineSites {
            guard let installName = DyldSharedCacheHypervisorVirtualMachinePatcher.classify(vma, in: chunks),
                  maskedSet.contains(installName)
            else {
                leftAlone += 1
                continue
            }
            seen.insert(installName)

            let current: Data
            do {
                current = try chunks.bytesAtVMA(vma, length: needle.count)
            } catch {
                log?("      [-] read failed at 0x\(hex(vma)): \(error)")
                refused += 1
                continue
            }
            guard current == needle else {
                log?("      [-] unexpected bytes at 0x\(hex(vma)) (\(current.hex)); refusing  (\(installName))")
                refused += 1
                continue
            }

            let writeVMA = vma &+ UInt64(maskOffset)
            if dryRun {
                plannedSpans.append(DyldSharedCacheWriteSpan.byte(at: writeVMA))
            } else {
                try chunks.write(at: writeVMA, Data([maskedByte]))
            }
            log?(
                "      [+] \(dryRun ? "would mask" : "masked") \(installName)  string@0x\(hex(vma))  "
                    + "now queries Xern.hv_vmm_present, will see ENOENT (not a VM)",
            )
            masked += 1
        }

        // Sites an earlier run masked: nothing to write, but their pages join the
        // re-attestation so a re-run leaves slot hashes and bytes in agreement.
        var alreadyMasked = 0
        for vma in maskedSites {
            guard let installName = DyldSharedCacheHypervisorVirtualMachinePatcher.classify(vma, in: chunks),
                  maskedSet.contains(installName)
            else { continue }
            seen.insert(installName)
            reattestOnlySpans.append(DyldSharedCacheWriteSpan(vma: vma, length: needle.count))
            alreadyMasked += 1
        }
        if alreadyMasked > 0 {
            log?("  [.] \(alreadyMasked) site(s) already masked; queueing their pages for re-attestation")
        }

        for installName in maskedInstallNames where !seen.contains(installName) {
            log?("      [.] no hv_vmm_present site in \(installName) on this cache")
        }

        let spans = (dryRun ? plannedSpans : chunks.recordedWrites) + reattestOnlySpans
        var reattestation: DyldSharedCacheReattestation?
        if !spans.isEmpty {
            log?("  [.] \(dryRun ? "dry-run: would re-attest" : "re-attesting") \(spans.count) modified page span(s)…")
            reattestation = try DyldSharedCacheCodeSignature.reattest(
                in: chunks,
                modifiedSpans: spans,
                dryRun: dryRun,
                log: log,
            )
        }

        log?(
            "  [+] account hv_vmm mask complete: \(masked) masked, \(alreadyMasked) already masked, "
                + "\(leftAlone) other site(s) left alone, \(refused) refused/error",
        )
        return Result(
            masked: masked,
            alreadyMasked: alreadyMasked,
            leftAlone: leftAlone,
            refused: refused,
            installNamesSeen: seen,
            reattestation: reattestation,
        )
    }

    // MARK: - Formatting

    private static func hex(_ value: UInt64) -> String {
        String(value, radix: 16, uppercase: true)
    }
}
