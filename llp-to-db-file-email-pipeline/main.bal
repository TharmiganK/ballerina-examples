import ballerina/tcp;
import ballerina/log;

configurable string mllpHostName = "localhost";
configurable int mllpPort = 8888;
configurable string adminEmail = "admin@example.com";

listener tcp:Listener mllpListener = check new (mllpPort, localHost = mllpHostName);

service on mllpListener {
    remote function onConnect() returns tcp:ConnectionService {
        return new MllpService();
    }
}

service class MllpService {
    *tcp:ConnectionService;

    remote function onBytes(readonly & byte[] data) {
        do {
        _ = start observationPipeline.execute(check string:fromBytes(data));
        } on fail error err {
            log:printError("failed to process MLLP message", err);
        }
    }
}
