# Polling and retry settings for the consumer. See the README for how to tune them.
#
# + maxBatchSize - Messages requested per receive while the circuit is closed (1-10)
# + waitTimeSeconds - Long-poll wait per receive (0-20)
# + visibilityTimeoutSeconds - How long a received message stays hidden. Messages in a batch are processed one after
# another, so this must exceed `maxBatchSize` × the worst-case processing time of one message
# + maxAttempts - Receives after which a message that keeps failing is moved to the DLQ. This is a receive budget,
# not a count of processing attempts: half-open trials and messages returned unprocessed use it up too, so after an
# outage a message may reach the DLQ after fewer real attempts. Keep the redrive `maxReceiveCount` higher than this
# + retryBaseDelaySeconds - Delay before the first retry
# + retryBackOffFactor - Multiplier applied to the delay on every further attempt, as in `http:RetryConfig`.
# `2` doubles it; `1` keeps it fixed. Values below `1` are treated as `1`
# + retryMaxDelaySeconds - Upper limit for the retry delay
# + receiveErrorBackoffSeconds - Pause after a failed receive call (an SQS problem, not a downstream one)
# + maxMessageSizeBytes - The DLQ's `MaximumMessageSize`. Optional DLQ attributes are dropped to stay within it
public type ConsumerConfig record {|
    int maxBatchSize = 10;
    int waitTimeSeconds = 20;
    int visibilityTimeoutSeconds = 150;
    int maxAttempts = 5;
    int retryBaseDelaySeconds = 10;
    decimal retryBackOffFactor = 2;
    int retryMaxDelaySeconds = 900;
    decimal receiveErrorBackoffSeconds = 5;
    int maxMessageSizeBytes = 1048576;
|};

# Rolling window over which the failure rate is measured, as in `http:RollingWindow`.
#
# + timeWindow - Length of the window in seconds
# + bucketSize - Size of each slice of the window in seconds; the oldest slice drops out as time moves on
# + requestVolumeThreshold - Minimum results in the window before the failure rate is checked
public type RollingWindowConfig record {|
    decimal timeWindow = 60;
    decimal bucketSize = 10;
    int requestVolumeThreshold = 5;
|};

# Circuit breaker settings. The first three fields follow `http:CircuitBreakerConfig`.
#
# + rollingWindow - Window over which successes and failures are counted
# + failureThreshold - Failure rate (0-1) that must be exceeded to open the circuit
# + consecutiveFailureThreshold - Failures in a row that open the circuit regardless of traffic volume,
# so quiet queues are protected too. `()` turns this rule off; Config.toml cannot express `()`, so change the default
# here to do that
# + resetTime - Seconds the circuit stays open before trying again
# + halfOpenTrialInterval - Seconds between trial messages while the circuit is half-open
public type BreakerConfig record {|
    RollingWindowConfig rollingWindow = {};
    float failureThreshold = 0.5;
    int? consecutiveFailureThreshold = 3;
    decimal resetTime = 30;
    decimal halfOpenTrialInterval = 5;
|};

public enum CircuitState {
    CLOSED,
    OPEN,
    HALF_OPEN
}

# How the consumer may poll next.
public enum PollMode {
    # Poll a full batch
    FULL_BATCH,
    # Poll one trial message
    TRIAL,
    # Do not poll; wait `waitSeconds` and ask again
    WAIT
}

# The circuit breaker's answer to "may the consumer poll now?".
#
# + mode - Whether to poll a full batch, one trial message, or nothing
# + waitSeconds - How long to wait before asking again when `mode` is `WAIT`
public type PollPermit record {|
    PollMode mode;
    decimal waitSeconds = 0;
|};

# Details attached to every processing error.
#
# + code - Short error code, e.g. `INVALID_PAYLOAD`, `HTTP_503`, `NETWORK`
# + correlationId - Correlation ID of the message, for finding related logs
# + affectedSystem - The system where the failure happened
public type ProcessingErrorDetail record {|
    string code;
    string correlationId;
    string affectedSystem;
|};

# A failure that may succeed later, such as a downstream outage. Retried, and counted by the circuit breaker.
public type TransientError distinct error<ProcessingErrorDetail>;

# A failure that will never succeed, such as an invalid message. Sent to the DLQ, and ignored by the circuit breaker.
public type PermanentError distinct error<ProcessingErrorDetail>;

public type ProcessingError TransientError|PermanentError;

# What happened to a received message.
enum Disposition {
    # Removed from the source queue (processed, or moved to the DLQ)
    DONE,
    # Left in the source queue to be retried later
    RETRY_LATER
}

# Example message payload. Replace it with your own message type.
# Open, so fields added later by producers are accepted instead of failing every message.
#
# + eventId - Unique ID of the event, used as the idempotency key
# + orderId - Order the event applies to
# + status - New order status
type OrderEvent record {
    string eventId;
    string orderId;
    string status;
};
