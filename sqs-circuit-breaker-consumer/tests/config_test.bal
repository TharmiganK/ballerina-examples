import ballerina/test;

@test:Config
function defaultsAreValid() {
    test:assertEquals(actual = validateConfig({}, {}), expected = ());
}

function invalidConfigs() returns map<[ConsumerConfig, BreakerConfig, string]> {
    return {
        "batch too large": [{maxBatchSize: 20}, {}, "maxBatchSize"],
        "batch empty": [{maxBatchSize: 0}, {}, "maxBatchSize"],
        "wait too long": [{waitTimeSeconds: 25}, {}, "waitTimeSeconds"],
        "visibility zero": [{visibilityTimeoutSeconds: 0}, {}, "visibilityTimeoutSeconds"],
        "visibility over 12 h": [{visibilityTimeoutSeconds: 43201}, {}, "visibilityTimeoutSeconds"],
        "no attempts": [{maxAttempts: 0}, {}, "maxAttempts"],
        "negative base delay": [{retryBaseDelaySeconds: -1}, {}, "retryBaseDelaySeconds"],
        "max delay over 12 h": [{retryMaxDelaySeconds: 43201}, {}, "retryMaxDelaySeconds"],
        "message size over 1 MiB": [{maxMessageSizeBytes: 1048577}, {}, "maxMessageSizeBytes"],
        "negative receive backoff": [{receiveErrorBackoffSeconds: -1}, {}, "receiveErrorBackoffSeconds"],
        "zero bucket": [{}, {rollingWindow: {bucketSize: 0}}, "rollingWindow.bucketSize"],
        "window below bucket": [{}, {rollingWindow: {timeWindow: 5, bucketSize: 10}}, "rollingWindow.timeWindow"],
        "negative volume": [{}, {rollingWindow: {requestVolumeThreshold: -1}}, "rollingWindow.requestVolumeThreshold"],
        "threshold above 1": [{}, {failureThreshold: 1.5}, "failureThreshold"],
        "consecutive zero": [{}, {consecutiveFailureThreshold: 0}, "consecutiveFailureThreshold"],
        "negative reset": [{}, {resetTime: -1}, "resetTime"],
        "negative trial interval": [{}, {halfOpenTrialInterval: -1}, "halfOpenTrialInterval"]
    };
}

@test:Config {dataProvider: invalidConfigs}
function invalidSettingIsRejected(ConsumerConfig consumer, BreakerConfig breaker, string setting) {
    error? result = validateConfig(consumer, breaker);
    if result is () {
        test:assertFail(string `${setting} must be rejected`);
    }
    test:assertTrue(result.message().includes(setting + " ="), msg = result.message());
}
