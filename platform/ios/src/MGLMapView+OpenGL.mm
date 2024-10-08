#import "MGLFoundation_Private.h"
#import "MGLLoggingConfiguration_Private.h"
#import "MGLMapView+OpenGL.h"

#include <mbgl/gl/renderable_resource.hpp>

#import <GLKit/GLKit.h>
#import <OpenGLES/EAGL.h>
#import <QuartzCore/CAEAGLLayer.h>

@interface MGLMapViewImplDelegate : NSObject <GLKViewDelegate>
@end

@implementation MGLMapViewImplDelegate {
    MGLMapViewOpenGLImpl* _impl;
}

- (instancetype)initWithImpl:(MGLMapViewOpenGLImpl*)impl {
    if (self = [super init]) {
        _impl = impl;
    }
    return self;
}

- (void)glkView:(nonnull GLKView*)view drawInRect:(CGRect)rect {
    _impl->render();
}

@end

namespace {
CGFloat contentScaleFactor() {
    return [UIScreen instancesRespondToSelector:@selector(nativeScale)]
        ? [[UIScreen mainScreen] nativeScale]
        : [[UIScreen mainScreen] scale];
}
} // namespace

class MGLMapViewOpenGLRenderableResource final : public mbgl::gl::RenderableResource {
public:
    MGLMapViewOpenGLRenderableResource(MGLMapViewOpenGLImpl& backend_)
        : backend(backend_),
          delegate([[MGLMapViewImplDelegate alloc] initWithImpl:&backend]),
          atLeastiOS_12_2_0([NSProcessInfo.processInfo
              isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion){ 12, 2, 0 }]) {
    }

    void bind() override {
        backend.restoreFramebufferBinding();
    }

    mbgl::Size framebufferSize() {
        assert(glView);
        return { static_cast<uint32_t>(glView.drawableWidth),
                 static_cast<uint32_t>(glView.drawableHeight) };
    }

private:
    MGLMapViewOpenGLImpl& backend;

public:
    MGLMapViewImplDelegate* delegate = nil;
    GLKView *glView = nil;
    EAGLContext *context = nil;
    const bool atLeastiOS_12_2_0;

    // We count how often the context was activated/deactivated so that we can truly deactivate it
    // after the activation count drops to 0.
    NSUInteger activationCount = 0;
};

MGLMapViewOpenGLImpl::MGLMapViewOpenGLImpl(MGLMapView* nativeView_)
    : MGLMapViewImpl(nativeView_),
      mbgl::gl::RendererBackend(mbgl::gfx::ContextMode::Unique),
      mbgl::gfx::Renderable({ 0, 0 }, std::make_unique<MGLMapViewOpenGLRenderableResource>(*this)) {
}

MGLMapViewOpenGLImpl::~MGLMapViewOpenGLImpl() {
    auto& resource = getResource<MGLMapViewOpenGLRenderableResource>();
    if (resource.context && [[EAGLContext currentContext] isEqual:resource.context]) {
        [EAGLContext setCurrentContext:nil];
    }
}

void MGLMapViewOpenGLImpl::setOpaque(const bool opaque) {
    auto& resource = getResource<MGLMapViewOpenGLRenderableResource>();
    resource.glView.opaque = opaque;
    resource.glView.layer.opaque = opaque;
}

void MGLMapViewOpenGLImpl::setPresentsWithTransaction(const bool value) {
    auto& resource = getResource<MGLMapViewOpenGLRenderableResource>();
    CAEAGLLayer* eaglLayer = MGL_OBJC_DYNAMIC_CAST(resource.glView.layer, CAEAGLLayer);
    eaglLayer.presentsWithTransaction = value;
}

void MGLMapViewOpenGLImpl::display() {
    auto& resource = getResource<MGLMapViewOpenGLRenderableResource>();
    // Calling `display` here directly causes the stuttering bug (if
    // `presentsWithTransaction` is `YES` - see above)
    // as reported in https://github.com/mapbox/mapbox-gl-native-ios/issues/350
    //
    // Since we use `presentsWithTransaction` to synchronize with UIView
    // annotations, we now let the system handle when the view is rendered. This
    // has the potential to increase latency
    [resource.glView setNeedsDisplay];
}

void MGLMapViewOpenGLImpl::createView() {
    auto& resource = getResource<MGLMapViewOpenGLRenderableResource>();
    if (resource.glView) {
        return;
    }

    if (!resource.context) {
        resource.context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
        assert(resource.context);
    }

    resource.glView = [[GLKView alloc] initWithFrame:mapView.bounds context:resource.context];
    resource.glView.delegate = resource.delegate;
    resource.glView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    resource.glView.contentScaleFactor = contentScaleFactor();
    resource.glView.contentMode = UIViewContentModeCenter;
    resource.glView.drawableStencilFormat = GLKViewDrawableStencilFormat8;
    resource.glView.drawableDepthFormat = GLKViewDrawableDepthFormat16;
    resource.glView.opaque = mapView.opaque;
    resource.glView.tintColor = nil;
    resource.glView.layer.opaque = mapView.opaque;
    resource.glView.enableSetNeedsDisplay = YES;
    CAEAGLLayer* eaglLayer = MGL_OBJC_DYNAMIC_CAST(resource.glView.layer, CAEAGLLayer);
    eaglLayer.presentsWithTransaction = NO;

    [mapView insertSubview:resource.glView atIndex:0];
}

UIView* MGLMapViewOpenGLImpl::getView() {
    auto& resource = getResource<MGLMapViewOpenGLRenderableResource>();
    return resource.glView;
}

void MGLMapViewOpenGLImpl::deleteView() {
    auto& resource = getResource<MGLMapViewOpenGLRenderableResource>();
    [resource.glView deleteDrawable];
}

mbgl::gl::ProcAddress MGLMapViewOpenGLImpl::getExtensionFunctionPointer(const char* name) {
    static CFBundleRef framework = CFBundleGetBundleWithIdentifier(CFSTR("com.apple.opengles"));
    if (!framework) {
        throw std::runtime_error("Failed to load OpenGL framework.");
    }

    return reinterpret_cast<mbgl::gl::ProcAddress>(CFBundleGetFunctionPointerForName(
        framework, (__bridge CFStringRef)[NSString stringWithUTF8String:name]));
}

void MGLMapViewOpenGLImpl::activate() {
    auto& resource = getResource<MGLMapViewOpenGLRenderableResource>();
    if (resource.activationCount++) {
        return;
    }

    [EAGLContext setCurrentContext:resource.context];
}

void MGLMapViewOpenGLImpl::deactivate() {
    auto& resource = getResource<MGLMapViewOpenGLRenderableResource>();
    if (--resource.activationCount) {
        return;
    }

    [EAGLContext setCurrentContext:nil];
}

/// This function is called before we start rendering, when iOS invokes our rendering method.
/// iOS already sets the correct framebuffer and viewport for us, so we need to update the
/// context state with the anticipated values.
void MGLMapViewOpenGLImpl::updateAssumedState() {
    auto& resource = getResource<MGLMapViewOpenGLRenderableResource>();
    assumeFramebufferBinding(ImplicitFramebufferBinding);
    assumeViewport(0, 0, resource.framebufferSize());
}

void MGLMapViewOpenGLImpl::restoreFramebufferBinding() {
    auto& resource = getResource<MGLMapViewOpenGLRenderableResource>();
    if (!implicitFramebufferBound()) {
        // Something modified our state, and we need to bind the original drawable again.
        // Doing this also sets the viewport to the full framebuffer.
        // Note that in reality, iOS does not use the Framebuffer 0 (it's typically 1), and we
        // only use this is a placeholder value.
        [resource.glView bindDrawable];
        updateAssumedState();
    } else {
        // Our framebuffer is still bound, but the viewport might have changed.
        setViewport(0, 0, resource.framebufferSize());
    }
}

UIImage* MGLMapViewOpenGLImpl::snapshot() {
    auto& resource = getResource<MGLMapViewOpenGLRenderableResource>();
    return resource.glView.snapshot;
}

void MGLMapViewOpenGLImpl::layoutChanged() {
    const auto scaleFactor = contentScaleFactor();
    size = { static_cast<uint32_t>(mapView.bounds.size.width * scaleFactor),
             static_cast<uint32_t>(mapView.bounds.size.height * scaleFactor) };
}

EAGLContext* MGLMapViewOpenGLImpl::getEAGLContext() {
    auto& resource = getResource<MGLMapViewOpenGLRenderableResource>();
    return resource.context;
}
