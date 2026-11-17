import ballerina/http;
import ballerinax/aws.sqs;

const string DOWNSTREAM_SYSTEM = "order-service";
const string CORRELATION_ID_ATTRIBUTE = "correlationId";
final string:RegExp ORDER_ID_PATTERN = re `[A-Za-z0-9_-]+`;

# Handles one message: parse it, call the downstream system, and classify any failure.
# Replace the body of this function with your own business logic.
#
# + message - The received SQS message
# + return - `()` on success, otherwise a `TransientError` or a `PermanentError`
isolated function processMessage(sqs:Message message) returns ProcessingError? {
    string correlationId = correlationIdOf(message);
    string? body = message.body;
    if body is () {
        return error PermanentError("Message has no body", code = "EMPTY_BODY", correlationId = correlationId,
                affectedSystem = "consumer");
    }
    OrderEvent|PermanentError event = parseEvent(body, correlationId);
    if event is PermanentError {
        return event;
    }

    // The idempotency key lets the downstream system ignore a message it has already processed,
    // because SQS can deliver the same message more than once.
    map<string> headers = {"X-Correlation-ID": correlationId, "Idempotency-Key": event.eventId};
    http:Response|http:ClientError response = downstreamClient->/orders/[event.orderId]/events.post(message = event,
        headers = headers
    );
    if response is http:ClientError {
        return error TransientError("Downstream system unreachable", response, code = "NETWORK",
                correlationId = correlationId, affectedSystem = DOWNSTREAM_SYSTEM);
    }
    return classifyStatus(response.statusCode, correlationId);
}

# Parses and validates the message body.
#
# + body - The message body
# + correlationId - Correlation ID of the message
# + return - The event, or a `PermanentError` if the body is not a valid `OrderEvent`
isolated function parseEvent(string body, string correlationId) returns OrderEvent|PermanentError {
    OrderEvent|error event = body.fromJsonStringWithType();
    if event is error {
        return error PermanentError("Message is not a valid OrderEvent", event, code = "INVALID_PAYLOAD",
                correlationId = correlationId, affectedSystem = "consumer");
    }
    // The HTTP client does not percent-encode path segments, so `/`, `?` or `..` would change the target URL.
    if !ORDER_ID_PATTERN.isFullMatch(event.orderId) {
        return error PermanentError("orderId contains characters that are not allowed in a URL path segment",
                code = "INVALID_PAYLOAD", correlationId = correlationId, affectedSystem = "consumer");
    }
    return event;
}

# Maps an HTTP status code to success, a transient error, or a permanent error.
# Adjust this to how your downstream API reports errors and duplicates.
#
# + statusCode - Status code returned by the downstream system
# + correlationId - Correlation ID of the message
# + return - `()` for 2xx, otherwise a `ProcessingError`
isolated function classifyStatus(int statusCode, string correlationId) returns ProcessingError? {
    if statusCode >= 200 && statusCode < 300 {
        return;
    }
    string code = string `HTTP_${statusCode}`;
    string errorMessage = string `Downstream system returned ${statusCode}`;
    // 408/429/5xx: the downstream system is slow, overloaded, or down. 3xx: redirects are not followed, and a
    // redirect usually means maintenance or a moved endpoint. 401/403: a token may have expired. A lasting 3xx, 401
    // or 403 needs a configuration fix, so alert on it.
    if (statusCode >= 300 && statusCode < 400) || statusCode == 408 || statusCode == 429 || statusCode == 401
            || statusCode == 403 || statusCode >= 500 {
        return error TransientError(errorMessage, code = code, correlationId = correlationId,
                affectedSystem = DOWNSTREAM_SYSTEM);
    }
    // Any other 4xx means the request itself is wrong; retrying will not help.
    return error PermanentError(errorMessage, code = code, correlationId = correlationId,
            affectedSystem = DOWNSTREAM_SYSTEM);
}

# Uses the producer's `correlationId` message attribute if present, otherwise the SQS message ID.
#
# + message - The received SQS message
# + return - The correlation ID to use for logging and error reporting
isolated function correlationIdOf(sqs:Message message) returns string {
    map<sqs:MessageAttributeValue>? attributes = message.messageAttributes;
    if attributes is map<sqs:MessageAttributeValue> && attributes.hasKey(CORRELATION_ID_ATTRIBUTE) {
        sqs:MessageAttributeValue attribute = attributes.get(CORRELATION_ID_ATTRIBUTE);
        string? correlationId = attribute.stringValue;
        if correlationId is string {
            return correlationId;
        }
    }
    return message.messageId ?: "unknown";
}
