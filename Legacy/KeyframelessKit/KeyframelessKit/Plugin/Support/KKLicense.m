/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKLicense.h"

#import <CommonCrypto/CommonDigest.h>
#import <Security/Security.h>
#import <fcntl.h>
#import <os/lock.h>
#import <sys/file.h>
#import <sys/stat.h>
#import <unistd.h>

NSString *const KKLicenseProductMirage = @"mirage";
NSString *const KKLicenseProductCanvas = @"canvas";
NSString *const KKLicenseProductSteno = @"steno";

// P-256 public key as an X9.63 uncompressed point. The private half exists
// only as a secret in the activation Worker, which is the entire point: this
// process can CHECK an activation record but cannot produce one, so a
// hand-written defaults entry fails verification.
//
// Must stay byte-identical to `publicKeyX963` in LicenseManager.swift, or the
// trial banner and the render disagree about activation. Rotating the pair
// invalidates every issued record, so it means a re-activation for everyone.
static const uint8_t kKKLicensePublicKey[65] = {
    0x04, 0x07, 0x0a, 0x25, 0x33, 0xf2, 0xb5, 0x7d, 0x76, 0x5f, 0x99,
    0xae, 0x0a, 0xa7, 0x0a, 0xa6, 0x16, 0x51, 0x21, 0xf0, 0x3c, 0xc0,
    0x3b, 0x5d, 0x6a, 0x93, 0x85, 0x14, 0x8b, 0x57, 0x5e, 0x3b, 0xe0,
    0x55, 0x30, 0x23, 0x29, 0x17, 0x3f, 0xbd, 0xcd, 0x38, 0x7f, 0xf8,
    0x61, 0xa3, 0x5e, 0x83, 0x30, 0x0d, 0x10, 0xd6, 0xe5, 0x6d, 0xb5,
    0xd1, 0xce, 0x30, 0x2c, 0x8b, 0x14, 0xea, 0xfb, 0x34, 0x95};

/// The shared per-user installation ID used by every Keyframeless process.
///
/// The signed claim keeps the historical wire name `machineID`, but its value
/// is deliberately not a hardware identifier. Sandboxed FxPlug services and
/// app extensions do not provide a reliable cross-process `gethostuuid`
/// contract. A UUID file in the app-group container is stable in every product
/// and avoids exposing hardware identity to the activation service.
static NSString *KKLicenseInstallationID(void) {
  NSFileManager *fm = NSFileManager.defaultManager;
  NSURL *container = [fm containerURLForSecurityApplicationGroupIdentifier:
                             @"group.com.keyframeless"];
  if (!container)
    return nil;
  NSURL *directory = [container URLByAppendingPathComponent:@"License"
                                                isDirectory:YES];
  if (![fm createDirectoryAtURL:directory
          withIntermediateDirectories:YES
                           attributes:nil
                                error:NULL])
    return nil;

  NSURL *lockURL =
      [directory URLByAppendingPathComponent:@".installation-id.lock"];
  int lockFD = open(lockURL.fileSystemRepresentation, O_CREAT | O_RDWR,
                    S_IRUSR | S_IWUSR);
  if (lockFD < 0)
    return nil;
  if (flock(lockFD, LOCK_EX) != 0) {
    close(lockFD);
    return nil;
  }

  NSURL *identityURL =
      [directory URLByAppendingPathComponent:@"installation-id"];
  NSString *raw = [NSString stringWithContentsOfURL:identityURL
                                           encoding:NSUTF8StringEncoding
                                              error:NULL];
  NSString *trimmed = [raw
      stringByTrimmingCharactersInSet:NSCharacterSet
                                          .whitespaceAndNewlineCharacterSet];
  NSUUID *parsed =
      trimmed.length ? [[NSUUID alloc] initWithUUIDString:trimmed] : nil;
  NSString *identity = parsed.UUIDString;
  if (!identity) {
    identity = NSUUID.UUID.UUIDString;
    NSString *contents = [identity stringByAppendingString:@"\n"];
    if (![contents writeToURL:identityURL
                   atomically:YES
                     encoding:NSUTF8StringEncoding
                        error:NULL])
      identity = nil;
    else
      chmod(identityURL.fileSystemRepresentation, S_IRUSR | S_IWUSR);
  }

  flock(lockFD, LOCK_UN);
  close(lockFD);
  return identity;
}

static NSString *KKLicenseSHA256Hex(NSData *data) {
  uint8_t digest[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
  NSMutableString *hex =
      [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
  for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++)
    [hex appendFormat:@"%02x", digest[i]];
  return hex;
}

/// ECDSA-verify `signature` (DER) over `payload` with the embedded public key.
static BOOL KKLicenseSignatureValid(NSData *payload, NSData *signature) {
  NSData *keyData = [NSData dataWithBytes:kKKLicensePublicKey
                                   length:sizeof(kKKLicensePublicKey)];
  NSDictionary *attrs = @{
    (__bridge id)kSecAttrKeyType : (__bridge id)kSecAttrKeyTypeECSECPrimeRandom,
    (__bridge id)kSecAttrKeyClass : (__bridge id)kSecAttrKeyClassPublic,
    (__bridge id)kSecAttrKeySizeInBits : @256,
  };
  CFErrorRef err = NULL;
  SecKeyRef pub = SecKeyCreateWithData((__bridge CFDataRef)keyData,
                                       (__bridge CFDictionaryRef)attrs, &err);
  if (!pub) {
    if (err)
      CFRelease(err);
    return NO;
  }
  BOOL ok = SecKeyVerifySignature(
      pub, kSecKeyAlgorithmECDSASignatureMessageX962SHA256,
      (__bridge CFDataRef)payload, (__bridge CFDataRef)signature, &err);
  CFRelease(pub);
  if (err)
    CFRelease(err);
  return ok;
}

/// The signed payload's claims must match what is being asked about: the
/// record for one product can't stand in for another installation.
static BOOL KKLicenseClaimsValid(NSData *payload, NSString *productID) {
  NSDictionary *claims = [NSJSONSerialization JSONObjectWithData:payload
                                                         options:0
                                                           error:NULL];
  if (![claims isKindOfClass:[NSDictionary class]])
    return NO;
  NSString *product = claims[@"product"];
  if (![product isKindOfClass:[NSString class]] ||
      ![product isEqualToString:productID])
    return NO;
  NSString *machine = claims[@"machineID"];
  if (![machine isKindOfClass:[NSString class]] || !machine.length)
    return NO;
  NSString *here = KKLicenseInstallationID();
  return here && [machine isEqualToString:here];
}

BOOL KKLicenseIsActivated(NSString *productID) {
  if (productID.length == 0)
    return NO;
  // The suite is re-created per call on purpose: Foundation caches suite
  // domains via cfprefsd, so this stays cheap while still observing an
  // activation written from another process (the inspector ViewBridge).
  NSUserDefaults *suite =
      [[NSUserDefaults alloc] initWithSuiteName:@"group.com.keyframeless"];
  NSDictionary *record = [suite
      dictionaryForKey:[NSString
                           stringWithFormat:@"com.keyframeless.license.%@",
                                            productID]];
  NSString *payloadB64 = record[@"payload"];
  NSString *signatureB64 = record[@"sig"];
  if (![payloadB64 isKindOfClass:[NSString class]] ||
      ![signatureB64 isKindOfClass:[NSString class]])
    return NO;
  NSData *payload = [[NSData alloc] initWithBase64EncodedString:payloadB64
                                                        options:0];
  NSData *signature = [[NSData alloc] initWithBase64EncodedString:signatureB64
                                                          options:0];
  if (!payload.length || !signature.length)
    return NO;

  // Verifying is ~100us and this is called per rendered frame, so the verdict
  // is memoised against a digest of the record itself: a record swapped under
  // us (activation, or an edit) misses the cache and re-verifies.
  static NSMutableDictionary<NSString *, NSString *> *verified;
  static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
  NSMutableData *stamp = [payload mutableCopy];
  [stamp appendData:signature];
  NSString *digest = KKLicenseSHA256Hex(stamp);
  os_unfair_lock_lock(&lock);
  BOOL cached = [verified[productID] isEqualToString:digest];
  os_unfair_lock_unlock(&lock);
  if (cached)
    return YES;

  if (!KKLicenseSignatureValid(payload, signature))
    return NO;
  if (!KKLicenseClaimsValid(payload, productID))
    return NO;

  os_unfair_lock_lock(&lock);
  if (!verified)
    verified = [NSMutableDictionary dictionary];
  verified[productID] = digest;
  os_unfair_lock_unlock(&lock);
  return YES;
}
