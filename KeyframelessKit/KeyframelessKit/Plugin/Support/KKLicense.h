/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Product IDs used by the shared license activation flow. Must match the
/// IDs the activation popover (`KeyframelessAI`'s `LicenseManager`) persists
/// under.
FOUNDATION_EXPORT NSString *const KKLicenseProductMirage;
FOUNDATION_EXPORT NSString *const KKLicenseProductCanvas;
FOUNDATION_EXPORT NSString *const KKLicenseProductSteno;

/// YES once the product has been activated. Activation is a one-time Payhip
/// verification performed by the shared popover (`KKLicenseBannerHost` in
/// `KeyframelessAI`), persisted to the app-group defaults suite so every
/// Keyframeless process (inspector ViewBridge, plugin XPC, workflow
/// extension) reads the same state. Safe to call per render.
FOUNDATION_EXPORT BOOL KKLicenseIsActivated(NSString *productID);

NS_ASSUME_NONNULL_END
