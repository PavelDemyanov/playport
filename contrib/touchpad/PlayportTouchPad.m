// SPDX-License-Identifier: GPL-3.0-or-later
// PlayportTouchPad: an on-screen game controller for Playport, as a prototype
// loaded into the app (README.md).
//
// The system's GCVirtualController (iOS 15+) draws two thumbsticks, A/B/X/Y,
// the shoulders and the triggers over the app, and appears to it as an ordinary
// GCController with an extendedGamepad. Playport hands that controller to the
// game as XInput (HostIO.attach) as it does a real one. It is on the screen
// while no physical pad is connected: one connects, it hides; it goes, it is back.
//
// The system draws no Home, Start or Back, so a row of buttons at the top centre:
//   Home   Playport's in-game menu (InGameMenu.open(), as Home held does):
//          Resume, Quit game;
//   Back / Start   their XInput bits added to the touch pad's state
//          (host_pad_set, slot 0) while held;
//   opacity   the touch pad's and these buttons': 100 -> 75 -> 50 -> 30 %;
//          held, it turns the touch pad off, all of it (it disconnects, so no
//          invisible touch areas stay) leaving only this button, or back on.
// While the menu is open the touch pad is hidden and the menu's rows take taps.
// Before the runtime starts it also sets MADEIRA_KEEP_SMC and WINEDLLOVERRIDES
// (runtime_environment). Log: Documents/playport-touchpad.log.

#import <GameController/GameController.h>
#import <UIKit/UIKit.h>
#include <dlfcn.h>
#include <stdbool.h>

/* host_io.h / hio_pads.h: the XInput gamepad the app hands the runtime */
typedef struct {
    uint16_t buttons;
    uint8_t left_trigger, right_trigger;
    int16_t thumb_lx, thumb_ly, thumb_rx, thumb_ry;
} hio_pad_state;

enum { XI_START = 0x0010, XI_BACK = 0x0020, XI_LB = 0x0100, XI_RB = 0x0200,
       XI_A = 0x1000, XI_B = 0x2000, XI_X = 0x4000, XI_Y = 0x8000 };

typedef void (*host_pad_set_fn)(int slot, const hio_pad_state *st);
/* Swift: a global addressor takes nothing; a method takes its object as self (x20, clang's swift_context). */
typedef void **(*menu_addressor_fn)(void) __attribute__((swiftcall));
typedef bool (*menu_method_fn)(void *self __attribute__((swift_context))) __attribute__((swiftcall));

static host_pad_set_fn host_pad_set_ptr;
static menu_addressor_fn menu_shared_addressor;
static menu_method_fn menu_open_ptr, menu_is_open_ptr;

static GCVirtualController *touch_pad;
static BOOL touch_pad_connected;
static UIWindow *button_window;
static UIView *button_bar;
static uint16_t held_bits;
static CADisplayLink *held_link;
static CGFloat opacity = 1.0;
static NSString *const opacity_key = @"PlayportTouchPadOpacity";
/* Turned off by the player (the opacity button held): the touch pad is
 * disconnected, all of it; only that button stays. */
static BOOL player_hidden;
static NSString *const hidden_key = @"PlayportTouchPadHidden";
static UIButton *home_button, *back_button, *start_button, *opacity_button;
static BOOL opacity_button_shows_pad;
static GCController *touch_controller;  /* the touch pad's GCController while connected */

static void tp_log(NSString *format, ...)
{
    va_list args;
    va_start(args, format);
    NSString *line = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/playport-touchpad.log"];
    NSString *stamped = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], line];
    NSFileHandle *file = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!file)
    {
        [stamped writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:nil];
        return;
    }
    [file seekToEndOfFile];
    [file writeData:[stamped dataUsingEncoding:NSUTF8StringEncoding]];
    [file closeFile];
}

/* ---- Playport's own entry points, looked up in the executable ---- */

static void resolve_playport(void)
{
    void *self = dlopen(NULL, RTLD_NOW);
    host_pad_set_ptr = (host_pad_set_fn)dlsym(self, "host_pad_set");
    menu_shared_addressor = (menu_addressor_fn)dlsym(self, "$s8Playport10InGameMenuC6sharedACvau");
    menu_open_ptr = (menu_method_fn)dlsym(self, "$s8Playport10InGameMenuC4openSbyF");
    menu_is_open_ptr = (menu_method_fn)dlsym(self, "$s8Playport10InGameMenuC6isOpenSbvg");
    tp_log(@"environment: MADEIRA_KEEP_SMC=%s WINEDLLOVERRIDES=%s", getenv("MADEIRA_KEEP_SMC"), getenv("WINEDLLOVERRIDES"));
    tp_log(@"Playport entry points: host_pad_set %s, InGameMenu.shared %s, open %s, isOpen %s",
           host_pad_set_ptr ? "ok" : "MISSING", menu_shared_addressor ? "ok" : "MISSING",
           menu_open_ptr ? "ok" : "MISSING", menu_is_open_ptr ? "ok" : "MISSING");
}

/* InGameMenu.shared, a final class: its methods take the object as Swift's self. */
static void *in_game_menu(void)
{
    void **storage;
    if (!menu_shared_addressor) return NULL;
    storage = menu_shared_addressor();
    return storage ? *storage : NULL;
}

static BOOL menu_is_open(void)
{
    void *menu = in_game_menu();
    return menu && menu_is_open_ptr ? menu_is_open_ptr(menu) : NO;
}

static BOOL menu_open(void)
{
    void *menu = in_game_menu();
    return menu && menu_open_ptr ? menu_open_ptr(menu) : NO;
}

/* ---- the pad state with Start / Back added ---- */

static int16_t thumb(float f)
{
    if (f < -1) f = -1;
    if (f > 1) f = 1;
    return (int16_t)(f < 0 ? f * 32768.0f : f * 32767.0f);
}

static void send_pad_state(void)
{
    GCExtendedGamepad *pad = touch_pad.controller.extendedGamepad;
    hio_pad_state st = {0};

    if (!host_pad_set_ptr || !pad) return;
    if (pad.buttonA.isPressed) st.buttons |= XI_A;
    if (pad.buttonB.isPressed) st.buttons |= XI_B;
    if (pad.buttonX.isPressed) st.buttons |= XI_X;
    if (pad.buttonY.isPressed) st.buttons |= XI_Y;
    if (pad.leftShoulder.isPressed) st.buttons |= XI_LB;
    if (pad.rightShoulder.isPressed) st.buttons |= XI_RB;
    st.buttons |= held_bits;
    st.left_trigger = (uint8_t)(pad.leftTrigger.value * 255.0f + 0.5f);
    st.right_trigger = (uint8_t)(pad.rightTrigger.value * 255.0f + 0.5f);
    st.thumb_lx = thumb(pad.leftThumbstick.xAxis.value);
    st.thumb_ly = thumb(pad.leftThumbstick.yAxis.value);
    st.thumb_rx = thumb(pad.rightThumbstick.xAxis.value);
    st.thumb_ry = thumb(pad.rightThumbstick.yAxis.value);
    host_pad_set_ptr(0, &st);
}

@interface TPTarget : NSObject
@end

static void touch_pad_update(NSString *reason);

static TPTarget *target;

/* ---- the overlay: system pad view, our buttons ---- */

static NSArray<UIView *> *controller_views(void)
{
    NSMutableArray *found = [NSMutableArray array];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes)
    {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows)
        {
            if (window == button_window) continue;
            NSMutableArray *stack = [NSMutableArray arrayWithObject:window];
            while (stack.count)
            {
                UIView *view = stack.lastObject;
                [stack removeLastObject];
                if ([NSStringFromClass(view.class) containsString:@"GCControllerView"])
                {
                    [found addObject:view];
                    continue;
                }
                [stack addObjectsFromArray:view.subviews];
            }
        }
    }
    return found;
}

static BOOL physical_pad_present(void);

static void set_opacity_button_icon(BOOL pad)
{
    UIImageSymbolConfiguration *config;

    if (pad == opacity_button_shows_pad) return;
    opacity_button_shows_pad = pad;
    config = [UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIImageSymbolWeightSemibold];
    [opacity_button setImage:[UIImage systemImageNamed:pad ? @"gamecontroller.fill" : @"circle.lefthalf.filled"
                                     withConfiguration:config] forState:UIControlStateNormal];
}

static void apply_overlay_state(void)
{
    BOOL menu = menu_is_open();
    BOOL shown = !menu && !physical_pad_present() && (touch_pad_connected || player_hidden);

    for (UIView *view in controller_views())
    {
        view.alpha = opacity;
        view.hidden = menu;
    }
    /* hidden views take no touches: off means off, not invisible */
    home_button.hidden = back_button.hidden = start_button.hidden = player_hidden;
    set_opacity_button_icon(player_hidden);
    button_bar.alpha = player_hidden ? MAX(opacity, 0.6) : opacity;
    button_window.hidden = !shown;
}

@interface TPPassthroughWindow : UIWindow
@end

@implementation TPPassthroughWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event
{
    UIView *view = [super hitTest:point withEvent:event];
    return (view == self || view == self.rootViewController.view || view == button_bar) ? nil : view;
}
@end

@interface TPRootController : UIViewController
@end

@implementation TPRootController
- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
@end

@implementation TPTarget

- (void)homeTapped
{
    BOOL opened = menu_open();
    tp_log(@"Home: Playport menu %@", opened ? @"opened" : @"not opened (no game running)");
    apply_overlay_state();
}

- (void)startDown { [self hold:XI_START]; }
- (void)backDown { [self hold:XI_BACK]; }
- (void)startUp { [self letGo:XI_START]; }
- (void)backUp { [self letGo:XI_BACK]; }

- (void)hold:(uint16_t)bit
{
    if (menu_is_open()) return;
    held_bits |= bit;
    send_pad_state();
    if (!held_link)
    {
        /* Playport rewrites the slot whenever the touch pad changes: the held bit goes again every frame. */
        held_link = [CADisplayLink displayLinkWithTarget:self selector:@selector(heldTick)];
        [held_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    }
}

- (void)letGo:(uint16_t)bit
{
    held_bits &= ~bit;
    send_pad_state();
    if (!held_bits)
    {
        [held_link invalidate];
        held_link = nil;
    }
}

- (void)heldTick { send_pad_state(); }

- (void)opacityTapped
{
    if (player_hidden) return;
    opacity = opacity > 0.9 ? 0.75 : opacity > 0.6 ? 0.5 : opacity > 0.4 ? 0.3 : 1.0;
    [NSUserDefaults.standardUserDefaults setDouble:opacity forKey:opacity_key];
    tp_log(@"opacity %.0f%%", opacity * 100);
    apply_overlay_state();
}

/* Held: the touch pad off, all of it (it disconnects, its overlay and touches go), or back on. */
- (void)opacityLongPress:(UILongPressGestureRecognizer *)gesture
{
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    player_hidden = !player_hidden;
    [NSUserDefaults.standardUserDefaults setBool:player_hidden forKey:hidden_key];
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium] impactOccurred];
    if (player_hidden && held_bits)
    {
        held_bits = 0;
        [held_link invalidate];
        held_link = nil;
        send_pad_state();
    }
    touch_pad_update(player_hidden ? @"turned off by the player" : @"turned on by the player");
    apply_overlay_state();
}

- (void)tick { apply_overlay_state(); }

@end

static UIButton *make_button(NSString *symbol, SEL down, SEL up)
{
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIImageSymbolWeightSemibold];
    [button setImage:[UIImage systemImageNamed:symbol withConfiguration:config] forState:UIControlStateNormal];
    button.tintColor = UIColor.whiteColor;
    button.backgroundColor = [UIColor colorWithWhite:0.15 alpha:0.55];
    button.layer.cornerRadius = 20;
    button.layer.borderWidth = 1;
    button.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.35].CGColor;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button.widthAnchor constraintEqualToConstant:40].active = YES;
    [button.heightAnchor constraintEqualToConstant:40].active = YES;
    if (up)
    {
        [button addTarget:target action:down forControlEvents:UIControlEventTouchDown];
        [button addTarget:target action:up forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    }
    else [button addTarget:target action:down forControlEvents:UIControlEventTouchUpInside];
    return button;
}

static void buttons_start(void)
{
    UIWindowScene *scene = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes)
        if ([s isKindOfClass:UIWindowScene.class]) { scene = (UIWindowScene *)s; break; }
    if (!scene) { tp_log(@"no window scene for the buttons"); return; }

    target = [[TPTarget alloc] init];
    button_window = [[TPPassthroughWindow alloc] initWithWindowScene:scene];
    button_window.windowLevel = UIWindowLevelAlert + 1;
    button_window.backgroundColor = UIColor.clearColor;
    TPRootController *root = [[TPRootController alloc] init];
    root.view.backgroundColor = UIColor.clearColor;
    button_window.rootViewController = root;

    home_button = make_button(@"house.fill", @selector(homeTapped), NULL);
    back_button = make_button(@"rectangle.on.rectangle", @selector(backDown), @selector(backUp));
    start_button = make_button(@"line.3.horizontal", @selector(startDown), @selector(startUp));
    opacity_button = make_button(@"circle.lefthalf.filled", @selector(opacityTapped), NULL);
    UILongPressGestureRecognizer *hold = [[UILongPressGestureRecognizer alloc] initWithTarget:target
                                                                                        action:@selector(opacityLongPress:)];
    hold.minimumPressDuration = 0.6;
    [opacity_button addGestureRecognizer:hold];  /* cancels the tap once recognised */
    UIStackView *bar = [[UIStackView alloc] initWithArrangedSubviews:@[home_button, back_button, start_button, opacity_button]];
    bar.axis = UILayoutConstraintAxisHorizontal;
    bar.spacing = 14;
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    button_bar = bar;
    [root.view addSubview:bar];
    [bar.centerXAnchor constraintEqualToAnchor:root.view.centerXAnchor].active = YES;
    [bar.topAnchor constraintEqualToAnchor:root.view.safeAreaLayoutGuide.topAnchor constant:8].active = YES;

    button_window.hidden = NO;
    [NSTimer scheduledTimerWithTimeInterval:0.5 target:target selector:@selector(tick) userInfo:nil repeats:YES];
    tp_log(@"buttons shown: Home, Back, Start, opacity %.0f%%%@", opacity * 100, player_hidden ? @"; touch pad off" : @"");
}

/* ---- the system pad ---- */

static void log_controllers(NSString *when)
{
    NSMutableArray *names = [NSMutableArray array];
    for (GCController *c in GCController.controllers)
        [names addObject:[NSString stringWithFormat:@"%@%@%@", c.vendorName, c.extendedGamepad ? @" (extended)" : @"",
                          (touch_pad && c == touch_pad.controller) ? @" [touch]" : @""]];
    tp_log(@"%@: GCController.controllers = [%@]", when, [names componentsJoinedByString:@", "]);
}

/* A connected pad that is not the touch pad itself. */
static BOOL physical_pad_present(void)
{
    for (GCController *controller in GCController.controllers)
    {
        if (controller == touch_controller || (touch_pad && controller == touch_pad.controller)) continue;
        if (controller.extendedGamepad) return YES;
    }
    return NO;
}

static void touch_pad_update(NSString *reason)
{
    BOOL physical = physical_pad_present();

    if ((physical || player_hidden) && touch_pad_connected)
    {
        [touch_pad disconnect];
        touch_pad_connected = NO;
        tp_log(@"%@: %@, touch pad disconnected", reason, physical ? @"a physical pad is connected" : @"off");
        apply_overlay_state();
    }
    else if (!physical && !player_hidden && !touch_pad_connected)
    {
        touch_pad_connected = YES;
        [touch_pad connectWithReplyHandler:^(NSError *error) {
            if (error)
            {
                touch_pad_connected = NO;
                tp_log(@"%@: connect failed: %@", reason, error);
            }
            else
            {
                touch_controller = touch_pad.controller;
                tp_log(@"%@: touch pad shown (%@)", reason, touch_pad.controller.vendorName);
                apply_overlay_state();
            }
        }];
    }
}

/* The system draws only some elements: an element set it refuses throws from
 * the initializer, so each set is tried in turn, the fullest first. */
static GCVirtualController *touch_pad_create(void)
{
    NSArray *base = @[
        GCInputLeftThumbstick, GCInputRightThumbstick,
        GCInputButtonA, GCInputButtonB, GCInputButtonX, GCInputButtonY,
        GCInputLeftShoulder, GCInputRightShoulder,
    ];
    NSArray *sets = @[ [base arrayByAddingObjectsFromArray:@[GCInputLeftTrigger, GCInputRightTrigger]], base ];

    for (NSArray *elements in sets)
    {
        GCVirtualControllerConfiguration *config = [[GCVirtualControllerConfiguration alloc] init];
        config.elements = [NSSet setWithArray:elements];
        @try
        {
            GCVirtualController *pad = [GCVirtualController virtualControllerWithConfiguration:config];
            tp_log(@"touch pad created with %lu elements", (unsigned long)elements.count);
            return pad;
        }
        @catch (NSException *e)
        {
            tp_log(@"%lu elements refused: %@: %@", (unsigned long)elements.count, e.name, e.reason);
        }
    }
    return nil;
}

static void touch_pad_start(void)
{
    if (touch_pad) return;
    resolve_playport();
    NSNumber *saved = [NSUserDefaults.standardUserDefaults objectForKey:opacity_key];
    if (saved) opacity = saved.doubleValue;
    player_hidden = [NSUserDefaults.standardUserDefaults boolForKey:hidden_key];
    if (!(touch_pad = touch_pad_create())) return;
    buttons_start();

    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserverForName:GCControllerDidConnectNotification object:nil queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification *note) {
        GCController *controller = note.object;
        if (controller == touch_controller || controller == touch_pad.controller) return;
        log_controllers([NSString stringWithFormat:@"did connect \"%@\"", controller.vendorName]);
        touch_pad_update([NSString stringWithFormat:@"connected \"%@\"", controller.vendorName]);
    }];
    [nc addObserverForName:GCControllerDidDisconnectNotification object:nil queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification *note) {
        GCController *controller = note.object;
        if (controller == touch_controller || controller == touch_pad.controller) return;
        touch_pad_update([NSString stringWithFormat:@"disconnected \"%@\"", controller.vendorName]);
    }];
    touch_pad_update(@"start");
}

/* Before the runtime starts (the library loads before main):
 * - MADEIRA_KEEP_SMC=1: FEX in 0.4.0, with SMC tracking off once Mono is found,
 *   breaks Mono (Unity 2019's String.Replace reads at a character's value);
 *   fex 0033/0038 on main address that;
 * - WINEDLLOVERRIDES: Playport sets windows.gaming.input=d only when the variable
 *   is unset (HostIO.start, setenv(..., 0)); with the host pad provider, games on
 *   Rewired need Windows.Gaming.Input. Playport or a game still overrides it. */
static void runtime_environment(void)
{
    setenv("MADEIRA_KEEP_SMC", "1", 0);
    setenv("WINEDLLOVERRIDES", "winemenubuilder.exe=d", 0);
}

__attribute__((constructor))
static void touch_pad_init(void)
{
    runtime_environment();
    /* The overlay needs the app's window: start once the app is active the first time. */
    __block id observer = [NSNotificationCenter.defaultCenter
        addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification *note) {
        [NSNotificationCenter.defaultCenter removeObserver:observer];
        /* Controllers already paired are reported shortly after launch. */
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            touch_pad_start();
        });
    }];
}
