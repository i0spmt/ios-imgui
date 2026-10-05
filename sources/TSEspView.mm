//
//  TSEspView.mm
//  imgui
//

#import "TSEspView.h"

#import <Metal/Metal.h>

#import "imgui.h"
#import "imgui_internal.h"
#import "backends/imgui_impl_metal.h"

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

// This layer owns a context of its own, separate from the menu's. The two draw
// independently, and the Metal backend keeps its state per context, so each
// needs its own ImGui_ImplMetal_Init.
static ImGuiContext *_TSEspContext = nullptr;

static const NSInteger kTSEspMaxMetalAttempts = 20;
static const NSTimeInterval kTSEspMetalRetryDelay = 0.5;

#pragma mark - Pass-through Metal view

@interface TSEspMetalView : MTKView
@end

@implementation TSEspMetalView

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event { return nil; }
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event { return NO; }

@end

#pragma mark -

@interface TSEspView () <MTKViewDelegate>
@end

@implementation TSEspView {
    TSEspMetalView *_mtkView;
    id<MTLDevice> _device;
    id<MTLCommandQueue> _commandQueue;

    BOOL _imguiReady;
    BOOL _espEnabled;
    NSInteger _metalAttempts;
}

- (instancetype)initWithFrame:(CGRect)frame
{
    if (CGRectIsEmpty(frame)) {
        frame = [UIScreen mainScreen].bounds;
    }

    self = [super initWithFrame:frame];
    if (!self) {
        return nil;
    }

    self.backgroundColor = [UIColor clearColor];
    self.opaque = NO;
    self.userInteractionEnabled = NO;
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    // Metal is set up lazily for the same reason as the menu overlay: the GPU
    // device is not available while the HUD process is still starting.
    [self scheduleMetalSetup];

    return self;
}

- (void)dealloc
{
    if (_imguiReady && _TSEspContext) {
        ImGuiContext *prev = ImGui::GetCurrentContext();
        ImGui::SetCurrentContext(_TSEspContext);
        ImGui_ImplMetal_Shutdown();
        ImGui::DestroyContext(_TSEspContext);
        _TSEspContext = nullptr;
        if (prev != nullptr) {
            ImGui::SetCurrentContext(prev);
        }
    }
}

#pragma mark - Hit testing

// Nothing in this layer is interactive. Returning nil here as well as in the
// Metal view keeps the whole subtree out of hit testing, whatever order UIKit
// walks it in.
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event { return nil; }
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event { return NO; }

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
        if (_metalAttempts < kTSEspMaxMetalAttempts) {
            __weak typeof(self) weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(kTSEspMetalRetryDelay * NSEC_PER_SEC)),
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
    _mtkView = (TSEspMetalView *)[[TSEspMetalView alloc] initWithFrame:viewBounds];
    _mtkView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _mtkView.device = _device;
    _mtkView.delegate = self;
    _mtkView.clearColor = MTLClearColorMake(0, 0, 0, 0);
    _mtkView.opaque = NO;
    _mtkView.backgroundColor = [UIColor clearColor];
    _mtkView.preferredFramesPerSecond = 60;
    _mtkView.userInteractionEnabled = NO;
    // Stays parked until the feature is switched on.
    _mtkView.paused = !_espEnabled;
    [self addSubview:_mtkView];

    [self setupImGui];
}

- (void)setupImGui
{
    ImGuiContext *prev = ImGui::GetCurrentContext();

    IMGUI_CHECKVERSION();
    _TSEspContext = ImGui::CreateContext();
    ImGui::SetCurrentContext(_TSEspContext);

    ImGuiIO &io = ImGui::GetIO();
    io.IniFilename = NULL;
    io.LogFilename = NULL;
    io.MouseDrawCursor = false;
    io.BackendFlags |= ImGuiBackendFlags_RendererHasVtxOffset;
    io.Fonts->AddFontDefault();

    ImGui_ImplMetal_Init(_device);
    _imguiReady = YES;

    if (prev != nullptr) {
        ImGui::SetCurrentContext(prev);
    }
}

#pragma mark - Enabling

- (void)setEspEnabled:(BOOL)enabled
{
    _espEnabled = enabled;
    self.hidden = !enabled;
    // Pausing stops the display link entirely, so a disabled layer does not
    // draw or present anything.
    _mtkView.paused = !enabled;
}

- (BOOL)isEspEnabled
{
    return _espEnabled;
}

#pragma mark - MTKViewDelegate

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size
{
    (void)view;
    (void)size;
}

- (void)drawInMTKView:(MTKView *)view
{
    if (!_imguiReady || !_espEnabled || !_TSEspContext) {
        return;
    }

    CGSize boundsSize = view.bounds.size;
    if (boundsSize.width < 1.0 || boundsSize.height < 1.0) {
        return;
    }

    MTLRenderPassDescriptor *renderPassDescriptor = view.currentRenderPassDescriptor;
    if (!renderPassDescriptor) {
        return;
    }

    // The menu renders from its own context, so bind ours for the duration of
    // the frame and hand the previous one back afterwards.
    ImGuiContext *prev = ImGui::GetCurrentContext();
    ImGui::SetCurrentContext(_TSEspContext);

    ImGuiIO &io = ImGui::GetIO();
    io.DisplaySize = ImVec2((float)boundsSize.width, (float)boundsSize.height);

    CGFloat framebufferScale = view.contentScaleFactor;
    if (framebufferScale <= 0.0) {
        framebufferScale = [UIScreen mainScreen].nativeScale;
    }
    if (framebufferScale <= 0.0) {
        framebufferScale = 2.0;
    }
    io.DisplayFramebufferScale = ImVec2(framebufferScale, framebufferScale);
    io.DeltaTime = 1.0f / 60.0f;

    id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
    id<MTLRenderCommandEncoder> renderEncoder =
        [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];

    ImGui_ImplMetal_NewFrame(renderPassDescriptor);
    ImGui::NewFrame();

    [self drawShapes];

    ImGui::Render();
    ImGui_ImplMetal_RenderDrawData(ImGui::GetDrawData(), commandBuffer, renderEncoder);

    [renderEncoder endEncoding];

    id<CAMetalDrawable> drawable = view.currentDrawable;
    if (drawable) {
        [commandBuffer presentDrawable:drawable];
    }
    [commandBuffer commit];

    if (prev != nullptr) {
        ImGui::SetCurrentContext(prev);
    }
}

- (void)drawShapes
{
    ImGuiIO &io = ImGui::GetIO();
    const float w = io.DisplaySize.x;
    const float h = io.DisplaySize.y;

    // The background draw list covers the whole viewport and needs no window,
    // which is exactly what a decoration-free overlay wants.
    ImDrawList *drawList = ImGui::GetBackgroundDrawList();

    const int boxCount = 3;
    const ImU32 strokeColor = IM_COL32(255, 255, 255, 220);
    const ImU32 lineColor = IM_COL32(255, 255, 255, 110);

    // Lines are drawn from the top of the screen down to the top edge of each
    // box.
    const ImVec2 origin = ImVec2(w * 0.5f, 0.0f);

    // Slightly different heights and fill levels per box, so the layer reads as
    // three separate things rather than a repeated pattern.
    const float heightScale[boxCount] = { 1.0f, 0.78f, 0.9f };
    const float verticalOffset[boxCount] = { 0.0f, 0.06f, -0.04f };
    const float fillLevel[boxCount] = { 0.85f, 0.45f, 0.2f };

    const float baseW = 46.0f;
    const float baseH = 86.0f;

    for (int i = 0; i < boxCount; i++) {
        const float centreX = (w / (float)(boxCount + 1)) * (float)(i + 1);
        const float centreY = h * (0.42f + verticalOffset[i]);
        const float boxW = baseW * heightScale[i];
        const float boxH = baseH * heightScale[i];

        const ImVec2 topLeft = ImVec2(centreX - boxW * 0.5f, centreY - boxH * 0.5f);
        const ImVec2 bottomRight = ImVec2(centreX + boxW * 0.5f, centreY + boxH * 0.5f);

        drawList->AddRect(topLeft, bottomRight, strokeColor, 0.0f, 0, 1.0f);
        drawList->AddLine(origin, ImVec2(centreX, topLeft.y), lineColor, 1.0f);

        [self drawBarAtLeftOfBox:topLeft bottomRight:bottomRight fill:fillLevel[i] drawList:drawList];
    }
}

// Vertical bar hugging the left edge of a box, filled from the bottom up.
// The fill runs red at the bottom to green at the top, and the top colour is
// interpolated by the fill level, so a nearly empty bar reads as red while a
// full one reads as green.
- (void)drawBarAtLeftOfBox:(ImVec2)topLeft
               bottomRight:(ImVec2)bottomRight
                      fill:(float)fill
                  drawList:(ImDrawList *)drawList
{
    const float barWidth = 3.0f;
    const float barGap = 3.0f;

    const ImVec2 barMin = ImVec2(topLeft.x - barGap - barWidth, topLeft.y);
    const ImVec2 barMax = ImVec2(topLeft.x - barGap, bottomRight.y);

    drawList->AddRectFilled(barMin, barMax, IM_COL32(0, 0, 0, 140));

    fill = ImClamp(fill, 0.0f, 1.0f);
    if (fill > 0.0f) {
        const float filledTop = barMax.y - (barMax.y - barMin.y) * fill;

        const ImU32 bottomColor = IM_COL32(220, 40, 40, 235);
        const ImU32 topColor = IM_COL32((int)(220.0f + (40.0f - 220.0f) * fill),
                                        (int)(40.0f + (220.0f - 40.0f) * fill),
                                        40,
                                        235);

        drawList->AddRectFilledMultiColor(ImVec2(barMin.x, filledTop), barMax,
                                          topColor, topColor, bottomColor, bottomColor);
    }

    drawList->AddRect(barMin, barMax, IM_COL32(0, 0, 0, 200), 0.0f, 0, 1.0f);
}

@end
