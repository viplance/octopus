#import <AppKit/AppKit.h>
#include <napi.h>
#include <IOKit/hid/IOHIDManager.h>
#include <CoreFoundation/CoreFoundation.h>
#include <Foundation/Foundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <ApplicationServices/ApplicationServices.h>
#include <IOKit/hidsystem/ev_keymap.h>
#include <IOKit/hidsystem/IOLLEvent.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/hid/IOHIDLib.h>
#include <IOKit/hid/IOHIDUsageTables.h>
#include <atomic>
#include <iostream>
#include <thread>

// ==========================================
// HID ENUMERATION
// ==========================================

Napi::Value GetDevices(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    Napi::Array result = Napi::Array::New(env);
    uint32_t index = 0;

    CFMutableDictionaryRef matchingDict = IOServiceMatching(kIOHIDDeviceKey);
    if (!matchingDict) return result;

    io_iterator_t iter;
    if (IOServiceGetMatchingServices(kIOMasterPortDefault, matchingDict, &iter) != kIOReturnSuccess) {
        return result;
    }

    io_service_t device;
    while ((device = IOIteratorNext(iter))) {
        CFStringRef nameRef = (CFStringRef)IORegistryEntryCreateCFProperty(device, CFSTR(kIOHIDProductKey), kCFAllocatorDefault, 0);
        char buffer[256];
        std::string name = "Unknown Device";
        if (nameRef && CFStringGetCString(nameRef, buffer, sizeof(buffer), kCFStringEncodingUTF8)) {
            name = buffer;
        }
        if (nameRef) CFRelease(nameRef);

        CFNumberRef usagePageRef = (CFNumberRef)IORegistryEntryCreateCFProperty(device, CFSTR(kIOHIDPrimaryUsagePageKey), kCFAllocatorDefault, 0);
        int usagePage = 0;
        if (usagePageRef) {
            CFNumberGetValue(usagePageRef, kCFNumberIntType, &usagePage);
            CFRelease(usagePageRef);
        }

        CFNumberRef usageRef = (CFNumberRef)IORegistryEntryCreateCFProperty(device, CFSTR(kIOHIDPrimaryUsageKey), kCFAllocatorDefault, 0);
        int usage = 0;
        if (usageRef) {
            CFNumberGetValue(usageRef, kCFNumberIntType, &usage);
            CFRelease(usageRef);
        }

        std::string type = "other";
        if (usagePage == kHIDPage_GenericDesktop) {
            if (usage == kHIDUsage_GD_Keyboard) type = "keyboard";
            else if (usage == kHIDUsage_GD_Mouse) type = "mouse";
            else if (usage == kHIDUsage_GD_Pointer) type = "touchpad";
        }

        // Filter to only include keyboard, mouse, touchpad
        if (type != "other") {
            Napi::Object devObj = Napi::Object::New(env);
            devObj.Set("name", name);
            devObj.Set("type", type);
            devObj.Set("usagePage", usagePage);
            devObj.Set("usage", usage);
            result[index++] = devObj;
        }

        IOObjectRelease(device);
    }
    IOObjectRelease(iter);

    return result;
}


// ==========================================
// EVENT TAPPING (INTERCEPT & INJECT)
// ==========================================

Napi::ThreadSafeFunction tsfn;
std::atomic<bool> is_intercepting{false};
int current_shortcut = 1; // 1 = Cmd+Option+E, 2 = Eject
CFMachPortRef eventTap = NULL;
CFRunLoopSourceRef runLoopSource = NULL;
CGPoint saved_cursor_position;

struct EventData {
    int type;
    int64_t keycode;
    int64_t flags;
    double mouseX;
    double mouseY;
    double dx;
    double dy;
    int64_t mouseButton;
    int64_t scrollWheel;
    bool isDown;
    std::string rawData;
};

static CGRect cached_display_bounds = CGRectNull;
static double display_bounds_cache_time = 0;

static CGRect getScreenBounds() {
    double now = CFAbsoluteTimeGetCurrent();
    if (now - display_bounds_cache_time < 5.0 && !CGRectIsNull(cached_display_bounds)) {
        return cached_display_bounds;
    }
    uint32_t displayCount = 0;
    CGGetActiveDisplayList(0, NULL, &displayCount);
    if (displayCount == 0) return CGRectNull;
    CGDirectDisplayID* displays = new CGDirectDisplayID[displayCount];
    CGGetActiveDisplayList(displayCount, displays, &displayCount);
    CGRect total = CGRectNull;
    for (uint32_t i = 0; i < displayCount; i++) {
        CGRect bounds = CGDisplayBounds(displays[i]);
        total = CGRectIsNull(total) ? bounds : CGRectUnion(total, bounds);
    }
    delete[] displays;
    cached_display_bounds = total;
    display_bounds_cache_time = now;
    return total;
}

static CGPoint clampToScreen(CGPoint pt) {
    CGRect bounds = getScreenBounds();
    if (CGRectIsNull(bounds)) return pt;
    if (pt.x < CGRectGetMinX(bounds)) pt.x = CGRectGetMinX(bounds);
    if (pt.x >= CGRectGetMaxX(bounds)) pt.x = CGRectGetMaxX(bounds) - 1;
    if (pt.y < CGRectGetMinY(bounds)) pt.y = CGRectGetMinY(bounds);
    if (pt.y >= CGRectGetMaxY(bounds)) pt.y = CGRectGetMaxY(bounds) - 1;
    return pt;
}

CGEventRef CGEventCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void* refcon) {
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        CGEventTapEnable(eventTap, true);
        return event;
    }

    if (current_shortcut == 2 && type == NX_SYSDEFINED) {
        NSEvent *nsEvent = [NSEvent eventWithCGEvent:event];
        if (nsEvent.type == NSEventTypeSystemDefined && nsEvent.subtype == NX_SUBTYPE_AUX_CONTROL_BUTTONS) {
            int keyCode = (nsEvent.data1 & 0xFFFF0000) >> 16;
            int keyFlags = (nsEvent.data1 & 0x0000FFFF);
            bool isKeyDown = (((keyFlags & 0xFF00) >> 8) == 0xA);
            
            if (keyCode == NX_KEYTYPE_EJECT && isKeyDown) {
                is_intercepting = !is_intercepting;
                
                if (is_intercepting) {
                    CGEventRef locEvent = CGEventCreate(NULL);
                    saved_cursor_position = CGEventGetLocation(locEvent);
                    CFRelease(locEvent);
                } else {
                    CGWarpMouseCursorPosition(saved_cursor_position);
                }

                EventData* ed = new EventData{ -1, is_intercepting ? 1 : 0, 0, 0, 0, 0, 0, 0, 0, false, "" };
                tsfn.NonBlockingCall(ed, [](Napi::Env env, Napi::Function jsCallback, EventData* value) {
                    jsCallback.Call({ Napi::String::New(env, "toggle"), Napi::Boolean::New(env, value->keycode != 0) });
                    delete value;
                });
                return NULL;
            }
        }
    } else if (current_shortcut == 1 && type == kCGEventKeyDown) {
        CGEventFlags flags = CGEventGetFlags(event);
        int64_t keycode = CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
        if ((flags & kCGEventFlagMaskCommand) && (flags & kCGEventFlagMaskAlternate) && keycode == 14) {
            is_intercepting = !is_intercepting;
            
            if (is_intercepting) {
                CGEventRef locEvent = CGEventCreate(NULL);
                saved_cursor_position = CGEventGetLocation(locEvent);
                CFRelease(locEvent);
            } else {
                CGWarpMouseCursorPosition(saved_cursor_position);
            }

            EventData* ed = new EventData{ -1, is_intercepting ? 1 : 0, 0, 0, 0, 0, 0, 0, 0, false, "" };
            tsfn.NonBlockingCall(ed, [](Napi::Env env, Napi::Function jsCallback, EventData* value) {
                jsCallback.Call({ Napi::String::New(env, "toggle"), Napi::Boolean::New(env, value->keycode != 0) });
                delete value;
            });
            return NULL;
        }
    }

    if (!is_intercepting) {
        return event;
    }

    EventData* ed = new EventData{ (int)type, 0, 0, 0, 0, 0, 0, 0, 0, false, "" };

    if (type == kCGEventKeyDown || type == kCGEventKeyUp) {
        ed->keycode = CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
        ed->flags = CGEventGetFlags(event);
    } else if (type == kCGEventMouseMoved || type == kCGEventLeftMouseDragged || type == kCGEventRightMouseDragged) {
        CGWarpMouseCursorPosition(saved_cursor_position);
        ed->dx = CGEventGetDoubleValueField(event, kCGMouseEventDeltaX);
        ed->dy = CGEventGetDoubleValueField(event, kCGMouseEventDeltaY);
        ed->type = -3; // compact mouse move
    } else if (type == kCGEventLeftMouseDown || type == kCGEventLeftMouseUp ||
               type == kCGEventRightMouseDown || type == kCGEventRightMouseUp) {
        CGWarpMouseCursorPosition(saved_cursor_position);
        ed->dx = CGEventGetDoubleValueField(event, kCGMouseEventDeltaX);
        ed->dy = CGEventGetDoubleValueField(event, kCGMouseEventDeltaY);
        ed->mouseButton = (type == kCGEventRightMouseDown || type == kCGEventRightMouseUp) ? 1 : 0;
        ed->isDown = (type == kCGEventLeftMouseDown || type == kCGEventRightMouseDown);
        ed->type = -4; // compact mouse click
    } else {
        CFDataRef data = CGEventCreateData(kCFAllocatorDefault, event);
        if (data) {
            ed->rawData = std::string((const char*)CFDataGetBytePtr(data), CFDataGetLength(data));
            CFRelease(data);
        }
        ed->type = -2; // raw events (scroll, gestures, NX_SYSDEFINED)
    }

    tsfn.NonBlockingCall(ed, [](Napi::Env env, Napi::Function jsCallback, EventData* value) {
        Napi::Object obj = Napi::Object::New(env);
        obj.Set("type", value->type);
        if (value->type == -3) {
            obj.Set("dx", value->dx);
            obj.Set("dy", value->dy);
        } else if (value->type == -4) {
            obj.Set("dx", value->dx);
            obj.Set("dy", value->dy);
            obj.Set("mouseButton", value->mouseButton);
            obj.Set("isDown", value->isDown);
        } else if (value->type == -2) {
            if (!value->rawData.empty()) {
                obj.Set("rawData", Napi::Buffer<char>::Copy(env, value->rawData.data(), value->rawData.length()));
            }
        } else {
            obj.Set("keycode", value->keycode);
            obj.Set("flags", value->flags);
        }
        jsCallback.Call({ Napi::String::New(env, "event"), obj });
        delete value;
    });

    return NULL;
}

bool global_share_keyboard = true;
bool global_share_mouse = true;

void RunLoopThread() {
    CGEventMask eventMask = CGEventMaskBit(NX_SYSDEFINED);
    
    if (global_share_keyboard) {
        eventMask |= CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventKeyUp) | CGEventMaskBit(kCGEventFlagsChanged);
    }
    
    if (global_share_mouse) {
        eventMask |= CGEventMaskBit(kCGEventMouseMoved) | CGEventMaskBit(kCGEventLeftMouseDragged) |
                     CGEventMaskBit(kCGEventRightMouseDragged) | CGEventMaskBit(kCGEventLeftMouseDown) |
                     CGEventMaskBit(kCGEventLeftMouseUp) | CGEventMaskBit(kCGEventRightMouseDown) |
                     CGEventMaskBit(kCGEventRightMouseUp) | CGEventMaskBit(kCGEventScrollWheel) |
                     CGEventMaskBit(29) | CGEventMaskBit(30) | CGEventMaskBit(31) | 
                     CGEventMaskBit(18) | CGEventMaskBit(19) | CGEventMaskBit(20) | CGEventMaskBit(32);
    }

    eventTap = CGEventTapCreate(kCGHIDEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault, eventMask, CGEventCallback, NULL);
    
    if (!eventTap) {
        std::cerr << "Failed to create event tap. Requires Accessibility permissions in System Settings -> Privacy & Security." << std::endl;
        return;
    }

    runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0);
    CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, kCFRunLoopCommonModes);
    CGEventTapEnable(eventTap, true);
    CFRunLoopRun();
}

Napi::Value StartTap(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    if (info.Length() < 1 || !info[0].IsFunction()) {
        Napi::TypeError::New(env, "Function expected").ThrowAsJavaScriptException();
        return env.Null();
    }
    
    if (info.Length() >= 3) {
        global_share_keyboard = info[1].As<Napi::Boolean>().Value();
        global_share_mouse = info[2].As<Napi::Boolean>().Value();
    }

    tsfn = Napi::ThreadSafeFunction::New(
        env,
        info[0].As<Napi::Function>(),
        "EventTapCallback",
        0,
        1
    );

    std::thread(RunLoopThread).detach();

    return env.Null();
}

Napi::Value SetIntercepting(const Napi::CallbackInfo& info) {
    if (info.Length() > 0 && info[0].IsBoolean()) {
        bool new_val = info[0].As<Napi::Boolean>().Value();
        if (is_intercepting != new_val) {
            is_intercepting = new_val;
            if (is_intercepting) {
                CGEventRef locEvent = CGEventCreate(NULL);
                saved_cursor_position = CGEventGetLocation(locEvent);
                CFRelease(locEvent);
            } else {
                CGWarpMouseCursorPosition(saved_cursor_position);
            }
        }
    }
    return info.Env().Null();
}

Napi::Value SetShortcut(const Napi::CallbackInfo& info) {
    if (info.Length() > 0 && info[0].IsNumber()) {
        current_shortcut = info[0].As<Napi::Number>().Int32Value();
    }
    return info.Env().Null();
}

Napi::Value InjectEvent(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    if (info.Length() < 1 || !info[0].IsObject()) return env.Null();

    Napi::Object obj = info[0].As<Napi::Object>();
    int type = obj.Get("type").As<Napi::Number>().Int32Value();

    CGEventRef event = NULL;

    if (type == -3) {
        double dx = obj.Has("dx") ? obj.Get("dx").As<Napi::Number>().DoubleValue() : 0;
        double dy = obj.Has("dy") ? obj.Get("dy").As<Napi::Number>().DoubleValue() : 0;
        CGEventRef locEv = CGEventCreate(NULL);
        CGPoint loc = CGEventGetLocation(locEv);
        CFRelease(locEv);
        loc.x += dx;
        loc.y += dy;
        loc = clampToScreen(loc);
        event = CGEventCreateMouseEvent(NULL, kCGEventMouseMoved, loc, kCGMouseButtonLeft);
        if (event) {
            CGEventSetDoubleValueField(event, kCGMouseEventDeltaX, dx);
            CGEventSetDoubleValueField(event, kCGMouseEventDeltaY, dy);
        }
    } else if (type == -4) {
        double dx = obj.Has("dx") ? obj.Get("dx").As<Napi::Number>().DoubleValue() : 0;
        double dy = obj.Has("dy") ? obj.Get("dy").As<Napi::Number>().DoubleValue() : 0;
        int64_t button = obj.Has("mouseButton") ? obj.Get("mouseButton").As<Napi::Number>().Int64Value() : 0;
        bool isDown = obj.Has("isDown") ? obj.Get("isDown").As<Napi::Boolean>().Value() : true;
        CGEventRef locEv = CGEventCreate(NULL);
        CGPoint loc = CGEventGetLocation(locEv);
        CFRelease(locEv);
        loc.x += dx;
        loc.y += dy;
        loc = clampToScreen(loc);
        CGEventType clickType;
        CGMouseButton btn;
        if (button == 1) {
            clickType = isDown ? kCGEventRightMouseDown : kCGEventRightMouseUp;
            btn = kCGMouseButtonRight;
        } else {
            clickType = isDown ? kCGEventLeftMouseDown : kCGEventLeftMouseUp;
            btn = kCGMouseButtonLeft;
        }
        event = CGEventCreateMouseEvent(NULL, clickType, loc, btn);
    } else if (type == -2) {
        if (obj.Has("rawData") && obj.Get("rawData").IsBuffer()) {
            Napi::Buffer<uint8_t> buffer = obj.Get("rawData").As<Napi::Buffer<uint8_t>>();
            CFDataRef data = CFDataCreate(kCFAllocatorDefault, buffer.Data(), buffer.Length());
            if (data) {
                event = CGEventCreateFromData(kCFAllocatorDefault, data);
                if (event) {
                    CGEventType rawType = CGEventGetType(event);
                    CGEventRef currentLocEvent = CGEventCreate(NULL);
                    CGPoint currentLoc = CGEventGetLocation(currentLocEvent);
                    CFRelease(currentLocEvent);

                    if (rawType == kCGEventMouseMoved || rawType == kCGEventLeftMouseDragged || rawType == kCGEventRightMouseDragged ||
                        rawType == kCGEventLeftMouseDown || rawType == kCGEventLeftMouseUp || rawType == kCGEventRightMouseDown || rawType == kCGEventRightMouseUp) {
                        double dx = 0, dy = 0;
                        if (rawType == kCGEventMouseMoved || rawType == kCGEventLeftMouseDragged || rawType == kCGEventRightMouseDragged) {
                            dx = CGEventGetDoubleValueField(event, kCGMouseEventDeltaX);
                            dy = CGEventGetDoubleValueField(event, kCGMouseEventDeltaY);
                        }
                        currentLoc.x += dx;
                        currentLoc.y += dy;
                        currentLoc = clampToScreen(currentLoc);
                    }
                    CGEventSetLocation(event, currentLoc);
                }
                CFRelease(data);
            }
        }
    } else if (type == kCGEventKeyDown || type == kCGEventKeyUp) {
        int64_t keycode = obj.Get("keycode").As<Napi::Number>().Int64Value();
        int64_t flags = obj.Get("flags").As<Napi::Number>().Int64Value();
        event = CGEventCreateKeyboardEvent(NULL, (CGKeyCode)keycode, type == kCGEventKeyDown);
        if (event) CGEventSetFlags(event, (CGEventFlags)flags);
    }

    if (event) {
        CGEventPost(kCGHIDEventTap, event);
        CFRelease(event);
    }

    return env.Null();
}

Napi::Object Init(Napi::Env env, Napi::Object exports) {
    exports.Set("getDevices", Napi::Function::New(env, GetDevices));
    exports.Set("startTap", Napi::Function::New(env, StartTap));
    exports.Set("setIntercepting", Napi::Function::New(env, SetIntercepting));
    exports.Set("setShortcut", Napi::Function::New(env, SetShortcut));
    exports.Set("injectEvent", Napi::Function::New(env, InjectEvent));
    return exports;
}

NODE_API_MODULE(octopussync_mac, Init)
