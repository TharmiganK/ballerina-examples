import ballerina/log;
import ballerina/time;

# Success and failure counts for one slice of the rolling window.
#
# + slotId - The time slice these counts belong to; `-1` when unused
# + successes - Successful messages in the slice
# + failures - Transient failures in the slice
type Bucket record {|
    int slotId;
    int successes;
    int failures;
|};

# A circuit breaker that decides when the consumer may poll SQS.
#
# - CLOSED: poll normally.
# - OPEN: do not poll. Messages stay in the queue and their receive count does not grow.
# - HALF_OPEN: poll one trial message at a time to check whether the downstream system has recovered.
#
# The circuit opens when either rule is met:
# - the failure rate over the rolling window exceeds `failureThreshold`, or
# - `consecutiveFailureThreshold` failures happen in a row.
public isolated class PollingCircuitBreaker {
    private final string name;
    private final BreakerConfig & readonly config;
    private final int bucketCount;
    private final decimal startTime;

    private CircuitState state = CLOSED;
    private Bucket[] buckets = [];
    private int consecutiveFailures = 0;
    private decimal openUntil = 0;
    private decimal nextTrialAt = 0;

    public isolated function init(string name, BreakerConfig config) {
        self.name = name;
        self.config = config.cloneReadOnly();
        RollingWindowConfig window = config.rollingWindow;
        self.bucketCount = int:max(1, <int>(window.timeWindow / window.bucketSize).ceiling());
        self.startTime = time:monotonicNow();
        self.resetCounters();
    }

    # Called by the consumer before every poll.
    #
    # + return - Whether the consumer may poll a full batch or one trial message, or how long to wait
    public isolated function acquirePermit() returns PollPermit {
        lock {
            self.refreshState();
            decimal now = time:monotonicNow();
            if self.state == OPEN {
                return {mode: WAIT, waitSeconds: self.openUntil - now};
            }
            if self.state == HALF_OPEN {
                if now < self.nextTrialAt {
                    return {mode: WAIT, waitSeconds: self.nextTrialAt - now};
                }
                self.nextTrialAt = now + self.config.halfOpenTrialInterval;
                return {mode: TRIAL};
            }
            return {mode: FULL_BATCH};
        }
    }

    public isolated function recordSuccess() {
        lock {
            if self.state == HALF_OPEN {
                self.resetCounters();
                self.transitionTo(CLOSED);
            } else if self.state == CLOSED {
                self.consecutiveFailures = 0;
                self.addResult(failed = false);
            }
        }
    }

    # Record only transient failures here. Permanent failures say nothing about the downstream system's health.
    public isolated function recordTransientFailure() {
        lock {
            if self.state == HALF_OPEN {
                self.open(reason = "trial message failed");
                return;
            }
            if self.state != CLOSED {
                return;
            }
            self.consecutiveFailures += 1;
            self.addResult(failed = true);

            int? consecutiveLimit = self.config.consecutiveFailureThreshold;
            if consecutiveLimit is int && self.consecutiveFailures >= consecutiveLimit {
                self.open(reason = string `${self.consecutiveFailures} failures in a row`);
                return;
            }
            [int, int] [totalCount, failureCount] = self.windowCounts();
            if totalCount < self.config.rollingWindow.requestVolumeThreshold {
                return;
            }
            float failureRate = <float>failureCount / <float>totalCount;
            if failureRate > self.config.failureThreshold {
                self.open(reason = string `failure rate ${failureRate} over ${totalCount} messages`);
            }
        }
    }

    # + return - The current state. An open circuit whose open period has ended is reported as `HALF_OPEN`
    public isolated function currentState() returns CircuitState {
        lock {
            self.refreshState();
            return self.state;
        }
    }

    # + return - Seconds left until the circuit stops being open, rounded up; `0` when it is not open
    public isolated function remainingOpenSeconds() returns int {
        lock {
            self.refreshState();
            if self.state != OPEN {
                return 0;
            }
            decimal remaining = self.openUntil - time:monotonicNow();
            return remaining <= 0d ? 0 : <int>remaining.ceiling();
        }
    }

    # Moves an open circuit to half-open once its open period has ended. Every read of the state calls this, so the
    # breaker moves on without a timer thread and even though nothing is being polled.
    private isolated function refreshState() {
        lock {
            decimal now = time:monotonicNow();
            if self.state == OPEN && now >= self.openUntil {
                self.transitionTo(HALF_OPEN);
                self.nextTrialAt = now;
            }
        }
    }

    private isolated function open(string reason) {
        lock {
            self.openUntil = time:monotonicNow() + self.config.resetTime;
            self.transitionTo(OPEN);
            log:printWarn("Circuit opened", breaker = self.name, reason = reason, openSeconds = self.config.resetTime);
        }
    }

    private isolated function addResult(boolean failed) {
        lock {
            int slotId = self.currentSlotId();
            Bucket bucket = self.buckets[slotId % self.bucketCount];
            if bucket.slotId != slotId {
                // This bucket still holds an old time slice; reuse it for the current one.
                bucket.slotId = slotId;
                bucket.successes = 0;
                bucket.failures = 0;
            }
            if failed {
                bucket.failures += 1;
            } else {
                bucket.successes += 1;
            }
        }
    }

    # + return - Total results and failures that are still inside the rolling window
    private isolated function windowCounts() returns [int, int] {
        lock {
            int currentSlot = self.currentSlotId();
            int totalCount = 0;
            int failureCount = 0;
            foreach Bucket bucket in self.buckets {
                if bucket.slotId >= 0 && currentSlot - bucket.slotId < self.bucketCount {
                    totalCount += bucket.successes + bucket.failures;
                    failureCount += bucket.failures;
                }
            }
            return [totalCount, failureCount];
        }
    }

    private isolated function currentSlotId() returns int {
        decimal elapsed = time:monotonicNow() - self.startTime;
        return <int>(elapsed / self.config.rollingWindow.bucketSize).floor();
    }

    # Clears all counts, so failures from before an outage cannot reopen the circuit after it closes.
    private isolated function resetCounters() {
        lock {
            self.consecutiveFailures = 0;
            Bucket[] emptyBuckets = [];
            foreach int _ in 0 ..< self.bucketCount {
                emptyBuckets.push({slotId: -1, successes: 0, failures: 0});
            }
            self.buckets = emptyBuckets;
        }
    }

    private isolated function transitionTo(CircuitState newState) {
        lock {
            log:printInfo("Circuit state changed", breaker = self.name, fromState = self.state, toState = newState);
            self.state = newState;
        }
    }
}
