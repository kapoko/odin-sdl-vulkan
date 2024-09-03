package main

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:math"
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
deviceExtensions := [?]cstring{vk.KHR_SWAPCHAIN_EXTENSION_NAME, "VK_KHR_portability_subset"}

QueueFamilyIndices :: struct {
    graphicsFamily: Maybe(u32),
    presentFamily:  Maybe(u32),
}

SwapChainSupportDetails :: struct {
    capabilities: vk.SurfaceCapabilitiesKHR,
    formats:      [dynamic]vk.SurfaceFormatKHR,
    presentModes: [dynamic]vk.PresentModeKHR,
}

VulkanHandles :: struct {
    instance:                    vk.Instance,
    debugMessenger:              vk.DebugUtilsMessengerEXT,
    device:                      vk.Device,
    graphicsQueue, presentQueue: vk.Queue,
    surface:                     vk.SurfaceKHR,
    swapChain:                   vk.SwapchainKHR,
    swapChainImages:             [dynamic]vk.Image,
    swapChainImageFormat:        vk.Format,
    swapChainExtent:             vk.Extent2D,
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

query_swap_chain_support :: proc(
    device: vk.PhysicalDevice,
    surface: vk.SurfaceKHR,
) -> (
    details: SwapChainSupportDetails,
) {
    vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(device, surface, &details.capabilities)

    formatCount: u32
    vk.GetPhysicalDeviceSurfaceFormatsKHR(device, surface, &formatCount, nil)
    if (formatCount != 0) {
        details.formats = make([dynamic]vk.SurfaceFormatKHR, formatCount)
        vk.GetPhysicalDeviceSurfaceFormatsKHR(device, surface, &formatCount, &details.formats[0])
    }

    presentModeCount: u32
    vk.GetPhysicalDeviceSurfacePresentModesKHR(device, surface, &presentModeCount, nil)
    if (presentModeCount != 0) {
        details.presentModes = make([dynamic]vk.PresentModeKHR, presentModeCount)
        vk.GetPhysicalDeviceSurfacePresentModesKHR(
            device,
            surface,
            &presentModeCount,
            &details.presentModes[0],
        )
    }

    return details
}

destroy_swap_chain_support :: proc(support: SwapChainSupportDetails) {
    delete(support.presentModes)
    delete(support.formats)
}

choose_swap_surface_format :: proc(
    availableFormats: [dynamic]vk.SurfaceFormatKHR,
) -> vk.SurfaceFormatKHR {
    for availableFormat in availableFormats {
        if (availableFormat.format == vk.Format.B8G8R8A8_SRGB &&
               availableFormat.colorSpace == vk.ColorSpaceKHR.COLORSPACE_SRGB_NONLINEAR) {
            return availableFormat
        }
    }

    // Could rank the available formats based on how 'good' they are but most cases first one is ok
    return availableFormats[0]
}

choose_swap_present_mode :: proc(
    availablePresentModes: [dynamic]vk.PresentModeKHR,
) -> vk.PresentModeKHR {

    for availablePresentMode in availablePresentModes {
        if (availablePresentMode == vk.PresentModeKHR.MAILBOX) {
            return availablePresentMode
        }
    }

    return vk.PresentModeKHR.FIFO
}

choose_swap_extent :: proc(
    window: ^sdl2.Window,
    capabilities: ^vk.SurfaceCapabilitiesKHR,
) -> vk.Extent2D {
    if capabilities.currentExtent.width != max(u32) {
        return capabilities.currentExtent
    }

    width, height: i32
    sdl2.Vulkan_GetDrawableSize(window, &width, &height)

    actualExtent: vk.Extent2D = {u32(width), u32(height)}
    min, max := capabilities.minImageExtent, capabilities.maxImageExtent
    actualExtent.width = math.clamp(actualExtent.width, min.width, max.width)
    actualExtent.height = math.clamp(actualExtent.height, min.height, max.height)

    return actualExtent
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
    swapChainAdequate: bool = false
    if extensionsSupported {
        support := query_swap_chain_support(device, surface)
        defer destroy_swap_chain_support(support)
        swapChainAdequate = len(support.formats) > 0 && len(support.presentModes) > 0
    }

    isSuitable = is_queue_family_complete(indices) && extensionsSupported && swapChainAdequate

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
    createInfo.enabledExtensionCount = len(deviceExtensions)
    createInfo.ppEnabledExtensionNames = &deviceExtensions[0]

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

create_swap_chain :: proc(
    window: ^sdl2.Window,
    physicalDevice: vk.PhysicalDevice,
    device: vk.Device,
    surface: vk.SurfaceKHR,
) -> (
    swapChain: vk.SwapchainKHR,
    swapChainImages: [dynamic]vk.Image,
    swapChainImageFormat: vk.Format,
    swapChainExtent: vk.Extent2D,
    ok: bool,
) {
    support := query_swap_chain_support(physicalDevice, surface)
    defer destroy_swap_chain_support(support)

    surfaceFormat := choose_swap_surface_format(support.formats)
    presentMode := choose_swap_present_mode(support.presentModes)
    extent := choose_swap_extent(window, &support.capabilities)

    imageCount := support.capabilities.minImageCount + 1
    if (support.capabilities.maxImageCount > 0 &&
           imageCount > support.capabilities.maxImageCount) {
        imageCount = support.capabilities.maxImageCount
    }

    createInfo := vk.SwapchainCreateInfoKHR{}
    createInfo.sType = vk.StructureType.SWAPCHAIN_CREATE_INFO_KHR
    createInfo.surface = surface
    createInfo.minImageCount = imageCount
    createInfo.imageFormat = surfaceFormat.format
    createInfo.imageColorSpace = surfaceFormat.colorSpace
    createInfo.imageExtent = extent
    createInfo.imageArrayLayers = 1
    createInfo.imageUsage = {.COLOR_ATTACHMENT}

    indices := find_queue_families(physicalDevice, surface)
    queueFamilyIndices := [?]u32{indices.graphicsFamily.(u32), indices.presentFamily.(u32)}

    if (indices.graphicsFamily != indices.presentFamily) {
        createInfo.imageSharingMode = .CONCURRENT
        createInfo.queueFamilyIndexCount = 2
        createInfo.pQueueFamilyIndices = &queueFamilyIndices[0]
    } else {
        createInfo.imageSharingMode = .EXCLUSIVE
        createInfo.queueFamilyIndexCount = 0
        createInfo.pQueueFamilyIndices = nil
    }

    createInfo.preTransform = support.capabilities.currentTransform
    createInfo.compositeAlpha = {.OPAQUE}
    createInfo.presentMode = presentMode
    createInfo.clipped = true

    if (vk.CreateSwapchainKHR(device, &createInfo, nil, &swapChain) != .SUCCESS) {
        log.error("Failed to create swap chain")
    }

    vk.GetSwapchainImagesKHR(device, swapChain, &imageCount, nil)
    swapChainImages = make([dynamic]vk.Image, imageCount)
    vk.GetSwapchainImagesKHR(device, swapChain, &imageCount, &swapChainImages[0])

    return swapChain, swapChainImages, surfaceFormat.format, extent, true
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
    handles.swapChain, handles.swapChainImages, handles.swapChainImageFormat, handles.swapChainExtent =
        create_swap_chain(window, physicalDevice, handles.device, handles.surface) or_return

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

    delete(ctx.swapChainImages)
    vk.DestroySwapchainKHR(ctx.device, ctx.swapChain, nil)
    vk.DestroyDevice(ctx.device, nil)
    vk.DestroySurfaceKHR(ctx.instance, ctx.surface, nil)
    vk.DestroyInstance(ctx.instance, nil)
    sdl2.DestroyWindow(ctx.window)
    sdl2.Quit()
}
