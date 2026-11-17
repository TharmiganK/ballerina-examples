import ballerina/lang.runtime;
import ballerina/test;

// Short timings keep the tests fast: a 2 s window of four 0.5 s buckets, and a 1 s open period.
final RollingWindowConfig shortWindow = {timeWindow: 2, bucketSize: 0.5, requestVolumeThreshold: 4};

final BreakerConfig rateOnlyConfig = {
    rollingWindow: shortWindow,
    failureThreshold: 0.5,
    consecutiveFailureThreshold: (),
    resetTime: 1,
    halfOpenTrialInterval: 0
};

// The volume threshold is out of reach here, so only the consecutive rule can open the circuit.
final BreakerConfig consecutiveOnlyConfig = {
    rollingWindow: {timeWindow: 2, bucketSize: 0.5, requestVolumeThreshold: 100},
    consecutiveFailureThreshold: 3,
    resetTime: 1,
    halfOpenTrialInterval: 0
};

isolated function recordFailures(PollingCircuitBreaker breaker, int count) {
    foreach int _ in 1 ... count {
        breaker.recordTransientFailure();
    }
}

@test:Config
function rateRuleWaitsForRequestVolume() {
    PollingCircuitBreaker breaker = new (name = "test", config = rateOnlyConfig);
    recordFailures(breaker, count = 3);
    test:assertEquals(actual = breaker.currentState(), expected = CLOSED, msg = "3 results is below the volume of 4");
    breaker.recordTransientFailure();
    test:assertEquals(actual = breaker.currentState(), expected = OPEN);
    test:assertEquals(actual = breaker.acquirePermit().mode, expected = WAIT, msg = "no polling while open");
}

@test:Config
function rateMustExceedThreshold() {
    PollingCircuitBreaker breaker = new (name = "test", config = rateOnlyConfig);
    breaker.recordSuccess();
    breaker.recordSuccess();
    recordFailures(breaker, count = 2);
    test:assertEquals(actual = breaker.currentState(), expected = CLOSED, msg = "0.5 is not greater than 0.5");
    breaker.recordTransientFailure();
    test:assertEquals(actual = breaker.currentState(), expected = OPEN, msg = "0.6 is greater than 0.5");
}

@test:Config
function oldFailuresLeaveTheWindow() {
    PollingCircuitBreaker breaker = new (name = "test", config = rateOnlyConfig);
    recordFailures(breaker, count = 3);
    runtime:sleep(2.6);
    breaker.recordTransientFailure();
    test:assertEquals(actual = breaker.currentState(), expected = CLOSED, msg = "only 1 failure left in the window");
}

@test:Config
function consecutiveRuleOpensOnQuietQueue() {
    PollingCircuitBreaker breaker = new (name = "test", config = consecutiveOnlyConfig);
    // Each failure arrives after the previous one has left the 2 s window, as on a quiet queue.
    foreach int attempt in 1 ... 3 {
        if attempt > 1 {
            runtime:sleep(2.1);
        }
        breaker.recordTransientFailure();
    }
    test:assertEquals(actual = breaker.currentState(), expected = OPEN);
}

@test:Config
function successResetsConsecutiveCount() {
    PollingCircuitBreaker breaker = new (name = "test", config = consecutiveOnlyConfig);
    recordFailures(breaker, count = 2);
    breaker.recordSuccess();
    recordFailures(breaker, count = 2);
    test:assertEquals(actual = breaker.currentState(), expected = CLOSED, msg = "never 3 in a row");
    breaker.recordTransientFailure();
    test:assertEquals(actual = breaker.currentState(), expected = OPEN);
}

@test:Config
function consecutiveRuleCanBeTurnedOff() {
    PollingCircuitBreaker breaker = new (name = "test", config = {
        rollingWindow: {requestVolumeThreshold: 100},
        consecutiveFailureThreshold: ()
    });
    recordFailures(breaker, count = 5);
    test:assertEquals(actual = breaker.currentState(), expected = CLOSED);
}

@test:Config
function halfOpenTrialFailsThenSucceeds() {
    PollingCircuitBreaker breaker = new (name = "test", config = consecutiveOnlyConfig);
    recordFailures(breaker, count = 3);
    test:assertEquals(actual = breaker.currentState(), expected = OPEN);

    runtime:sleep(1.1);
    test:assertEquals(actual = breaker.acquirePermit().mode, expected = TRIAL, msg = "one trial message");
    test:assertEquals(actual = breaker.currentState(), expected = HALF_OPEN);
    breaker.recordTransientFailure();
    test:assertEquals(actual = breaker.currentState(), expected = OPEN, msg = "a failed trial reopens the circuit");

    runtime:sleep(1.1);
    test:assertEquals(actual = breaker.acquirePermit().mode, expected = TRIAL);
    breaker.recordSuccess();
    test:assertEquals(actual = breaker.currentState(), expected = CLOSED);
    test:assertEquals(actual = breaker.acquirePermit().mode, expected = FULL_BATCH, msg = "full batches again");

    recordFailures(breaker, count = 2);
    test:assertEquals(actual = breaker.currentState(), expected = CLOSED, msg = "counts were cleared on close");
}

// The consumer relies on this: once the open period ends, the next message of a batch is processed as the trial.
@test:Config
function stateBecomesHalfOpenWithoutAPoll() {
    PollingCircuitBreaker breaker = new (name = "test", config = consecutiveOnlyConfig);
    recordFailures(breaker, count = 3);
    test:assertTrue(breaker.remainingOpenSeconds() > 0);
    runtime:sleep(1.1);
    test:assertEquals(actual = breaker.currentState(), expected = HALF_OPEN);
    test:assertEquals(actual = breaker.remainingOpenSeconds(), expected = 0);
    breaker.recordSuccess();
    test:assertEquals(actual = breaker.currentState(), expected = CLOSED, msg = "the next result decides");
}

@test:Config
function halfOpenSpacesOutTrials() {
    PollingCircuitBreaker breaker = new (name = "test", config = {
        consecutiveFailureThreshold: 1,
        resetTime: 0.5,
        halfOpenTrialInterval: 1
    });
    breaker.recordTransientFailure();
    runtime:sleep(0.6);
    test:assertEquals(actual = breaker.acquirePermit().mode, expected = TRIAL);
    PollPermit nextPermit = breaker.acquirePermit();
    test:assertEquals(actual = nextPermit.mode, expected = WAIT, msg = "the next trial must wait");
    test:assertTrue(nextPermit.waitSeconds > 0d);
}
