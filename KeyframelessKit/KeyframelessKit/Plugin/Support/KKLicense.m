/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKLicense.h"

#import <CommonCrypto/CommonDigest.h>
#import <Security/Security.h>
#import <os/lock.h>

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

/// This machine, as the activation Worker sees it. Only consulted when a
/// record actually carries a `machineID`, so binding can be switched on
/// server-side later without a client change. `gethostuuid` keeps this free of
/// an IOKit link and is stable across boots; a sandbox that refuses it yields
/// nil, which reads as "unbound" rather than "invalid".
static NSString *KKLicenseMachineID(void) {
  uuid_t uuid;
  struct timespec wait = {0, 0};
  if (gethostuuid(uuid, &wait) != 0)
    return nil;
  uuid_string_t str;
  uuid_unparse_upper(uuid, str);
  return @(str);
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
/// record for one product can't stand in for another, and a machine-bound
/// record can't be copied to a second machine.
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
  if ([machine isKindOfClass:[NSString class]] && machine.length) {
    NSString *here = KKLicenseMachineID();
    if (!here || ![machine isEqualToString:here])
      return NO;
  }
  return YES;
}

BOOL KKLicenseIsActivated(NSString *productID) {
  if (productID.length == 0)
    return NO;
  // The suite is re-created per call on purpose: Foundation caches suite
  // domains via cfprefsd, so this stays cheap while still observing an
  // activation written from another process (the inspector ViewBridge).
  NSUserDefaults *suite = [[NSUserDefaults alloc]
      initWithSuiteName:@"group.com.keyframeless"];
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
