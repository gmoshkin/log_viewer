set_window_dark_mode :: (window: HWND) {
    value := BOOL.TRUE;
    rc := DwmSetWindowAttribute(window, DWMWA_USE_IMMERSIVE_DARK_MODE, *value, size_of(BOOL));
    if rc != S_OK {
        code, message := get_error_value_and_string();
        log_error("DwmSetWindowAttribute(DWMWA_USE_IMMERSIVE_DARK_MODE, true) failed: % %", code, message);
    }
}

#scope_module;

DwmSetWindowAttribute :: (hwnd: HWND, dwAttribute: DWORD, pvAttribute: *void, cbAttribute: DWORD) -> HRESULT #foreign dwmapi;

DWMWA_USE_IMMERSIVE_DARK_MODE :: 20;

dwmapi :: #library,system "dwmapi";

#import "Windows";
#import "System";
#import "Basic";
