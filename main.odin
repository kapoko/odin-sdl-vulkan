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

SwapChainHandles :: struct {
    swapChain:            vk.SwapchainKHR,
    swapChainImages:      [dynamic]vk.Image,
    swapChainImageViews:  [dynamic]vk.ImageView,
    swapChainImageFormat: vk.Format,
    swapChainExtent:      vk.Extent2D,
}

GraphicsPipelineHandles :: struct {
    pipelineLayout:   vk.PipelineLayout,
    graphicsPipeline: vk.Pipeline,
}

LogicalDeviceHandles :: struct {
    device:                      vk.Device,
    graphicsQueue, presentQueue: vk.Queue,
}

VulkanHandles :: struct {
    instance:                      vk.Instance,
    debugMessenger:                vk.DebugUtilsMessengerEXT,
    surface:                       vk.SurfaceKHR,
    renderPass:                    vk.RenderPass,
    using logicalDeviceHandles:    LogicalDeviceHandles,
    using swapChainHandles:        SwapChainHandles,
    using graphicsPipelineHandles: GraphicsPipelineHandles,
}

CTX :: struct {
    window:              ^sdl2.Window,
    using vulkanHandles: VulkanHandles,
}

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
) -> (
    result: SwapChainHandles,
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

    if (vk.CreateSwapchainKHR(device, &createInfo, nil, &result.swapChain) != .SUCCESS) {
        log.error("Failed to create swap chain")
    }

    vk.GetSwapchainImagesKHR(device, result.swapChain, &imageCount, nil)
    result.swapChainImages = make([dynamic]vk.Image, imageCount)
    vk.GetSwapchainImagesKHR(device, result.swapChain, &imageCount, &result.swapChainImages[0])

    result.swapChainImageFormat = surfaceFormat.format
    result.swapChainExtent = extent

    return result, true
}

create_image_views :: proc(
    device: vk.Device,
    handles: SwapChainHandles,
) -> (
    imageViews: [dynamic]vk.ImageView,
    ok: bool,
) {
    imageViews = make([dynamic]vk.ImageView, len(handles.swapChainImages))

    for image, i in handles.swapChainImages {
        createInfo := vk.ImageViewCreateInfo{}
        createInfo.sType = vk.StructureType.IMAGE_VIEW_CREATE_INFO
        createInfo.image = image
        createInfo.viewType = vk.ImageViewType.D2
        createInfo.format = handles.swapChainImageFormat
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
            log.errorf("Failed to create image view %v/%v!", i, len(handles.swapChainImageViews))
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

    renderPassInfo := vk.RenderPassCreateInfo{}
    renderPassInfo.sType = .RENDER_PASS_CREATE_INFO
    renderPassInfo.attachmentCount = 1
    renderPassInfo.pAttachments = &colorAttachment
    renderPassInfo.subpassCount = 1
    renderPassInfo.pSubpasses = &subpass

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

init_vulkan :: proc(window: ^sdl2.Window) -> (v: VulkanHandles, ok: bool) {
    v.instance = create_vulkan_instance(window) or_return
    v.debugMessenger = setup_debug_messenger(v.instance) or_return
    v.surface = create_surface(window, v.instance) or_return
    physicalDevice := pick_physical_device(v.instance, v.surface) or_return
    v.logicalDeviceHandles = create_logical_device(physicalDevice, v.surface) or_return
    v.swapChainHandles = create_swap_chain(window, physicalDevice, v.device, v.surface) or_return
    v.swapChainImageViews = create_image_views(v.device, v.swapChainHandles) or_return
    v.renderPass = create_render_pass(v.device, v.swapChainImageFormat) or_return
    v.graphicsPipelineHandles = create_graphics_pipeline(
        v.device,
        v.renderPass,
        v.swapChainExtent,
    ) or_return

    return v, true
}

destroy_vulkan :: proc(v: VulkanHandles) {
    if ENABLE_VALIDATION_LAYERS {
        vk.DestroyDebugUtilsMessengerEXT(v.instance, v.debugMessenger, nil)
    }

    for imageView in v.swapChainImageViews {
        vk.DestroyImageView(v.device, imageView, nil)
    }

    delete(v.swapChainImages)
    delete(v.swapChainImageViews)
    vk.DestroyPipeline(v.device, v.graphicsPipeline, nil)
    vk.DestroyPipelineLayout(v.device, v.pipelineLayout, nil)
    vk.DestroyRenderPass(v.device, v.renderPass, nil)
    vk.DestroySwapchainKHR(v.device, v.swapChain, nil)
    vk.DestroyDevice(v.device, nil)
    vk.DestroySurfaceKHR(v.instance, v.surface, nil)
    vk.DestroyInstance(v.instance, nil)
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

    destroy_vulkan(ctx.vulkanHandles)
    sdl2.DestroyWindow(ctx.window)
    sdl2.Quit()
}
