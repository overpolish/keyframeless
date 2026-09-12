/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#include "MTDurationRecords.h"
#include <math.h>
#include <stdlib.h>

static bool validRecords(const MTDurationRecord *records, size_t count) {
    if (count && !records) return false;
    for (size_t i = 0; i < count; ++i) {
        if ((records[i].addedMotion < MTAddedMotionNone || records[i].addedMotion > MTAddedMotionHandheld) || (records[i].easing < MTEasingSmooth || records[i].easing > MTEasingEaseOut) || !isfinite(records[i].time) || !isfinite(records[i].value) ||
            !isfinite(records[i].duration) || records[i].duration < 0 ||
            (i && records[i].time <= records[i - 1].time)) return false;
    }
    return true;
}

static size_t countUnmatchedValue(const MTDurationRecord *records, size_t count,
                                  const bool *matched, double value,
                                  size_t *found) {
    size_t total = 0;
    *found = 0;
    for (size_t i = 0; i < count; ++i) {
        if (!matched[i] && records[i].value == value) {
            total++;
            *found = i;
        }
    }
    return total;
}

bool MTReconcileDurations(const MTDurationRecord *previous,
                          size_t previousCount,
                          const MTDurationRecord *current,
                          size_t currentCount,
                          double defaultDuration,
                          MTDurationRecord *output) {
    if (!validRecords(previous, previousCount) ||
        !validRecords(current, currentCount) || !isfinite(defaultDuration) ||
        defaultDuration < 0 || (currentCount && !output)) return false;

    bool *previousMatched = previousCount ? calloc(previousCount, sizeof(bool)) : NULL;
    bool *currentMatched = currentCount ? calloc(currentCount, sizeof(bool)) : NULL;
    if ((previousCount && !previousMatched) || (currentCount && !currentMatched)) {
        free(previousMatched);
        free(currentMatched);
        return false;
    }

    bool matchEndpoints = false;
    for (size_t i = 0; i < previousCount; ++i) matchEndpoints |= previous[i].matchEndpoints;
    for (size_t i = 0; i < currentCount; ++i) {
        output[i] = current[i];
        output[i].matchEndpoints = matchEndpoints;
        output[i].linkID = 0;
        output[i].previousIndex = SIZE_MAX;
        for (size_t j = 0; j < previousCount; ++j) {
            if (!previousMatched[j] && current[i].time == previous[j].time) {
                currentMatched[i] = previousMatched[j] = true;
                output[i].duration = previous[j].duration;
                output[i].useAvailableTime = previous[j].useAvailableTime;
                output[i].easing = previous[j].easing;
                output[i].addedMotion = previous[j].addedMotion;
                output[i].linkID = previous[j].linkID;
                output[i].previousIndex = j;
                break;
            }
        }
    }

    // A value match is safe only when that value occurs once on each side
    // among the records still without an association.
    for (size_t i = 0; i < currentCount; ++i) {
        if (currentMatched[i]) continue;
        size_t previousIndex = 0, currentIndex = 0;
        size_t previousMatches = countUnmatchedValue(previous, previousCount,
                                                      previousMatched,
                                                      current[i].value,
                                                      &previousIndex);
        size_t currentMatches = countUnmatchedValue(current, currentCount,
                                                     currentMatched,
                                                     current[i].value,
                                                     &currentIndex);
        if (previousMatches == 1 && currentMatches == 1) {
            currentMatched[currentIndex] = previousMatched[previousIndex] = true;
            output[currentIndex].duration = previous[previousIndex].duration;
            output[currentIndex].useAvailableTime = previous[previousIndex].useAvailableTime;
            output[currentIndex].easing = previous[previousIndex].easing;
            output[currentIndex].addedMotion = previous[previousIndex].addedMotion;
            output[currentIndex].linkID = previous[previousIndex].linkID;
            output[currentIndex].previousIndex = previousIndex;
        }
    }

    size_t previousRemaining = 0, currentRemaining = 0;
    for (size_t i = 0; i < previousCount; ++i) previousRemaining += !previousMatched[i];
    for (size_t i = 0; i < currentCount; ++i) currentRemaining += !currentMatched[i];
    if (previousRemaining == currentRemaining) {
        size_t previousIndex = 0;
        for (size_t currentIndex = 0; currentIndex < currentCount; ++currentIndex) {
            if (currentMatched[currentIndex]) continue;
            while (previousIndex < previousCount && previousMatched[previousIndex])
                previousIndex++;
            previousMatched[previousIndex] = currentMatched[currentIndex] = true;
            output[currentIndex].duration = previous[previousIndex].duration;
            output[currentIndex].useAvailableTime = previous[previousIndex].useAvailableTime;
            output[currentIndex].easing = previous[previousIndex].easing;
            output[currentIndex].addedMotion = previous[previousIndex].addedMotion;
            output[currentIndex].linkID = previous[previousIndex].linkID;
            output[currentIndex].previousIndex = previousIndex;
            previousIndex++;
        }
    }
    for (size_t i = 0; i < currentCount; ++i)
        if (!currentMatched[i]) {
            output[i].duration = defaultDuration;
            output[i].useAvailableTime = false;
            output[i].easing = MTEasingSmooth;
            output[i].addedMotion = MTAddedMotionNone;
        }

    free(previousMatched);
    free(currentMatched);
    return true;
}
