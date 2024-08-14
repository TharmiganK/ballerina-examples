import ballerina/http;
import ballerina/http.httpscerr;
import ballerina/mime;

service class DefaultResponseInterceptor {
    *http:ResponseInterceptor;

    isolated remote function interceptResponse(http:Response res) returns http:Response|error {
        res.setHeader("API-Version", "v1.0.0");
        return processJsonPayload(res);
    }
}

service class DefaultRequestInterceptor {
    *http:RequestInterceptor;

    isolated resource function 'default [string... path](http:RequestContext ctx,
            @http:Header string? API\-Version) returns http:NextService|error? {
        if API\-Version is string && API\-Version != "v1.0.0" {
            return error httpscerr:NotImplementedError("API version is not supported",
                body = {
                "message": string `API version ${API\-Version} is not supported`,
                "timestamp": getCurrentTimeStamp()
            }
            );
        }
        return ctx.next();
    }
}

service class DefaultResponseErrorInterceptor {
    *http:ResponseErrorInterceptor;

    remote function interceptResponseError(error err) returns error {
        return error httpscerr:DefaultStatusCodeError("Default error", err, body = {
            message: err.message(),
            timestamp: "2021-01-01T00:00:00.000Z"
        });
    }
}

service class ServiceRequestInterceptor {
    *http:RequestInterceptor;

    resource function 'default [string... path](http:RequestContext ctx,
            http:Request req) returns http:NextService|error? {
        if req.hasHeader("Content-Type") && req.getContentType() != mime:APPLICATION_JSON {
            return error httpscerr:UnsupportedMediaTypeError("Content-Type is not supported",
                body = {
                "message": "Only application/json is supported",
                "timestamp": getCurrentTimeStamp()
            });
        }
        return ctx.next();
    }
}
