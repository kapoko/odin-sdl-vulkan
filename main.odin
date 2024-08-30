package main

import "core:log"
import "core:mem"
import "vendor:sdl2"
import vk "vendor:vulkan"

WINDOW_TITLE :: "Vulkan SDL"
VIEW_WIDTH :: 640
VIEW_HEIGHT :: 480
WINDOW_FLAGS :: sdl2.WindowFlags{.SHOWN, .ALLOW_HIGHDPI, .VULKAN}

CTX :: struct {
	window: ^sdl2.Window,
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

slice_to_multi_ptr :: proc(slice: []$T) -> [^]T {
	return cast([^]T)raw_data(slice)
}

init_vulkan :: proc() -> (instance: vk.Instance) {
	getInstanceProcAddr := sdl2.Vulkan_GetVkGetInstanceProcAddr()
	assert(getInstanceProcAddr != nil)

	vk.load_proc_addresses_global(getInstanceProcAddr)
	assert(vk.CreateInstance != nil)

	appInfo := vk.ApplicationInfo{}
	appInfo.sType = .APPLICATION_INFO
	appInfo.pApplicationName = WINDOW_TITLE
	appInfo.applicationVersion = vk.MAKE_VERSION(1, 0, 0)
	appInfo.pEngineName = "No Engine"
	appInfo.engineVersion = vk.MAKE_VERSION(1, 0, 0)
	appInfo.apiVersion = vk.API_VERSION_1_3

	extensionCount: u32
	sdl2.Vulkan_GetInstanceExtensions(ctx.window, &extensionCount, nil)
	//extensionNames := make([^]cstring, extensionCount
	extensionNames := make([dynamic]cstring, extensionCount)
	sdl2.Vulkan_GetInstanceExtensions(ctx.window, &extensionCount, &extensionNames[0])

	createInfo := vk.InstanceCreateInfo{}
	createInfo.sType = vk.StructureType.INSTANCE_CREATE_INFO
	createInfo.pApplicationInfo = &appInfo
	createInfo.enabledLayerCount = 0
	createInfo.enabledExtensionCount = extensionCount
	createInfo.ppEnabledExtensionNames = &extensionNames[0]
	log.warn(extensionNames)

	log.warn(extensionNames[0])
	log.warn(extensionNames[1])
	log.warn(createInfo)

	res := vk.CreateInstance(&createInfo, nil, &instance)
	if res != vk.Result.SUCCESS {
		log.error("Failed to create Vulkan instance")
	}

	return
}

cleanup :: proc() {
	sdl2.DestroyWindow(ctx.window)
	sdl2.Quit()
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
	init_vulkan()

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

	cleanup()
}
