import AppKit
import QuartzCore
import ScreenCore

// Native controls only: no real display changes or preference writes.
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let window = NSWindow(
  contentRect: NSRect(x: 0, y: 0, width: 320, height: 270), styleMask: [.titled],
  backing: .buffered, defer: false)
let button = MascotButton()
button.frame = NSRect(x: 24, y: 22, width: 272, height: 210)
window.contentView!.addSubview(button)
button.update(isBlack: false)
button.shortcut = "⌃⌥B"
button.layout()
func hit(_ p: NSPoint) -> Bool {
  button.hitTest(button.convert(p, to: button.superview)) === button
}
assert(hit(NSPoint(x: 136, y: 115)))
for p in [
  NSPoint(x: 1, y: 100), NSPoint(x: 136, y: 205), NSPoint(x: 136, y: 40), NSPoint(x: 38, y: 18),
] { assert(!hit(p), "blank hit \(p)") }
let titleY: CGFloat = 24
assert((0..<272).contains { hit(NSPoint(x: $0, y: Int(titleY))) })
assert(!hit(NSPoint(x: 270, y: 24)))
final class Receiver: NSObject {
  var count = 0
  @objc func clicked() { count += 1 }
}
let receiver = Receiver()
button.target = receiver
button.action = #selector(Receiver.clicked)
func mouse(_ type: NSEvent.EventType, _ p: NSPoint) -> NSEvent {
  NSEvent.mouseEvent(
    with: type, location: button.convert(p, to: nil), modifierFlags: [], timestamp: 0,
    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
}
let center = NSPoint(x: 136, y: 115)
let blank = NSPoint(x: 136, y: 40)
app.postEvent(mouse(.leftMouseUp, blank), atStart: true)
button.mouseDown(with: mouse(.leftMouseDown, center))
assert(receiver.count == 0)
app.postEvent(mouse(.leftMouseUp, center), atStart: true)
button.mouseDown(with: mouse(.leftMouseDown, center))
assert(receiver.count == 1)
button.mouseDown(with: mouse(.leftMouseDown, blank))
assert(receiver.count == 1)
button.mouseMoved(with: mouse(.mouseMoved, blank))
let hover = Mirror(reflecting: button).children.first { $0.label == "hovering" }!.value as! Bool
assert(!hover)
button.setSettingsProgress(1)
assert(hit(NSPoint(x: 136, y: 180)))
assert(!hit(NSPoint(x: 136, y: 150)))
assert(!hit(NSPoint(x: 136, y: 24)))
assert(!hit(NSPoint(x: 1, y: 180)))
button.isEnabled = false
assert(!hit(NSPoint(x: 136, y: 180)))
print(
  "PASS home silhouette and text hit, transparent edges and gap miss, drag to blank cancels, real hit invokes action, blank hover inactive, small mascot silhouette, disabled control"
)

button.isEnabled = true
button.setSettingsProgress(0)
button.setEyeClosure(0)
let portrait = button.layer!.sublayers!.first {
  $0.sublayers?.contains { $0 is CAShapeLayer } == true
}!
let eyes = portrait.sublayers!.compactMap { $0 as? CAShapeLayer }
assert(eyes.count == 2)
if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
  button.mouseMoved(with: mouse(.mouseMoved, center))
  assert(CATransform3DIsIdentity(eyes[0].transform))
  assert(CATransform3DIsIdentity(portrait.transform))
  print("PASS reduced motion suppresses gaze and petting")
} else {
  button.mouseMoved(with: mouse(.mouseMoved, NSPoint(x: 230, y: 180)))
  assert(eyes[0].transform.m41 > 0 && eyes[1].transform.m41 > 0)
  assert(eyes[0].transform.m22 == 1)
  button.mouseMoved(with: mouse(.mouseMoved, NSPoint(x: 70, y: 180)))
  assert(eyes[0].transform.m41 < 0)
  button.mouseMoved(with: mouse(.mouseMoved, center))
  assert(eyes[0].transform.m22 < 1)
  assert(portrait.transform.m11 > portrait.transform.m22)
  let hoverTransform = portrait.transform
  button.layout()
  assert(
    portrait.transform.m11 == hoverTransform.m11 && portrait.transform.m22 == hoverTransform.m22)
  button.setEyeClosure(0.5)
  assert(CATransform3DIsIdentity(eyes[0].transform))
  button.mouseMoved(with: mouse(.mouseMoved, center))
  assert(CATransform3DIsIdentity(eyes[0].transform))
  button.setEyeClosure(0)
  button.mouseMoved(with: mouse(.mouseMoved, center))
  button.mouseExited(with: mouse(.mouseMoved, blank))
  assert(CATransform3DIsIdentity(eyes[0].transform))
  assert(portrait.transform.m11 == portrait.transform.m22)
  button.setSettingsProgress(1)
  button.mouseMoved(with: mouse(.mouseMoved, NSPoint(x: 136, y: 180)))
  assert(eyes[0].transform.m22 == 0.9)
  print(
    "PASS bounded gaze direction, nearby vs petting, stable layout, blackout priority, pointer exit reset, gentler compact reaction"
  )

  button.setSettingsProgress(0)
  button.updateTrackingAreas()
  assert(
    window.contentView!.trackingAreas.contains {
      ($0.owner as? MascotButton) === button && $0.options.contains(.inVisibleRect)
    })
  let above = NSPoint(x: 136, y: 235)
  assert(!hit(above))
  button.mouseMoved(with: mouse(.mouseMoved, above))
  assert(eyes[0].transform.m42 > 0)
  assert(portrait.transform.m42 > 0)
  assert(abs(portrait.transform.m12) < 0.0001)
  button.mouseMoved(with: mouse(.mouseMoved, NSPoint(x: 270, y: 150)))
  assert(portrait.transform.m41 > 0 && portrait.transform.m12 < 0)
  assert(abs(atan2(portrait.transform.m12, portrait.transform.m11)) <= Double.pi / 90 + 0.0001)
  assert(abs(portrait.transform.m41) <= 1.5)
  let bodyAnimation = portrait.animation(forKey: "feedback")!
  let eyeAnimation = eyes[0].animation(forKey: "attention")!
  assert(bodyAnimation.duration > eyeAnimation.duration)
  button.mouseMoved(with: mouse(.mouseMoved, NSPoint(x: 0, y: 150)))
  assert(portrait.transform.m41 < 0 && portrait.transform.m12 > 0)
  button.mouseMoved(with: mouse(.mouseMoved, center))
  assert(portrait.transform.m41 == 0 && portrait.transform.m12 == 0)
  button.setEyeClosure(0.5)
  assert(CATransform3DIsIdentity(eyes[0].transform))
  assert(portrait.transform.m41 == 0 && portrait.transform.m12 == 0)
  button.setEyeClosure(0)
  button.mouseExited(with: mouse(.mouseMoved, blank))
  assert(CATransform3DIsIdentity(portrait.transform))
  print(
    "PASS full content tracking registration; upper blank gaze without click; bounded left/right lean; slower body follow; petting and closure override; exit reset"
  )

}

func descendants(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(descendants) }
let settings = ShortcutSettings(current: .defaultToggle, schedule: BlackoutSchedule())
let settingsWindow = NSWindow(
  contentRect: NSRect(x: 0, y: 0, width: 320, height: 400), styleMask: [.titled],
  backing: .buffered, defer: false)
settingsWindow.contentView = settings.view
let recorder = descendants(settings.view).compactMap { $0 as? KeycapButton }.first!
var applied = 0
settings.apply = { _ in
  applied += 1
  return nil
}
func start() {
  recorder.performClick(nil)
  assert(settings.isRecording)
  assert(recorder.isRecording)
}
func send(
  _ type: NSEvent.EventType, _ flags: NSEvent.ModifierFlags, _ code: UInt16 = 59,
  _ chars: String = "", repeatKey: Bool = false
) {
  let e = NSEvent.keyEvent(
    with: type, location: .zero, modifierFlags: flags, timestamp: 0,
    windowNumber: settingsWindow.windowNumber, context: nil, characters: chars,
    charactersIgnoringModifiers: chars, isARepeat: repeatKey, keyCode: code)!
  assert(settings.handleRecordingEvent(e))
}
start()
let recorderSize = recorder.frame.size
send(.flagsChanged, .control)
assert(recorder.keys == ["⌃"])
send(.flagsChanged, [.control, .option])
assert(recorder.keys == ["⌃", "⌥"])
send(.flagsChanged, .control)
assert(recorder.keys == ["⌃"])
send(.flagsChanged, [])
assert(recorder.keys.isEmpty)
assert(applied == 0 && recorder.frame.size == recorderSize)
send(.keyDown, [.control, .option], 11, "b")
assert(
  !settings.isRecording && !recorder.isRecording && recorder.keys == ["⌃", "⌥", "B"] && applied == 1
)
print("PASS modifiers appear/release, stable size, valid combination saves")
start()
send(.keyDown, [], 0, "a")
assert(settings.isRecording && recorder.keys == ["A"] && applied == 1)
send(.keyUp, [], 0, "a")
assert(recorder.keys.isEmpty)
settings.apply = { _ in "Conflict" }
send(.keyDown, .command, 0, "a")
assert(settings.isRecording && recorder.keys == ["⌘", "A"] && settings.current == .defaultToggle)
send(.keyDown, .command, 0, "a", repeatKey: true)
assert(recorder.keys == ["⌘", "A"])
send(.keyDown, [], 53)
assert(
  !settings.isRecording && settings.current == .defaultToggle && recorder.keys == ["⌃", "⌥", "B"])
print("PASS invalid input, conflict, repeat, Escape preserve prior binding")
start()
send(.flagsChanged, [.control, .option])
settings.deactivate()
assert(!settings.isRecording && !recorder.isRecording && recorder.keys == ["⌃", "⌥", "B"])
start()
assert(recorder.keys.isEmpty)
send(.flagsChanged, [.control, .option, .shift, .command])
assert(recorder.keys == ["⌃", "⌥", "⇧", "⌘"])

settings.deactivate()

// Schedule animation must not block ordinary edits or lose failed changes.
func settle(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
let schedulePanel = ScreenPanel()
let scheduleSettings = ShortcutSettings(current: .defaultToggle, schedule: BlackoutSchedule())
var savedSchedule = BlackoutSchedule()
scheduleSettings.applySchedule = {
  savedSchedule = $0
  return nil
}
schedulePanel.showSettings(scheduleSettings)
settle(0.35)
let scheduleWindow = schedulePanel.window!
let compactHeight = scheduleWindow.contentView!.bounds.height
let scheduleControls = descendants(scheduleSettings.view)
let scheduleSwitch = scheduleControls.compactMap { $0 as? NSSwitch }.first {
  $0.accessibilityLabel() == L10n.text("Enable scheduled blackout")
}!
let pickers = scheduleControls.compactMap { $0 as? WheelTimePicker }
let days = scheduleControls.compactMap { $0 as? DayButton }
let timeRow = pickers[0].superview!.superview!.superview!
let mascot = descendants(scheduleWindow.contentView!).compactMap { $0 as? MascotButton }.first!
func enableSchedule(_ enabled: Bool) {
  scheduleSwitch.state = enabled ? .on : .off
  app.sendAction(scheduleSwitch.action!, to: scheduleSwitch.target, from: scheduleSwitch)
}
enableSchedule(true)
if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
  settle(0.1)
  assert(timeRow.alphaValue > 0 && timeRow.alphaValue < 1)
}
settle(0.35)
assert(savedSchedule.enabled && timeRow.alphaValue == 1 && !timeRow.isHidden)
assert(scheduleWindow.contentView!.bounds.height > compactHeight)
let expandedHeight = scheduleWindow.contentView!.bounds.height
days[0].performClick(nil)
assert(mascot.isEnabled && !savedSchedule.weekdays.contains(days[0].tag))
assert(scheduleWindow.contentView!.bounds.height == expandedHeight)
settle(0.18)
for day in days.dropFirst().dropLast() { day.performClick(nil) }
days.last!.performClick(nil)
assert(savedSchedule.weekdays.count == 1 && days.last!.state == .on)
settle(0.35)
scheduleSettings.applySchedule = { _ in "Save failed" }
enableSchedule(false)
assert(scheduleSwitch.state == .on && !timeRow.isHidden)
scheduleSettings.applySchedule = {
  savedSchedule = $0
  return nil
}
enableSchedule(false)
if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
  settle(0.04)
  assert(!timeRow.isHidden && timeRow.alphaValue < 1)
}
enableSchedule(true)
settle(0.35)
assert(timeRow.alphaValue == 1 && !timeRow.isHidden && savedSchedule.enabled)
enableSchedule(false)
settle(0.5)
assert(timeRow.isHidden && !savedSchedule.enabled)
assert(abs(scheduleWindow.contentView!.bounds.height - compactHeight) < 0.5)
print(
  "PASS schedule reveal/reversal, weekday edits without window animation, last-day validation, failed-save rollback, final collapse height"
)

// Time wheels: bounds, digit entry, debounced scroll and 12/24-hour mapping.
func wheelKey(_ code: UInt16, _ characters: String = "") -> NSEvent {
  NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
    windowNumber: window.windowNumber, context: nil, characters: characters,
    charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
}
let minuteWheel = TimeWheel(values: (0...59).map { String(format: "%02d", $0) })
var commits = 0
minuteWheel.changed = { commits += 1 }
minuteWheel.select(59)
minuteWheel.keyDown(with: wheelKey(125))
assert(minuteWheel.selected == 59 && commits == 0)
minuteWheel.keyDown(with: wheelKey(115))
assert(minuteWheel.selected == 0 && commits == 1)
minuteWheel.keyDown(with: wheelKey(18, "1"))
minuteWheel.keyDown(with: wheelKey(19, "2"))
assert(minuteWheel.selected == 12)
let scroll = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
  wheel1: -30, wheel2: 0, wheel3: 0)!
let beforeScroll = commits
minuteWheel.scrollWheel(with: NSEvent(cgEvent: scroll)!)
assert(commits == beforeScroll)
settle(0.22)
assert(commits == beforeScroll + 1 && minuteWheel.selected > 12)
minuteWheel.scrollWheel(with: NSEvent(cgEvent: scroll)!)
minuteWheel.select(8) // An external rollback cancels pending gesture callbacks.
settle(0.22)
assert(minuteWheel.selected == 8 && commits == beforeScroll + 1)

for locale in ["en_US", "en_GB"] {
  let picker = WheelTimePicker(locale: Locale(identifier: locale))
  picker.frame = NSRect(x: 20, y: 20, width: 100, height: 30)
  window.contentView!.addSubview(picker)
  picker.dateValue = Calendar.current.date(bySettingHour: 0, minute: 15, second: 0, of: Date())!
  _ = picker.sendAction(nil, to: nil)
  let wheels = Mirror(reflecting: picker).children.first { $0.label == "wheels" }!.value as! [TimeWheel]
  assert(wheels.count == (locale == "en_US" ? 3 : 2))
  assert(wheels[0].selected == 0 && wheels[1].selected == 15)
  if wheels.count == 3 {
    wheels[2].keyDown(with: wheelKey(125))
    assert(Calendar.current.component(.hour, from: picker.dateValue) == 12)
  }
  picker.dateValue = Calendar.current.date(bySettingHour: 23, minute: 59, second: 0, of: Date())!
  assert(wheels[0].selected == (wheels.count == 3 ? 11 : 23))
  assert(wheels[1].selected == 59)
  _ = picker.sendAction(nil, to: nil)
  picker.removeFromSuperview()
}
enableSchedule(true)
settle(0.35)
let originalTime = pickers[0].dateValue
pickers[0].dateValue = pickers[1].dateValue
app.sendAction(pickers[0].action!, to: pickers[0].target, from: pickers[0])
assert(pickers[0].dateValue == originalTime)
print("PASS wheel boundaries, digit entry, settled scroll, pending rollback, 12/24-hour mapping, equal-time rejection")

// Motion must not save intermediate frames or overwrite a later rollback.
let animatedWheel = TimeWheel(values: (0...59).map { String(format: "%02d", $0) })
animatedWheel.frame = NSRect(x: 0, y: 0, width: 64, height: 150)
window.contentView!.addSubview(animatedWheel)
var motionCommits = 0
animatedWheel.changed = { motionCommits += 1 }
func wheelPosition() -> CGFloat {
  Mirror(reflecting: animatedWheel).children.first { $0.label == "position" }!.value as! CGFloat
}
func clickWheel(_ y: CGFloat) {
  let event = NSEvent.mouseEvent(with: .leftMouseDown,
    location: animatedWheel.convert(NSPoint(x: 32, y: y), to: nil), modifierFlags: [],
    timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
    clickCount: 1, pressure: 1)!
  animatedWheel.mouseDown(with: event)
}
let reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
animatedWheel.select(10)
clickWheel(105)
if !reducedMotion {
  settle(0.04)
  assert(wheelPosition() > 10 && wheelPosition() < 11 && motionCommits == 0)
}
settle(0.15)
assert(animatedWheel.selected == 11 && wheelPosition() == 11 && motionCommits == 1)
clickWheel(105)
animatedWheel.select(7)
let rollbackCommits = motionCommits
settle(0.16)
assert(animatedWheel.selected == 7 && wheelPosition() == 7 && motionCommits == rollbackCommits)
clickWheel(105)
animatedWheel.finishScrolling()
assert(animatedWheel.selected == 8)
let closedCommits = motionCommits
settle(0.16)
assert(motionCommits == closedCommits)
let fractionalScroll = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
  wheel1: -20, wheel2: 0, wheel3: 0)!
animatedWheel.scrollWheel(with: NSEvent(cgEvent: fractionalScroll)!)
if !reducedMotion {
  settle(0.19)
  assert(wheelPosition() > 8 && wheelPosition() < 9 && motionCommits == closedCommits)
  // A fresh gesture interrupts the snap from its visible position.
  let positionBeforeInterrupt = wheelPosition()
  animatedWheel.scrollWheel(with: NSEvent(cgEvent: fractionalScroll)!)
  assert(wheelPosition() > positionBeforeInterrupt && motionCommits == closedCommits)
}
settle(0.35)
assert(wheelPosition() == CGFloat(animatedWheel.selected) && motionCommits == closedCommits + 1)
print("PASS wheel motion intermediate frames, single commit, interrupted snap, rollback and close during animation")
