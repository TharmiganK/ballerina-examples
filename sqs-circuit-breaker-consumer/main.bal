import ballerina/http;
import ballerinax/aws.auth;
import ballerinax/aws.sqs;

configurable string awsRegion = ?;
configurable string queueUrl = ?;
configurable string dlqUrl = ?;
configurable string downstreamUrl = ?;

// Tuning values; override them in Config.toml. The defaults are in types.bal.
configurable ConsumerConfig consumerConfig = {};
configurable BreakerConfig breakerConfig = {};

const int MAX_VISIBILITY_TIMEOUT = 43200;

// Credentials come from the AWS default chain (environment, IAM role, EKS Pod Identity or IRSA, ...).
final sqs:Client sqsClient = check new ({region: awsRegion, auth: auth:DEFAULT_CREDENTIALS});

// No HTTP-level retries: failed messages are retried through SQS. Keep the timeout well below the visibility timeout.
final http:Client downstreamClient = check new (downstreamUrl, timeout = 10);

public function main() returns error? {
    check validateConfig(consumerConfig, breakerConfig);
    PollingCircuitBreaker breaker = new (DOWNSTREAM_SYSTEM, consumerConfig.maxBatchSize, breakerConfig);
    QueueConsumer consumer = new (sqsClient, queueUrl, dlqUrl, breaker, consumerConfig);
    consumer.run();
}

# Rejects settings that would make the breaker panic or SQS reject every call.
#
# + consumer - Consumer settings
# + breaker - Circuit breaker settings
# + return - An error naming the first invalid setting
isolated function validateConfig(ConsumerConfig consumer, BreakerConfig breaker) returns error? {
    check checkRange("maxBatchSize", consumer.maxBatchSize, 1, 10);
    check checkRange("waitTimeSeconds", consumer.waitTimeSeconds, 0, 20);
    check checkRange("visibilityTimeoutSeconds", consumer.visibilityTimeoutSeconds, 1, MAX_VISIBILITY_TIMEOUT);
    check checkRange("maxAttempts", consumer.maxAttempts, 1);
    check checkRange("retryBaseDelaySeconds", consumer.retryBaseDelaySeconds, 0, MAX_VISIBILITY_TIMEOUT);
    check checkRange("retryMaxDelaySeconds", consumer.retryMaxDelaySeconds, 0, MAX_VISIBILITY_TIMEOUT);
    check checkRange("maxMessageSizeBytes", consumer.maxMessageSizeBytes, 1024, 1048576);
    check checkRange("receiveErrorBackoffSeconds", consumer.receiveErrorBackoffSeconds, 0d);

    RollingWindowConfig window = breaker.rollingWindow;
    check checkRange("rollingWindow.bucketSize", window.bucketSize, 0.001);
    check checkRange("rollingWindow.timeWindow", window.timeWindow, window.bucketSize);
    check checkRange("rollingWindow.requestVolumeThreshold", window.requestVolumeThreshold, 0);
    check checkRange("failureThreshold", breaker.failureThreshold, 0.0, 1.0);
    int? consecutiveLimit = breaker.consecutiveFailureThreshold;
    if consecutiveLimit is int {
        check checkRange("consecutiveFailureThreshold", consecutiveLimit, 1);
    }
    check checkRange("resetTime", breaker.resetTime, 0d);
    check checkRange("halfOpenTrialInterval", breaker.halfOpenTrialInterval, 0d);
}

type Number int|decimal|float;

isolated function checkRange(string name, Number value, Number min, Number? max = ()) returns error? {
    decimal actual = <decimal>value;
    if actual < <decimal>min || (max !is () && actual > <decimal>max) {
        string allowed = max is () ? string `at least ${min}` : string `between ${min} and ${max}`;
        return error(string `Invalid setting ${name} = ${value}: must be ${allowed}`);
    }
}
