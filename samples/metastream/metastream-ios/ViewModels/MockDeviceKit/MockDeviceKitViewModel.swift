/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// MockDeviceKitViewModel.swift
//
// View model for managing mock devices during development and testing of DAT SDK features.
// Mock devices simulate real Meta wearable device behavior, allowing developers to test
// streaming, photo capture, and device management workflows without physical hardware.
//

#if DEBUG

import Foundation
import MWDATMockDevice

extension MockDeviceKitView {
  @MainActor
  class ViewModel: ObservableObject {
    private let mockDeviceKit: MockDeviceKitInterface
    @Published var cardViewModels: [MockDeviceCardView.ViewModel] = []

    init(mockDeviceKit: MockDeviceKitInterface) {
      self.mockDeviceKit = mockDeviceKit
      self.cardViewModels = mockDeviceKit.pairedDevices.map { MockDeviceCardView.ViewModel(device: $0) }
    }

    // Add a new mock Ray-Ban Meta device
    // Run SDK call on .default QoS to match SDK's internal BackgroundThread QoS
    // Using higher QoS (like .userInitiated) causes priority inversion warnings
    func pairRaybanMeta() {
      let kit = mockDeviceKit
      DispatchQueue.global(qos: .default).async {
        let mockDevice = kit.pairRaybanMeta()
        // Use nonisolated(unsafe) since MockRaybanMeta is thread-safe for our usage
        nonisolated(unsafe) let device = mockDevice
        DispatchQueue.main.async { [weak self] in
          self?.cardViewModels.append(MockDeviceCardView.ViewModel(device: device))
        }
      }
    }

    func unpairDevice(_ device: MockDevice) {
      if let idx = cardViewModels.firstIndex(where: { $0.id == device.deviceIdentifier }) {
        cardViewModels.remove(at: idx)
        mockDeviceKit.unpairDevice(device)
      }
    }
  }
}

#endif
