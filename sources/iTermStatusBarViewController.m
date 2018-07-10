//
//  iTermStatusBarViewController.m
//  iTerm2SharedARC
//
//  Created by George Nachman on 6/28/18.
//

#import "iTermStatusBarViewController.h"

#import "DebugLogging.h"
#import "iTermStatusBarContainerView.h"
#import "iTermStatusBarLayout.h"
#import "iTermStatusBarSpringComponent.h"
#import "iTermStatusBarView.h"
#import "NSArray+iTerm.h"
#import "NSTimer+iTerm.h"
#import "NSView+iTerm.h"

NS_ASSUME_NONNULL_BEGIN

static const CGFloat iTermStatusBarViewControllerMargin = 5;
static const CGFloat iTermStatusBarViewControllerTopMargin = 1;
static const CGFloat iTermStatusBarViewControllerContainerHeight = 21;

@interface iTermStatusBarViewController ()<
    iTermStatusBarComponentDelegate,
    iTermStatusBarLayoutDelegate>

@end

@implementation iTermStatusBarViewController {
    NSMutableArray<iTermStatusBarContainerView *> *_containerViews;
    NSArray<iTermStatusBarContainerView *> *_visibleContainerViews;
}

- (instancetype)initWithLayout:(iTermStatusBarLayout *)layout
                         scope:(nonnull iTermVariableScope *)scope {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _scope = scope;
        _layout = layout;
        for (id<iTermStatusBarComponent> component in layout.components) {
            [component statusBarComponentSetVariableScope:scope];
        }
    }
    return self;
}

- (void)loadView {
    self.view = [[iTermStatusBarView alloc] initWithFrame:NSZeroRect];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self updateViews];
}

- (void)viewWillLayout {
    NSArray<iTermStatusBarContainerView *> *previouslyVisible = _visibleContainerViews.copy;
    _visibleContainerViews = [self visibleContainerViews];
    DLog(@"--- begin status bar layout ---");
    [self updateDesiredWidths];
    [self updateDesiredOrigins];

    [_visibleContainerViews enumerateObjectsUsingBlock:
     ^(iTermStatusBarContainerView * _Nonnull view, NSUInteger idx, BOOL * _Nonnull stop) {
         view.frame = NSMakeRect(view.desiredOrigin,
                                 iTermStatusBarViewControllerTopMargin,
                                 view.desiredWidth,
                                 iTermStatusBarViewControllerContainerHeight);
         [view.component statusBarComponentWidthDidChangeTo:view.desiredWidth];
     }];
    // Remove defunct views
    for (iTermStatusBarContainerView *view in previouslyVisible) {
        if (![_visibleContainerViews containsObject:view]) {
            [view removeFromSuperview];
        }
    }
    // Add new views
    for (iTermStatusBarContainerView *view in _visibleContainerViews) {
        if (view.superview != self.view) {
            [self.view addSubview:view];
        }
    }
    DLog(@"--- end status bar layout ---");
}

- (void)setTemporaryLeftComponent:(nullable id<iTermStatusBarComponent>)temporaryLeftComponent {
    _temporaryLeftComponent = temporaryLeftComponent;
    [self updateViews];
    [self.view layoutSubtreeIfNeeded];
}

- (void)setTemporaryRightComponent:(nullable id<iTermStatusBarComponent>)temporaryRightComponent {
    _temporaryRightComponent = temporaryRightComponent;
    [self updateViews];
    [self.view layoutSubtreeIfNeeded];
}

- (void)variablesDidChange:(NSSet<NSString *> *)names {
    [_layout.components enumerateObjectsUsingBlock:^(id<iTermStatusBarComponent> _Nonnull component, NSUInteger idx, BOOL * _Nonnull stop) {
        NSSet<NSString *> *dependencies = [component statusBarComponentVariableDependencies];
        if ([dependencies intersectsSet:names]) {
            [component statusBarComponentVariablesDidChange:names];
        }
    }];
}

- (NSViewController<iTermFindViewController> *)searchViewController {
    return [_containerViews mapWithBlock:^id(iTermStatusBarContainerView *containerView) {
        return containerView.component.statusBarComponentSearchViewController;
    }].firstObject;
}

#pragma mark - Private

- (void)updateMargins:(NSArray<iTermStatusBarContainerView *> *)views {
    __block BOOL foundMargin = NO;
    __block BOOL previousHadMargin = NO;
    [views enumerateObjectsUsingBlock:^(iTermStatusBarContainerView * _Nonnull view, NSUInteger idx, BOOL * _Nonnull stop) {
        const BOOL hasMargins = view.component.statusBarComponentHasMargins;
        if (hasMargins && !foundMargin) {
            view.leftMargin = iTermStatusBarViewControllerMargin;
            foundMargin = YES;
        } else if (hasMargins) {
            if (previousHadMargin) {
                view.leftMargin = iTermStatusBarViewControllerMargin / 2;
            } else {
                view.leftMargin = 0;
            }
        } else {
            view.leftMargin = 0;
        }
        previousHadMargin = hasMargins;
    }];
    
    foundMargin = NO;
    previousHadMargin = NO;
    [views enumerateObjectsWithOptions:NSEnumerationReverse usingBlock:^(iTermStatusBarContainerView * _Nonnull view, NSUInteger idx, BOOL * _Nonnull stop) {
        const BOOL hasMargins = view.component.statusBarComponentHasMargins;
        if (hasMargins && !foundMargin) {
            view.rightMargin = iTermStatusBarViewControllerMargin;
            foundMargin = YES;
        } else if (hasMargins) {
            if (previousHadMargin) {
                view.rightMargin = iTermStatusBarViewControllerMargin / 2;
            } else {
                view.rightMargin = 0;
            }
        } else {
            view.rightMargin = 0;
        }
        previousHadMargin = hasMargins;
    }];
}

- (void)updateDesiredWidths {
    [self updateMargins:_visibleContainerViews];
    
     const CGFloat totalMarginWidth = [[_visibleContainerViews reduceWithFirstValue:@0 block:^NSNumber *(NSNumber *sum, iTermStatusBarContainerView *view) {
        return @(sum.doubleValue + view.leftMargin + view.rightMargin);
    }] doubleValue];
     
    __block CGFloat availableWidth = self.view.frame.size.width - totalMarginWidth;
    DLog(@"updateDesiredWidths available=%@", @(availableWidth));
    // Allocate minimum widths
    [_visibleContainerViews enumerateObjectsUsingBlock:^(iTermStatusBarContainerView * _Nonnull view, NSUInteger idx, BOOL * _Nonnull stop) {
        view.desiredWidth = view.component.statusBarComponentMinimumWidth;
        availableWidth -= view.desiredWidth;
    }];
    DLog(@"updateDesiredWidths after assigning minimums: available=%@", @(availableWidth));

    if (availableWidth < 1) {
        return;
    }

    // Find views that can grow
    NSArray<iTermStatusBarContainerView *> *views = [_visibleContainerViews filteredArrayUsingBlock:^BOOL(iTermStatusBarContainerView *view) {
        return ([view.component.class statusBarComponentCanStretch] &&
                floor(view.component.statusBarComponentPreferredWidth) > floor(view.desiredWidth));
    }];


    while (views.count) {
        double sumOfSpringConstants = [[views reduceWithFirstValue:@0 block:^NSNumber *(NSNumber *sum, iTermStatusBarContainerView *containerView) {
            if (![containerView.component.class statusBarComponentCanStretch]) {
                return sum;
            }
            return @(sum.doubleValue + containerView.component.statusBarComponentSpringConstant);
        }] doubleValue];

        DLog(@"updateDesiredWidths have %@ views that can grow: available=%@",
              @(views.count), @(availableWidth));

        __block double growth = 0;
        // Divvy up space proportionate to spring constants.
        [views enumerateObjectsUsingBlock:^(iTermStatusBarContainerView * _Nonnull view, NSUInteger idx, BOOL * _Nonnull stop) {
            const double weight = view.component.statusBarComponentSpringConstant / sumOfSpringConstants;
            double delta = floor(availableWidth * weight);
            const double maximum = view.component.statusBarComponentPreferredWidth;
            const double proposed = view.desiredWidth + delta;
            const double overage = floor(MAX(0, proposed - maximum));
            delta -= overage;
            view.desiredWidth += delta;
            growth += delta;
            DLog(@"  grow %@ by %@ to %@. Its preferred width is %@", view.component, @(delta), @(view.desiredWidth), @(view.component.statusBarComponentPreferredWidth));
        }];
        availableWidth -= growth;
        DLog(@"updateDesiredWidths after divvying: available = %@", @(availableWidth));

        if (availableWidth < 1) {
            return;
        }

        const NSInteger numberBefore = views.count;
        // Remove satisifed views.
        views = [views filteredArrayUsingBlock:^BOOL(iTermStatusBarContainerView *view) {
            const BOOL unsatisfied = floor(view.component.statusBarComponentPreferredWidth) > ceil(view.desiredWidth);
            if (unsatisfied) {
                DLog(@"%@ unsatisfied prefers=%@ allocated=%@", view.component.class, @(view.component.statusBarComponentPreferredWidth), @(view.desiredWidth));
            }
            return unsatisfied;
        }];
        if (growth < 1 && views.count == numberBefore) {
            DLog(@"Stopping. growth=%@ views %@->%@", @(growth), @(views.count), @(numberBefore));
            return;
        }
    }
}

- (void)updateDesiredOrigins {
    CGFloat x = 0;
    for (iTermStatusBarContainerView *container in _visibleContainerViews) {
        x += container.leftMargin;
        container.desiredOrigin = x;
        x += container.desiredWidth;
        x += container.rightMargin;
    }
}

- (NSArray<iTermStatusBarContainerView *> *)visibleContainerViews {
    const CGFloat allowedWidth = self.view.frame.size.width;
    if (allowedWidth < iTermStatusBarViewControllerMargin * 2) {
        return @[];
    }

    NSMutableArray<iTermStatusBarContainerView *> *prioritized = [_containerViews sortedArrayUsingComparator:^NSComparisonResult(iTermStatusBarContainerView * _Nonnull obj1, iTermStatusBarContainerView * _Nonnull obj2) {
        NSComparisonResult result = [@(obj2.component.statusBarComponentPriority) compare:@(obj1.component.statusBarComponentPriority)];
        if (result != NSOrderedSame) {
            return result;
        }

        NSInteger index1 = [self->_containerViews indexOfObject:obj1];
        NSInteger index2 = [self->_containerViews indexOfObject:obj2];
        return [@(index1) compare:@(index2)];
    }].mutableCopy;
    NSMutableArray<iTermStatusBarContainerView *> *prioritizedNonzerominimum = [prioritized filteredArrayUsingBlock:^BOOL(iTermStatusBarContainerView *anObject) {
        return anObject.component.statusBarComponentMinimumWidth > 0;
    }].mutableCopy;
    CGFloat desiredWidth = [self minimumWidthOfContainerViews:prioritized];
    while (desiredWidth > allowedWidth && allowedWidth >= 0) {
        iTermStatusBarContainerView *viewToRemove = prioritizedNonzerominimum.lastObject;
        [prioritized removeObject:viewToRemove];
        [prioritizedNonzerominimum removeObject:viewToRemove];
        desiredWidth = [self minimumWidthOfContainerViews:prioritizedNonzerominimum];
    }

    // Preserve original order
    return [_containerViews filteredArrayUsingBlock:^BOOL(iTermStatusBarContainerView *anObject) {
        return [prioritized containsObject:anObject];
    }];
}

- (CGFloat)minimumWidthOfContainerViews:(NSArray<iTermStatusBarContainerView *> *)views {
    [self updateMargins:views];
    NSNumber *sumOfMinimumWidths = [views reduceWithFirstValue:@0 block:^id(NSNumber *sum, iTermStatusBarContainerView *containerView) {
        DLog(@"Minimum width of %@ is %@", containerView.component.class, @(containerView.component.statusBarComponentMinimumWidth));
        return @(sum.doubleValue + containerView.leftMargin + containerView.component.statusBarComponentMinimumWidth + containerView.rightMargin);
    }];
    return sumOfMinimumWidths.doubleValue;
}

- (iTermStatusBarContainerView *)containerViewForComponent:(id<iTermStatusBarComponent>)component {
    return [_containerViews objectPassingTest:^BOOL(iTermStatusBarContainerView *containerView, NSUInteger index, BOOL *stop) {
        return [containerView.component isEqualToComponent:component];
    }];
}

- (void)updateViews {
    NSMutableArray<iTermStatusBarContainerView *> *updatedContainerViews = [NSMutableArray array];
    NSMutableArray<id<iTermStatusBarComponent>> *components = [_layout.components mutableCopy];
    if (_temporaryLeftComponent) {
        [components insertObject:_temporaryLeftComponent atIndex:0];
    }
    if (_temporaryRightComponent) {
        iTermStatusBarSpringComponent *spring = [iTermStatusBarSpringComponent springComponentWithCompressionResistance:1];
        [components addObject:spring];
        [components addObject:_temporaryRightComponent];
    }
    for (id<iTermStatusBarComponent> component in components) {
        iTermStatusBarContainerView *view = [self containerViewForComponent:component];
        if (view) {
            [_containerViews removeObject:view];
        } else {
            view = [[iTermStatusBarContainerView alloc] initWithComponent:component];
        }
        component.delegate = self;
        [updatedContainerViews addObject:view];
    }
    _containerViews = updatedContainerViews;
    [self.view setNeedsLayout:YES];
}

#pragma mark - iTermStatusBarLayoutDelegate

- (void)statusBarLayoutDidChange:(iTermStatusBarLayout *)layout {
    [self updateViews];
}

#pragma mark - iTermStatusBarComponentDelegate

- (BOOL)statusBarComponentIsInSetupUI:(id<iTermStatusBarComponent>)component {
    return NO;
}

- (void)statusBarComponentKnobsDidChange:(id<iTermStatusBarComponent>)component {
    // Shouldn't happen since this is not the setup UI
}

- (void)statusBarComponentPreferredSizeDidChange:(id<iTermStatusBarComponent>)component {
    [self.view setNeedsLayout:YES];
}

@end

NS_ASSUME_NONNULL_END