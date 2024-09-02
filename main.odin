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

check_validation_layer_support :: proc() -> bool {
    layerCount: u32
    if res := vk.EnumerateInstanceLayerProperties(&layerCount, nil); res != .SUCCESS {
        log.error("Failed to enumerate validation layers")
    }

    if layerCount == 0 {
        log.error("No validation layers available.")
        return false
    }

    availableLayers := make([dynamic]vk.LayerProperties, layerCount)
    defer delete(availableLayers)
    vk.EnumerateInstanceLayerProperties(&layerCount, &availableLayers[0])

    for layer in validationLayers {
        layerFound := false
        for &layerProperties in availableLayers {
            if runtime.cstring_cmp(layer, cast(cstring)&layerProperties.layerName[0]) == 0 {
                layerFound = true
                break
            }
        }

        if !layerFound do return false
    }

    return true
}

populate_debug_create_info :: proc(
    createInfo: ^vk.DebugUtilsMessengerCreateInfoEXT,
) -> ^vk.DebugUtilsMessengerCreateInfoEXT {
    debug_callback :: proc "system" (
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

    createInfo.sType = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT
    createInfo.messageSeverity = {.VERBOSE | .WARNING | .ERROR | .INFO}
    createInfo.messageType = {.GENERAL, .VALIDATION, .PERFORMANCE}
    createInfo.pfnUserCallback = debug_callback

    return createInfo
}

create_vulkan_instance :: proc(instance: ^vk.Instance) -> bool {
    // Load addresses of vulkan addresses
    getInstanceProcAddr := sdl2.Vulkan_GetVkGetInstanceProcAddr()
    assert(getInstanceProcAddr != nil)
    vk.load_proc_addresses_global(getInstanceProcAddr)
    assert(vk.CreateInstance != nil)

    if (ENABLE_VALIDATION_LAYERS && !check_validation_layer_support()) {
        log.error("Validation layers requested, but not available")
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
    append(&extensionNames, vk.KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME)

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
    createInfo.flags |= {.ENUMERATE_PORTABILITY_KHR}

    if (ENABLE_VALIDATION_LAYERS) {
        createInfo.enabledLayerCount = len(validationLayers)
        createInfo.ppEnabledLayerNames = &validationLayers[0]
        debugCreateInfo := vk.DebugUtilsMessengerCreateInfoEXT{}
        createInfo.pNext = populate_debug_create_info(&debugCreateInfo)
    }

    res := vk.CreateInstance(&createInfo, nil, instance)
    if res != vk.Result.SUCCESS {
        log.error("Failed to create Vulkan instance", res)
        return false
    }

    // Load the rest of the vulkan functions
    vk.load_proc_addresses_instance(instance^)

    return true
}

setup_debug_messenger :: proc(
    instance: ^vk.Instance,
    debugMessenger: ^vk.DebugUtilsMessengerEXT,
) -> bool {
    // Setup debug messenger
    if ENABLE_VALIDATION_LAYERS {
        debugCreateInfo := vk.DebugUtilsMessengerCreateInfoEXT{}
        if vk.CreateDebugUtilsMessengerEXT(
               instance^,
               populate_debug_create_info(&debugCreateInfo),
               nil,
               debugMessenger,
           ) !=
           .SUCCESS {
            log.error("Failed to setup debug messenger.")
            return false
        }
    }

    return true
}

pick_physical_device :: proc(instance: ^vk.Instance) -> bool {
    physicalDevice: vk.PhysicalDevice = nil

    deviceCount: u32 = 0
    vk.EnumeratePhysicalDevices(instance^, &deviceCount, nil)

    if deviceCount == 0 {
        log.error("Failed to find GPUs with Vulkan support")
        return false
    }

    devices := make([dynamic]vk.PhysicalDevice, deviceCount)
    vk.EnumeratePhysicalDevices(instance^, &deviceCount, &devices[0])

    isDeviceSuitable :: proc(device: vk.PhysicalDevice) -> bool {
        deviceProperties := vk.PhysicalDeviceProperties{}
        deviceFeatures := vk.PhysicalDeviceFeatures{}
        vk.GetPhysicalDeviceProperties(device, &deviceProperties)
        vk.GetPhysicalDeviceFeatures(device, &deviceFeatures)

        // Could check features, but support is all we need for now
        return true
    }

    for device in devices {
        if (isDeviceSuitable(device)) {
            physicalDevice = device
        }
    }

    if (physicalDevice == nil) {
        log.error("Failed to find a suitable GPU!")
        return false
    }

    return true
}

init_vulkan :: proc(instance: ^vk.Instance, debugMessenger: ^vk.DebugUtilsMessengerEXT) -> bool {
    create_vulkan_instance(instance) or_return
    setup_debug_messenger(instance, debugMessenger) or_return
    pick_physical_device(instance) or_return

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
