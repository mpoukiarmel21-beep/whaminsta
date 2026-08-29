#import <UIKit/UIKit.h>
#import "../Core/IVContainer.h"

NS_ASSUME_NONNULL_BEGIN

/// Per-container auto-swipe configuration panel, PUSHED on the panel's nav stack.
/// The user enters the phrases the bot may auto-send on a match (one per line),
/// the number of swipes (0 = unlimited) and the min/max delay (seconds) between
/// actions. "Enregistrer" persists the config (and lights the row icon).
/// "Démarrer" persists, starts the IVAutoSwipe engine, and dismisses the whole
/// panel so Instagram's own UI is frontmost for the bot to drive. "Arrêter" stops it.
@interface IVAutoSwipeVC : UIViewController
- (instancetype)initWithContainer:(IVContainer *)container;
@end

NS_ASSUME_NONNULL_END
