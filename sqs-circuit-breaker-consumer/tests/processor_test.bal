import ballerina/test;

@test:Config
function parseEventAcceptsUnknownFields() {
    OrderEvent|PermanentError event = parseEvent(
            string `{"eventId":"e1","orderId":"o-1","status":"PAID","source":"web"}`, "c");
    test:assertTrue(event is OrderEvent, msg = "a field added by the producer must not fail the message");
}

function unsafeOrderIds() returns map<[string]> {
    return {
        "slash": ["1/cancel"],
        "query": ["x?admin=true"],
        "dot segment": [".."],
        "encoded": ["%2F"],
        "empty": [""]
    };
}

@test:Config {dataProvider: unsafeOrderIds}
function parseEventRejectsUnsafeOrderId(string orderId) {
    string body = {eventId: "e1", orderId, status: "PAID"}.toJsonString();
    OrderEvent|PermanentError event = parseEvent(body, "c");
    if event is OrderEvent {
        test:assertFail(string `orderId "${orderId}" must be rejected`);
    }
    test:assertEquals(actual = event.detail().code, expected = "INVALID_PAYLOAD");
}

function statusCases() returns map<[int, string]> {
    return {
        "200": [200, "success"],
        "204": [204, "success"],
        "302": [302, "transient"],
        "307": [307, "transient"],
        "400": [400, "permanent"],
        "401": [401, "transient"],
        "403": [403, "transient"],
        "404": [404, "permanent"],
        "408": [408, "transient"],
        "409": [409, "permanent"],
        "422": [422, "permanent"],
        "429": [429, "transient"],
        "500": [500, "transient"],
        "503": [503, "transient"]
    };
}

@test:Config {dataProvider: statusCases}
function classifyStatusMapsCodes(int statusCode, string expected) {
    ProcessingError? result = classifyStatus(statusCode, "c");
    string actual = result is () ? "success" : result is TransientError ? "transient" : "permanent";
    test:assertEquals(actual, expected);
}
