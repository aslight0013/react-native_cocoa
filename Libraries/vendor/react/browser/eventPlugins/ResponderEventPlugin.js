/**
 * Copyright 2013-2014 Facebook, Inc.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 * @providesModule ResponderEventPlugin
 */

"use strict";

var EventConstants = require('EventConstants');
var EventPluginUtils = require('EventPluginUtils');
var EventPropagators = require('EventPropagators');
var NodeHandle = require('NodeHandle');
var ReactInstanceHandles = require('ReactInstanceHandles');
var ResponderSyntheticEvent = require('ResponderSyntheticEvent');
var ResponderTouchHistoryStore = require('ResponderTouchHistoryStore');

var accumulate = require('accumulate');
var keyOf = require('keyOf');

var isStartish = EventPluginUtils.isStartish;
var isMoveish = EventPluginUtils.isMoveish;
var isEndish = EventPluginUtils.isEndish;
var executeDirectDispatch = EventPluginUtils.executeDirectDispatch;
var hasDispatches = EventPluginUtils.hasDispatches;
var executeDispatchesInOrderStopAtTrue =
  EventPluginUtils.executeDispatchesInOrderStopAtTrue;

/**
 * ID of element that should respond to touch/move types of interactions, as
 * indicated explicitly by relevant callbacks.
 */
var responderID = null;

/**
 * Last reported number of active touches.
 */
var previousActiveTouches = 0;

var changeResponder = function(nextResponderID) {
  var oldResponderID = responderID;
  responderID = nextResponderID;
  if (ResponderEventPlugin.GlobalResponderHandler !== null) {
    ResponderEventPlugin.GlobalResponderHandler.onChange(
      oldResponderID,
      nextResponderID
    );
  }
};

var eventTypes = {
  /**
   * On a `touchStart`/`mouseDown`, is it desired that this element become the
   * responder?
   */
  startShouldSetResponder: {
    phasedRegistrationNames: {
      bubbled: keyOf({onStartShouldSetResponder: null}),
      captured: keyOf({onStartShouldSetResponderCapture: null})
    }
  },

  /**
   * On a `scroll`, is it desired that this element become the responder? This
   * is usually not needed, but should be used to retroactively infer that a
   * `touchStart` had occured during momentum scroll. During a momentum scroll,
   * a touch start will be immediately followed by a scroll event if the view is
   * currently scrolling.
   *
   * TODO: This shouldn't bubble.
   */
  scrollShouldSetResponder: {
    phasedRegistrationNames: {
      bubbled: keyOf({onScrollShouldSetResponder: null}),
      captured: keyOf({onScrollShouldSetResponderCapture: null})
    }
  },

  /**
   * On text selection change, should this element become the responder? This
   * is needed for text inputs or other views with native selection, so the
   * JS view can claim the responder.
   *
   * TODO: This shouldn't bubble.
   */
  selectionChangeShouldSetResponder: {
    phasedRegistrationNames: {
      bubbled: keyOf({onSelectionChangeShouldSetResponder: null}),
      captured: keyOf({onSelectionChangeShouldSetResponderCapture: null})
    }
  },

  /**
   * On a `touchMove`/`mouseMove`, is it desired that this element become the
   * responder?
   */
  moveShouldSetResponder: {
    phasedRegistrationNames: {
      bubbled: keyOf({onMoveShouldSetResponder: null}),
      captured: keyOf({onMoveShouldSetResponderCapture: null})
    }
  },

  /**
   * Direct responder events dispatched directly to responder. Do not bubble.
   */
  responderStart: {registrationName: keyOf({onResponderStart: null})},
  responderMove: {registrationName: keyOf({onResponderMove: null})},
  responderEnd: {registrationName: keyOf({onResponderEnd: null})},
  responderRelease: {registrationName: keyOf({onResponderRelease: null})},
  responderTerminationRequest: {
    registrationName: keyOf({onResponderTerminationRequest: null})
  },
  responderGrant: {registrationName: keyOf({onResponderGrant: null})},
  responderReject: {registrationName: keyOf({onResponderReject: null})},
  responderTerminate: {registrationName: keyOf({onResponderTerminate: null})}
};

/**
 *
 * Responder System:
 * ----------------
 *
 * - A global, solitary "interaction lock" on a view.
 * - If a `NodeHandle` becomes the responder, it should convey visual feedback
 *   immediately to indicate so, either by highlighting or moving accordingly.
 * - To be the responder means, that touches are exclusively important to that
 *   responder view, and no other view.
 * - While touches are still occuring, the responder lock can be transfered to
 *   a new view, but only to increasingly "higher" views (meaning ancestors of
 *   the current responder).
 *
 * Responder being granted:
 * ------------------------
 *
 * - Touch starts, moves, and scrolls can cause an ID to become the responder.
 * - We capture/bubble `startShouldSetResponder`/`moveShouldSetResponder` to
 *   the "appropriate place".
 * - If nothing is currently the responder, the "appropriate place" is the
 *   initiating event's `targetID`.
 * - If something *is* already the responder, the "appropriate place" is the
 *   first common ancestor of the event target and the current `responderID`.
 * - Some negotiation happens: See the timing diagram below.
 * - Scrolled views automatically become responder. The reasoning is that a
 *   platform scroll view that isn't built on top of the responder system has
 *   began scrolling, and the active responder must now be notified that the
 *   interaction is no longer locked to it - the system has taken over.
 *
 * - Responder being released:
 *   As soon as no more touches that *started* inside of descendents of the
 *   *current* responderID, an `onResponderRelease` event is dispatched to the
 *   current responder, and the responder lock is released.
 *
 * TODO:
 * - on "end", a callback hook for `onResponderEndShouldRemainResponder` that
 *   determines if the responder lock should remain.
 * - If a view shouldn't "remain" the responder, any active touches should by
 *   default be considered "dead" and do not influence future negotiations or
 *   bubble paths. It should be as if those touches do not exist.
 * -- For multitouch: Usually a translate-z will choose to "remain" responder
 *  after one out of many touches ended. For translate-y, usually the view
 *  doesn't wish to "remain" responder after one of many touches end.
 * - Consider building this on top of a `stopPropagation` model similar to
 *   `W3C` events.
 * - Ensure that `onResponderTerminate` is called on touch cancels, whether or
 *   not `onResponderTerminationRequest` returns `true` or `false`.
 *
 */

/*                                             Negotiation Performed
                                             +-----------------------+
                                            /                         \
Process low level events to    +     Current Responder      +   wantsResponderID
determine who to perform negot-|   (if any exists at all)   |
iation/transition              | Otherwise just pass through|
-------------------------------+----------------------------+------------------+
Bubble to find first ID        |                            |
to return true:wantsResponderID|                            |
                               |                            |
     +-------------+           |                            |
     | onTouchStart|           |                            |
     +------+------+     none  |                            |
            |            return|                            |
+-----------v-------------+true| +------------------------+ |
|onStartShouldSetResponder|----->|onResponderStart (cur)  |<-----------+
+-----------+-------------+    | +------------------------+ |          |
            |                  |                            | +--------+-------+
            | returned true for|       false:REJECT +-------->|onResponderReject
            | wantsResponderID |                    |       | +----------------+
            | (now attempt     | +------------------+-----+ |
            |  handoff)        | |   onResponder          | |
            +------------------->|      TerminationRequest| |
                               | +------------------+-----+ |
                               |                    |       | +----------------+
                               |         true:GRANT +-------->|onResponderGrant|
                               |                            | +--------+-------+
                               | +------------------------+ |          |
                               | |   onResponderTerminate |<-----------+
                               | +------------------+-----+ |
                               |                    |       | +----------------+
                               |                    +-------->|onResponderStart|
                               |                            | +----------------+
Bubble to find first ID        |                            |
to return true:wantsResponderID|                            |
                               |                            |
     +-------------+           |                            |
     | onTouchMove |           |                            |
     +------+------+     none  |                            |
            |            return|                            |
+-----------v-------------+true| +------------------------+ |
|onMoveShouldSetResponder |----->|onResponderMove (cur)   |<-----------+
+-----------+-------------+    | +------------------------+ |          |
            |                  |                            | +--------+-------+
            | returned true for|       false:REJECT +-------->|onResponderRejec|
            | wantsResponderID |                    |       | +----------------+
            | (now attempt     | +------------------+-----+ |
            |  handoff)        | |   onResponder          | |
            +------------------->|      TerminationRequest| |
                               | +------------------+-----+ |
                               |                    |       | +----------------+
                               |         true:GRANT +-------->|onResponderGrant|
                               |                            | +--------+-------+
                               | +------------------------+ |          |
                               | |   onResponderTerminate |<-----------+
                               | +------------------+-----+ |
                               |                    |       | +----------------+
                               |                    +-------->|onResponderMove |
                               |                            | +----------------+
                               |                            |
                               |                            |
      Some active touch started|                            |
      inside current responder | +------------------------+ |
      +------------------------->|      onResponderEnd    | |
      |                        | +------------------------+ |
  +---+---------+              |                            |
  | onTouchEnd  |              |                            |
  +---+---------+              |                            |
      |                        | +------------------------+ |
      +------------------------->|     onResponderEnd     | |
      No active touches started| +-----------+------------+ |
      inside current responder |             |              |
                               |             v              |
                               | +------------------------+ |
                               | |    onResponderRelease  | |
                               | +------------------------+ |
                               |                            |
                               +                            + */



/**
 * A note about event ordering in the `EventPluginHub`.
 *
 * Suppose plugins are injected in the following order:
 *
 * `[R, S, C]`
 *
 * To help illustrate the example, assume `S` is `SimpleEventPlugin` (for
 * `onClick` etc) and `R` is `ResponderEventPlugin`.
 *
 * "Deferred-Dispatched Events":
 *
 * - The current event plugin system will traverse the list of injected plugins,
 *   in order, and extract events by collecting the plugin's return value of
 *   `extractEvents()`.
 * - These events that are returned from `extractEvents` are "deferred
 *   dispatched events".
 * - When returned from `extractEvents`, deferred-dispatched events contain an
 *   "accumulation" of deferred dispatches.
 * - These deferred dispatches are accumulated/collected before they are
 *   returned, but processed at a later time by the `EventPluginHub` (hence the
 *   name deferred).
 *
 * In the process of returning their deferred-dispatched events, event plugins
 * themselves can dispatch events on-demand without returning them from
 * `extractEvents`. Plugins might want to do this, so that they can use event
 * dispatching as a tool that helps them decide which events should be extracted
 * in the first place.
 *
 * "On-Demand-Dispatched Events":
 *
 * - On-demand-dispatched events are not returned from `extractEvents`.
 * - On-demand-dispatched events are dispatched during the process of returning
 *   the deferred-dispatched events.
 * - They should not have side effects.
 * - They should be avoided, and/or eventually be replaced with another
 *   abstraction that allows event plugins to perform multiple "rounds" of event
 *   extraction.
 *
 * Therefore, the sequence of event dispatches becomes:
 *
 * - `R`s on-demand events (if any)   (dispatched by `R` on-demand)
 * - `S`s on-demand events (if any)   (dispatched by `S` on-demand)
 * - `C`s on-demand events (if any)   (dispatched by `C` on-demand)
 * - `R`s extracted events (if any)   (dispatched by `EventPluginHub`)
 * - `S`s extracted events (if any)   (dispatched by `EventPluginHub`)
 * - `C`s extracted events (if any)   (dispatched by `EventPluginHub`)
 *
 * In the case of `ResponderEventPlugin`: If the `startShouldSetResponder`
 * on-demand dispatch returns `true` (and some other details are satisfied) the
 * `onResponderGrant` deferred dispatched event is returned from
 * `extractEvents`. The sequence of dispatch executions in this case
 * will appear as follows:
 *
 * - `startShouldSetResponder` (`ResponderEventPlugin` dispatches on-demand)
 * - `touchStartCapture`       (`EventPluginHub` dispatches as usual)
 * - `touchStart`              (`EventPluginHub` dispatches as usual)
 * - `responderGrant/Reject`   (`EventPluginHub` dispatches as usual)
 *
 * @param {string} topLevelType Record from `EventConstants`.
 * @param {string} topLevelTargetID ID of deepest React rendered element.
 * @param {object} nativeEvent Native browser event.
 * @return {*} An accumulation of synthetic events.
 */
function setResponderAndExtractTransfer(
    topLevelType,
    topLevelTargetID,
    nativeEvent) {
  var shouldSetEventType =
    isStartish(topLevelType) ? eventTypes.startShouldSetResponder :
    isMoveish(topLevelType) ? eventTypes.moveShouldSetResponder :
    topLevelType === EventConstants.topLevelTypes.topSelectionChange ?
      eventTypes.selectionChangeShouldSetResponder :
    eventTypes.scrollShouldSetResponder;

  // TODO: stop one short of the the current responder.
  var bubbleShouldSetFrom = !responderID ?
    topLevelTargetID :
    ReactInstanceHandles._getFirstCommonAncestorID(responderID, topLevelTargetID);

  // When capturing/bubbling the "shouldSet" event, we want to skip the target
  // (deepest ID) if it happens to be the current responder. The reasoning:
  // It's strange to get an `onMoveShouldSetResponder` when you're *already*
  // the responder.
  var skipOverBubbleShouldSetFrom = bubbleShouldSetFrom === responderID;
  var shouldSetEvent = ResponderSyntheticEvent.getPooled(
    shouldSetEventType,
    bubbleShouldSetFrom,
    nativeEvent
  );
  shouldSetEvent.touchHistory = ResponderTouchHistoryStore.touchHistory;
  if (skipOverBubbleShouldSetFrom) {
    EventPropagators.accumulateTwoPhaseDispatchesSkipTarget(shouldSetEvent);
  } else {
    EventPropagators.accumulateTwoPhaseDispatches(shouldSetEvent);
  }
  var wantsResponderID = executeDispatchesInOrderStopAtTrue(shouldSetEvent);
  if (!shouldSetEvent.isPersistent()) {
    shouldSetEvent.constructor.release(shouldSetEvent);
  }

  if (!wantsResponderID || wantsResponderID === responderID) {
    return null;
  }
  var extracted;
  var grantEvent = ResponderSyntheticEvent.getPooled(
    eventTypes.responderGrant,
    wantsResponderID,
    nativeEvent
  );
  grantEvent.touchHistory = ResponderTouchHistoryStore.touchHistory;

  EventPropagators.accumulateDirectDispatches(grantEvent);
  if (responderID) {

    var terminationRequestEvent = ResponderSyntheticEvent.getPooled(
      eventTypes.responderTerminationRequest,
      responderID,
      nativeEvent
    );
    terminationRequestEvent.touchHistory = ResponderTouchHistoryStore.touchHistory;
    EventPropagators.accumulateDirectDispatches(terminationRequestEvent);
    var shouldSwitch = !hasDispatches(terminationRequestEvent) ||
      executeDirectDispatch(terminationRequestEvent);
    if (!terminationRequestEvent.isPersistent()) {
      terminationRequestEvent.constructor.release(terminationRequestEvent);
    }

    if (shouldSwitch) {
      var terminateType = eventTypes.responderTerminate;
      var terminateEvent = ResponderSyntheticEvent.getPooled(
        terminateType,
        responderID,
        nativeEvent
      );
      terminateEvent.touchHistory = ResponderTouchHistoryStore.touchHistory;
      EventPropagators.accumulateDirectDispatches(terminateEvent);
      extracted = accumulate(extracted, [grantEvent, terminateEvent]);
      changeResponder(wantsResponderID);
    } else {
      var rejectEvent = ResponderSyntheticEvent.getPooled(
        eventTypes.responderReject,
        wantsResponderID,
        nativeEvent
      );
      rejectEvent.touchHistory = ResponderTouchHistoryStore.touchHistory;
      EventPropagators.accumulateDirectDispatches(rejectEvent);
      extracted = accumulate(extracted, rejectEvent);
    }
  } else {
    extracted = accumulate(extracted, grantEvent);
    changeResponder(wantsResponderID);
  }
  return extracted;
}

/**
 * A transfer is a negotiation between a currently set responder and the next
 * element to claim responder status. Any start event could trigger a transfer
 * of responderID. Any move event could trigger a transfer.
 *
 * @param {string} topLevelType Record from `EventConstants`.
 * @return {boolean} True if a transfer of responder could possibly occur.
 */
function canTriggerTransfer(topLevelType, topLevelTargetID) {
  return topLevelTargetID && (
    topLevelType === EventConstants.topLevelTypes.topScroll ||
    topLevelType === EventConstants.topLevelTypes.topSelectionChange ||
    isStartish(topLevelType) ||
    isMoveish(topLevelType)
  );
}

/**
 * Returns whether or not this touch end event makes it such that there are no
 * longer any touches that started inside of the current `responderID`.
 *
 * @param {NativeEvent} nativeEvent Native touch end event.
 * @return {bool} Whether or not this touch end event ends the responder.
 */
function noResponderTouches(nativeEvent) {
  var touches = nativeEvent.touches;
  if (!touches || touches.length === 0) {
    return true;
  }
  for (var i = 0; i < touches.length; i++) {
    var activeTouch = touches[i];
    var target = activeTouch.target;
    if (target !== null && target !== undefined && target !== 0) {
      // Is the original touch location inside of the current responder?
      var commonAncestor =
        ReactInstanceHandles._getFirstCommonAncestorID(
          responderID,
          NodeHandle.getRootNodeID(target)
        );
      if (commonAncestor === responderID) {
        return false;
      }
    }
  }
  return true;
}


var ResponderEventPlugin = {

  getResponderID: function() {
    return responderID;
  },

  eventTypes: eventTypes,

  /**
   * We must be resilient to `topLevelTargetID` being `undefined` on
   * `touchMove`, or `touchEnd`. On certain platforms, this means that a native
   * scroll has assumed control and the original touch targets are destroyed.
   *
   * @param {string} topLevelType Record from `EventConstants`.
   * @param {DOMEventTarget} topLevelTarget The listening component root node.
   * @param {string} topLevelTargetID ID of `topLevelTarget`.
   * @param {object} nativeEvent Native browser event.
   * @return {*} An accumulation of synthetic events.
   * @see {EventPluginHub.extractEvents}
   */
  extractEvents: function(
      topLevelType,
      topLevelTarget,
      topLevelTargetID,
      nativeEvent) {


    ResponderTouchHistoryStore.recordTouchTrack(topLevelType, nativeEvent);

    var extracted = canTriggerTransfer(topLevelType, topLevelTargetID) ?
      setResponderAndExtractTransfer(topLevelType, topLevelTargetID, nativeEvent) :
      null;
    // Responder may or may not have transfered on a new touch start/move.
    // Regardless, whoever is the responder after any potential transfer, we
    // direct all touch start/move/ends to them in the form of
    // `onResponderMove/Start/End`. These will be called for *every* additional
    // finger that move/start/end, dispatched directly to whoever is the
    // current responder at that moment, until the responder is "released".
    //
    // These multiple individual change touch events are are always bookended
    // by `onResponderGrant`, and one of
    // (`onResponderRelease/onResponderTerminate`).
    var isResponderTouchStart = responderID && isStartish(topLevelType);
    var isResponderTouchMove = responderID && isMoveish(topLevelType);
    var isResponderTouchTerminate = responderID && topLevelType === EventConstants.topLevelTypes.topTouchCancel;
    var isResponderTouchEnd = responderID && isEndish(topLevelType);
    var incrementalTouch =
      isResponderTouchStart ? eventTypes.responderStart :
      isResponderTouchMove ? eventTypes.responderMove :
      isResponderTouchTerminate ? eventTypes.responderTerminate :
      isResponderTouchEnd ? eventTypes.responderEnd :
      null;

    if (incrementalTouch) {
      var gesture =
        ResponderSyntheticEvent.getPooled(incrementalTouch, responderID, nativeEvent);
      gesture.touchHistory = ResponderTouchHistoryStore.touchHistory;
      EventPropagators.accumulateDirectDispatches(gesture);
      extracted = accumulate(extracted, gesture);
    }

    var isResponderRelease =
      responderID && isEndish(topLevelType) && noResponderTouches(nativeEvent);
    if (isResponderRelease) {
      var release = ResponderSyntheticEvent.getPooled(
        eventTypes.responderRelease,
        responderID,
        nativeEvent
      );
      release.touchHistory = ResponderTouchHistoryStore.touchHistory;
      EventPropagators.accumulateDirectDispatches(release);
      extracted = accumulate(extracted, release);
      changeResponder(null);
    }

    var numberActiveTouches =
      ResponderTouchHistoryStore.touchHistory.numberActiveTouches;
    if (ResponderEventPlugin.GlobalInteractionHandler &&
      numberActiveTouches !== previousActiveTouches) {
      ResponderEventPlugin.GlobalInteractionHandler.onChange(
        numberActiveTouches
      );
    }
    previousActiveTouches = numberActiveTouches;

    return extracted;
  },

  GlobalResponderHandler: null,
  GlobalInteractionHandler: null,

  injection: {
    /**
     * @param {{onChange: (ReactID, ReactID) => void} GlobalResponderHandler
     * Object that handles any change in responder. Use this to inject
     * integration with an existing touch handling system etc.
     */
    injectGlobalResponderHandler: function(GlobalResponderHandler) {
      ResponderEventPlugin.GlobalResponderHandler = GlobalResponderHandler;
    },

    /**
     * @param {{onChange: (numberActiveTouches) => void} GlobalInteractionHandler
     * Object that handles any change in the number of active touches.
     */
    injectGlobalInteractionHandler: function(GlobalInteractionHandler) {
      ResponderEventPlugin.GlobalInteractionHandler = GlobalInteractionHandler;
    },
  }
};

module.exports = ResponderEventPlugin;
