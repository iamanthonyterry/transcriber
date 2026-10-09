import CoreMIDI
import Foundation

/// A MIDI message written as text: "note 60", "cc 20", "program 5", optionally with "ch 2" (channel 1 if left out).
/// `value` is the velocity or controller value (127 if empty).
struct MIDIMessage: Equatable {
    enum Kind { case note, control, program }
    var kind: Kind
    var channel: Int  // 1...16
    var number: Int   // 0...127
    var value: Int    // 0...127

    init?(_ text: String, value: String) {
        let w = text.lowercased().split { $0 == " " || $0 == "," }.map(String.init)
        guard w.count >= 2, let n = Int(w[1]), (0...127).contains(n) else { return nil }
        switch w[0] {
        case "note": kind = .note
        case "cc", "control": kind = .control
        case "program", "pc": kind = .program
        default: return nil
        }
        number = n
        channel = 1
        if w.count >= 4, w[2] == "ch" || w[2] == "channel" {
            guard let c = Int(w[3]), (1...16).contains(c) else { return nil }
            channel = c
        } else if w.count != 2 {
            return nil
        }
        let v = value.trimmingCharacters(in: .whitespaces)
        guard let parsed = v.isEmpty ? 127 : Int(v), (0...127).contains(parsed) else { return nil }
        self.value = parsed
    }

    /// MIDI 1.0 messages as Universal MIDI Packet words (a note is an on followed by an off).
    var packets: [UInt32] {
        func word(_ status: UInt32, _ d1: Int, _ d2: Int) -> UInt32 {
            0x2000_0000 | (status | UInt32(channel - 1)) << 16 | UInt32(d1) << 8 | UInt32(d2)
        }
        switch kind {
        case .note: return [word(0x90, number, max(value, 1)), word(0x80, number, 0)]
        case .control: return [word(0xB0, number, value)]
        case .program: return [word(0xC0, number, 0)]
        }
    }
}

/// A virtual MIDI source named "Transcriber" that other apps (QLab, ProPresenter, Companion) can pick as an input.
final class MIDIOut: @unchecked Sendable {
    private let queue = DispatchQueue(label: "midi.send")
    private var client = MIDIClientRef()
    private var source = MIDIEndpointRef()

    /// Makes the source appear. Called as soon as a MIDI rule exists, so the receiving app can find it before the first cue.
    func open() {
        queue.async { [self] in
            guard source == 0 else { return }
            guard MIDIClientCreateWithBlock("Transcriber" as CFString, &client, nil) == noErr else { return }
            if MIDISourceCreateWithProtocol(client, "Transcriber" as CFString, ._1_0, &source) != noErr { source = 0 }
        }
    }

    func send(_ message: MIDIMessage) {
        open()
        queue.async { [self] in
            guard source != 0 else { return }
            for (i, word) in message.packets.enumerated() {
                queue.asyncAfter(deadline: .now() + .milliseconds(i * 100)) { [self] in  // a note's off follows its on
                    var list = MIDIEventList()
                    let packet = MIDIEventListInit(&list, ._1_0)
                    _ = MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, packet, 0, 1, [word])
                    MIDIReceivedEventList(source, &list)
                }
            }
        }
    }
}
