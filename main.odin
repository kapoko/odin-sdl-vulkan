package main

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:strings"
import "vendor:sdl2"
import vk "vendor:vulkan"

WINDOW_TITLE :: "Vulkan SDL"
VIEW_WIDTH :: 640
VIEW_HEIGHT :: 480
WINDOW_FLAGS :: sdl2.WindowFlags{.SHOWN, .ALLOW_HIGHDPI, .VULKAN}
ENABLE_VALIDATION_LAYERS :: ODIN_DEBUG

validationLayers := [?]cstring{"VK_LAYER_KHRONOS_validation"}
deviceExtensions := [?]cstring{vk.KHR_SWAPCHAIN_EXTENSION_NAME}

QueueFamilyIndices :: struct {
    graphicsFamily: Maybe(u32),
    presentFamily:  Maybe(u32),
}

VulkanHandles :: struct {
    instance:                    vk.Instance,
    debugMessenger:              vk.DebugUtilsMessengerEXT,
    device:                      vk.Device,
    graphicsQueue, presentQueue: vk.Queue,
    surface:                     vk.SurfaceKHR,
}

CTX :: struct {
    window:              ^sdl2.Window,
    using vulkanHandles: VulkanHandles,
}

ctx := CTX{}

is_queue_family_complete :: proc(q: QueueFamilyIndices) -> bool {
    return q.graphicsFamily != nil && q.presentFamily != nil
}

init_window :: proc() -> (window: ^sdl2.Window, ok: bool) {
    if sdl_res := sdl2.Init(sdl2.INIT_VIDEO); sdl_res < 0 {
        log.errorf("sdl2.init returned %v.", sdl_res)
        return
    }

    bounds := sdl2.Rect{}
    if e := sdl2.GetDisplayBounds(0, &bounds); e != 0 {
        log.errorf("Unable to get desktop bounds.")
        return
    }

    windowX: i32 = ((bounds.w - bounds.x) / 2) - i32(VIEW_WIDTH / 2) + bounds.x
    windowY: i32 = ((bounds.h - bounds.y) / 2) - i32(VIEW_HEIGHT / 2) + bounds.y

    window = sdl2.CreateWindow(
        WINDOW_TITLE,
        windowX,
        windowY,
        VIEW_WIDTH,
        VIEW_HEIGHT,
        WINDOW_FLAGS,
    )

    if window == nil {
        log.errorf("sdl2.CreateWindow failed.")
        return
    }

    return window, true
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
            if runtime.cstring_eq(layer, cast(cstring)&layerProperties.layerName[0]) {
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
    createInfo.sType = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT
    createInfo.messageSeverity = {.WARNING, .ERROR}
    createInfo.messageType = {.GENERAL, .VALIDATION, .PERFORMANCE}

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

    createInfo.pfnUserCallback = debug_callback

    return createInfo
}

create_vulkan_instance :: proc(instance: ^vk.Instance) -> bool {
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

    if (ENABLE_VALIDATION_LAYERS) {
        append(&extensionNames, vk.EXT_DEBUG_UTILS_EXTENSION_NAME)
    }

    createInfo := vk.InstanceCreateInfo{}

    vk.EnumerateInstanceExtensionProperties(nil, &extensionCount, nil)
    supportedExtensions := make([dynamic]vk.ExtensionProperties, extensionCount)
    defer delete(supportedExtensions)
    vk.EnumerateInstanceExtensionProperties(nil, &extensionCount, &supportedExtensions[0])

    for &extension, i in supportedExtensions {
        if runtime.cstring_eq(
            vk.KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME,
            cast(cstring)&extension.extensionName[0],
        ) {
            append(&extensionNames, vk.KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME)
            createInfo.flags = {vk.InstanceCreateFlag.ENUMERATE_PORTABILITY_KHR}
        }
        if ODIN_DEBUG do log.infof("%v:\t%s", i + 1, extension.extensionName)
    }

    createInfo.sType = .INSTANCE_CREATE_INFO
    createInfo.pApplicationInfo = &appInfo
    createInfo.enabledLayerCount = 0
    createInfo.enabledExtensionCount = cast(u32)len(extensionNames)
    createInfo.ppEnabledExtensionNames = &extensionNames[0]

    if (ENABLE_VALIDATION_LAYERS) {
        createInfo.enabledLayerCount = cast(u32)len(validationLayers)
        createInfo.ppEnabledLayerNames = &validationLayers[0]
        debugCreateInfo := vk.DebugUtilsMessengerCreateInfoEXT{}
        createInfo.pNext = populate_debug_create_info(&debugCreateInfo)
    }

    res := vk.CreateInstance(&createInfo, nil, instance)
    if res != vk.Result.SUCCESS {
        log.error("Failed to create Vulkan instance:", res)
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

find_queue_families :: proc(
    device: vk.PhysicalDevice,
    surface: vk.SurfaceKHR,
) -> (
    indices: QueueFamilyIndices,
) {
    queueFamilyCount: u32 = 0

    vk.GetPhysicalDeviceQueueFamilyProperties(device, &queueFamilyCount, nil)

    if (queueFamilyCount == 0) {
        log.error("No queue families found")
        return
    }

    queueFamilies := make([dynamic]vk.QueueFamilyProperties, queueFamilyCount)
    defer delete(queueFamilies)
    vk.GetPhysicalDeviceQueueFamilyProperties(device, &queueFamilyCount, &queueFamilies[0])
    for queueFamily, i in queueFamilies {
        if (vk.QueueFlag.GRAPHICS in queueFamily.queueFlags) {
            indices.graphicsFamily = cast(u32)i
        }

        presentSupport: b32 = false
        vk.GetPhysicalDeviceSurfaceSupportKHR(device, cast(u32)i, surface, &presentSupport)

        if (presentSupport) {
            indices.presentFamily = cast(u32)i
        }

        if is_queue_family_complete(indices) {
            break
        }
    }

    return
}

create_surface :: proc(
    window: ^sdl2.Window,
    instance: vk.Instance,
) -> (
    surface: vk.SurfaceKHR,
    ok: bool,
) {
    if !sdl2.Vulkan_CreateSurface(window, instance, &surface) {
        log.error("Failed to create window surface")
        return
    }

    return surface, true
}

check_device_extension_support :: proc(device: vk.PhysicalDevice) -> bool {
    extensionCount: u32
    vk.EnumerateDeviceExtensionProperties(device, nil, &extensionCount, nil)
    availableExtensions := make([dynamic]vk.ExtensionProperties, extensionCount)
    defer delete(availableExtensions)
    vk.EnumerateDeviceExtensionProperties(device, nil, &extensionCount, &availableExtensions[0])

    found := 0
    for &availableExtension in availableExtensions {
        for extension in deviceExtensions {
            if runtime.cstring_eq(extension, cstring(&availableExtension.extensionName[0])) {
                found += 1
            }
        }
    }

    return len(deviceExtensions) == found
}

is_device_suitable :: proc(
    device: vk.PhysicalDevice,
    surface: vk.SurfaceKHR,
) -> (
    isSuitable: bool,
) {
    deviceProperties := vk.PhysicalDeviceProperties{}
    deviceFeatures := vk.PhysicalDeviceFeatures{}
    vk.GetPhysicalDeviceProperties(device, &deviceProperties)
    vk.GetPhysicalDeviceFeatures(device, &deviceFeatures)

    indices: QueueFamilyIndices = find_queue_families(device, surface)
    extensionsSupported := check_device_extension_support(device)
    isSuitable = is_queue_family_complete(indices) && extensionsSupported

    if isSuitable && ODIN_DEBUG {
        log.infof("Found suitable device: %s", deviceProperties.deviceName)
    }

    return
}

pick_physical_device :: proc(
    instance: vk.Instance,
    surface: vk.SurfaceKHR,
) -> (
    physicalDevice: vk.PhysicalDevice,
    ok: bool,
) {
    deviceCount: u32 = 0
    vk.EnumeratePhysicalDevices(instance, &deviceCount, nil)

    if deviceCount == 0 {
        log.error("Failed to find GPUs with Vulkan support")
        return
    }

    devices := make([dynamic]vk.PhysicalDevice, deviceCount)
    defer delete(devices)
    vk.EnumeratePhysicalDevices(instance, &deviceCount, &devices[0])

    for device in devices {
        if (is_device_suitable(device, surface)) {
            physicalDevice = device
        }
    }

    if (physicalDevice == nil) {
        log.error("Failed to find a suitable GPU!")
        return
    }

    ok = true
    return
}

create_logical_device :: proc(
    physicalDevice: vk.PhysicalDevice,
    surface: vk.SurfaceKHR,
) -> (
    device: vk.Device,
    graphicsQueue: vk.Queue,
    presentQueue: vk.Queue,
    ok: bool,
) {
    indices: QueueFamilyIndices = find_queue_families(physicalDevice, surface)
    queueFamilies := [?]u32{indices.graphicsFamily.(u32), indices.presentFamily.(u32)}
    uniqueQueueFamilies := make(map[u32]bool)
    defer delete(uniqueQueueFamilies)

    for i in queueFamilies {
        uniqueQueueFamilies[i] = true
    }

    queueCreateInfos := make([dynamic]vk.DeviceQueueCreateInfo)
    defer delete(queueCreateInfos)
    queuePriority: f32 = 1.0
    for queueFamily in uniqueQueueFamilies {
        queueCreateInfo := vk.DeviceQueueCreateInfo{}
        queueCreateInfo.sType = vk.StructureType.DEVICE_QUEUE_CREATE_INFO
        queueCreateInfo.queueFamilyIndex = indices.graphicsFamily.(u32)
        queueCreateInfo.queueCount = 1
        queueCreateInfo.pQueuePriorities = &queuePriority
        append(&queueCreateInfos, queueCreateInfo)
    }


    deviceFeatures := vk.PhysicalDeviceFeatures{} // Empty for now
    createInfo := vk.DeviceCreateInfo{}
    createInfo.sType = vk.StructureType.DEVICE_CREATE_INFO
    createInfo.pQueueCreateInfos = &queueCreateInfos[0]
    createInfo.queueCreateInfoCount = cast(u32)len(queueCreateInfos)
    createInfo.pEnabledFeatures = &deviceFeatures
    createInfo.enabledLayerCount = 0

    extensionCount: u32 = 0
    vk.EnumerateDeviceExtensionProperties(physicalDevice, nil, &extensionCount, nil)
    supportedExtensions := make([dynamic]vk.ExtensionProperties, extensionCount)
    defer delete(supportedExtensions)
    vk.EnumerateDeviceExtensionProperties(
        physicalDevice,
        nil,
        &extensionCount,
        &supportedExtensions[0],
    )

    extensions := [?]cstring{"VK_KHR_portability_subset"}

    for extension in extensions {
        extensionFound := false
        for &supportedExtension in supportedExtensions {
            if runtime.cstring_eq(extension, cast(cstring)&supportedExtension.extensionName[0]) {
                extensionFound = true
                break
            }
        }
        if !extensionFound {
            log.errorf("Device extension not found: %s", extension)
            return
        }
    }

    createInfo.enabledExtensionCount = len(extensions)
    createInfo.ppEnabledExtensionNames = &extensions[0]

    if (ENABLE_VALIDATION_LAYERS) {
        createInfo.enabledLayerCount = len(validationLayers)
        createInfo.ppEnabledLayerNames = &validationLayers[0]
    }

    if (vk.CreateDevice(physicalDevice, &createInfo, nil, &device) != .SUCCESS) {
        log.error("Failed to create logical device")
    }

    vk.GetDeviceQueue(device, indices.graphicsFamily.(u32), 0, &graphicsQueue)
    vk.GetDeviceQueue(device, indices.presentFamily.(u32), 0, &presentQueue)

    ok = true
    return
}

init_vulkan :: proc(window: ^sdl2.Window) -> (handles: VulkanHandles, ok: bool) {
    // Load addresses of vulkan addresses
    getInstanceProcAddr := sdl2.Vulkan_GetVkGetInstanceProcAddr()
    assert(getInstanceProcAddr != nil)
    vk.load_proc_addresses_global(getInstanceProcAddr)
    assert(vk.CreateInstance != nil)

    // Here we go
    create_vulkan_instance(&handles.instance) or_return
    setup_debug_messenger(&handles.instance, &handles.debugMessenger) or_return
    handles.surface = create_surface(window, handles.instance) or_return
    physicalDevice := pick_physical_device(handles.instance, handles.surface) or_return
    handles.device, handles.graphicsQueue, handles.presentQueue = create_logical_device(
        physicalDevice,
        handles.surface,
    ) or_return

    return handles, true
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

    ok: bool
    if ctx.window, ok = init_window(); !ok {
        os.exit(1)
    }

    if ctx.vulkanHandles, ok = init_vulkan(ctx.window); !ok {
        os.exit(1)
    }

    shouldClose := false
    for !shouldClose {
        // Main loop
        e: sdl2.Event

        for sdl2.PollEvent(&e) {
            #partial switch (e.type) {
            case .QUIT:
                shouldClose = true
            case .KEYDOWN:
                if e.key.keysym.sym == .ESCAPE do shouldClose = true
            }
        }
    }

    if ENABLE_VALIDATION_LAYERS {
        vk.DestroyDebugUtilsMessengerEXT(ctx.instance, ctx.debugMessenger, nil)
    }

    vk.DestroyDevice(ctx.device, nil)
    vk.DestroySurfaceKHR(ctx.instance, ctx.surface, nil)
    vk.DestroyInstance(ctx.instance, nil)
    sdl2.DestroyWindow(ctx.window)
    sdl2.Quit()
}
