import ballerina/lang.runtime;
import ballerina/log;
import ballerinax/aws.sqs;

const int MAX_ATTRIBUTE_LENGTH = 256;
const string ERROR_MESSAGE_ATTRIBUTE = "errorMessage";
const string SOURCE_QUEUE_ATTRIBUTE = "sourceQueueUrl";

# Polls one SQS queue with `sqs:Client`, letting a circuit breaker decide when to poll.
#
# A hand-written loop is used instead of `sqs:Listener` because the listener cannot be paused,
# and pausing is exactly what the circuit breaker needs to do.
public isolated class QueueConsumer {
    private final sqs:Client sqsClient;
    private final string queueUrl;
    private final string dlqUrl;
    private final PollingCircuitBreaker breaker;
    private final ConsumerConfig & readonly config;
    private boolean running = true;

    public isolated function init(sqs:Client sqsClient, string queueUrl, string dlqUrl,
            PollingCircuitBreaker breaker, ConsumerConfig config) {
        self.sqsClient = sqsClient;
        self.queueUrl = queueUrl;
        self.dlqUrl = dlqUrl;
        self.breaker = breaker;
        self.config = config.cloneReadOnly();
    }

    public isolated function run() {
        log:printInfo("Consumer started", queueUrl = self.queueUrl);
        while self.isRunning() {
            // Ask the circuit breaker first. While it is open, nothing is received.
            PollPermit permit = self.breaker.acquirePermit();
            if permit.maxMessages == 0 {
                runtime:sleep(permit.waitSeconds);
                continue;
            }
            sqs:Message[]|sqs:Error messages = self.sqsClient->receiveMessage(self.queueUrl,
                    maxNumberOfMessages = permit.maxMessages,
                    waitTimeSeconds = self.config.waitTimeSeconds,
                    visibilityTimeout = self.config.visibilityTimeoutSeconds,
                    messageAttributeNames = ["All"],
                    messageSystemAttributeNames = [sqs:APPROXIMATE_RECEIVE_COUNT, sqs:MESSAGE_GROUP_ID]);
            if messages is sqs:Error {
                log:printError("Failed to receive messages", messages, queueUrl = self.queueUrl);
                runtime:sleep(self.config.receiveErrorBackoffSeconds);
                continue;
            }
            self.handleBatch(messages);
        }
        log:printInfo("Consumer stopped", queueUrl = self.queueUrl);
    }

    # Stops polling after the current batch.
    public isolated function stop() {
        lock {
            self.running = false;
        }
    }

    private isolated function isRunning() returns boolean {
        lock {
            return self.running;
        }
    }

    private isolated function handleBatch(sqs:Message[] messages) {
        // FIFO queues: once a message of a group is held back for retry, the group's later messages in this
        // batch must wait too, or they would be processed out of order.
        map<boolean> blockedGroups = {};
        foreach sqs:Message message in messages {
            if self.breaker.currentState() == OPEN {
                // The circuit opened during this batch: return the rest unprocessed until it may close. The state
                // stays OPEN past `openUntil` until the next poll, so wait at least 1 s for the half-open trial.
                self.returnToQueue(message, delaySeconds = int:max(self.breaker.remainingOpenSeconds(), 1));
                continue;
            }
            string? groupId = groupIdOf(message);
            if groupId is string && blockedGroups.hasKey(groupId) {
                self.returnToQueue(message, delaySeconds = 0);
                continue;
            }
            Disposition disposition = self.handleMessage(message);
            if disposition == RETRY_LATER && groupId is string {
                blockedGroups[groupId] = true;
            }
        }
    }

    private isolated function handleMessage(sqs:Message message) returns Disposition {
        // A panic in the processing code must not stop the consumer; it is turned into a transient error.
        error? result = trap processMessage(message);
        if result is () {
            self.breaker.recordSuccess();
            self.delete(message);
            return DONE;
        }
        ProcessingError failure = asProcessingError(result, correlationIdOf(message));
        if failure is PermanentError {
            if failure.detail().affectedSystem == DOWNSTREAM_SYSTEM {
                // The downstream system answered, so it is up, even though it rejected this message.
                self.breaker.recordSuccess();
            }
            return self.moveToDlq(message, failure, reason = "PERMANENT");
        }

        self.breaker.recordTransientFailure();
        int receiveCount = receiveCountOf(message);
        // Give up on a message only while the circuit is closed. During an outage every message fails,
        // so failing says nothing about the message itself; it waits in the queue instead.
        if self.breaker.currentState() == CLOSED && receiveCount >= self.config.maxAttempts {
            return self.moveToDlq(message, failure, reason = "RETRIES_EXHAUSTED");
        }
        int retryDelay = int:max(retryDelaySeconds(self.config, receiveCount), self.breaker.remainingOpenSeconds());
        log:printWarn("Transient failure, will retry", failure, correlationId = failure.detail().correlationId,
                receiveCount = receiveCount, retryDelaySeconds = retryDelay);
        self.returnToQueue(message, delaySeconds = retryDelay);
        return RETRY_LATER;
    }

    # Sends the message to the DLQ with the failure details as message attributes, then deletes it from the
    # source queue. The delete happens only after the send succeeds, so a message is never lost.
    #
    # + message - The received SQS message
    # + failure - The error that caused the message to be sent to the DLQ
    # + reason - A short string describing why the message is being sent to the DLQ
    # + return - `DONE` if the message was sent to the DLQ, otherwise `RETRY_LATER` if the send failed and the message was returned to the source queue.
    private isolated function moveToDlq(sqs:Message message, ProcessingError failure, string reason)
            returns Disposition {
        ProcessingErrorDetail detail = failure.detail();
        string errorText = failure.message();
        map<sqs:MessageAttributeValue> attributes = {
            "errorCode": {dataType: "String", stringValue: detail.code},
            "errorReason": {dataType: "String", stringValue: reason},
            [ERROR_MESSAGE_ATTRIBUTE]: {
                dataType: "String",
                stringValue: errorText.substring(0,
                    int:min(errorText.length(), MAX_ATTRIBUTE_LENGTH))
            },
            "affectedSystem": {dataType: "String", stringValue: detail.affectedSystem},
            "correlationId": {dataType: "String", stringValue: detail.correlationId},
            [SOURCE_QUEUE_ATTRIBUTE]: {dataType: "String", stringValue: self.queueUrl},
            "originalMessageId": {dataType: "String", stringValue: message.messageId ?: "unknown"},
            "receiveCount": {dataType: "Number", stringValue: receiveCountOf(message).toString()}
        };
        string body = message.body ?: "(empty body)";
        sqs:SendMessageConfig sendConfig = {
            messageAttributes: fitToSize(body, attributes, self.config.maxMessageSizeBytes)
        };
        if self.dlqUrl.endsWith(".fifo") {
            // A FIFO DLQ needs a group ID and a deduplication ID; keep the original group to preserve order.
            sendConfig.messageGroupId = groupIdOf(message) ?: "default";
            sendConfig.messageDeduplicationId = message.messageId ?: detail.correlationId;
        }
        sqs:SendMessageResponse|sqs:Error sendResult = self.sqsClient->sendMessage(self.dlqUrl, body,
                sendMessageConfig = sendConfig);
        if sendResult is sqs:Error {
            log:printError("Failed to send message to DLQ, keeping it in the source queue", sendResult,
                    correlationId = detail.correlationId);
            self.returnToQueue(message, delaySeconds = self.config.retryBaseDelaySeconds);
            return RETRY_LATER;
        }
        log:printWarn("Message moved to DLQ", failure, correlationId = detail.correlationId, errorCode = detail.code,
                reason = reason);
        self.delete(message);
        return DONE;
    }

    private isolated function delete(sqs:Message message) {
        string? receiptHandle = message.receiptHandle;
        if receiptHandle is () {
            return;
        }
        sqs:Error? result = self.sqsClient->deleteMessage(self.queueUrl, receiptHandle);
        if result is sqs:Error {
            // The message will be delivered again; the idempotency key makes that harmless.
            log:printError("Failed to delete message", result, correlationId = correlationIdOf(message));
        }
    }

    # Makes the message visible again after `delaySeconds`, so it is retried then.
    #
    # + message - The received SQS message
    # + delaySeconds - How long to wait before the message is retried
    private isolated function returnToQueue(sqs:Message message, int delaySeconds) {
        string? receiptHandle = message.receiptHandle;
        if receiptHandle is () {
            return;
        }
        sqs:Error? result = self.sqsClient->changeMessageVisibility(self.queueUrl, receiptHandle,
                visibilityTimeout = delaySeconds);
        if result is sqs:Error {
            // Not fatal: the message still reappears when its original visibility timeout ends.
            log:printWarn("Failed to change message visibility", result, correlationId = correlationIdOf(message));
        }
    }
}

# Keeps a `ProcessingError` as it is, and turns any other error, such as a trapped panic, into a `TransientError`.
# Retrying it means a bug that affects every message opens the circuit and keeps the messages in the queue until it
# is fixed, instead of sending them all to the DLQ.
#
# + err - The error returned or trapped while processing a message
# + correlationId - Correlation ID of the message
# + return - The error classified as transient or permanent
isolated function asProcessingError(error err, string correlationId) returns ProcessingError {
    if err is ProcessingError {
        return err;
    }
    return error TransientError("Unexpected error while processing the message", err, code = "UNEXPECTED_ERROR",
            correlationId = correlationId, affectedSystem = "consumer");
}

isolated function receiveCountOf(sqs:Message message) returns int {
    sqs:MessageAttributes? systemAttributes = message.messageSystemAttributes;
    return systemAttributes?.approximateReceiveCount ?: 1;
}

isolated function groupIdOf(sqs:Message message) returns string? {
    sqs:MessageAttributes? systemAttributes = message.messageSystemAttributes;
    return systemAttributes?.messageGroupId;
}

# Exponential backoff: base, base × factor, base × factor², ... up to the configured maximum.
#
# + config - Consumer settings holding the retry delays
# + receiveCount - How many times the message has been received
# + return - How long to wait before retrying the message
isolated function retryDelaySeconds(ConsumerConfig config, int receiveCount) returns int {
    decimal factor = decimal:max(config.retryBackOffFactor, 1);
    decimal maxDelay = <decimal>config.retryMaxDelaySeconds;
    decimal delay = decimal:min(<decimal>config.retryBaseDelaySeconds, maxDelay);
    foreach int _ in 1 ..< receiveCount {
        delay = decimal:min(delay * factor, maxDelay);
    }
    return <int>delay.ceiling();
}

# SQS counts the body and every attribute's name, type and value toward the maximum message size. Drops the
# optional attributes, `errorMessage` first and then `sourceQueueUrl`, until the message fits, so a large body can
# still reach the DLQ.
#
# + body - The message body
# + attributes - The DLQ attributes; modified in place
# + maxBytes - The DLQ's maximum message size
# + return - The attributes that fit
isolated function fitToSize(string body, map<sqs:MessageAttributeValue> attributes, int maxBytes)
        returns map<sqs:MessageAttributeValue> {
    foreach string optional in [ERROR_MESSAGE_ATTRIBUTE, SOURCE_QUEUE_ATTRIBUTE] {
        if messageSizeBytes(body, attributes) <= maxBytes {
            break;
        }
        _ = attributes.removeIfHasKey(optional);
    }
    return attributes;
}

isolated function messageSizeBytes(string body, map<sqs:MessageAttributeValue> attributes) returns int {
    int size = body.toBytes().length();
    foreach [string, sqs:MessageAttributeValue] [name, attribute] in attributes.entries() {
        size += name.toBytes().length() + attribute.dataType.toBytes().length()
            + (attribute.stringValue ?: "").toBytes().length() + (attribute.binaryValue ?: []).length();
    }
    return size;
}
