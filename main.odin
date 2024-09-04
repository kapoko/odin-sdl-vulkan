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

WINDOW_TITLE :: "Odin SDL Vulkan"
VIEW_WIDTH :: 640
VIEW_HEIGHT :: 480
WINDOW_FLAGS :: sdl2.WindowFlags{.SHOWN, .ALLOW_HIGHDPI, .VULKAN, .RESIZABLE}
ENABLE_VALIDATION_LAYERS :: ODIN_DEBUG
MAX_FRAMES_IN_FLIGHT :: 2

validationLayers := [?]cstring{"VK_LAYER_KHRONOS_validation"}
deviceExtensions := [?]cstring{vk.KHR_SWAPCHAIN_EXTENSION_NAME, "VK_KHR_portability_subset"}

QueueFamilyIndices :: struct {
    graphicsFamily: Maybe(u32),
    presentFamily:  Maybe(u32),
}

SwapChainSupportDetails :: struct {
    capabilities: vk.SurfaceCapabilitiesKHR,
    formats:      []vk.SurfaceFormatKHR,
    presentModes: []vk.PresentModeKHR,
}

Swapchain :: struct {
    handle:       vk.SwapchainKHR,
    images:       []vk.Image,
    imageViews:   []vk.ImageView,
    imageFormat:  vk.Format,
    extent:       vk.Extent2D,
    framebuffers: []vk.Framebuffer,
}

GraphicsPipelineHandles :: struct {
    pipelineLayout:   vk.PipelineLayout,
    graphicsPipeline: vk.Pipeline,
}

LogicalDeviceHandles :: struct {
    device:                      vk.Device,
    graphicsQueue, presentQueue: vk.Queue,
}

SyncObjects :: struct {
    imageAvailableSemaphore: vk.Semaphore,
    renderFinishedSemaphore: vk.Semaphore,
    inFlightFence:           vk.Fence,
}

VulkanHandles :: struct {
    instance:                      vk.Instance,
    debugMessenger:                vk.DebugUtilsMessengerEXT,
    surface:                       vk.SurfaceKHR,
    renderPass:                    vk.RenderPass,
    commandPool:                   vk.CommandPool,
    commandBuffers:                [MAX_FRAMES_IN_FLIGHT]vk.CommandBuffer,
    syncObjects:                   [MAX_FRAMES_IN_FLIGHT]SyncObjects,
    physicalDevice:                vk.PhysicalDevice,
    swapchain:                     Swapchain,
    using logicalDeviceHandles:    LogicalDeviceHandles,
    using graphicsPipelineHandles: GraphicsPipelineHandles,
}

CTX :: struct {
    window:              ^sdl2.Window,
    currentFrame:        u32,
    framebufferResized:  bool,
    using vulkanHandles: VulkanHandles,
}

init_window :: proc(framebufferResized: ^bool) -> (window: ^sdl2.Window, ok: bool) {
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

    sdl2.SetEventFilter(window_event_handler, framebufferResized)
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

window_event_handler :: proc "c" (userdata: rawptr, event: ^sdl2.Event) -> i32 {
    context = runtime.default_context()

    if (event.type == sdl2.EventType.WINDOWEVENT) {
        windowEvent: ^sdl2.WindowEvent = &event.window
        #partial switch (windowEvent.event) {
        case sdl2.WindowEventID.RESIZED:
            framebufferResized := cast(^bool)userdata
            framebufferResized^ = true

            return 0
        }
    }

    return 1
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

    availableLayers := make([]vk.LayerProperties, layerCount)
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

create_vulkan_instance :: proc(window: ^sdl2.Window) -> (instance: vk.Instance, ok: bool) {
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
    sdl2.Vulkan_GetInstanceExtensions(window, &extensionCount, nil)
    extensionNames := make([dynamic]cstring, extensionCount)
    defer delete(extensionNames)
    sdl2.Vulkan_GetInstanceExtensions(window, &extensionCount, &extensionNames[0])

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

    res := vk.CreateInstance(&createInfo, nil, &instance)
    if res != vk.Result.SUCCESS {
        log.error("Failed to create Vulkan instance:", res)
        return
    }

    // Load the rest of the vulkan functions
    vk.load_proc_addresses_instance(instance)

    return instance, true
}

setup_debug_messenger :: proc(
    instance: vk.Instance,
) -> (
    debugMessenger: vk.DebugUtilsMessengerEXT,
    ok: bool,
) {
    // Setup debug messenger
    if ENABLE_VALIDATION_LAYERS {
        debugCreateInfo := vk.DebugUtilsMessengerCreateInfoEXT{}
        if vk.CreateDebugUtilsMessengerEXT(
               instance,
               populate_debug_create_info(&debugCreateInfo),
               nil,
               &debugMessenger,
           ) !=
           .SUCCESS {
            log.error("Failed to setup debug messenger.")
            return
        }
    }

    return debugMessenger, true
}

is_queue_family_complete :: proc(q: QueueFamilyIndices) -> bool {
    return q.graphicsFamily != nil && q.presentFamily != nil
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

    queueFamilies := make([]vk.QueueFamilyProperties, queueFamilyCount)
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
    availableExtensions := make([]vk.ExtensionProperties, extensionCount)
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
        details.formats = make([]vk.SurfaceFormatKHR, formatCount)
        vk.GetPhysicalDeviceSurfaceFormatsKHR(device, surface, &formatCount, &details.formats[0])
    }

    presentModeCount: u32
    vk.GetPhysicalDeviceSurfacePresentModesKHR(device, surface, &presentModeCount, nil)
    if (presentModeCount != 0) {
        details.presentModes = make([]vk.PresentModeKHR, presentModeCount)
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
    availableFormats: []vk.SurfaceFormatKHR,
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

choose_swap_present_mode :: proc(availablePresentModes: []vk.PresentModeKHR) -> vk.PresentModeKHR {

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

    devices := make([]vk.PhysicalDevice, deviceCount)
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
    result: LogicalDeviceHandles,
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

    if (vk.CreateDevice(physicalDevice, &createInfo, nil, &result.device) != .SUCCESS) {
        log.error("Failed to create logical device")
    }

    vk.GetDeviceQueue(result.device, indices.graphicsFamily.(u32), 0, &result.graphicsQueue)
    vk.GetDeviceQueue(result.device, indices.presentFamily.(u32), 0, &result.presentQueue)

    ok = true
    return
}

create_swap_chain :: proc(
    window: ^sdl2.Window,
    physicalDevice: vk.PhysicalDevice,
    device: vk.Device,
    surface: vk.SurfaceKHR,
    oldSwapchain: vk.SwapchainKHR = 0,
) -> (
    swapchain: Swapchain,
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
    createInfo.oldSwapchain = oldSwapchain

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

    if (vk.CreateSwapchainKHR(device, &createInfo, nil, &swapchain.handle) != .SUCCESS) {
        log.error("Failed to create swap chain")
    }

    vk.GetSwapchainImagesKHR(device, swapchain.handle, &imageCount, nil)
    swapchain.images = make([]vk.Image, imageCount)
    vk.GetSwapchainImagesKHR(device, swapchain.handle, &imageCount, &swapchain.images[0])

    swapchain.imageFormat = surfaceFormat.format
    swapchain.extent = extent

    return swapchain, true
}

recreate_swapchain :: proc(window: ^sdl2.Window, v: ^VulkanHandles) -> (ok: bool) {
    // In case window is minimized, wait
    width, height: i32
    sdl2.Vulkan_GetDrawableSize(window, &width, &height)
    for (width == 0 || height == 0) {
        sdl2.Vulkan_GetDrawableSize(window, &width, &height)
        sdl2.WaitEvent(nil)
    }

    vk.DeviceWaitIdle(v.device)

    oldSwapchain := v.swapchain

    v.swapchain = create_swap_chain(
        window,
        v.physicalDevice,
        v.device,
        v.surface,
        v.swapchain.handle,
    ) or_return
    v.swapchain.imageViews = create_image_views(v.device, v.swapchain) or_return
    v.swapchain.framebuffers = create_framebuffers(v.swapchain, v.renderPass, v.device) or_return

    cleanup_swapchain(v.device, oldSwapchain)

    return true
}

create_image_views :: proc(
    device: vk.Device,
    swapchain: Swapchain,
) -> (
    imageViews: []vk.ImageView,
    ok: bool,
) {
    imageViews = make([]vk.ImageView, len(swapchain.images))

    for image, i in swapchain.images {
        createInfo := vk.ImageViewCreateInfo{}
        createInfo.sType = vk.StructureType.IMAGE_VIEW_CREATE_INFO
        createInfo.image = image
        createInfo.viewType = vk.ImageViewType.D2
        createInfo.format = swapchain.imageFormat
        createInfo.components.r = vk.ComponentSwizzle.IDENTITY
        createInfo.components.g = vk.ComponentSwizzle.IDENTITY
        createInfo.components.b = vk.ComponentSwizzle.IDENTITY
        createInfo.components.a = vk.ComponentSwizzle.IDENTITY
        createInfo.subresourceRange.aspectMask = {.COLOR}
        createInfo.subresourceRange.baseMipLevel = 0
        createInfo.subresourceRange.levelCount = 1
        createInfo.subresourceRange.baseArrayLayer = 0
        createInfo.subresourceRange.layerCount = 1

        if (vk.CreateImageView(device, &createInfo, nil, &imageViews[i]) != .SUCCESS) {
            log.errorf("Failed to create image view %v/%v!", i, len(swapchain.imageViews))
            return
        }
    }

    return imageViews, true
}

read_file :: proc(path: string) -> (data: []byte, ok: bool) {
    data, ok = os.read_entire_file_from_filename(path)

    return
}

create_shader_module :: proc(
    device: vk.Device,
    code: []byte,
) -> (
    shaderModule: vk.ShaderModule,
    ok: bool,
) {
    createInfo := vk.ShaderModuleCreateInfo{}
    createInfo.sType = vk.StructureType.SHADER_MODULE_CREATE_INFO
    createInfo.codeSize = len(code)
    createInfo.pCode = cast(^u32)&code[0]

    if (vk.CreateShaderModule(device, &createInfo, nil, &shaderModule) != .SUCCESS) {
        log.error("Failed to create shader module")
        return
    }

    return shaderModule, true
}

create_render_pass :: proc(
    device: vk.Device,
    swapChainImageFormat: vk.Format,
) -> (
    renderPass: vk.RenderPass,
    ok: bool,
) {
    colorAttachment := vk.AttachmentDescription{}
    colorAttachment.format = swapChainImageFormat
    colorAttachment.samples = {._1}
    colorAttachment.loadOp = .CLEAR
    colorAttachment.storeOp = .STORE
    colorAttachment.stencilLoadOp = .DONT_CARE
    colorAttachment.stencilStoreOp = .DONT_CARE
    colorAttachment.initialLayout = .UNDEFINED
    colorAttachment.finalLayout = .PRESENT_SRC_KHR

    colorAttachmentRef := vk.AttachmentReference{}
    colorAttachmentRef.attachment = 0
    colorAttachmentRef.layout = .COLOR_ATTACHMENT_OPTIMAL

    subpass := vk.SubpassDescription{}
    subpass.pipelineBindPoint = .GRAPHICS
    subpass.colorAttachmentCount = 1
    subpass.pColorAttachments = &colorAttachmentRef

    dependency := vk.SubpassDependency{}
    dependency.srcSubpass = vk.SUBPASS_EXTERNAL
    dependency.dstSubpass = 0
    dependency.srcStageMask = {.COLOR_ATTACHMENT_OUTPUT}
    dependency.srcAccessMask = nil
    dependency.dstStageMask = {.COLOR_ATTACHMENT_OUTPUT}
    dependency.dstAccessMask = {.COLOR_ATTACHMENT_WRITE}

    renderPassInfo := vk.RenderPassCreateInfo{}
    renderPassInfo.sType = .RENDER_PASS_CREATE_INFO
    renderPassInfo.attachmentCount = 1
    renderPassInfo.pAttachments = &colorAttachment
    renderPassInfo.subpassCount = 1
    renderPassInfo.pSubpasses = &subpass
    renderPassInfo.dependencyCount = 1
    renderPassInfo.pDependencies = &dependency

    if (vk.CreateRenderPass(device, &renderPassInfo, nil, &renderPass) != .SUCCESS) {
        log.error("Failed to create render pass")
        return
    }

    return renderPass, true
}

create_graphics_pipeline :: proc(
    device: vk.Device,
    renderPass: vk.RenderPass,
    swapChainExtent: vk.Extent2D,
) -> (
    handles: GraphicsPipelineHandles,
    ok: bool,
) {
    vertShaderCode := read_file("shaders/vert.spv") or_return
    fragShaderCode := read_file("shaders/frag.spv") or_return
    defer delete(vertShaderCode)
    defer delete(fragShaderCode)

    vertShaderModule := create_shader_module(device, vertShaderCode) or_return
    fragShaderModule := create_shader_module(device, fragShaderCode) or_return
    defer vk.DestroyShaderModule(device, fragShaderModule, nil)
    defer vk.DestroyShaderModule(device, vertShaderModule, nil)

    vertShaderStageInfo := vk.PipelineShaderStageCreateInfo{}
    vertShaderStageInfo.sType = .PIPELINE_SHADER_STAGE_CREATE_INFO
    vertShaderStageInfo.stage = {.VERTEX}
    vertShaderStageInfo.module = vertShaderModule
    vertShaderStageInfo.pName = "main"

    fragShaderStageInfo := vk.PipelineShaderStageCreateInfo{}
    fragShaderStageInfo.sType = .PIPELINE_SHADER_STAGE_CREATE_INFO
    fragShaderStageInfo.stage = {.FRAGMENT}
    fragShaderStageInfo.module = fragShaderModule
    fragShaderStageInfo.pName = "main"

    shaderStages := [?]vk.PipelineShaderStageCreateInfo{vertShaderStageInfo, fragShaderStageInfo}

    dynamicStates := [?]vk.DynamicState{.VIEWPORT, .SCISSOR}
    dynamicState := vk.PipelineDynamicStateCreateInfo{}
    dynamicState.sType = .PIPELINE_DYNAMIC_STATE_CREATE_INFO
    dynamicState.dynamicStateCount = len(dynamicStates)
    dynamicState.pDynamicStates = &dynamicStates[0]

    vertexInputInfo := vk.PipelineVertexInputStateCreateInfo{}
    vertexInputInfo.sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO
    vertexInputInfo.vertexBindingDescriptionCount = 0
    vertexInputInfo.pVertexBindingDescriptions = nil // Optional
    vertexInputInfo.vertexAttributeDescriptionCount = 0
    vertexInputInfo.pVertexAttributeDescriptions = nil // Optional

    inputAssembly := vk.PipelineInputAssemblyStateCreateInfo{}
    inputAssembly.sType = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO
    inputAssembly.topology = vk.PrimitiveTopology.TRIANGLE_LIST
    inputAssembly.primitiveRestartEnable = false

    viewport := vk.Viewport{}
    viewport.x = 0
    viewport.y = 0
    viewport.width = f32(swapChainExtent.width)
    viewport.height = f32(swapChainExtent.height)
    viewport.minDepth = 0
    viewport.maxDepth = 1

    scissor := vk.Rect2D{}
    scissor.offset = {0, 0}
    scissor.extent = swapChainExtent

    viewportState := vk.PipelineViewportStateCreateInfo{}
    viewportState.sType = .PIPELINE_VIEWPORT_STATE_CREATE_INFO
    viewportState.viewportCount = 1
    viewportState.pViewports = &viewport
    viewportState.scissorCount = 1
    viewportState.pScissors = &scissor

    rasterizer := vk.PipelineRasterizationStateCreateInfo{}
    rasterizer.sType = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO
    rasterizer.depthClampEnable = false
    rasterizer.rasterizerDiscardEnable = false
    rasterizer.polygonMode = .FILL
    rasterizer.lineWidth = 1
    rasterizer.cullMode = {.BACK}
    rasterizer.frontFace = .CLOCKWISE
    rasterizer.depthBiasEnable = false
    rasterizer.depthBiasConstantFactor = 0 // Optional
    rasterizer.depthBiasClamp = 0 // Optional
    rasterizer.depthBiasSlopeFactor = 0 // Optional

    multisampling := vk.PipelineMultisampleStateCreateInfo{}
    multisampling.sType = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO
    multisampling.sampleShadingEnable = false
    multisampling.rasterizationSamples = {._1}
    multisampling.minSampleShading = 1 // Optional
    multisampling.pSampleMask = nil // Optional
    multisampling.alphaToCoverageEnable = false // Optional
    multisampling.alphaToOneEnable = false // Optional

    colorBlendAttachment := vk.PipelineColorBlendAttachmentState{}
    colorBlendAttachment.colorWriteMask = {.R, .G, .B, .A}
    colorBlendAttachment.blendEnable = false
    colorBlendAttachment.srcColorBlendFactor = .ONE // Optional
    colorBlendAttachment.dstColorBlendFactor = .ZERO // Optional
    colorBlendAttachment.colorBlendOp = .ADD // Optional
    colorBlendAttachment.srcAlphaBlendFactor = .ONE // Optional
    colorBlendAttachment.dstAlphaBlendFactor = .ZERO // Optional
    colorBlendAttachment.alphaBlendOp = .ADD // Optional

    colorBlending := vk.PipelineColorBlendStateCreateInfo{}
    colorBlending.sType = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO
    colorBlending.logicOpEnable = false
    colorBlending.logicOp = .COPY // Optional
    colorBlending.attachmentCount = 1
    colorBlending.pAttachments = &colorBlendAttachment
    colorBlending.blendConstants[0] = 0 // Optional
    colorBlending.blendConstants[1] = 0 // Optional
    colorBlending.blendConstants[2] = 0 // Optional
    colorBlending.blendConstants[3] = 0 // Optional

    pipelineLayoutInfo := vk.PipelineLayoutCreateInfo{}
    pipelineLayoutInfo.sType = .PIPELINE_LAYOUT_CREATE_INFO
    pipelineLayoutInfo.setLayoutCount = 0 // Optional
    pipelineLayoutInfo.pSetLayouts = nil // Optional
    pipelineLayoutInfo.pushConstantRangeCount = 0 // Optional
    pipelineLayoutInfo.pPushConstantRanges = nil // Optional

    if (vk.CreatePipelineLayout(device, &pipelineLayoutInfo, nil, &handles.pipelineLayout) !=
           .SUCCESS) {
        log.error("Failed to create pipeline layout")
        return
    }

    pipelineInfo := vk.GraphicsPipelineCreateInfo{}
    pipelineInfo.sType = .GRAPHICS_PIPELINE_CREATE_INFO
    pipelineInfo.stageCount = 2
    pipelineInfo.pStages = &shaderStages[0]
    pipelineInfo.pVertexInputState = &vertexInputInfo
    pipelineInfo.pInputAssemblyState = &inputAssembly
    pipelineInfo.pViewportState = &viewportState
    pipelineInfo.pRasterizationState = &rasterizer
    pipelineInfo.pMultisampleState = &multisampling
    pipelineInfo.pDepthStencilState = nil // Optional
    pipelineInfo.pColorBlendState = &colorBlending
    pipelineInfo.pDynamicState = &dynamicState
    pipelineInfo.layout = handles.pipelineLayout
    pipelineInfo.renderPass = renderPass
    pipelineInfo.subpass = 0
    pipelineInfo.basePipelineIndex = -1 // Optional

    if (vk.CreateGraphicsPipelines(device, 0, 1, &pipelineInfo, nil, &handles.graphicsPipeline) !=
           .SUCCESS) {
        log.error("Failed to create graphics pipeline")
    }

    return handles, true
}

create_framebuffers :: proc(
    swapchain: Swapchain,
    renderPass: vk.RenderPass,
    device: vk.Device,
) -> (
    framebuffers: []vk.Framebuffer,
    ok: bool,
) {
    framebuffers = make([]vk.Framebuffer, len(swapchain.imageViews))

    for &buffer, i in framebuffers {
        attachments := [?]vk.ImageView{swapchain.imageViews[i]}

        framebufferInfo := vk.FramebufferCreateInfo{}
        framebufferInfo.sType = .FRAMEBUFFER_CREATE_INFO
        framebufferInfo.renderPass = renderPass
        framebufferInfo.attachmentCount = 1
        framebufferInfo.pAttachments = &attachments[0]
        framebufferInfo.width = swapchain.extent.width
        framebufferInfo.height = swapchain.extent.height
        framebufferInfo.layers = 1

        if (vk.CreateFramebuffer(device, &framebufferInfo, nil, &buffer) != .SUCCESS) {
            log.error("Failed to create framebuffer")
            return
        }
    }

    return framebuffers, true
}

create_command_pool :: proc(
    physicalDevice: vk.PhysicalDevice,
    surface: vk.SurfaceKHR,
    device: vk.Device,
) -> (
    commandPool: vk.CommandPool,
    ok: bool,
) {
    queueFamilyIndices := find_queue_families(physicalDevice, surface)

    poolInfo := vk.CommandPoolCreateInfo{}
    poolInfo.sType = .COMMAND_POOL_CREATE_INFO
    poolInfo.flags = {.RESET_COMMAND_BUFFER}
    poolInfo.queueFamilyIndex = queueFamilyIndices.graphicsFamily.(u32)

    if (vk.CreateCommandPool(device, &poolInfo, nil, &commandPool) != .SUCCESS) {
        log.error("Failed to create command pool")
    }

    return commandPool, true
}

create_command_buffers :: proc(
    device: vk.Device,
    commandPool: vk.CommandPool,
) -> (
    commandBuffers: [MAX_FRAMES_IN_FLIGHT]vk.CommandBuffer,
    ok: bool,
) {
    allocInfo := vk.CommandBufferAllocateInfo{}
    allocInfo.sType = .COMMAND_BUFFER_ALLOCATE_INFO
    allocInfo.commandPool = commandPool
    allocInfo.level = .PRIMARY
    allocInfo.commandBufferCount = len(commandBuffers)

    if (vk.AllocateCommandBuffers(device, &allocInfo, &commandBuffers[0]) != .SUCCESS) {
        log.error("Failed to allocate command buffers")
        return
    }

    return commandBuffers, true
}

record_command_buffer :: proc(
    commandBuffer: vk.CommandBuffer,
    renderPass: vk.RenderPass,
    swapchain: Swapchain,
    graphicsPipeline: vk.Pipeline,
    imageIndex: u32,
) -> (
    ok: bool,
) {
    beginInfo := vk.CommandBufferBeginInfo{}
    beginInfo.sType = .COMMAND_BUFFER_BEGIN_INFO
    beginInfo.flags = nil // Optional
    beginInfo.pInheritanceInfo = nil // Optional

    if (vk.BeginCommandBuffer(commandBuffer, &beginInfo) != .SUCCESS) {
        log.error("Failed to begin recording command buffer!")
        return
    }

    renderPassInfo := vk.RenderPassBeginInfo{}
    renderPassInfo.sType = .RENDER_PASS_BEGIN_INFO
    renderPassInfo.renderPass = renderPass
    renderPassInfo.framebuffer = swapchain.framebuffers[imageIndex]
    renderPassInfo.renderArea.offset = {0, 0}
    renderPassInfo.renderArea.extent = swapchain.extent

    clearColor := vk.ClearValue {
        color = {float32 = {0, 0, 0, 1}},
    }
    renderPassInfo.clearValueCount = 1
    renderPassInfo.pClearValues = &clearColor


    vk.CmdBeginRenderPass(commandBuffer, &renderPassInfo, .INLINE)
    vk.CmdBindPipeline(commandBuffer, .GRAPHICS, graphicsPipeline)

    viewport := vk.Viewport{}
    viewport.x = 0
    viewport.y = 0
    viewport.width = f32(swapchain.extent.width)
    viewport.height = f32(swapchain.extent.height)
    viewport.minDepth = 0
    viewport.maxDepth = 1
    vk.CmdSetViewport(commandBuffer, 0, 1, &viewport)

    scissor := vk.Rect2D{}
    scissor.offset = {0, 0}
    scissor.extent = swapchain.extent
    vk.CmdSetScissor(commandBuffer, 0, 1, &scissor)

    vk.CmdDraw(commandBuffer, 3, 1, 0, 0)

    vk.CmdEndRenderPass(commandBuffer)
    if vk.EndCommandBuffer(commandBuffer) != .SUCCESS {
        log.error("Failed to record command buffer")
    }

    return true
}

create_sync_objects :: proc(
    device: vk.Device,
) -> (
    syncObjects: [MAX_FRAMES_IN_FLIGHT]SyncObjects,
    ok: bool,
) {
    semaphoreInfo := vk.SemaphoreCreateInfo{}
    semaphoreInfo.sType = .SEMAPHORE_CREATE_INFO
    fenceInfo := vk.FenceCreateInfo{}
    fenceInfo.sType = .FENCE_CREATE_INFO
    fenceInfo.flags = {.SIGNALED}

    for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
        if (vk.CreateSemaphore(
                   device,
                   &semaphoreInfo,
                   nil,
                   &syncObjects[i].imageAvailableSemaphore,
               ) !=
                   .SUCCESS ||
               vk.CreateSemaphore(
                   device,
                   &semaphoreInfo,
                   nil,
                   &syncObjects[i].renderFinishedSemaphore,
               ) !=
                   .SUCCESS ||
               vk.CreateFence(device, &fenceInfo, nil, &syncObjects[i].inFlightFence) !=
                   .SUCCESS) {

            log.error("Failed to create semaphores")
            return
        }
    }

    return syncObjects, true
}

init_vulkan :: proc(window: ^sdl2.Window) -> (v: VulkanHandles, ok: bool) {
    v.instance = create_vulkan_instance(window) or_return
    v.debugMessenger = setup_debug_messenger(v.instance) or_return
    v.surface = create_surface(window, v.instance) or_return
    v.physicalDevice = pick_physical_device(v.instance, v.surface) or_return
    v.logicalDeviceHandles = create_logical_device(v.physicalDevice, v.surface) or_return
    v.swapchain = create_swap_chain(window, v.physicalDevice, v.device, v.surface) or_return
    v.swapchain.imageViews = create_image_views(v.device, v.swapchain) or_return
    v.renderPass = create_render_pass(v.device, v.swapchain.imageFormat) or_return
    v.graphicsPipelineHandles = create_graphics_pipeline(
        v.device,
        v.renderPass,
        v.swapchain.extent,
    ) or_return
    v.swapchain.framebuffers = create_framebuffers(v.swapchain, v.renderPass, v.device) or_return
    v.commandPool = create_command_pool(v.physicalDevice, v.surface, v.device) or_return
    v.commandBuffers = create_command_buffers(v.device, v.commandPool) or_return
    v.syncObjects = create_sync_objects(v.device) or_return

    return v, true
}

cleanup_swapchain :: proc(device: vk.Device, s: Swapchain) {
    for buffer in s.framebuffers {
        vk.DestroyFramebuffer(device, buffer, nil)
    }

    for imageView in s.imageViews {
        vk.DestroyImageView(device, imageView, nil)
    }

    delete(s.images)
    delete(s.imageViews)
    delete(s.framebuffers)
    vk.DestroySwapchainKHR(device, s.handle, nil)
}

destroy_vulkan :: proc(v: VulkanHandles) {
    cleanup_swapchain(v.device, v.swapchain)
    vk.DestroyPipeline(v.device, v.graphicsPipeline, nil)
    vk.DestroyPipelineLayout(v.device, v.pipelineLayout, nil)
    vk.DestroyRenderPass(v.device, v.renderPass, nil)

    for s in v.syncObjects {
        vk.DestroySemaphore(v.device, s.imageAvailableSemaphore, nil)
        vk.DestroySemaphore(v.device, s.renderFinishedSemaphore, nil)
        vk.DestroyFence(v.device, s.inFlightFence, nil)
    }

    vk.DestroyCommandPool(v.device, v.commandPool, nil)
    vk.DestroyDevice(v.device, nil)

    if ENABLE_VALIDATION_LAYERS {
        vk.DestroyDebugUtilsMessengerEXT(v.instance, v.debugMessenger, nil)
    }

    vk.DestroySurfaceKHR(v.instance, v.surface, nil)
    vk.DestroyInstance(v.instance, nil)
}

draw :: proc(
    v: ^VulkanHandles,
    window: ^sdl2.Window,
    framebufferResized: ^bool,
    currentFrame: ^u32,
) -> (
    ok: bool,
) {
    sync := v.syncObjects[currentFrame^]
    commandBuffer := v.commandBuffers[currentFrame^]

    vk.WaitForFences(v.device, 1, &sync.inFlightFence, true, max(u64))

    imageIndex: u32
    res := vk.AcquireNextImageKHR(
        v.device,
        v.swapchain.handle,
        max(u64),
        sync.imageAvailableSemaphore,
        0,
        &imageIndex,
    )

    if res == .ERROR_OUT_OF_DATE_KHR {
        recreate_swapchain(window, v) or_return
    } else if (res != .SUCCESS && res != .SUBOPTIMAL_KHR) {
        log.error("Failed to acquire swap chain image")
        return
    }

    vk.ResetFences(v.device, 1, &sync.inFlightFence)

    vk.ResetCommandBuffer(v.commandBuffers[currentFrame^], {})
    record_command_buffer(
        v.commandBuffers[currentFrame^],
        v.renderPass,
        v.swapchain,
        v.graphicsPipeline,
        imageIndex,
    )

    submitInfo := vk.SubmitInfo{}
    submitInfo.sType = .SUBMIT_INFO

    waitSemaphores := [?]vk.Semaphore{sync.imageAvailableSemaphore}
    waitStages: vk.PipelineStageFlags = {.COLOR_ATTACHMENT_OUTPUT}
    submitInfo.waitSemaphoreCount = 1
    submitInfo.pWaitSemaphores = &waitSemaphores[0]
    submitInfo.pWaitDstStageMask = &waitStages
    submitInfo.commandBufferCount = 1
    submitInfo.pCommandBuffers = &commandBuffer

    signalSemaphores := [?]vk.Semaphore{sync.renderFinishedSemaphore}
    submitInfo.signalSemaphoreCount = 1
    submitInfo.pSignalSemaphores = &signalSemaphores[0]

    if (vk.QueueSubmit(v.graphicsQueue, 1, &submitInfo, sync.inFlightFence) != .SUCCESS) {
        log.error("Failed to submit draw command buffer")
    }

    presentInfo := vk.PresentInfoKHR{}
    presentInfo.sType = .PRESENT_INFO_KHR
    presentInfo.waitSemaphoreCount = 1
    presentInfo.pWaitSemaphores = &signalSemaphores[0]

    swapChains := [?]vk.SwapchainKHR{v.swapchain.handle}
    presentInfo.swapchainCount = 1
    presentInfo.pSwapchains = &swapChains[0]
    presentInfo.pImageIndices = &imageIndex
    presentInfo.pResults = nil

    res = vk.QueuePresentKHR(v.presentQueue, &presentInfo)

    if res == .ERROR_OUT_OF_DATE_KHR || res == .SUBOPTIMAL_KHR || framebufferResized^ {
        framebufferResized^ = false
        recreate_swapchain(window, v) or_return
    } else if res != .SUCCESS {
        log.error("Failed to present swap chain image")
        return
    }

    currentFrame^ = (currentFrame^ + 1) % MAX_FRAMES_IN_FLIGHT
    return true
}

main :: proc() {
    context.logger = log.create_console_logger()

    ctx := CTX{}

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
    if ctx.window, ok = init_window(&ctx.framebufferResized); !ok {
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

        draw(&ctx.vulkanHandles, ctx.window, &ctx.framebufferResized, &ctx.currentFrame)
        vk.DeviceWaitIdle(ctx.device)
    }

    destroy_vulkan(ctx.vulkanHandles)
    sdl2.DestroyWindow(ctx.window)
    sdl2.Quit()
}
