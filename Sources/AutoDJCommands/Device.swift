// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

import ArgumentParser
import AutoDJKit
import Foundation

struct USBCheckCmd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "usb-check", abstract: "check that the cues on a USB device are still the collection's",
        discussion: """
            Reads every track's analysis file on a USB device Rekordbox exported to and compares its hot
            cues and memory cues with master.db. Rekordbox's Sync Manager doesn't update the cues of tracks
            already on a device, so after auto-dj (or you, with the device unplugged) changes cues, those
            tracks keep their old ones there until they're exported again. Lists the tracks that are out
            of date and the playlists to re-export (right-click > Export Playlist > the device, replace).
            Read-only; Rekordbox can be open.
            """)
    @OptionGroup var g: Globals
    @Argument(help: "the device, e.g. /Volumes/PRIMARY (default: every mounted device with a Rekordbox export)")
    var volume: String?

    func run() throws {
        let vols = volume.map { [Config.expandUser($0)] } ?? USBDevice.volumes()
        if vols.isEmpty {
            print("No USB device with a Rekordbox export is mounted.")
            return
        }
        for (i, v) in vols.enumerated() {
            if i > 0 { print() }
            print(USBDevice.format(try USBDevice.check(volume: v, masterDB: g.paths.masterDB)).joined(separator: "\n"))
        }
    }
}
