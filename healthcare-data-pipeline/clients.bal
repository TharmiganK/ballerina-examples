import ballerina/http;
import ballerinax/googleapis.gmail;
import ballerinax/postgresql;
import ballerinax/postgresql.driver as _;
import ballerinax/rabbitmq;

import xlibb/pipeline;
import ballerina/time;

configurable string refreshToken = ?;
configurable string clientId = ?;
configurable string clientSecret = ?;
configurable string dbPassword = ?;
configurable string analyticsApiUrl = "http://localhost:9090/analytics";

final gmail:Client gmailClient = check new gmail:Client(
    config = {
        auth: {
            refreshToken,
            clientId,
            clientSecret
        }
    }
);

final postgresql:Client dbClient = check new (password = dbPassword);

final http:Client analyticsClient = check new (analyticsApiUrl);

final rabbitmq:MessageStore failureStore = check new ("health.observations.failure", declareQueue = {queueConfig: {autoDelete: false}});
final rabbitmq:MessageStore replayStore = check new ("health.observations.replay");
final rabbitmq:MessageStore deadLetterStore = check new ("health.observations.deadletter", declareQueue = {queueConfig: {autoDelete: false}});

final pipeline:HandlerChain observationPipeline = check new (
    name = "observation-pipeline",
    processors = [
        parseMllpHl7Message,
        filterObservationMessage,
        createReportFromMessage
    ],
    destinations = [
        writeReportToFile,
        insertPatientToDatabase,
        sendToHealthAnalyticsAPI
    ],
    failureStore = failureStore,
    replayListenerConfig = {
        replayStore,
        deadLetterStore
    }
);

listener rabbitmq:Listener failureStoreListener = check new (rabbitmq:DEFAULT_HOST, rabbitmq:DEFAULT_PORT);

@rabbitmq:ServiceConfig {
    queueName: "health.observations.failure",
    autoAck: false
}
service on failureStoreListener {

    remote function onMessage(rabbitmq:AnydataMessage message) returns error? {
        pipeline:Message failedMsg = check message.content.toJson().fromJsonWithType();
        string currentTimestamp = time:utcToEmailString(time:utcNow());
        string subject = string `[${currentTimestamp}] Message with ID: ${failedMsg.id} failed in the pipeline`;
        string bodyInHtml = createFailureHtmlReport(failedMsg);
        _ = check gmailClient->/users/me/messages/send.post(
            {
                to: [adminEmail],
                subject,
                bodyInHtml
            }
        );
    }
}
