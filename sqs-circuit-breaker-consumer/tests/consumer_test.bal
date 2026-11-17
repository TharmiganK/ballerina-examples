import ballerina/test;
import ballerinax/aws.sqs;

@test:Config
function backoffDoublesWithDefaults() {
    ConsumerConfig config = {};
    int[] delays = from int receiveCount in 1 ... 5
        select retryDelaySeconds(config, receiveCount);
    test:assertEquals(actual = delays, expected = [10, 20, 40, 80, 160]);
}

@test:Config
function backoffIsCappedAtMaximum() {
    ConsumerConfig config = {retryMaxDelaySeconds: 30};
    int[] delays = from int receiveCount in 1 ... 4
        select retryDelaySeconds(config, receiveCount);
    test:assertEquals(actual = delays, expected = [10, 20, 30, 30]);
}

@test:Config
function backoffFactorBelowOneIsFixed() {
    ConsumerConfig config = {retryBackOffFactor: 0.5};
    test:assertEquals(actual = retryDelaySeconds(config, 4), expected = 10);
}

function dlqAttributes() returns map<sqs:MessageAttributeValue> {
    return {
        "errorCode": {dataType: "String", stringValue: "HTTP_503"},
        [ERROR_MESSAGE_ATTRIBUTE]: {dataType: "String", stringValue: "Downstream system returned 503"},
        [SOURCE_QUEUE_ATTRIBUTE]: {dataType: "String", stringValue: "https://sqs.example/queue"},
        "receiveCount": {dataType: "Number", stringValue: "5"}
    };
}

@test:Config
function sizeCountsBodyAndAttributes() {
    map<sqs:MessageAttributeValue> attributes = {"ab": {dataType: "String", stringValue: "é"}};
    // body 3 + name 2 + type 6 + value 2 (é is 2 bytes in UTF-8)
    test:assertEquals(actual = messageSizeBytes("abc", attributes), expected = 13);
}

@test:Config
function smallMessageKeepsAllAttributes() {
    map<sqs:MessageAttributeValue> attributes = fitToSize("{}", dlqAttributes(), 1024);
    test:assertEquals(actual = attributes.length(), expected = 4);
}

@test:Config
function largeMessageDropsOptionalAttributesInOrder() {
    map<sqs:MessageAttributeValue> all = dlqAttributes();
    int attributesSize = messageSizeBytes("", all);
    int errorMessageSize = messageSizeBytes("", {[ERROR_MESSAGE_ATTRIBUTE]: all.get(ERROR_MESSAGE_ATTRIBUTE)});
    int maxBytes = 2048;
    string body = createString(maxBytes - attributesSize + errorMessageSize);

    map<sqs:MessageAttributeValue> fitted = fitToSize(body, dlqAttributes(), maxBytes);
    test:assertFalse(fitted.hasKey(ERROR_MESSAGE_ATTRIBUTE));
    test:assertTrue(fitted.hasKey(SOURCE_QUEUE_ATTRIBUTE), msg = "dropping errorMessage was enough");
    test:assertTrue(messageSizeBytes(body, fitted) <= maxBytes);

    fitted = fitToSize(body + "x", dlqAttributes(), maxBytes);
    test:assertFalse(fitted.hasKey(SOURCE_QUEUE_ATTRIBUTE));
    test:assertTrue(fitted.hasKey("errorCode"), msg = "required attributes are kept");
}

function createString(int length) returns string {
    string[] chars = from int _ in 0 ..< length
        select "x";
    return string:'join("", ...chars);
}

@test:Config
function processingErrorsKeepTheirClassification() {
    PermanentError permanent = error("bad payload", code = "INVALID_PAYLOAD", correlationId = "c", affectedSystem = "consumer");
    test:assertTrue(asProcessingError(permanent, "c") is PermanentError);
}

@test:Config
function unexpectedErrorsBecomeTransient() {
    error? panicked = trap panicInProcessing();
    if panicked is () {
        test:assertFail("expected the panic to be trapped");
    }
    ProcessingError failure = asProcessingError(panicked, "c1");
    if failure !is TransientError {
        test:assertFail("a panic must be retried, not sent to the DLQ");
    }
    test:assertEquals(actual = failure.detail().code, expected = "UNEXPECTED_ERROR");
    test:assertEquals(actual = failure.detail().correlationId, expected = "c1");
}

function panicInProcessing() returns error? {
    int[] empty = [];
    _ = empty[1];
}
