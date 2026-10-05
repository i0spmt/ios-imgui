//
//  TSImGuiView.mm
//  TrollSpeed
//
//  Created by Lessica on 2024/10/4.
//

#import "TSImGuiView.h"

#import <Metal/Metal.h>

#import "imgui.h"
#import "imgui_internal.h"
#import "backends/imgui_impl_metal.h"

// MTKView is forward declared with a minimal interface so the prefix header
// stays free of MetalKit — the framework is linked in the Makefile and
// resolved by the Objective-C runtime at launch.
@class MTKView;

@protocol MTKViewDelegate <NSObject>
- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size;
- (void)drawInMTKView:(MTKView *)view;
@end

@interface MTKView : UIView
@property (nullable, nonatomic, strong) id<MTLDevice> device;
@property (nullable, nonatomic, weak) id<MTKViewDelegate> delegate;
@property (nonatomic) MTLClearColor clearColor;
@property (nullable, nonatomic, readonly) id<CAMetalDrawable> currentDrawable;
@property (nullable, nonatomic, readonly) MTLRenderPassDescriptor *currentRenderPassDescriptor;
@property (nonatomic) NSInteger preferredFramesPerSecond;
@property (nonatomic, getter=isPaused) BOOL paused;
@property (nonatomic) BOOL enableSetNeedsDisplay;
@end

#pragma mark -

// Rect of the floating ImGui window in view-local coordinates, refreshed on
// every frame. hitTest only captures touches that fall inside this rect, so
// anything else keeps passing through to whatever is underneath.
static CGRect _TSImGuiWindowRect = CGRectZero;

// Single ImGui context owned by this view. SetCurrentContext at the top of
// each frame keeps the right one active even when something else swaps it.
static ImGuiContext *_TSImGuiMainContext = nullptr;

// Display size seen on the previous frame, used to notice a rotation.
static ImVec2 _TSLastDisplaySize = ImVec2(0.0f, 0.0f);

// The GPU device is not reliably available while the HUD is still starting up,
// so acquiring it is retried instead of failing outright.
static const NSInteger kTSImGuiMaxMetalAttempts = 20;
static const NSTimeInterval kTSImGuiMetalRetryDelay = 0.5;

#pragma mark - Pointer queue

// Pointer transitions are QUEUED rather than sampled by the frame. A whole tap
// can land between two draws while the main queue is busy, and sampling the
// current state would miss it entirely. A frame consumes at most ONE button
// change, so press and release always land in different frames and neither is
// swallowed.
struct TSPointerEvent {
    CGPoint p;
    BOOL down;
};

static const int kTSPointerQueueCap = 32;
static TSPointerEvent _TSPointerQueue[kTSPointerQueueCap];
static int _TSPointerHead = 0;
static int _TSPointerTail = 0;
static CGPoint _TSPointerPos = {0.0, 0.0};
static BOOL _TSPointerDown = NO;
static CFTimeInterval _TSPointerEventTime = 0.0;
static CFTimeInterval _TSPointerDownTime = 0.0;

// The view the injected window coordinates are converted into.
static __weak UIView *_TSImGuiHostView = nil;
// pathIdentity of the finger the AX path is currently following.
static NSInteger _TSAxPointer = -1;


static void TSPushPointer(CGPoint p, BOOL down)
{
    _TSPointerEventTime = CACurrentMediaTime();

    // Movement without a button change collapses into the last entry,
    // otherwise dragging a window would flood the queue and only add lag.
    const int prev = (_TSPointerTail - 1 + kTSPointerQueueCap) % kTSPointerQueueCap;
    if (_TSPointerTail != _TSPointerHead && _TSPointerQueue[prev].down == down) {
        _TSPointerQueue[prev].p = p;
        return;
    }

    const int next = (_TSPointerTail + 1) % kTSPointerQueueCap;
    if (next == _TSPointerHead) {
        _TSPointerHead = (_TSPointerHead + 1) % kTSPointerQueueCap;   // drop oldest
    }
    _TSPointerQueue[_TSPointerTail].p = p;
    _TSPointerQueue[_TSPointerTail].down = down;
    _TSPointerTail = next;
}

#pragma mark - AX injection

void TSImGuiInjectTouch(CGPoint windowPoint, NSInteger phase,
                        NSInteger pointerId, UIWindow *window)
{
    UIView *host = _TSImGuiHostView;
    if (!host || !window) {
        return;
    }

    if (CGRectIsEmpty(_TSImGuiWindowRect)) {
        // Menu is closed: nothing here is ours. Re-opening is owned by the
        // hotspot view in HUDRootViewController, which gets the tap through
        // the regular UIKit delivery.
        return;
    }

    const BOOL isActivePhase = (phase != UITouchPhaseEnded && phase != UITouchPhaseCancelled);
    const CGPoint localPoint = [host convertPoint:windowPoint fromView:window];
    const BOOL insideWindow = CGRectContainsPoint(_TSImGuiWindowRect, localPoint);

    // One finger owns the pointer. A touch that starts outside the ImGui
    // window is none of our business — it belongs to whatever is underneath,
    // and claiming it here is what would make the overlay swallow taps it
    // should let through.
    if (phase == UITouchPhaseBegan) {
        if (!insideWindow) {
            return;
        }
        _TSAxPointer = pointerId;
    } else if (_TSAxPointer >= 0) {
        if (pointerId != _TSAxPointer) {
            return;
        }
        // Deliberately NOT re-checking insideWindow: once a drag owns the
        // pointer it must keep receiving moves after the finger leaves the
        // window, otherwise dragging the title bar stops half-way.
    } else {
        return;     // tail of a touch we never owned
    }

    if (!isActivePhase) {
        _TSAxPointer = -1;
    }

    TSPushPointer(localPoint, isActivePhase);
}

#pragma mark -

@interface TSImGuiView () <MTKViewDelegate>
@end

@implementation TSImGuiView {
    MTKView *_mtkView;
    id<MTLDevice> _device;
    id<MTLCommandQueue> _commandQueue;

    BOOL _imguiReady;
    BOOL _menuVisible;
    BOOL _espEnabled;
    NSInteger _metalAttempts;

    UITouch *__weak _trackedTouch;
}

- (instancetype)initWithFrame:(CGRect)frame
{
    // The caller passes the HUD root view bounds, but that is often zero in
    // viewDidLoad. Fall back to the main screen rect so the Metal view and
    // the ImGui display size are always non-zero on the very first frame.
    if (CGRectIsEmpty(frame)) {
        frame = [UIScreen mainScreen].bounds;
    }

    self = [super initWithFrame:frame];
    if (!self) {
        return nil;
    }

    self.backgroundColor = [UIColor clearColor];
    self.opaque = NO;
    self.userInteractionEnabled = YES;
    self.multipleTouchEnabled = YES;
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    // Metal is NOT touched here. viewDidLoad runs before the HUD window is
    // registered with SpringBoard and before the run loop starts, and the GPU
    // device is not available that early — so setup is deferred and retried.
    [self scheduleMetalSetup];

    return self;
}

- (void)dealloc
{
    if (_imguiReady) {
        ImGui_ImplMetal_Shutdown();
        if (_TSImGuiMainContext) {
            ImGui::DestroyContext(_TSImGuiMainContext);
            _TSImGuiMainContext = nullptr;
        }
    }
}

#pragma mark - Deferred Metal setup

- (void)scheduleMetalSetup
{
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf attemptMetalSetup];
    });
}

- (void)attemptMetalSetup
{
    if (_mtkView) {
        return;
    }

    _metalAttempts++;

    _device = MTLCreateSystemDefaultDevice();
    if (!_device) {
        if (_metalAttempts < kTSImGuiMaxMetalAttempts) {
            __weak typeof(self) weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(kTSImGuiMetalRetryDelay * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [weakSelf attemptMetalSetup];
            });
        }
        return;
    }

    _commandQueue = [_device newCommandQueue];
    if (!_commandQueue) {
        return;
    }

    Class mtkClass = NSClassFromString(@"MTKView");
    if (!mtkClass) {
        return;
    }

    CGRect viewBounds = CGRectIsEmpty(self.bounds) ? [UIScreen mainScreen].bounds : self.bounds;
    _mtkView = (MTKView *)[[mtkClass alloc] initWithFrame:viewBounds];
    _mtkView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _mtkView.device = _device;
    _mtkView.delegate = self;
    _mtkView.clearColor = MTLClearColorMake(0, 0, 0, 0);
    _mtkView.opaque = NO;
    _mtkView.backgroundColor = [UIColor clearColor];
    _mtkView.preferredFramesPerSecond = 60;
    // Touches are handled by this wrapper, whose hitTest gates them on the
    // ImGui window rect. The Metal view must never claim one itself — a
    // full-screen interactive subview inside a hit-testing window is exactly
    // what makes an overlay swallow the whole screen.
    _mtkView.userInteractionEnabled = NO;
    [self addSubview:_mtkView];
    _TSImGuiHostView = _mtkView;

    [self setupImGui];
}

- (void)setupImGui
{
    IMGUI_CHECKVERSION();
    // Take the context CreateContext returns and bind it explicitly. It
    // restores whichever context was current before, so with a second ImGui
    // layer in the process GetCurrentContext() here would hand back that other
    // context — and everything below, including ImGui_ImplMetal_Init, would be
    // applied to the wrong one.
    _TSImGuiMainContext = ImGui::CreateContext();
    ImGui::SetCurrentContext(_TSImGuiMainContext);

    ImGuiIO &io = ImGui::GetIO();
    io.IniFilename = NULL;
    io.LogFilename = NULL;
    io.ConfigFlags |= ImGuiConfigFlags_IsTouchScreen;
    io.ConfigFlags |= ImGuiConfigFlags_NavNoCaptureKeyboard;
    io.MouseDrawCursor = false;
    // Without this a single draw list overflows 16-bit vertex indices and the
    // Metal backend crashes once the UI grows.
    io.BackendFlags |= ImGuiBackendFlags_RendererHasVtxOffset;

    // Resize from the corner grip only. Dragging an edge is far too easy to
    // trigger by accident with a finger, while the corner grip stays usable.
    // This flag gates the edges alone — the grip is counted separately.
    io.ConfigWindowsResizeFromEdges = false;

    ImGuiStyle &style = ImGui::GetStyle();
    style.TouchExtraPadding = ImVec2(8.0f, 8.0f);
    style.AntiAliasedLines = true;
    style.AntiAliasedLinesUseTex = true;
    style.AntiAliasedFill = true;
    ImGui::StyleColorsDark();

    io.Fonts->AddFontDefault();

    ImGui_ImplMetal_Init(_device);
    _imguiReady = YES;
}

#pragma mark - Visibility

- (void)setMenuVisible:(BOOL)visible
{
    const BOOL changed = (_menuVisible != visible);
    _menuVisible = visible;

    // Hide the view outright when the menu is closed, rather than relying on
    // hitTest alone. A hidden view takes no part in hit testing at all, which
    // closes off any delivery path that does not go through the public
    // hitTest:withEvent: — and leaves the screen under the HUD fully live.
    self.hidden = !visible;
    self.userInteractionEnabled = visible;

    if (changed && self.menuVisibilityChanged) {
        self.menuVisibilityChanged(visible);
    }

    if (visible && CGRectIsEmpty(_TSImGuiWindowRect)) {
        // Seed the hit rect with the default window geometry so a tap placed
        // on the window right after it opens is captured even before the first
        // draw has published the real rect.
        CGRect bounds = CGRectIsEmpty(self.bounds) ? [UIScreen mainScreen].bounds : self.bounds;
        const CGFloat w = MIN(460.0f, bounds.size.width - 24.0f);
        const CGFloat h = MIN(320.0f, bounds.size.height - 24.0f);
        _TSImGuiWindowRect = CGRectMake((bounds.size.width - w) * 0.5f,
                                        (bounds.size.height - h) * 0.5f,
                                        w, h);
    }
    if (!visible) {
        _TSImGuiWindowRect = CGRectZero;
    }
}

- (BOOL)isMenuVisible
{
    return _menuVisible;
}

#pragma mark - Hit testing

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event
{
    // Taps outside the ImGui window must fall through — return nil so UIKit
    // asks the view underneath. Only taps inside the window rect are ours,
    // and once the menu is closed nothing is.
    if (!_menuVisible || !_imguiReady) {
        return nil;
    }
    if (CGRectIsEmpty(_TSImGuiWindowRect)) {
        return nil;
    }
    if (CGRectContainsPoint(_TSImGuiWindowRect, point)) {
        return self;
    }
    return nil;
}

#pragma mark - Touches

// ImGui is a one-pointer UI, so exactly one contact is followed — our own.
//
// event.allTouches must NOT be used here. In the HUD process it also contains
// phantoms out of the TSEventFetcher pool: those synthetic UITouch objects live
// for the lifetime of the process, and when an Ended is lost (AX reuses
// pathIdentity and delivers events in batches) the contact stays in the set
// forever at Stationary. After that "pressed" is permanently true and
// anyObject hands back the phantom's coordinate just as often as the real one.
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    // Newest contact of the set. NSSet iteration order is arbitrary, so pick
    // by timestamp rather than "whichever came first".
    UITouch *pick = nil;
    for (UITouch *t in touches) {
        if (t.phase == UITouchPhaseEnded || t.phase == UITouchPhaseCancelled) {
            continue;
        }
        if (!pick || t.timestamp >= pick.timestamp) {
            pick = t;
        }
    }
    if (!pick) {
        return;
    }
    _trackedTouch = pick;
    TSPushPointer([pick locationInView:(_mtkView ?: self)], YES);
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    UITouch *t = _trackedTouch;
    if (!t || ![touches containsObject:t]) {
        return;     // somebody else's finger, not our pointer
    }
    TSPushPointer([t locationInView:(_mtkView ?: self)], YES);
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    [self finishTouches:touches];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    [self finishTouches:touches];
}

- (void)finishTouches:(NSSet<UITouch *> *)touches
{
    UITouch *t = _trackedTouch;
    if (!t || ![touches containsObject:t]) {
        return;
    }
    _trackedTouch = nil;
    _TSAxPointer = -1;
    TSPushPointer([t locationInView:(_mtkView ?: self)], NO);
}

#pragma mark - MTKViewDelegate

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size
{
    (void)view;
    (void)size;
}

- (void)drawInMTKView:(MTKView *)view
{
    if (!_imguiReady) {
        return;
    }
    if (_TSImGuiMainContext) {
        ImGui::SetCurrentContext(_TSImGuiMainContext);
    }

    ImGuiIO &io = ImGui::GetIO();
    io.ConfigFlags |= ImGuiConfigFlags_IsTouchScreen;

    const CFTimeInterval now = CACurrentMediaTime();

    // Drain the pointer queue. Every event moves the position, but at most one
    // button change is applied per frame — otherwise a tap that fits entirely
    // between two frames would collapse into "nothing happened".
    BOOL buttonChangedThisFrame = NO;
    while (_TSPointerHead != _TSPointerTail) {
        const TSPointerEvent ev = _TSPointerQueue[_TSPointerHead];
        if (ev.down != _TSPointerDown) {
            if (buttonChangedThisFrame) {
                break;                      // the rest belongs to the next frame
            }
            _TSPointerDown = ev.down;
            buttonChangedThisFrame = YES;
            if (_TSPointerDown) {
                _TSPointerDownTime = now;
            }
        }
        _TSPointerPos = ev.p;
        _TSPointerHead = (_TSPointerHead + 1) % kTSPointerQueueCap;
    }

    // Safety net for a stuck pointer: ImGui still holds the button while the
    // finger is long gone. A live hold keeps moving and sending events, so a
    // couple of seconds of total silence means a lost Ended. A non-empty queue
    // is exempt — events are still arriving, so the state resolves by itself.
    if (_TSPointerDown && _TSPointerHead == _TSPointerTail) {
        const BOOL silentTooLong = (now - _TSPointerDownTime > 2.0) &&
                                   (now - _TSPointerEventTime > 1.5);
        if (silentTooLong) {
            _TSPointerDown = NO;
            _trackedTouch = nil;
            _TSAxPointer = -1;
        }
    }

    CGSize boundsSize = view.bounds.size;
    io.DisplaySize = ImVec2((float)boundsSize.width, (float)boundsSize.height);

    // This has to match the real drawableSize / bounds.size ratio, or ImGui
    // computes wrong scissor rects and the UI comes out clipped. contentScaleFactor
    // is by definition the factor Metal applied, unlike screen.scale which
    // differs from it on downsampled displays (Plus / XR / mini models).
    CGFloat framebufferScale = view.contentScaleFactor;
    if (framebufferScale <= 0.0) {
        framebufferScale = [UIScreen mainScreen].nativeScale;
    }
    if (framebufferScale <= 0.0) {
        framebufferScale = 2.0;
    }
    io.DisplayFramebufferScale = ImVec2(framebufferScale, framebufferScale);
    io.DeltaTime = 1.0f / 60.0f;

    io.MousePos = ImVec2((float)_TSPointerPos.x, (float)_TSPointerPos.y);
    io.MouseDown[0] = _TSPointerDown;

    MTLRenderPassDescriptor *renderPassDescriptor = view.currentRenderPassDescriptor;
    if (!renderPassDescriptor) {
        return;
    }

    id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
    id<MTLRenderCommandEncoder> renderEncoder =
        [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];

    ImGui_ImplMetal_NewFrame(renderPassDescriptor);
    ImGui::NewFrame();

    [self drawMenu];

    ImGui::Render();
    ImGui_ImplMetal_RenderDrawData(ImGui::GetDrawData(), commandBuffer, renderEncoder);

    [renderEncoder endEncoding];

    id<CAMetalDrawable> drawable = view.currentDrawable;
    if (drawable) {
        [commandBuffer presentDrawable:drawable];
    }
    [commandBuffer commit];
}

- (void)drawMenu
{
    if (!_menuVisible) {
        _TSImGuiWindowRect = CGRectZero;
        return;
    }

    ImGuiIO &io = ImGui::GetIO();

    // Keep the window inside the screen: 460 wide does not fit a 430pt phone,
    // and the overhang put the title bar partly off-screen.
    float windowW = MIN(460.0f, io.DisplaySize.x - 24.0f);
    float windowH = MIN(320.0f, io.DisplaySize.y - 24.0f);

    ImGuiWindow *existing = ImGui::FindWindowByName("imgui");
    if (!existing) {
        ImGui::SetNextWindowPos(ImVec2((io.DisplaySize.x - windowW) * 0.5f,
                                       (io.DisplaySize.y - windowH) * 0.5f),
                                ImGuiCond_FirstUseEver);
        ImGui::SetNextWindowSize(ImVec2(windowW, windowH), ImGuiCond_FirstUseEver);
    } else if (fabsf(_TSLastDisplaySize.x - io.DisplaySize.x) > 0.5f ||
               fabsf(_TSLastDisplaySize.y - io.DisplaySize.y) > 0.5f) {
        // The screen just changed shape — a rotation. ImGui keeps window
        // positions in absolute coordinates and never clamps them itself, so a
        // window that sat comfortably in portrait can end up completely off
        // screen once the height collapses in landscape. Pull it back in.
        ImVec2 size = existing->Size;
        size.x = ImMin(size.x, windowW);
        size.y = ImMin(size.y, windowH);
        ImGui::SetNextWindowSize(size, ImGuiCond_Always);

        ImVec2 pos = existing->Pos;
        pos.x = ImClamp(pos.x, 0.0f, ImMax(0.0f, io.DisplaySize.x - size.x));
        pos.y = ImClamp(pos.y, 0.0f, ImMax(0.0f, io.DisplaySize.y - size.y));
        ImGui::SetNextWindowPos(pos, ImGuiCond_Always);
    }
    _TSLastDisplaySize = io.DisplaySize;

    bool open = _menuVisible;
    // Passing &open draws the standard close box in the title bar; tapping it
    // flips _menuVisible to NO and the overlay stops capturing touches.
    ImGui::Begin("imgui external ios menu example by t.me/iospmt", &open);
  
    

    
    // Drives the shape layer, which renders from its own ImGui context and
    // never takes a touch.
    bool esp = _espEnabled;
    if (ImGui::Checkbox("ESP", &esp) && esp != _espEnabled) {
        _espEnabled = esp;
        if (self.espEnabledChanged) {
            self.espEnabledChanged(esp);
        }
    }

    ImGui::Text("display sizee: %.0f x %.0f", io.DisplaySize.x, io.DisplaySize.y);
    ImGui::Text("fb scale: %.1f", io.DisplayFramebufferScale.x);
    ImGui::Text("fpz:     %.1f", io.Framerate);

    ImVec2 wp = ImGui::GetWindowPos();
    ImVec2 ws = ImGui::GetWindowSize();

    ImGui::End();

    if (!open) {
        // Closed via the title bar's close box. Apply it in THIS frame rather
        // than publishing a live rect and clearing it in the next one: if no
        // further frame arrives, a stale non-empty rect would keep capturing
        // touches forever and the screen below would stay dead.
        [self setMenuVisible:NO];
        return;
    }

    // Publish the window rect so hitTest can let touches outside it fall
    // through to whatever is below.
    _TSImGuiWindowRect = CGRectMake(wp.x, wp.y, ws.x, ws.y);
}

@end
