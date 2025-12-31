/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// MainAppView.swift
//
// Central navigation hub that displays different views based on DAT SDK registration and device states.
// When unregistered, shows the registration flow. When registered, shows the device selection screen
// for choosing which Meta wearable device to stream from.
//

import MWDATCore
import SwiftUI

struct MainAppView: View {
  let wearables: WearablesInterface
  @ObservedObject private var viewModel: WearablesViewModel
  #if DEBUG
  @ObservedObject private var debugMenuViewModel: DebugMenuViewModel
  #endif

  #if DEBUG
  init(wearables: WearablesInterface, viewModel: WearablesViewModel, debugMenuViewModel: DebugMenuViewModel) {
    self.wearables = wearables
    self.viewModel = viewModel
    self.debugMenuViewModel = debugMenuViewModel
  }
  #else
  init(wearables: WearablesInterface, viewModel: WearablesViewModel) {
    self.wearables = wearables
    self.viewModel = viewModel
  }
  #endif

  var body: some View {
    if viewModel.registrationState == .registered || viewModel.hasMockDevice {
      #if DEBUG
      StreamSessionView(wearables: wearables, wearablesVM: viewModel, autoStartStreaming: $debugMenuViewModel.shouldStartStreaming)
      #else
      StreamSessionView(wearables: wearables, wearablesVM: viewModel)
      #endif
    } else {
      // User not registered - show registration/onboarding flow
      HomeScreenView(viewModel: viewModel)
    }
  }
}
