import AppKit
import Carbon

@MainActor
final class NativeHotkeys {
    private var references: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    var onPress: ((UInt32) -> Void)?
    private let signature: OSType = 0x52534854

    func enable() throws {
        disable()
        var specification = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                          eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard status == noErr else { return status }
            let owner = Unmanaged<NativeHotkeys>.fromOpaque(context).takeUnretainedValue()
            guard identifier.signature == 0x52534854, (1...3).contains(identifier.id) else {
                return OSStatus(eventNotHandledErr)
            }
            let id = identifier.id
            Task { @MainActor in owner.onPress?(id) }
            return noErr
        }, 1, &specification, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard installed == noErr else {
            throw NSError(domain: "RAPPShot.Shortcuts", code: Int(installed),
                          userInfo: [NSLocalizedDescriptionKey: "macOS could not install the shortcut handler. App menu shortcuts still work."])
        }
        for (offset, key) in [kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8].enumerated() {
            var reference: EventHotKeyRef?
            let id = EventHotKeyID(signature: signature, id: UInt32(offset + 1))
            let status = RegisterEventHotKey(UInt32(key), UInt32(cmdKey | shiftKey), id,
                                             GetApplicationEventTarget(), 0, &reference)
            guard status == noErr, let reference else {
                disable()
                throw NSError(domain: "RAPPShot.Shortcuts", code: Int(status),
                              userInfo: [NSLocalizedDescriptionKey: "⌘⇧6/7/8 are unavailable, often because another app or Hammerspoon owns them. Disable those conflicting bindings or use RAPP Shot’s Capture menu."])
            }
            references.append(reference)
        }
    }

    func disable() {
        for reference in references { UnregisterEventHotKey(reference) }
        references.removeAll()
        if let handler { RemoveEventHandler(handler); self.handler = nil }
    }
}
