// Integration tests against a real SQS endpoint (AWS, or LocalStack via SQS_IT_ENDPOINT).
//
// They run only when SQS_IT_REGION is set, and are skipped otherwise. Credentials come from the AWS default chain.
// Each test creates its own source queue and DLQ, and every queue is deleted when the group finishes.

import ballerina/http;
import ballerina/lang.runtime;
import ballerina/os;
import ballerina/test;
import ballerina/uuid;
import ballerinax/aws.auth;
import ballerinax/aws.sqs;

final string integrationRegion = os:getEnv("SQS_IT_REGION");
final string integrationEndpoint = os:getEnv("SQS_IT_ENDPOINT");
final boolean integrationEnabled = integrationRegion != "";

const string INTEGRATION = "integration";
// Must match downstreamUrl in tests/Config.toml, which processMessage uses through the module-level client.
const int MOCK_DOWNSTREAM_PORT = 19090;
const decimal EVENTUALLY_TIMEOUT_SECONDS = 90;

// Short timings so a full retry cycle takes seconds rather than minutes.
final ConsumerConfig integrationConsumerConfig = {
    waitTimeSeconds: 1,
    visibilityTimeoutSeconds: 20,
    maxAttempts: 3,
    retryBaseDelaySeconds: 1,
    retryMaxDelaySeconds: 2,
    receiveErrorBackoffSeconds: 1
};

// A breaker that never opens, for tests about message handling only.
final BreakerConfig neverOpens = {consecutiveFailureThreshold: (), rollingWindow: {requestVolumeThreshold: 1000}};

isolated int downstreamStatus = 200;
isolated string[] acceptedEventIds = [];

final http:Service mockDownstream = isolated service object {
    isolated resource function post orders/[string orderId]/events(@http:Payload OrderEvent event)
            returns http:Response {
        int status = 200;
        lock {
            status = downstreamStatus;
        }
        if status < 300 {
            lock {
                acceptedEventIds.push(event.eventId);
            }
        }
        http:Response response = new;
        response.statusCode = status;
        return response;
    }
};

sqs:Client? integrationClient = ();
http:Listener? downstreamListener = ();
string[] createdQueueUrls = [];
[QueueConsumer, future<()>][] runningConsumers = [];

type QueuePair record {|
    string queueUrl;
    string dlqUrl;
|};

@test:BeforeGroups {value: [INTEGRATION]}
function setUpIntegration() returns error? {
    integrationClient = check createIntegrationClient();
    http:Listener mockListener = check new (MOCK_DOWNSTREAM_PORT);
    check mockListener.attach(mockDownstream, "/");
    check mockListener.'start();
    runtime:registerListener(mockListener);
    downstreamListener = mockListener;
}

@test:AfterEach
function stopConsumers() {
    foreach [QueueConsumer, future<()>] [consumer, running] in runningConsumers {
        consumer.stop();
        error? stopped = wait running;
        if stopped is error {
            test:assertFail("The consumer failed: " + stopped.message());
        }
    }
    runningConsumers = [];
}

@test:AfterGroups {value: [INTEGRATION], alwaysRun: true}
function tearDownIntegration() returns error? {
    stopConsumers();
    sqs:Client? sqsClient = integrationClient;
    if sqsClient is sqs:Client {
        foreach string queueUrl in createdQueueUrls {
            error? deleted = sqsClient->deleteQueue(queueUrl);
            if deleted is error {
                test:assertFail(string `Failed to delete test queue ${queueUrl}: ${deleted.message()}`);
            }
        }
    }
    createdQueueUrls = [];
    http:Listener? mockListener = downstreamListener;
    if mockListener is http:Listener {
        runtime:deregisterListener(mockListener);
        check mockListener.gracefulStop();
    }
}

@test:Config {groups: [INTEGRATION], enable: integrationEnabled}
function validMessageIsProcessedAndDeleted() returns error? {
    sqs:Client sqsClient = check getIntegrationClient();
    QueuePair queues = check createQueuePair(sqsClient);
    setDownstreamStatus(200);
    string eventId = check sendOrderEvent(sqsClient, queues.queueUrl);

    _ = startConsumer(sqsClient, queues, neverOpens);

    test:assertTrue(eventually(() => isAccepted(eventId)), msg = "the downstream system received the event");
    test:assertTrue(eventually(() => isEmpty(sqsClient, queues.queueUrl)), msg = "the message was deleted");
    test:assertEquals(actual = check receiveAll(sqsClient, queues.dlqUrl), expected = []);
}

@test:Config {groups: [INTEGRATION], enable: integrationEnabled}
function invalidMessageGoesToDlqWithDetails() returns error? {
    sqs:Client sqsClient = check getIntegrationClient();
    QueuePair queues = check createQueuePair(sqsClient);
    _ = check sqsClient->sendMessage(queues.queueUrl, "not json",
        messageAttributes = {"correlationId": {dataType: "String", stringValue: "corr-invalid"}});

    _ = startConsumer(sqsClient, queues, neverOpens);

    sqs:Message dlqMessage = check receiveOne(sqsClient, queues.dlqUrl);
    test:assertEquals(actual = dlqMessage.body, expected = "not json", msg = "the original body is kept");
    test:assertEquals(actual = attributeOf(dlqMessage, "errorCode"), expected = "INVALID_PAYLOAD");
    test:assertEquals(actual = attributeOf(dlqMessage, "errorReason"), expected = "PERMANENT");
    test:assertEquals(actual = attributeOf(dlqMessage, "correlationId"), expected = "corr-invalid");
    test:assertEquals(actual = attributeOf(dlqMessage, "sourceQueueUrl"), expected = queues.queueUrl);
    test:assertTrue(eventually(() => isEmpty(sqsClient, queues.queueUrl)), msg = "removed from the source queue");
}

@test:Config {groups: [INTEGRATION], enable: integrationEnabled}
function rejectedRequestGoesToDlqAndKeepsCircuitClosed() returns error? {
    sqs:Client sqsClient = check getIntegrationClient();
    QueuePair queues = check createQueuePair(sqsClient);
    setDownstreamStatus(404);
    _ = check sendOrderEvent(sqsClient, queues.queueUrl);

    PollingCircuitBreaker breaker = startConsumer(sqsClient, queues, {consecutiveFailureThreshold: 1});

    sqs:Message dlqMessage = check receiveOne(sqsClient, queues.dlqUrl);
    test:assertEquals(actual = attributeOf(dlqMessage, "errorCode"), expected = "HTTP_404");
    test:assertEquals(actual = breaker.currentState(), expected = CLOSED, msg = "a 4xx means the downstream is up");
}

@test:Config {groups: [INTEGRATION], enable: integrationEnabled}
function transientFailuresGoToDlqAfterMaxAttempts() returns error? {
    sqs:Client sqsClient = check getIntegrationClient();
    QueuePair queues = check createQueuePair(sqsClient);
    setDownstreamStatus(503);
    _ = check sendOrderEvent(sqsClient, queues.queueUrl);

    _ = startConsumer(sqsClient, queues, neverOpens);

    sqs:Message dlqMessage = check receiveOne(sqsClient, queues.dlqUrl);
    test:assertEquals(actual = attributeOf(dlqMessage, "errorCode"), expected = "HTTP_503");
    test:assertEquals(actual = attributeOf(dlqMessage, "errorReason"), expected = "RETRIES_EXHAUSTED");
    test:assertEquals(actual = attributeOf(dlqMessage, "receiveCount"),
            expected = integrationConsumerConfig.maxAttempts.toString());
}

@test:Config {groups: [INTEGRATION], enable: integrationEnabled}
function circuitOpensDuringOutageAndRecovers() returns error? {
    sqs:Client sqsClient = check getIntegrationClient();
    QueuePair queues = check createQueuePair(sqsClient);
    setDownstreamStatus(503);
    string[] eventIds = [];
    foreach int _ in 1 ... 3 {
        eventIds.push(check sendOrderEvent(sqsClient, queues.queueUrl));
    }

    // More attempts than the outage uses up, so no message is declared out of retries during the test.
    PollingCircuitBreaker breaker = startConsumer(sqsClient, queues,
        {consecutiveFailureThreshold: 2, resetTime: 3, halfOpenTrialInterval: 1}, maxAttempts = 20);

    test:assertTrue(eventually(() => breaker.currentState() != CLOSED), msg = "the outage opened the circuit");
    test:assertEquals(actual = check receiveAll(sqsClient, queues.dlqUrl), expected = [],
            msg = "no message goes to the DLQ during the outage");

    setDownstreamStatus(200);
    foreach string eventId in eventIds {
        test:assertTrue(eventually(() => isAccepted(eventId)), msg = string `${eventId} processed after recovery`);
    }
    test:assertEquals(actual = breaker.currentState(), expected = CLOSED);
    test:assertTrue(eventually(() => isEmpty(sqsClient, queues.queueUrl)), msg = "the backlog drained");
    test:assertEquals(actual = check receiveAll(sqsClient, queues.dlqUrl), expected = []);
}

function createIntegrationClient() returns sqs:Client|error {
    if integrationEndpoint != "" {
        return new ({region: integrationRegion, auth: auth:DEFAULT_CREDENTIALS,
            endpoint: {customEndpoint: integrationEndpoint}});
    }
    return new ({region: integrationRegion, auth: auth:DEFAULT_CREDENTIALS});
}

function getIntegrationClient() returns sqs:Client|error {
    sqs:Client? sqsClient = integrationClient;
    if sqsClient is () {
        return error("The SQS client was not created; check the BeforeGroups output");
    }
    return sqsClient;
}

# Creates a DLQ and a source queue that redrives to it, with names unique to this run.
#
# + sqsClient - The SQS client
# + return - The queue URLs, or an error
function createQueuePair(sqs:Client sqsClient) returns QueuePair|error {
    string name = string `sqs-cb-it-${uuid:createType4AsString().substring(0, 13)}`;
    string dlqUrl = check sqsClient->createQueue(name + "-dlq");
    createdQueueUrls.push(dlqUrl);
    sqs:GetQueueAttributesResponse dlqAttributes = check sqsClient->getQueueAttributes(dlqUrl,
        attributeNames = [sqs:QUEUE_ARN]);
    string dlqArn = dlqAttributes.queueAttributes.get("QueueArn");
    string queueUrl = check sqsClient->createQueue(name,
        queueAttributes = {redrivePolicy: {deadLetterTargetArn: dlqArn, maxReceiveCount: 50}});
    createdQueueUrls.push(queueUrl);
    return {queueUrl, dlqUrl};
}

function startConsumer(sqs:Client sqsClient, QueuePair queues, BreakerConfig breakerSettings,
        int maxAttempts = integrationConsumerConfig.maxAttempts) returns PollingCircuitBreaker {
    ConsumerConfig settings = integrationConsumerConfig.clone();
    settings.maxAttempts = maxAttempts;
    PollingCircuitBreaker breaker = new (name = "integration-test", config = breakerSettings);
    QueueConsumer consumer = new (sqsClient, queues.queueUrl, queues.dlqUrl, breaker, settings);
    future<()> running = start consumer.run();
    runningConsumers.push([consumer, running]);
    return breaker;
}

function sendOrderEvent(sqs:Client sqsClient, string queueUrl) returns string|error {
    string eventId = uuid:createType4AsString();
    string body = {eventId, orderId: "order-1", status: "PAID"}.toJsonString();
    _ = check sqsClient->sendMessage(queueUrl, body);
    return eventId;
}

function setDownstreamStatus(int status) {
    lock {
        downstreamStatus = status;
    }
}

function isAccepted(string eventId) returns boolean {
    lock {
        return acceptedEventIds.indexOf(eventId) !is ();
    }
}

function isEmpty(sqs:Client sqsClient, string queueUrl) returns boolean|error {
    sqs:GetQueueAttributesResponse response = check sqsClient->getQueueAttributes(queueUrl,
        attributeNames = [sqs:APPROXIMATE_NUMBER_OF_MESSAGES, sqs:APPROXIMATE_NUMBER_OF_MESSAGES_NOT_VISIBLE]);
    map<string> attributes = response.queueAttributes;
    int visible = check int:fromString(attributes.get("ApproximateNumberOfMessages"));
    int inFlight = check int:fromString(attributes.get("ApproximateNumberOfMessagesNotVisible"));
    return visible + inFlight == 0;
}

# Waits for one message on the queue, for up to `EVENTUALLY_TIMEOUT_SECONDS`.
#
# + sqsClient - The SQS client
# + queueUrl - The queue to read
# + return - The message, or an error if none arrived in time
function receiveOne(sqs:Client sqsClient, string queueUrl) returns sqs:Message|error {
    decimal waited = 0;
    while waited < EVENTUALLY_TIMEOUT_SECONDS {
        sqs:Message[] messages = check sqsClient->receiveMessage(queueUrl, waitTimeSeconds = 5,
            messageAttributeNames = ["All"]);
        if messages.length() > 0 {
            return messages[0];
        }
        waited += 5d;
    }
    return error(string `No message arrived on ${queueUrl}`);
}

# + sqsClient - The SQS client
# + queueUrl - The queue to read
# + return - The bodies of the messages currently on the queue, after a short wait
function receiveAll(sqs:Client sqsClient, string queueUrl) returns string[]|error {
    sqs:Message[] messages = check sqsClient->receiveMessage(queueUrl, waitTimeSeconds = 2,
        maxNumberOfMessages = 10);
    return from sqs:Message message in messages
        select message.body ?: "";
}

function attributeOf(sqs:Message message, string name) returns string? {
    map<sqs:MessageAttributeValue>? attributes = message.messageAttributes;
    if attributes is () || !attributes.hasKey(name) {
        return ();
    }
    sqs:MessageAttributeValue attribute = attributes.get(name);
    return attribute.stringValue;
}

function eventually(function () returns boolean|error condition) returns boolean {
    decimal waited = 0;
    while waited < EVENTUALLY_TIMEOUT_SECONDS {
        boolean|error result = condition();
        if result is true {
            return true;
        }
        runtime:sleep(1);
        waited += 1d;
    }
    return false;
}
