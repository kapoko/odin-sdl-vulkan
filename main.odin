package main

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:strings"
import "vendor:sdl2"
import vk "vendor:vulkan"

WINDOW_TITLE :: "Vulkan SDL"
VIEW_WIDTH :: 640
VIEW_HEIGHT :: 480
WINDOW_FLAGS :: sdl2.WindowFlags{.SHOWN, .ALLOW_HIGHDPI, .VULKAN}
ENABLE_VALIDATION_LAYERS :: ODIN_DEBUG

validationLayers := [?]cstring{"VK_LAYER_KHRONOS_validation"}

CTX :: struct {
    window:         ^sdl2.Window,
    vulkanInstance: vk.Instance,
    debugMessenger: vk.DebugUtilsMessengerEXT,
}

ctx := CTX{}

init_window :: proc() -> bool {
    if sdl_res := sdl2.Init(sdl2.INIT_VIDEO); sdl_res < 0 {
        log.errorf("sdl2.init returned %v.", sdl_res)
        return false
    }

    bounds := sdl2.Rect{}
    if e := sdl2.GetDisplayBounds(0, &bounds); e != 0 {
        log.errorf("Unable to get desktop bounds.")
        return false
    }

    windowX: i32 = ((bounds.w - bounds.x) / 2) - i32(VIEW_WIDTH / 2) + bounds.x
    windowY: i32 = ((bounds.h - bounds.y) / 2) - i32(VIEW_HEIGHT / 2) + bounds.y

    ctx.window = sdl2.CreateWindow(
        WINDOW_TITLE,
        windowX,
        windowY,
        VIEW_WIDTH,
        VIEW_HEIGHT,
        WINDOW_FLAGS,
    )

    if ctx.window == nil {
        log.errorf("sdl2.CreateWindow failed.")
        return false
    }

    return true
}

debug_callback: vk.ProcDebugUtilsMessengerCallbackEXT : proc "system" (
    messageSeverity: vk.DebugUtilsMessageSeverityFlagsEXT,
    messageTypes: vk.DebugUtilsMessageTypeFlagsEXT,
    pCallbackData: ^vk.DebugUtilsMessengerCallbackDataEXT,
    pUserData: rawptr,
) -> b32 {
    context = runtime.default_context()
    context.logger = log.create_console_logger()

    level: runtime.Logger_Level

    switch {
    case .ERROR in messageSeverity:
        level = .Error
    case .WARNING in messageSeverity:
        level = .Warning
    case .VERBOSE in messageSeverity:
        level = .Debug
    case:
        level = .Info
    }

    log.logf(level, "Validation layer: %v", pCallbackData.pMessage)
    return false
}

init_vulkan :: proc(instance: ^vk.Instance, debugMessenger: ^vk.DebugUtilsMessengerEXT) -> bool {
    // Load addresses of vulkan addresses
    getInstanceProcAddr := sdl2.Vulkan_GetVkGetInstanceProcAddr()
    assert(getInstanceProcAddr != nil)
    vk.load_proc_addresses_global(getInstanceProcAddr)
    assert(vk.CreateInstance != nil)

    layerCount: u32
    vk.EnumerateInstanceLayerProperties(&layerCount, nil)
    availableLayers := make([dynamic]vk.LayerProperties, layerCount)
    defer delete(availableLayers)
    vk.EnumerateInstanceLayerProperties(&layerCount, &availableLayers[0])

    missingLayers := false
    for layer in validationLayers {
        layerFound := false
        for &layerProperties in availableLayers {
            if runtime.cstring_cmp(layer, cast(cstring)&layerProperties.layerName[0]) == 0 {
                layerFound = true
                break
            }
        }

        if !layerFound do missingLayers = true
    }

    if (ENABLE_VALIDATION_LAYERS && missingLayers) {
        log.error("Validation layers requested, but not available!")
        return false
    }

    appInfo := vk.ApplicationInfo{}
    appInfo.sType = .APPLICATION_INFO
    appInfo.pApplicationName = WINDOW_TITLE
    appInfo.applicationVersion = vk.MAKE_VERSION(1, 0, 0)
    appInfo.pEngineName = "No Engine"
    appInfo.engineVersion = vk.MAKE_VERSION(1, 0, 0)
    appInfo.apiVersion = vk.API_VERSION_1_3

    extensionCount: u32

    sdl2.Vulkan_GetInstanceExtensions(ctx.window, &extensionCount, nil)
    extensionNames := make([dynamic]cstring, extensionCount)
    defer delete(extensionNames)
    sdl2.Vulkan_GetInstanceExtensions(ctx.window, &extensionCount, &extensionNames[0])

    if (ENABLE_VALIDATION_LAYERS) {
        append(&extensionNames, vk.EXT_DEBUG_UTILS_EXTENSION_NAME)
    }

    when ODIN_DEBUG {
        vk.EnumerateInstanceExtensionProperties(nil, &extensionCount, nil)
        supportedExtensions := make([dynamic]vk.ExtensionProperties, extensionCount)
        defer delete(supportedExtensions)
        vk.EnumerateInstanceExtensionProperties(nil, &extensionCount, &supportedExtensions[0])
        log.infof("Available extensions:")
        for &extension, i in supportedExtensions {
            log.infof("%v:\t%s", i + 1, extension.extensionName)
        }
    }

    createInfo := vk.InstanceCreateInfo{}
    createInfo.sType = .INSTANCE_CREATE_INFO
    createInfo.pApplicationInfo = &appInfo
    createInfo.enabledLayerCount = 0
    createInfo.enabledExtensionCount = cast(u32)len(extensionNames)
    createInfo.ppEnabledExtensionNames = &extensionNames[0]

    debugCreateInfo := vk.DebugUtilsMessengerCreateInfoEXT{}
    debugCreateInfo.sType = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT
    debugCreateInfo.messageSeverity = {.VERBOSE | .WARNING | .ERROR | .INFO}
    debugCreateInfo.messageType = {.GENERAL, .VALIDATION, .PERFORMANCE}
    debugCreateInfo.pfnUserCallback = debug_callback

    if (ENABLE_VALIDATION_LAYERS) {
        createInfo.enabledLayerCount = len(validationLayers)
        createInfo.ppEnabledLayerNames = &validationLayers[0]

        createInfo.pNext = auto_cast &debugCreateInfo
    }

    res := vk.CreateInstance(&createInfo, nil, instance)
    if res != vk.Result.SUCCESS {
        log.error("Failed to create Vulkan instance", res)
        return false
    }

    // Load the rest of the vulkan functions
    vk.load_proc_addresses_instance(instance^)

    // Setup debug messenger
    if ENABLE_VALIDATION_LAYERS {
        if vk.CreateDebugUtilsMessengerEXT(instance^, &debugCreateInfo, nil, debugMessenger) !=
           .SUCCESS {
            log.error("Failed to setup debug messenger.")
            return false
        }
    }

    return true
}

main :: proc() {
    context.logger = log.create_console_logger()

    trackingAllocator: mem.Tracking_Allocator
    when ODIN_DEBUG {
        mem.tracking_allocator_init(&trackingAllocator, context.allocator)
        context.allocator = mem.tracking_allocator(&trackingAllocator)
    }

    reset_tracking_allocator :: proc(a: ^mem.Tracking_Allocator) -> (leaks: bool) {
        for _, value in a.allocation_map {
            log.warnf("%v: Leaked %v bytes\n", value.location, value.size)
            leaks = true
        }

        mem.tracking_allocator_clear(a)
        return
    }
    defer reset_tracking_allocator(&trackingAllocator)

    init_window()
    init_vulkan(&ctx.vulkanInstance, &ctx.debugMessenger)

    shouldClose := false
    for !shouldClose {
        // Main loop
        e: sdl2.Event

        for sdl2.PollEvent(&e) {
            #partial switch (e.type) {
            case .QUIT:
                shouldClose = true
            }
        }
    }

    if ENABLE_VALIDATION_LAYERS {
        vk.DestroyDebugUtilsMessengerEXT(ctx.vulkanInstance, ctx.debugMessenger, nil)
    }

    vk.DestroyInstance(ctx.vulkanInstance, nil)
    sdl2.DestroyWindow(ctx.window)
    sdl2.Quit()
}
