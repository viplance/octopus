#import <AppKit/AppKit.h>
#include <napi.h>
#include <IOKit/hid/IOHIDManager.h>
#include <CoreFoundation/CoreFoundation.h>
#include <Foundation/Foundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <ApplicationServices/ApplicationServices.h>
#include <IOKit/hidsystem/ev_keymap.h>
#include <IOKit/hidsystem/IOLLEvent.h>
#include <iostream>
#include <thread>

// ==========================================
// HID ENUMERATION
// ==========================================

Napi::Value GetDevices(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();

    IOHIDManagerRef hidManager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    if (!hidManager) {
        Napi::Error::New(env, "Failed to create IOHIDManager").ThrowAsJavaScriptException();
        return env.Null();
    }

    NSMutableArray *criteria = [NSMutableArray array];
    
    NSDictionary *keyboardDict = @{ @kIOHIDDeviceUsagePageKey: @(kHIDPage_GenericDesktop), @kIOHIDDeviceUsageKey: @(kHIDUsage_GD_Keyboard) };
    [criteria addObject:keyboardDict];

    NSDictionary *mouseDict = @{ @kIOHIDDeviceUsagePageKey: @(kHIDPage_GenericDesktop), @kIOHIDDeviceUsageKey: @(kHIDUsage_GD_Mouse) };
    [criteria addObject:mouseDict];

    NSDictionary *pointerDict = @{ @kIOHIDDeviceUsagePageKey: @(kHIDPage_GenericDesktop), @kIOHIDDeviceUsageKey: @(kHIDUsage_GD_Pointer) };
    [criteria addObject:pointerDict];

    IOHIDManagerSetDeviceMatchingMultiple(hidManager, (__bridge CFArrayRef)criteria);

    NSSet *hidDevicesSet = CFBridgingRelease(IOHIDManagerCopyDevices(hidManager));
    
    Napi::Array result = Napi::Array::New(env);
    
    if (hidDevicesSet) {
        uint32_t index = 0;
        for (id deviceObj in hidDevicesSet) {
            IOHIDDeviceRef device = (__bridge IOHIDDeviceRef)deviceObj;
            NSString *nameStr = (__bridge NSString *)IOHIDDeviceGetProperty(device, CFSTR(kIOHIDProductKey));
            std::string name = nameStr ? [nameStr UTF8String] : "Unknown Device";
            NSNumber *usagePageNum = (__bridge NSNumber *)IOHIDDeviceGetProperty(device, CFSTR(kIOHIDPrimaryUsagePageKey));
            int usagePage = usagePageNum ? [usagePageNum intValue] : 0;
            NSNumber *usageNum = (__bridge NSNumber *)IOHIDDeviceGetProperty(device, CFSTR(kIOHIDPrimaryUsageKey));
            int usage = usageNum ? [usageNum intValue] : 0;
            
            std::string type = "other";
            if (usagePage == kHIDPage_GenericDesktop) {
                if (usage == kHIDUsage_GD_Keyboard) type = "keyboard";
                else if (usage == kHIDUsage_GD_Mouse) type = "mouse";
                else if (usage == kHIDUsage_GD_Pointer) type = "touchpad";
            }
            
            Napi::Object devObj = Napi::Object::New(env);
            devObj.Set("name", name);
            devObj.Set("type", type);
            devObj.Set("usagePage", usagePage);
            devObj.Set("usage", usage);
            
            result[index++] = devObj;
        }
    }

    CFRelease(hidManager);
    return result;
}


// ==========================================
// EVENT TAPPING (INTERCEPT & INJECT)
// ==========================================

Napi::ThreadSafeFunction tsfn;
bool is_intercepting = false;
int current_shortcut = 1; // 1 = Cmd+Option+E, 2 = Eject
CFMachPortRef eventTap = NULL;
CFRunLoopSourceRef runLoopSource = NULL;

struct EventData {
    int type;
    int64_t keycode;
    int64_t flags;
    double mouseX;
    double mouseY;
    int64_t mouseButton;
    int64_t scrollWheel;
};

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
                EventData* ed = new EventData{ -1, is_intercepting ? 1 : 0, 0, 0, 0, 0, 0 };
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
            EventData* ed = new EventData{ -1, is_intercepting ? 1 : 0, 0, 0, 0, 0, 0 };
            tsfn.NonBlockingCall(ed, [](Napi::Env env, Napi::Function jsCallback, EventData* value) {
                jsCallback.Call({ Napi::String::New(env, "toggle"), Napi::Boolean::New(env, value->keycode != 0) });
                delete value;
            });
            return NULL;
        }
    }

    if (!is_intercepting || type == NX_SYSDEFINED) {
        return event;
    }

    // Block logic: do not forward event to macOS, instead send to JS via NonBlockingCall to avoid tap timeouts
    EventData* ed = new EventData{ (int)type, 0, 0, 0, 0, 0, 0 };
    
    if (type == kCGEventKeyDown || type == kCGEventKeyUp) {
        ed->keycode = CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
        ed->flags = CGEventGetFlags(event);
    } else if (type == kCGEventMouseMoved || type == kCGEventLeftMouseDragged || type == kCGEventRightMouseDragged) {
        // Send Deltas instead of absolute coordinates!
        ed->mouseX = CGEventGetDoubleValueField(event, kCGMouseEventDeltaX);
        ed->mouseY = CGEventGetDoubleValueField(event, kCGMouseEventDeltaY);
    } else if (type == kCGEventLeftMouseDown || type == kCGEventLeftMouseUp || type == kCGEventRightMouseDown || type == kCGEventRightMouseUp) {
        ed->mouseX = 0;
        ed->mouseY = 0;
        ed->mouseButton = CGEventGetIntegerValueField(event, kCGMouseEventButtonNumber);
    } else if (type == kCGEventScrollWheel) {
        ed->scrollWheel = CGEventGetIntegerValueField(event, kCGScrollWheelEventDeltaAxis1);
    }

    tsfn.NonBlockingCall(ed, [](Napi::Env env, Napi::Function jsCallback, EventData* value) {
        Napi::Object obj = Napi::Object::New(env);
        obj.Set("type", value->type);
        obj.Set("keycode", value->keycode);
        obj.Set("flags", value->flags);
        obj.Set("mouseX", value->mouseX);
        obj.Set("mouseY", value->mouseY);
        obj.Set("mouseButton", value->mouseButton);
        obj.Set("scrollWheel", value->scrollWheel);
        jsCallback.Call({ Napi::String::New(env, "event"), obj });
        delete value;
    });

    return NULL; // Block event from reaching host OS
}

bool global_share_keyboard = true;
bool global_share_mouse = true;

void RunLoopThread() {
    CGEventMask eventMask = CGEventMaskBit(NX_SYSDEFINED);
    
    if (global_share_keyboard) {
        eventMask |= CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventKeyUp);
    }
    
    if (global_share_mouse) {
        eventMask |= CGEventMaskBit(kCGEventMouseMoved) | CGEventMaskBit(kCGEventLeftMouseDragged) |
                     CGEventMaskBit(kCGEventRightMouseDragged) | CGEventMaskBit(kCGEventLeftMouseDown) |
                     CGEventMaskBit(kCGEventLeftMouseUp) | CGEventMaskBit(kCGEventRightMouseDown) |
                     CGEventMaskBit(kCGEventRightMouseUp) | CGEventMaskBit(kCGEventScrollWheel);
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
        is_intercepting = info[0].As<Napi::Boolean>().Value();
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
    
    if (type == kCGEventKeyDown || type == kCGEventKeyUp) {
        int64_t keycode = obj.Get("keycode").As<Napi::Number>().Int64Value();
        int64_t flags = obj.Get("flags").As<Napi::Number>().Int64Value();
        event = CGEventCreateKeyboardEvent(NULL, (CGKeyCode)keycode, type == kCGEventKeyDown);
        if (event) CGEventSetFlags(event, (CGEventFlags)flags);
    } else if (type == kCGEventMouseMoved || type == kCGEventLeftMouseDragged || type == kCGEventRightMouseDragged ||
               type == kCGEventLeftMouseDown || type == kCGEventLeftMouseUp || type == kCGEventRightMouseDown || type == kCGEventRightMouseUp) {
        
        double deltaX = obj.Get("mouseX").As<Napi::Number>().DoubleValue();
        double deltaY = obj.Get("mouseY").As<Napi::Number>().DoubleValue();
        int64_t mouseButton = obj.Get("mouseButton").As<Napi::Number>().Int64Value();
        
        // Compute new position based on CURRENT local mouse position
        CGEventRef currentLocEvent = CGEventCreate(NULL);
        CGPoint currentLoc = CGEventGetLocation(currentLocEvent);
        CFRelease(currentLocEvent);
        
        currentLoc.x += deltaX;
        currentLoc.y += deltaY;
        
        CGMouseButton btn = (CGMouseButton)mouseButton;
        if (type == kCGEventMouseMoved || type == kCGEventLeftMouseDragged) btn = kCGMouseButtonLeft;
        else if (type == kCGEventRightMouseDragged) btn = kCGMouseButtonRight;
        
        event = CGEventCreateMouseEvent(NULL, (CGEventType)type, currentLoc, btn);
        
        if (event) {
            CGEventSetDoubleValueField(event, kCGMouseEventDeltaX, deltaX);
            CGEventSetDoubleValueField(event, kCGMouseEventDeltaY, deltaY);
        }
    } else if (type == kCGEventScrollWheel) {
        int64_t scrollWheel = obj.Get("scrollWheel").As<Napi::Number>().Int64Value();
        event = CGEventCreateScrollWheelEvent(NULL, kCGScrollEventUnitLine, 1, (int32_t)scrollWheel);
    }

    if (event) {
        CGEventPost(kCGHIDEventTap, event); // Inject globally
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
